-- /onet/overseer/persist.lua
-- Config + voxel-map durability. SURVIVAL: only matters on reboot, invisible
-- otherwise. mapSaveThread keeps the voxel DB safe across restarts.
-- The map uses a compact tab-separated format (x\ty\tz\tname) so a large cave
-- system doesn't bloat to a multi-megabyte serialized table.

local cfg     = require("config")
local state   = require("state")
local voxelmap= require("voxelmap")
local log     = require("log").log

local M = {}

-- ── Config ────────────────────────────────────────────────
function M.saveConfig()
    local data = {
        DUMP_CHEST  = state.DUMP_CHEST,
        BASE_CHEST  = state.BASE_CHEST,
        PARK_ZONE   = state.PARK_ZONE,
        WANT_LIST   = state.WANT_LIST,
        target_fleet= state.target_fleet,
        zones       = {},
    }
    for z, rec in pairs(state.zones) do data.zones[z] = rec.chest end
    local f = fs.open(cfg.CONFIG_FILE, "w")
    if f then f.write(textutils.serialize(data)); f.close() end
end

function M.loadConfig()
    if not fs.exists(cfg.CONFIG_FILE) then return end
    local f = fs.open(cfg.CONFIG_FILE, "r")
    if not f then return end
    local data = textutils.unserialize(f.readAll() or "")
    f.close()
    if type(data) ~= "table" then return end
    state.DUMP_CHEST = data.DUMP_CHEST or state.DUMP_CHEST
    state.BASE_CHEST = data.BASE_CHEST or state.BASE_CHEST
    state.PARK_ZONE  = data.PARK_ZONE  or state.PARK_ZONE
    if type(data.WANT_LIST) == "table" then state.WANT_LIST = data.WANT_LIST end
    if data.target_fleet then state.target_fleet = data.target_fleet end
    if type(data.zones) == "table" then
        for z, pos in pairs(data.zones) do
            if state.zones[z] and type(pos) == "table" then state.zones[z].chest = pos end
        end
    end
    log("OVERSEER", "Config loaded.")
end

-- Broadcast config to the whole fleet. NOTE: park_pos is deliberately NOT sent
-- here — each turtle has a different slot, and a single broadcast value would
-- corrupt every turtle's park_pos. Park slots go via per-turtle PARK_ASSIGN.
function M.broadcastConfig()
    local zone_chests = {}
    for z, rec in pairs(state.zones) do zone_chests[z] = rec.chest end
    rednet.broadcast({
        type        = "CONFIG",
        dump        = state.DUMP_CHEST,
        base        = state.BASE_CHEST,
        want_list   = state.WANT_LIST,
        overseer_pos= state.overseer_pos,
        zone_chests = zone_chests,
    }, cfg.PROTOCOL)
end

-- ── Voxel map ─────────────────────────────────────────────
function M.saveMap()
    local f = fs.open(cfg.MAP_FILE, "w")
    if not f then return end
    for y, xt in pairs(state.master_voxels) do
        for x, zt in pairs(xt) do
            for z, name in pairs(zt) do
                f.write(x .. "\t" .. y .. "\t" .. z .. "\t" .. name .. "\n")
            end
        end
    end
    f.close()
    state.map_dirty = false
    state.last_map_save = os.epoch("utc")
end

function M.loadMap()
    if not fs.exists(cfg.MAP_FILE) then return end
    local f = fs.open(cfg.MAP_FILE, "r")
    if not f then return end
    while true do
        local line = f.readLine()
        if not line then break end
        local x, y, z, name = line:match("^(-?%d+)\t(-?%d+)\t(-?%d+)\t(.+)$")
        if x then voxelmap.setVoxel(tonumber(x), tonumber(y), tonumber(z), name) end
    end
    f.close()
    state.map_dirty = false
    log("OVERSEER", "Map loaded: " .. state.total_voxels .. " voxels.")
end

function M.mapSaveThread()
    while true do
        sleep(cfg.MAP_SAVE_INTERVAL)
        if state.map_dirty and state.map_persist_enabled then M.saveMap() end
    end
end

return M
