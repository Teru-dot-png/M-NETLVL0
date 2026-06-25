-- /onet/turtle/roles/role_scout.lua
-- ScoutRole: explore unmapped grid cells and report ore clusters. Lighter than
-- a miner — it tunnels short segments and scans aggressively so the overseer's
-- voxel map and clusters fill quickly, leaving the heavy extraction to miners.

local cfg         = require("config")
local state       = require("state")
local fuel        = require("fuel")
local vec         = require("vec")
local task_scan   = require("task_scan")
local task_tunnel = require("task_tunnel")
local task_fuel   = require("task_fuel")
local task_park   = require("task_park")
local log         = require("log").log

local M = {}
M.name = cfg.ROLES.SCOUT

local function requestSegment()
    if not state.server_id then return end
    pcall(rednet.send, state.server_id, {
        type = "SEGMENT_REQ", hwid = state.hwid, pos = vec.copy(state.pos),
    }, cfg.PROTOCOL)
end

function M:assignTask(agent)
    if not state.started then
        state.current_state = state.park_pos and "PARKED" or "STANDBY"
        agent.task = task_park.new()
        return
    end
    if fuel.fuelLevel() < cfg.FUEL_MIN then
        state.current_state = "RTB_FUEL"
        agent.task = task_fuel.new(vec.copy(state.pos))
        return
    end

    state.current_state = "MINING"
    if state.segment then
        -- Scouts cut short corridors then scan, rather than full segments.
        local seg = state.segment
        seg.len = math.min(seg.len, math.floor(cfg.SEGMENT_LEN / 2))
        local scan = task_scan.new()
        local tunnel = task_tunnel.new(seg)
        tunnel.parent = scan          -- tunnel, then scan the new frontier
        agent.task = tunnel
    else
        requestSegment()
        agent.task = task_scan.new()
    end
end

return M
