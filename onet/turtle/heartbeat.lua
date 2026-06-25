-- /onet/turtle/heartbeat.lua
-- Periodic HEARTBEAT to the overseer + an idle background scan every few beats
-- so the voxel map keeps filling even while a turtle is parked.

local cfg     = require("config")
local state   = require("state")
local fuel    = require("fuel")
local inventory= require("inventory")
local scanner = require("scanner")
local vec     = require("vec")

local M = {}

function M.heartbeatThread_inner()
    local beat = 0
    while true do
        beat = beat + 1
        if state.server_id then
            pcall(rednet.send, state.server_id, {
                type   = "HEARTBEAT",
                hwid   = state.hwid,
                role   = state.role,
                status = state.current_state,
                pos    = vec.copy(state.pos),
                dir    = state.my_dir,
                fuel   = turtle.getFuelLevel(),
                free   = inventory.freeSlots(),
            }, cfg.PROTOCOL)
        end
        -- Background scan while idle (don't fight an in-progress hot-swap).
        if state.HW.has_scanner and not state.scanning_now
           and (beat % cfg.SCAN_EVERY == 0)
           and (state.current_state == "PARKED" or state.current_state == "STANDBY") then
            local scan = scanner.scanAround()
            scanner.reportOres(scan)
            scanner.sendSnapshot(scan)
        end
        sleep(cfg.HEARTBEAT_INT)
    end
end

return M
