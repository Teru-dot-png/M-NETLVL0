-- /onet/overseer/orders.lua
-- getme order handling + ore-cluster dispatch. CORE: mergeOrCluster collapses a
-- swarm of individual ore voxels into one running-average centroid so we send
-- ONE turtle to a vein instead of forty turtles to forty blocks. Port the math
-- exactly — it's the difference between a fleet and a mob.

local cfg     = require("config")
local state   = require("state")
local fleet   = require("fleet")
local voxelmap= require("voxelmap")
local blocks  = require("blocks")
local log     = require("log").log

local M = {}
local floor = math.floor

-- ── Live ore feed (display ring buffer) ───────────────────
function M.pushOreFeed(ore, hwid, x, y, z)
    table.insert(state.ORE_FEED, { time = os.date("%H:%M"), ore = ore, hwid = hwid, x = x, y = y, z = z })
    if #state.ORE_FEED > cfg.ORE_FEED_MAX then table.remove(state.ORE_FEED, 1) end
end

-- ── Running-average centroid clustering (CORE) ────────────
function M.mergeOrCluster(ore, x, y, z)
    for _, cl in ipairs(state.clusters) do
        if cl.ore == ore then
            local d = math.abs(x - cl.cx) + math.abs(y - cl.cy) + math.abs(z - cl.cz)
            if d <= cfg.CLUSTER_RADIUS then
                cl.count = cl.count + 1
                cl.cx = floor((cl.cx * (cl.count - 1) + x) / cl.count + 0.5)
                cl.cy = floor((cl.cy * (cl.count - 1) + y) / cl.count + 0.5)
                cl.cz = floor((cl.cz * (cl.count - 1) + z) / cl.count + 0.5)
                return cl
            end
        end
    end
    local cl = { ore = ore, cx = x, cy = y, cz = z, count = 1, dispatched = false }
    state.clusters[#state.clusters + 1] = cl
    return cl
end

-- ── ORE_REPORT handler ────────────────────────────────────
function M.handleOreReport(msg)
    if type(msg.ore) ~= "string" or type(msg.pos) ~= "table" then return end
    local ore = blocks.normalizeOreName(msg.ore)
    local x, y, z = floor(msg.pos.x or 0), floor(msg.pos.y or 0), floor(msg.pos.z or 0)
    state.ore_log[ore] = (state.ore_log[ore] or 0) + 1
    M.pushOreFeed(ore, msg.hwid, x, y, z)

    if state.WANT_LIST[ore] then
        local cl = M.mergeOrCluster(ore, x, y, z)
        if not cl.dispatched then
            cl.dispatched = true
            local target = fleet.nearestIdle(cl.cx, cl.cy, cl.cz, nil)
            local f = target and state.fleet[target]
            if f then
                rednet.send(f.net_id, {
                    type = "GOTO", hwid = target, ore = ore,
                    pos = { x = cl.cx, y = cl.cy, z = cl.cz },
                }, cfg.PROTOCOL)
                log("OVERSEER", string.format("%s -> GOTO %s cluster(%d,%d,%d) n=%d",
                    target, ore, cl.cx, cl.cy, cl.cz, cl.count))
            end
        end
    end
end

-- ── ORE_MINED handler ─────────────────────────────────────
function M.handleOreMined(msg)
    local ore = tostring(msg.ore or "")
    local k = msg.pos and (floor(msg.pos.x)..":"..floor(msg.pos.y)..":"..floor(msg.pos.z)) or ""

    for order_ore, order in pairs(state.active_orders) do
        if ore:find(order_ore, 1, true) or order_ore:find(ore, 1, true) then
            if order.jobs[k] then
                order.jobs[k] = nil
                order.got = order.got + 1
                log("OVERSEER", string.format("getme %s: %d/%d", order_ore, order.got, order.target))
            end
        end
    end
    -- Allow re-dispatch of that area.
    if msg.pos then
        local px, py, pz = floor(msg.pos.x or 0), floor(msg.pos.y or 0), floor(msg.pos.z or 0)
        for _, cl in ipairs(state.clusters) do
            if cl.ore == ore then
                local d = math.abs(px - cl.cx) + math.abs(py - cl.cy) + math.abs(pz - cl.cz)
                if d <= cfg.CLUSTER_RADIUS then cl.dispatched = false end
            end
        end
    end
end

-- ── getme command ─────────────────────────────────────────
function M.countInDump(ore)
    if not state.vault then return 0 end
    local ok, list = pcall(state.vault.list, state.vault)
    if not ok or type(list) ~= "table" then return 0 end
    local total = 0
    for _, item in pairs(list) do
        local n = tostring(item.name or "")
        if n:find(ore, 1, true) then total = total + item.count end
    end
    return total
end

function M.startGetme(ore, target)
    ore = blocks.normalizeOreName(tostring(ore or ""))
    target = tonumber(target)
    if ore == "" or not target or target <= 0 then return false, "Usage: getme <ore> <count>" end
    state.active_orders[ore] = { target = target, got = 0, jobs = {} }
    local have = M.countInDump(ore)
    local on_map = #voxelmap.findOreInMap(ore, nil)
    log("OVERSEER", string.format("getme %s x%d. dump=%d map=%d", ore, target, have, on_map))
    if have >= target then state.active_orders[ore] = nil end
    return true
end

-- ── Order-driver thread: dispatch SEARCH_JOBs to nearest idle turtles ──
function M.orderThread()
    while true do
        sleep(3)
        for ore, order in pairs(state.active_orders) do
            local have = math.max(order.got, M.countInDump(ore))
            if have >= order.target then
                log("OVERSEER", "getme " .. ore .. " COMPLETE.")
                state.active_orders[ore] = nil
            else
                local pending = 0
                for _ in pairs(order.jobs) do pending = pending + 1 end
                local slots = (order.target - have) - pending
                if slots > 0 then
                    local ref = { x = state.view_cx, y = state.view_y, z = state.view_cz }
                    local locs = voxelmap.findOreInMap(ore, ref)
                    local sent = 0
                    for _, loc in ipairs(locs) do
                        if sent >= slots then break end
                        local lk = loc.x..":"..loc.y..":"..loc.z
                        if not order.jobs[lk] then
                            local target = fleet.nearestIdle(loc.x, loc.y, loc.z, nil)
                            local f = target and state.fleet[target]
                            if f then
                                rednet.send(f.net_id, {
                                    type = "SEARCH_JOB", hwid = target, ore = ore,
                                    pos = { x = loc.x, y = loc.y, z = loc.z }, amount = order.target,
                                }, cfg.PROTOCOL)
                                order.jobs[lk] = true
                                sent = sent + 1
                            end
                        end
                    end
                end
            end
        end
    end
end

return M
