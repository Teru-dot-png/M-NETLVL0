-- /onet/turtle/nav.lua
-- THE pathfinder. CORE — ported verbatim from the debugged V1 implementation;
-- only module boundaries changed (calibration moved to calibrate.lua, coord
-- helpers to vec, logging to log). Greedy axis step -> A* detour -> recovery
-- spiral -> climb-over, with pos-compare stuck detection, move reservations,
-- a PUSH_REQ on stall, and random GPS resync. Do not "clean this up": every
-- branch is here because of a specific failure mode that is no longer visible.

local cfg       = require("config")
local state     = require("state")
local cache     = require("cache")
local movers    = require("movers")
local scanner   = require("scanner")
local calibrate = require("calibrate")
local vec       = require("vec")
local log       = require("log").log

local M = {}

-- ── Recent-tile tracking (path cost penalty) ─────────────
local function noteRecentTile(p)
    if type(p) ~= "table" then return end
    state.recent_tiles[state.recent_tile_index] = { x = p.x, y = p.y, z = p.z }
    state.recent_tile_index = (state.recent_tile_index % state.RECENT_TILE_WINDOW) + 1
end

local function recentPenalty(x, y, z)
    local hits = 0
    for _, p in pairs(state.recent_tiles) do
        if p and p.x == x and p.y == y and p.z == z then hits = hits + 1 end
    end
    return hits * 1.5
end

-- ── Nav cost (unknown=4, air=1, stone=8, protected=nil) ──
local function navCost(nx, ny, nz)
    local name = cache.cacheGet(nx, ny, nz)
    if name == nil             then return 4 end
    if movers.isPassable(name) then return 1 end
    if movers.isDiggable(name) then return 8 end
    return nil
end

-- ── Min-heap ─────────────────────────────────────────────
local function newHeap() return { n = 0 } end
local function heapPush(h, node, pri)
    local i = h.n + 1; h.n = i; h[i] = { node = node, p = pri }
    while i > 1 do
        local p = math.floor(i / 2)
        if h[p].p > h[i].p then h[p], h[i] = h[i], h[p]; i = p else break end
    end
end
local function heapPop(h)
    if h.n == 0 then return nil end
    local top = h[1].node; h[1] = h[h.n]; h[h.n] = nil; h.n = h.n - 1
    local i = 1
    while true do
        local l, r, s = i * 2, i * 2 + 1, i
        if l <= h.n and h[l].p < h[s].p then s = l end
        if r <= h.n and h[r].p < h[s].p then s = r end
        if s == i then break end
        h[i], h[s] = h[s], h[i]; i = s
    end
    return top
end

-- ── A* short-range detour ────────────────────────────────
local function astarLocal(start, goal, node_budget)
    local function h(n)
        return math.abs(n.x - goal.x) + math.abs(n.y - goal.y) + math.abs(n.z - goal.z)
    end
    local open = newHeap(); local g_cost, came = {}, {}
    g_cost[vec.key(start)] = 0
    heapPush(open, { x = start.x, y = start.y, z = start.z, dir = nil }, h(start))
    local budget = math.max(128, tonumber(node_budget) or 512)
    local exp = 0
    while open.n > 0 do
        local cur = heapPop(open); local ck = vec.key(cur); exp = exp + 1
        if exp > budget then return nil end
        if cur.x == goal.x and cur.y == goal.y and cur.z == goal.z then
            local path, k = {}, ck
            while came[k] do table.insert(path, 1, came[k].step); k = came[k].pk end
            return path
        end
        local g = g_cost[ck]
        for _, nb in ipairs(vec.DIRS6) do
            local nx, ny, nz = cur.x + nb.dx, cur.y + nb.dy, cur.z + nb.dz
            local nc = navCost(nx, ny, nz)
            if nc then
                local turn_pen = 0
                if nb.dy ~= 0 then turn_pen = turn_pen + 0.8 end
                if cur.dir and cur.dir >= 0 and nb.dir >= 0 and cur.dir ~= nb.dir then
                    turn_pen = turn_pen + 0.4
                end
                local nk = nx .. ":" .. ny .. ":" .. nz
                local ng = g + nc + turn_pen + recentPenalty(nx, ny, nz)
                if not g_cost[nk] or ng < g_cost[nk] then
                    g_cost[nk] = ng
                    came[nk] = { pk = ck, step = { dx = nb.dx, dy = nb.dy, dz = nb.dz, dir = nb.dir } }
                    heapPush(open, { x = nx, y = ny, z = nz, dir = nb.dir }, ng + h({ x = nx, y = ny, z = nz }))
                end
            end
        end
    end
    return nil
end

local function executeDetour(path)
    for _, step in ipairs(path) do
        local ok
        if     step.dy ==  1 then ok = movers.stepUp()
        elseif step.dy == -1 then ok = movers.stepDown()
        else movers.face(step.dir); ok = movers.stepForward() end
        if not ok then return false end
        noteRecentTile(state.pos)
        sleep(0)
    end
    return true
end

local function adaptiveAStarBudget(start, goal, detours)
    local dist = math.abs(start.x - goal.x) + math.abs(start.y - goal.y) + math.abs(start.z - goal.z)
    local stuck = tonumber(state.nav_stuck_cnt) or 0
    local b = dist * 18 + (tonumber(detours) or 0) * 128 + stuck * 96
    if b < 256  then b = 256  end
    if b > 2048 then b = 2048 end
    return math.floor(b)
end

-- ── Move reservation (overseer coordination) ─────────────
function M.requestMoveReservation(target)
    if not state.server_id or type(target) ~= "table" then return true end
    state.reservation_nonce = state.reservation_nonce + 1
    local nonce = state.reservation_nonce
    state.reservation_pending[nonce] = { done = false, granted = false }
    pcall(rednet.send, state.server_id, {
        type   = "RESERVE_REQ",
        hwid   = state.hwid,
        nonce  = nonce,
        want   = target,
        ttl_ms = cfg.RESERVE_TTL_MS,
    }, cfg.PROTOCOL)
    local deadline = os.epoch("utc") + cfg.RESERVE_WAIT_MS
    while os.epoch("utc") < deadline do
        local st = state.reservation_pending[nonce]
        if st and st.done then
            state.reservation_pending[nonce] = nil
            return st.granted == true
        end
        sleep(0.05)
    end
    state.reservation_pending[nonce] = nil
    return true  -- fail open: laggy comms must not freeze movement
end

function M.releaseMoveReservation(target)
    if not state.server_id or type(target) ~= "table" then return end
    pcall(rednet.send, state.server_id, {
        type = "RESERVE_REL",
        hwid = state.hwid,
        want = target,
    }, cfg.PROTOCOL)
end

-- ── Greedy single step ────────────────────────────────────
local function greedyStep(goal)
    if state.pos.x == goal.x and state.pos.y == goal.y and state.pos.z == goal.z then
        return "arrived"
    end
    state.nav_last_want = nil
    local pos  = state.pos
    local DIRV = vec.DIRV
    local dx, dy, dz = goal.x - pos.x, goal.y - pos.y, goal.z - pos.z
    local axes = {
        { math.abs(dx), dx ~= 0 and (dx > 0 and 1 or 3) or nil, "h" },
        { math.abs(dz), dz ~= 0 and (dz > 0 and 2 or 0) or nil, "h" },
        { math.abs(dy), nil, dy > 0 and "u" or "d" },
    }
    table.sort(axes, function(a, b) return a[1] > b[1] end)
    for _, ax in ipairs(axes) do
        if ax[1] > 0 then
            if ax[3] == "u" then
                local target = { x = pos.x, y = pos.y + 1, z = pos.z }
                state.nav_last_want = target
                if M.requestMoveReservation(target) then
                    local ok = movers.stepUp()
                    M.releaseMoveReservation(target)
                    if ok then return "moved" end
                end
            elseif ax[3] == "d" then
                local target = { x = pos.x, y = pos.y - 1, z = pos.z }
                state.nav_last_want = target
                if M.requestMoveReservation(target) then
                    local ok = movers.stepDown()
                    M.releaseMoveReservation(target)
                    if ok then return "moved" end
                end
            else
                movers.face(ax[2])
                local target = {
                    x = pos.x + DIRV[state.facing].dx,
                    y = pos.y,
                    z = pos.z + DIRV[state.facing].dz,
                }
                state.nav_last_want = target
                local ok_i, dat_i = turtle.inspect()
                if ok_i and type(dat_i) == "table" then
                    local name = dat_i.name or ""
                    cache.cacheSet(pos.x + DIRV[state.facing].dx, pos.y, pos.z + DIRV[state.facing].dz, name)
                    if not movers.isPassable(name) and not movers.isDiggable(name) then
                        log("NAV", "Protected [" .. name .. "] on axis. Skipping.")
                        goto continue
                    end
                end
                if M.requestMoveReservation(target) then
                    local ok = movers.stepForward()
                    M.releaseMoveReservation(target)
                    if ok then return "moved" end
                end
            end
        end
        ::continue::
    end
    return "stuck"
end

-- ── Recovery spiral ───────────────────────────────────────
local function recoverSpiral(goal)
    log("NAV", "Running recovery spiral...")
    local function dist(p)
        return math.abs(p.x - goal.x) + math.abs(p.y - goal.y) + math.abs(p.z - goal.z)
    end
    local pos = state.pos
    local dirs = {
        function() movers.face(0); return movers.stepForward() end,
        function() movers.face(1); return movers.stepForward() end,
        function() movers.face(2); return movers.stepForward() end,
        function() movers.face(3); return movers.stepForward() end,
        function() return movers.stepUp()   end,
        function() return movers.stepDown() end,
    }
    local nbpos = {
        { x = pos.x,     y = pos.y,     z = pos.z - 1 },
        { x = pos.x + 1, y = pos.y,     z = pos.z     },
        { x = pos.x,     y = pos.y,     z = pos.z + 1 },
        { x = pos.x - 1, y = pos.y,     z = pos.z     },
        { x = pos.x,     y = pos.y + 1, z = pos.z     },
        { x = pos.x,     y = pos.y - 1, z = pos.z     },
    }
    local candidates = {}
    for i = 1, 6 do candidates[i] = { i = i, d = dist(nbpos[i]) } end
    table.sort(candidates, function(a, b) return a.d < b.d end)
    for _, c in ipairs(candidates) do
        if dirs[c.i]() then
            log("NAV", string.format("Spiral moved. Now at (%d,%d,%d).",
                state.pos.x, state.pos.y, state.pos.z))
            return true
        end
    end
    log("NAV", "All 6 blocked. Attempting climb-over...")
    if movers.stepUp() then
        for dir = 0, 3 do
            movers.face(dir)
            if movers.stepForward() then return true end
        end
        movers.stepDown()
    end
    log("NAV", "Spiral and climb-over both failed.")
    return false
end

-- ── Waypoint splitting (32-block legs) ───────────────────
local function waypointsTo(goal)
    local pos = state.pos
    local total = math.abs(pos.x - goal.x) + math.abs(pos.y - goal.y) + math.abs(pos.z - goal.z)
    if total <= cfg.WAYPOINT_DIST then return { goal } end
    local waypoints = {}
    local steps = math.ceil(total / cfg.WAYPOINT_DIST)
    for i = 1, steps do
        local t = i / steps
        waypoints[i] = {
            x = math.floor(pos.x + (goal.x - pos.x) * t + 0.5),
            y = math.floor(pos.y + (goal.y - pos.y) * t + 0.5),
            z = math.floor(pos.z + (goal.z - pos.z) * t + 0.5),
        }
    end
    waypoints[#waypoints] = goal
    return waypoints
end

-- ── Main moveTo ───────────────────────────────────────────
function M.moveTo(goal)
    if state.pos.x == goal.x and state.pos.y == goal.y and state.pos.z == goal.z then return true end
    if state.block_movement then state.block_movement = false; return false end

    local total_dist = math.abs(state.pos.x - goal.x) + math.abs(state.pos.y - goal.y) + math.abs(state.pos.z - goal.z)
    log("NAV", string.format("Nav to (%d,%d,%d) from (%d,%d,%d) [%d blocks]",
        goal.x, goal.y, goal.z, state.pos.x, state.pos.y, state.pos.z, total_dist))

    local waypoints   = waypointsTo(goal)
    local MAX_DETOURS = 6
    state.nav_prev_pos = vec.copy(state.pos)

    for wp_i, wp in ipairs(waypoints) do
        if #waypoints > 1 then
            log("NAV", string.format("Leg %d/%d -> (%d,%d,%d)", wp_i, #waypoints, wp.x, wp.y, wp.z))
        end
        local detours = 0

        while state.pos.x ~= wp.x or state.pos.y ~= wp.y or state.pos.z ~= wp.z do
            if state.home_requested then
                state.nav_stuck_cnt = 0; state.nav_prev_pos = nil; return false
            end

            local before = state.nav_prev_pos or vec.copy(state.pos)
            cache.liveInspect()
            local result = greedyStep(wp)

            if result == "arrived" then
                state.nav_stuck_cnt = 0; state.nav_prev_pos = vec.copy(state.pos); break
            end

            local after = vec.copy(state.pos)
            if after.x ~= before.x or after.y ~= before.y or after.z ~= before.z then
                state.nav_stuck_cnt = 0
                state.nav_prev_pos  = after
                noteRecentTile(after)
                if math.random() < 0.15 then calibrate.gpsSyncPos() end
                sleep(0)
            else
                state.nav_stuck_cnt = state.nav_stuck_cnt + 1
                state.nav_prev_pos  = after
                log("NAV", string.format("Stuck %d/%d at (%d,%d,%d) -> (%d,%d,%d)",
                    state.nav_stuck_cnt, cfg.STUCK_VALUE,
                    state.pos.x, state.pos.y, state.pos.z, wp.x, wp.y, wp.z))

                if state.nav_stuck_cnt >= cfg.STUCK_VALUE then
                    state.nav_stuck_cnt = 0
                    detours = detours + 1

                    -- PUSH_REQ: announce our priority so a lower-urgency turtle
                    -- on the target tile yields before we waste a spiral.
                    local target = state.nav_last_want
                    if not target then
                        local ddx = wp.x - state.pos.x
                        local ddy = wp.y - state.pos.y
                        local ddz = wp.z - state.pos.z
                        if math.abs(ddx) >= math.abs(ddz) and math.abs(ddx) >= math.abs(ddy) and ddx ~= 0 then
                            target = { x = state.pos.x + (ddx > 0 and 1 or -1), y = state.pos.y, z = state.pos.z }
                        elseif math.abs(ddz) >= math.abs(ddy) and ddz ~= 0 then
                            target = { x = state.pos.x, y = state.pos.y, z = state.pos.z + (ddz > 0 and 1 or -1) }
                        elseif ddy ~= 0 then
                            target = { x = state.pos.x, y = state.pos.y + (ddy > 0 and 1 or -1), z = state.pos.z }
                        end
                    end
                    pcall(rednet.broadcast, {
                        type     = "PUSH_REQ",
                        hwid     = state.hwid,
                        priority = cfg.PRIORITY[state.current_state] or 10,
                        at       = vec.copy(state.pos),
                        want     = target,
                    }, cfg.PROTOCOL)
                    sleep(0.4)

                    local snap = scanner.scanAround()
                    if snap and #snap > 0 then cache.feedCache(snap, state.pos) end

                    local budget = adaptiveAStarBudget(state.pos, wp, detours)
                    local path   = astarLocal(state.pos, wp, budget)
                    if path and #path > 0 then
                        log("NAV", "A* detour: " .. (#path) .. " steps (budget=" .. budget .. ").")
                        if not executeDetour(path) then log("NAV", "Detour execution failed.") end
                    else
                        log("NAV", "A* no path (budget=" .. budget .. "). Trying spiral.")
                        if not recoverSpiral(wp) then
                            if detours >= MAX_DETOURS then
                                log("NAV", "All recovery exhausted. Reporting STUCK.")
                                pcall(rednet.send, state.server_id, {
                                    type = "ALERT",
                                    hwid = state.hwid,
                                    msg  = string.format("STUCK (%d,%d,%d)->(%d,%d,%d)",
                                        state.pos.x, state.pos.y, state.pos.z,
                                        goal.x, goal.y, goal.z),
                                    pos  = vec.copy(state.pos),
                                }, cfg.PROTOCOL)
                                state.nav_stuck_cnt = 0; state.nav_prev_pos = nil
                                return false
                            end
                            sleep(2)
                        end
                    end
                else
                    sleep(0.3)
                end
            end
        end
    end

    local arrived = state.pos.x == goal.x and state.pos.y == goal.y and state.pos.z == goal.z
    if arrived then
        state.nav_stuck_cnt = 0; state.nav_prev_pos = nil
        log("NAV", string.format("Arrived at (%d,%d,%d).", goal.x, goal.y, goal.z))
    end
    return arrived
end

return M
