-- /onet/overseer/zones.lua
-- Storage-zone registry (§6). Tracks the chest coordinate and last-known
-- contents for each of the four zones. Classification of WHAT goes where lives
-- in lib/blocks.zoneFor so Hauler (sorting) and the overseer (fill display)
-- agree exactly.

local cfg    = require("config")
local state  = require("state")
local blocks = require("blocks")
local log    = require("log").log

local M = {}

function M.setChest(zone, pos)
    if not state.zones[zone] then return false, "Unknown zone: " .. tostring(zone) end
    state.zones[zone].chest = { x = pos.x, y = pos.y, z = pos.z }
    log("OVERSEER", string.format("Zone %s chest -> (%d,%d,%d)", zone, pos.x, pos.y, pos.z))
    return true
end

-- A builder broadcasts its placed layout; record chest positions per zone.
function M.ingestZoneMap(msg)
    if type(msg.zones) ~= "table" then return end
    for zone, pos in pairs(msg.zones) do
        if state.zones[zone] and type(pos) == "table" then
            state.zones[zone].chest = { x = pos.x, y = pos.y, z = pos.z }
        end
    end
    log("OVERSEER", "Zone map updated from builder " .. tostring(msg.hwid))
end

-- Which zone does an item belong to?
function M.zoneFor(item_name) return blocks.zoneFor(item_name) end

-- Return the chest coord a hauler should deliver an item to (nil if unset).
function M.chestFor(item_name)
    local z = blocks.zoneFor(item_name)
    return state.zones[z] and state.zones[z].chest, z
end

-- Snapshot of zone fill for the cockpit.
function M.fillSnapshot()
    local out = {}
    for _, zone in ipairs(cfg.ZONES) do
        local z = state.zones[zone]
        local n = 0
        if z and z.contents then for _, c in pairs(z.contents) do n = n + c end end
        out[zone] = { chest = z and z.chest, total = n }
    end
    return out
end

return M
