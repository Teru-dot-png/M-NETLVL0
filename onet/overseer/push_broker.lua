-- /onet/overseer/push_broker.lua
-- PUSH_REQ broker. CORE — this is where the overseer ARBITRATES which turtle
-- yields, by comparing move priorities. The hardest coordination problem in the
-- system, ~20 lines. A stuck pusher broadcasts its target tile + priority; we
-- find whoever is sitting there and, if that blocker is equal-or-lower urgency,
-- send it a direct YIELD. Lower priority number = higher urgency (never yields).

local cfg   = require("config")
local state = require("state")
local log   = require("log").log

local M = {}
local floor = math.floor

function M.handlePushReq(sender, msg)
    local pusher = tostring(msg.hwid or "")
    local want   = msg.want
    if type(want) ~= "table" then return end
    local tx, ty, tz = floor(want.x or 0), floor(want.y or 0), floor(want.z or 0)
    local pusher_pri = tonumber(msg.priority) or 10

    -- Who is on the target tile?
    for hwid, f in pairs(state.fleet) do
        if hwid ~= pusher and f.pos then
            if floor(f.pos.x or 0) == tx and floor(f.pos.y or 0) == ty and floor(f.pos.z or 0) == tz then
                local blocker_pri = cfg.PRIORITY[tostring(f.status or ""):upper()] or 10
                -- Blocker yields only if it is NOT more urgent than the pusher.
                if blocker_pri >= pusher_pri then
                    rednet.send(f.net_id, { type = "YIELD", hwid = hwid, pusher = pusher }, cfg.PROTOCOL)
                    log("PUSH", string.format("%s (pri %d) yields to %s (pri %d)",
                        hwid, blocker_pri, pusher, pusher_pri))
                end
                return
            end
        end
    end
end

return M
