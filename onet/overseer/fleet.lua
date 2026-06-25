-- /onet/overseer/fleet.lua
-- Fleet roster: enlist, heartbeat tracking, live count, loss detection
-- (LOSS_TIMEOUT of silence => dead). Also view-centre tracking + supply query.

local cfg   = require("config")
local state = require("state")
local log   = require("log").log

local M = {}
local floor = math.floor

function M.enlist(hwid, net_id, msg)
    local f = state.fleet[hwid]
    if not f then
        f = {
            net_id     = net_id,
            role       = msg.role or cfg.ROLES.MINER,
            status     = "STANDBY",
            pos        = msg.pos,
            dir        = 0,
            fuel       = msg.fuel or 0,
            free       = msg.free or cfg.CARGO_COUNT,
            crafty     = msg.crafty == true,
            last_pulse = os.epoch("utc"),
        }
        state.fleet[hwid] = f
        log("OVERSEER", "Enlisted " .. hwid .. " (crafty=" .. tostring(f.crafty) .. ")")
    else
        f.net_id = net_id
        f.last_pulse = os.epoch("utc")
        if msg.pos then f.pos = msg.pos end
    end
    return f
end

function M.updateFromHeartbeat(hwid, net_id, msg)
    local f = state.fleet[hwid]
    if not f then return nil end
    f.net_id     = net_id
    f.last_pulse = os.epoch("utc")
    if msg.fuel   then f.fuel   = msg.fuel   end
    if msg.free   then f.free   = msg.free   end
    if msg.pos    then f.pos    = msg.pos    end
    if msg.status then f.status = msg.status end
    if msg.dir    then f.dir    = msg.dir    end
    if msg.role   then f.role   = msg.role   end
    return f
end

function M.count()
    local n = 0
    for _ in pairs(state.fleet) do n = n + 1 end
    return n
end

-- Live (non-dead) count for population logic.
function M.liveCount()
    local now, n = os.epoch("utc"), 0
    for _, f in pairs(state.fleet) do
        if (now - (f.last_pulse or 0)) <= cfg.LOSS_TIMEOUT then n = n + 1 end
    end
    return n
end

function M.snapshot()
    local out = {}
    for hwid, f in pairs(state.fleet) do
        local p = f.pos or { x = 0, y = 0, z = 0 }
        out[#out + 1] = {
            hwid = hwid, role = f.role,
            status = tostring(f.status or "?"):upper(),
            fuel = f.fuel, free = f.free,
            pos = { x = p.x or 0, y = p.y or 0, z = p.z or 0 },
        }
    end
    table.sort(out, function(a, b) return tostring(a.hwid) < tostring(b.hwid) end)
    return out
end

-- Nearest turtle in an idle-ish state (for ore/getme dispatch).
function M.nearestIdle(x, y, z, exclude)
    local best, best_d = nil, math.huge
    for hwid, f in pairs(state.fleet) do
        if hwid ~= exclude and f.pos then
            local st = tostring(f.status or ""):upper()
            if st == "MINING" or st == "STANDBY" or st == "PARKED" then
                local d = math.abs(f.pos.x - x) + math.abs(f.pos.y - y) + math.abs(f.pos.z - z)
                if d < best_d then best_d = d; best = hwid end
            end
        end
    end
    return best
end

-- Remove turtles silent past LOSS_TIMEOUT; returns list of lost hwids so the
-- director can release their reservations/park claims and trigger replacement.
function M.pruneLost()
    local now, lost = os.epoch("utc"), {}
    for hwid, f in pairs(state.fleet) do
        if (now - (f.last_pulse or 0)) > cfg.LOSS_TIMEOUT then
            lost[#lost + 1] = hwid
            state.fleet[hwid] = nil
            log("ALERT", "Lost " .. hwid .. " (silent " .. floor((now - (f.last_pulse or 0)) / 1000) .. "s)")
        end
    end
    return lost
end

function M.updateViewCenter()
    local n, sx, sz, sy = 0, 0, 0, 0
    for _, f in pairs(state.fleet) do
        if f.pos then
            sx = sx + floor(f.pos.x or 0); sz = sz + floor(f.pos.z or 0)
            sy = sy + floor(f.pos.y or 64); n = n + 1
        end
    end
    if n > 0 then
        state.view_cx = floor(sx / n); state.view_cz = floor(sz / n); state.view_y = floor(sy / n)
    end
end

function M.checkSupplies()
    if not state.vault then return {} end
    local ok, list = pcall(state.vault.list, state.vault)
    if not ok or type(list) ~= "table" then return {} end
    local tally = {}
    for _, item in pairs(list) do
        local n = item.name:match(":(.+)") or item.name
        tally[n] = (tally[n] or 0) + item.count
    end
    return tally
end

return M
