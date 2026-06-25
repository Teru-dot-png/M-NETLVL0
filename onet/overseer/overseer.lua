-- /onet/overseer/overseer.lua
-- Overseer main loop. Runs every overseer thread in parallel, each pcall-wrapped
-- with auto-restart so one crash never takes the base offline (§10).

local cfg      = require("config")
local state    = require("state")
local log      = require("log").log
local director = require("director")
local orders   = require("orders")
local cockpit  = require("cockpit")
local terminal = require("terminal")
local persist  = require("persist")

local M = {}

local function supervised(name, inner)
    return function()
        while true do
            local ok, err = pcall(inner)
            if not ok then
                log("ALERT", "[" .. name .. "] crashed: " .. tostring(err) .. " — restart 2s")
                sleep(2)
            else
                return
            end
        end
    end
end

function M.run()
    parallel.waitForAll(
        supervised("listener", director.listenerThread),
        supervised("pruner",   director.prunerThread),
        supervised("orders",   orders.orderThread),
        supervised("mapsave",  persist.mapSaveThread),
        supervised("display",  cockpit.displayThread),
        supervised("terminal", terminal.terminalThread)
    )
end

return M
