-- /onet/boot_overseer.lua
-- Overseer boot: set the module path, find peripherals (modem, monitor, vault),
-- derive the grid origin from GPS, load persisted config + map, then hand off to
-- the overseer main loop.

package.path = table.concat({
    "/onet/?.lua",
    "/onet/lib/?.lua",
    "/onet/overseer/?.lua",
}, ";") .. ";" .. package.path

local cfg      = require("config")
local state    = require("state")
local log      = require("log").log
local gridmap  = require("gridmap")
local persist  = require("persist")
local overseer = require("overseer")

-- ── Peripherals ───────────────────────────────────────────
local modem = peripheral.find("modem")
assert(modem, "No modem attached to the overseer computer.")
rednet.open(peripheral.getName(modem))

state.mon   = peripheral.find("monitor")
state.vault = peripheral.find("chest") or peripheral.find("minecraft:chest")

-- ── Grid origin from GPS (also the base-protection centre) ─
local x, y, z = gps.locate(2)
if x then
    gridmap.setOrigin({ x = x, y = y, z = z })
    state.view_cx, state.view_y, state.view_cz = math.floor(x), math.floor(y), math.floor(z)
else
    log("ALERT", "No GPS fix — grid origin defaults to (0,0,0). Build a GPS constellation.")
    gridmap.setOrigin({ x = 0, y = 64, z = 0 })
end

-- ── Persisted state ───────────────────────────────────────
persist.loadConfig()
persist.loadMap()

-- ── Banner ────────────────────────────────────────────────
term.clear(); term.setCursorPos(1, 1); term.setTextColor(colors.cyan)
print("================ O-NET V2 OVERSEER ================")
term.setTextColor(colors.white)
print("  Protocol : " .. cfg.PROTOCOL)
print("  Monitor  : " .. (state.mon and "yes" or "none"))
print("  Vault    : " .. (state.vault and "yes" or "none"))
print("  Voxels   : " .. state.total_voxels)
print("  Target   : " .. state.target_fleet .. " turtles")
print("  Type 'help' for commands.")
term.setTextColor(colors.white)

overseer.run()
