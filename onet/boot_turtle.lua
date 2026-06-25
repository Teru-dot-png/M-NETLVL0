-- /onet/boot_turtle.lua
-- Turtle boot sequence: set the module path, detect hardware, calibrate from
-- GPS, enlist with the overseer, equip the pickaxe, then run the brain +
-- listener + heartbeat threads. Every thread is pcall-wrapped with auto-restart
-- so a transient error never drops the turtle to the shell (§10).

-- ── Module path: flat resolution across the /onet tree ────
package.path = table.concat({
    "/onet/?.lua",
    "/onet/lib/?.lua",
    "/onet/turtle/?.lua",
    "/onet/turtle/tasks/?.lua",
    "/onet/turtle/roles/?.lua",
}, ";") .. ";" .. package.path

local cfg       = require("config")
local state     = require("state")
local log       = require("log").log
local hardware  = require("hardware")
local pickaxe   = require("pickaxe")
local fuel      = require("fuel")
local calibrate = require("calibrate")
local network   = require("network")
local heartbeat = require("heartbeat")
local brain     = require("brain")

local function boot()
    term.clear(); term.setCursorPos(1, 1)
    log("BOOT", "================ O-NET V2 TURTLE ================")
    log("BOOT", "HWID: " .. state.hwid)

    hardware.detectHardware()
    network.openModem()
    fuel.wakeUp()
    calibrate.calibrate()
    network.handshake()
    pickaxe.bootEquipPickaxe()
    fuel.forageForCoal()

    log("BOOT", "Boot complete. role=" .. state.role .. " state=" .. state.current_state)
end

-- Wrap a thread so a crash logs and restarts instead of killing the turtle.
local function supervised(name, inner)
    return function()
        while true do
            local ok, err = pcall(inner)
            if not ok then
                log("ALERT", "[" .. name .. "] crashed: " .. tostring(err) .. " — restarting in 2s")
                sleep(2)
            else
                return  -- clean exit (shouldn't happen for these loops)
            end
        end
    end
end

boot()

parallel.waitForAll(
    supervised("brain",     brain.brainThread_inner),
    supervised("listener",  network.listenerThread_inner),
    supervised("heartbeat", heartbeat.heartbeatThread_inner)
)
