-- /onet/overseer/voxelmap.lua
-- Authoritative voxel database (ores / air / hazards only — never stone).
-- CORE: the volatile-solid inference in ingestGeoData is the hidden gem. When a
-- block a turtle previously saw is now ABSENT from a scan that covers its cell,
-- we promote it to air — passive cave-mapping without explicit air reports.
-- Subtle; understand it before touching it.

local cfg   = require("config")
local state = require("state")
local log   = require("log").log

local M = {}
local floor = math.floor

local AIR_NAMES = {
    ["minecraft:air"] = true, ["air"] = true, ["minecraft:cave_air"] = true,
    ["minecraft:void_air"] = true, [""] = true,
}

function M.isAir(n) return n == nil or n == cfg.AIR_MARKER or AIR_NAMES[n] == true end
function M.isOre(n) return n ~= nil and n:find("_ore", 1, true) ~= nil end

-- Only blocks worth keeping: stone-class is excluded because the navigator
-- already treats "unknown" as solid, so storing stone wastes memory.
function M.shouldStore(name)
    if not name or name == "" then return false end
    if name == cfg.AIR_MARKER then return true end
    if name:find("air")    then return true end
    if name:find("_ore")   then return true end
    if name:find("lava")   then return true end
    if name:find("water")  then return true end
    if name:find("chest")  then return true end
    if name:find("computer") then return true end
    if name:find("turtle") then return true end
    if name:find("furnace")then return true end
    return false
end

function M.isGeoScanNoise(name)
    return tostring(name or ""):lower():find("turtle", 1, true) ~= nil
end

function M.setVoxel(x, y, z, name)
    if not M.shouldStore(name) then return end
    local mv = state.master_voxels
    if not mv[y]    then mv[y] = {} end
    if not mv[y][x] then mv[y][x] = {} end
    if not mv[y][x][z] then state.total_voxels = state.total_voxels + 1 end
    mv[y][x][z] = name
    state.map_dirty = true
end

function M.getVoxel(x, y, z)
    local ly = state.master_voxels[y]; if not ly then return nil end
    local lx = ly[x];                  if not lx then return nil end
    return lx[z]
end

-- Process a GEO_DATA packet from a turtle.
function M.ingestGeoData(msg)
    local f = state.fleet[msg.hwid]
    if f then
        f.last_pulse = os.epoch("utc")
        if msg.pos then f.pos = msg.pos end
    end

    local scan = msg.scan_data
    local p    = msg.pos
    if type(scan) ~= "table" or type(p) ~= "table" then return end

    local ox, oy, oz = floor(p.x or 0), floor(p.y or 0), floor(p.z or 0)
    local now = os.epoch("utc")
    local seen = {}

    -- Prune stale volatile sightings.
    for k, v in pairs(state.volatile_solids) do
        if type(v) ~= "table" or (now - (tonumber(v.ts) or 0)) > cfg.VOL_SOLID_TTL_MS then
            state.volatile_solids[k] = nil
        end
    end

    for _, b in ipairs(scan) do
        if type(b) == "table" and type(b.name) == "string" then
            local ax, ay, az = floor(ox + (b.x or 0)), floor(oy + (b.y or 0)), floor(oz + (b.z or 0))
            local k = ax .. ":" .. ay .. ":" .. az
            if M.isGeoScanNoise(b.name) then
                M.setVoxel(ax, ay, az, cfg.AIR_MARKER)
                state.volatile_solids[k] = nil
            elseif M.isAir(b.name) then
                M.setVoxel(ax, ay, az, cfg.AIR_MARKER)
                state.volatile_solids[k] = nil
            else
                seen[k] = true
                if M.shouldStore(b.name) then
                    M.setVoxel(ax, ay, az, b.name)
                else
                    state.volatile_solids[k] = { x = ax, y = ay, z = az, ts = now }
                end
            end
        end
    end

    -- Negative-space inference: a volatile solid now inside the scan radius but
    -- not in this scan has been mined out -> promote to known air.
    local radius = floor(tonumber(msg.scan_radius) or 0)
    if radius > 0 then
        local r2 = radius * radius
        for k, v in pairs(state.volatile_solids) do
            local dx, dy, dz = v.x - ox, v.y - oy, v.z - oz
            if (dx * dx + dy * dy + dz * dz) <= r2 then
                if not seen[k] then
                    M.setVoxel(v.x, v.y, v.z, cfg.AIR_MARKER)
                    state.volatile_solids[k] = nil
                else
                    v.ts = now
                end
            end
        end
    end
end

-- Find every stored voxel whose name matches `ore`, nearest-first to refpos.
function M.findOreInMap(ore, refpos)
    local found = {}
    for y, xt in pairs(state.master_voxels) do
        for x, zt in pairs(xt) do
            for z, name in pairs(zt) do
                if type(name) == "string" and name:find(ore, 1, true) then
                    found[#found + 1] = { x = x, y = y, z = z, name = name }
                end
            end
        end
    end
    if refpos then
        table.sort(found, function(a, b)
            local da = math.abs(a.x - refpos.x) + math.abs(a.y - refpos.y) + math.abs(a.z - refpos.z)
            local db = math.abs(b.x - refpos.x) + math.abs(b.y - refpos.y) + math.abs(b.z - refpos.z)
            return da < db
        end)
    end
    return found
end

return M
