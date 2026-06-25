-- /onet/overseer/cockpit.lua
-- Monitor display. LUXURY tier (§11.2): if the monitor breaks, mining
-- continues. Kept compact and defensive — three panels (fleet, map slice,
-- zones + ore feed) plus a header with population status. Works headless.

local cfg     = require("config")
local state   = require("state")
local fleet   = require("fleet")
local zones   = require("zones")
local voxelmap= require("voxelmap")

local M = {}
local floor = math.floor

local function pad(s, w) s = tostring(s); if #s > w then return s:sub(1, w) end; return s .. string.rep(" ", w - #s) end

local function statusColor(st)
    st = tostring(st or ""):upper()
    if st == "MINING"   then return colors.lime   end
    if st == "STANDBY"  then return colors.yellow end
    if st == "PARKED"   then return colors.gray   end
    if st == "RTB_DUMP" then return colors.orange end
    if st == "RTB_FUEL" then return colors.red    end
    return colors.lightGray
end

function M.render()
    local mon = state.mon
    if not mon then return end
    mon.setBackgroundColor(colors.black)
    mon.clear()
    local w, h = mon.getSize()

    -- Header
    local up = floor((os.epoch("utc") - state.BOOT_TIME) / 1000)
    mon.setCursorPos(1, 1); mon.setTextColor(colors.cyan)
    mon.write(pad(string.format(" O-NET V2 OVERSEER  ID:%d  %s  UP %dm",
        os.getComputerID(), os.date("%H:%M:%S"), floor(up / 60)), w))
    mon.setCursorPos(1, 2); mon.setTextColor(colors.yellow)
    mon.write(pad(string.format(" FLEET %d/%d  VOXELS %d  CRAFT:%s",
        fleet.liveCount(), state.target_fleet, state.total_voxels,
        state.craft_authorized and "ON" or "off"), w))

    -- Left panel: fleet roster
    local row = 4
    mon.setCursorPos(1, row); mon.setTextColor(colors.white); mon.write(">> FLEET"); row = row + 1
    for hwid, f in pairs(state.fleet) do
        if row > h - 8 then break end
        local p = f.pos or {}
        mon.setCursorPos(1, row); mon.setTextColor(colors.cyan); mon.write(pad(hwid, 10))
        mon.setTextColor(statusColor(f.status))
        mon.write(pad(tostring(f.status or "?"):upper():sub(1, 8), 9))
        mon.setTextColor(colors.lightGray)
        mon.write(string.format("(%d,%d)", floor(p.x or 0), floor(p.z or 0)))
        row = row + 1
    end

    -- Zones + ore feed (bottom)
    local zr = h - 6
    mon.setCursorPos(1, zr); mon.setTextColor(colors.white); mon.write(">> ZONES"); zr = zr + 1
    local fill = zones.fillSnapshot()
    for _, z in ipairs(cfg.ZONES) do
        if zr > h - 2 then break end
        local info = fill[z]
        mon.setCursorPos(1, zr); mon.setTextColor(colors.lightGray)
        mon.write(pad(string.format(" %-12s %s  %d", z,
            info.chest and "set" or "----", info.total), w))
        zr = zr + 1
    end

    -- Ore feed ticker (last line)
    mon.setCursorPos(1, h); mon.setTextColor(colors.cyan)
    local feed = " (no ore yet)"
    if #state.ORE_FEED > 0 then
        local e = state.ORE_FEED[#state.ORE_FEED]
        feed = string.format(" %s %s %s (%d,%d,%d)", e.time, e.hwid, e.ore, e.x, e.y, e.z)
    end
    mon.write(pad(feed, w))
end

function M.displayThread()
    if not state.mon then return end
    while true do
        fleet.updateViewCenter()
        pcall(M.render)
        sleep(cfg.DISP_REFRESH)
    end
end

return M
