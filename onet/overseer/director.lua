-- /onet/overseer/director.lua
-- Event-driven coordination (Overmind Directive layer). Owns the rednet
-- listener and dispatches every message type to the right subsystem. Reacts to
-- events (ore found, fuel query, segment request, turtle lost) rather than
-- polling. Also assigns roles on enlist and runs the pruner.

local cfg      = require("config")
local state    = require("state")
local fleet    = require("fleet")
local gridmap  = require("gridmap")
local park     = require("park")
local voxelmap = require("voxelmap")
local orders   = require("orders")
local zones    = require("zones")
local population= require("population")
local push     = require("push_broker")
local persist  = require("persist")
local vec      = require("vec")
local log      = require("log").log

local M = {}
local floor = math.floor

-- ── Reservations ──────────────────────────────────────────
local function reserveKey(x, y, z) return floor(x)..":"..floor(y)..":"..floor(z) end

function M.expireReservations()
    local now = os.epoch("utc")
    for k, v in pairs(state.reservations) do
        if (now - (v.ts or 0)) > cfg.RESERVE_TTL_MS then state.reservations[k] = nil end
    end
end

local function clearReservationsFor(hwid)
    for k, v in pairs(state.reservations) do
        if v.hwid == hwid then state.reservations[k] = nil end
    end
end

-- ── Role decision on enlist ───────────────────────────────
-- First crafty turtle becomes the Genesis seed; everyone else mines until the
-- director reassigns them (operator or future auto-balancing).
local function decideRole(hwid, f)
    if f.crafty and not state.genesis_hwid then
        state.genesis_hwid = hwid
        return cfg.ROLES.GENESIS
    end
    return cfg.ROLES.MINER
end

-- ── Handlers ──────────────────────────────────────────────
local function handleAuthReq(sender, msg)
    local hwid = tostring(msg.hwid or sender)
    local f = fleet.enlist(hwid, sender, msg)
    if f.dir == nil or state.zone_assigned ~= true then
        local dir, offset = gridmap.assignLane(hwid)
        f.dir = dir; f.lane_offset = offset
    end
    f.role = decideRole(hwid, f)
    local park_pos = park.assignUnclaimedSlot(hwid, f.pos)
    rednet.send(sender, {
        type        = "AUTH_ACK",
        hwid        = hwid,
        dir         = f.dir,
        lane_offset = f.lane_offset,
        base        = state.BASE_CHEST,
        dump        = state.DUMP_CHEST,
        park_pos    = park_pos,
        want_list   = state.WANT_LIST,
        overseer_pos= state.overseer_pos,
        zone_chests = (function() local z = {} for k, r in pairs(state.zones) do z[k] = r.chest end return z end)(),
        role        = f.role,
    }, cfg.PROTOCOL)
    population.tick()
end

local function handleSegmentReq(sender, msg)
    local hwid = tostring(msg.hwid or sender)
    local seg = gridmap.nextSegment(hwid)
    if seg then
        rednet.send(sender, { type = "SEGMENT_GRANT", hwid = hwid, segment = seg }, cfg.PROTOCOL)
    end
end

local function handleParkReq(sender, msg)
    local hwid = tostring(msg.hwid or sender)
    local f = state.fleet[hwid]
    local pos = park.assignUnclaimedSlot(hwid, f and f.pos)
    if not pos then pos = park.getSlot(state.fleet_slot); state.fleet_slot = state.fleet_slot + 1 end
    rednet.send(sender, { type = "PARK_ASSIGN", hwid = hwid, pos = pos, nonce = msg.nonce }, cfg.PROTOCOL)
end

local function handleReserveReq(sender, msg)
    local hwid = tostring(msg.hwid or sender)
    local w = msg.want or {}
    local x, y, z = floor(w.x or 0), floor(w.y or 0), floor(w.z or 0)
    local k = reserveKey(x, y, z)
    local now = os.epoch("utc")
    local granted = false
    local ex = state.reservations[k]
    if not ex or ex.hwid == hwid or (now - (ex.ts or 0)) > cfg.RESERVE_TTL_MS then
        granted = true
        state.reservations[k] = { hwid = hwid, ts = now }
    end
    rednet.send(sender, { type = "RESERVE_ACK", hwid = hwid, nonce = msg.nonce, granted = granted }, cfg.PROTOCOL)
end

local function handleReserveRel(sender, msg)
    local hwid = tostring(msg.hwid or sender)
    local w = msg.want or {}
    local k = reserveKey(w.x or 0, w.y or 0, w.z or 0)
    local r = state.reservations[k]
    if r and r.hwid == hwid then state.reservations[k] = nil end
end

local function handleCoalQuery(sender, msg)
    local hwid = tostring(msg.hwid or sender)
    local ref = msg.pos or state.overseer_pos or { x = 0, y = 0, z = 0 }
    local coal = voxelmap.findOreInMap("coal_ore", ref)
    local pos = coal[1]
    rednet.send(sender, { type = "COAL_LOC", hwid = hwid, pos = pos and { x = pos.x, y = pos.y, z = pos.z } or nil }, cfg.PROTOCOL)
end

local function handlePickQuery(sender, msg)
    local hwid = tostring(msg.hwid or sender)
    local available = true  -- optimistic; base chest is operator-stocked
    rednet.send(sender, { type = "PICK_ANSWER", hwid = hwid, available = available }, cfg.PROTOCOL)
end

-- ── Listener thread ───────────────────────────────────────
function M.listenerThread()
    while true do
        local sender, msg = rednet.receive(cfg.PROTOCOL, 5)
        if type(msg) == "table" then
            local t = tostring(msg.type or "")
            if     t == "AUTH_REQ"     then handleAuthReq(sender, msg)
            elseif t == "HEARTBEAT"    then fleet.updateFromHeartbeat(tostring(msg.hwid or sender), sender, msg)
            elseif t == "GEO_DATA"     then voxelmap.ingestGeoData(msg)
            elseif t == "ORE_REPORT"   then orders.handleOreReport(msg)
            elseif t == "ORE_MINED"    then orders.handleOreMined(msg); if msg.seg then gridmap.markMined(msg.seg) end
            elseif t == "SEGMENT_REQ"  then handleSegmentReq(sender, msg)
            elseif t == "PARK_REQ"     then handleParkReq(sender, msg)
            elseif t == "PARK_RELEASE" then park.clearParkClaim(tostring(msg.hwid or sender))
            elseif t == "RESERVE_REQ"  then handleReserveReq(sender, msg)
            elseif t == "RESERVE_REL"  then handleReserveRel(sender, msg)
            elseif t == "COAL_QUERY"   then handleCoalQuery(sender, msg)
            elseif t == "PICK_QUERY"   then handlePickQuery(sender, msg)
            elseif t == "PUSH_REQ"     then push.handlePushReq(sender, msg)
            elseif t == "ZONE_MAP"     then zones.ingestZoneMap(msg)
            elseif t == "ALERT"        then
                table.insert(state.alert_log, os.date("%H:%M ") .. tostring(msg.hwid) .. " " .. tostring(msg.msg))
                if #state.alert_log > 8 then table.remove(state.alert_log, 1) end
            elseif t == "CRAFT_DONE"   then log("GENESIS", "New turtle reported by " .. tostring(msg.hwid)); population.tick()
            elseif t == "YIELD_ACK"    then -- noted; nothing required
            end
        end
        M.expireReservations()
    end
end

-- ── Pruner thread ─────────────────────────────────────────
function M.prunerThread()
    while true do
        sleep(2)
        local lost = fleet.pruneLost()
        for _, hwid in ipairs(lost) do
            clearReservationsFor(hwid)
            park.clearParkClaim(hwid)
            if hwid == state.genesis_hwid then state.genesis_hwid = nil end
        end
        if #lost > 0 then population.tick() end  -- replace-on-loss
    end
end

return M
