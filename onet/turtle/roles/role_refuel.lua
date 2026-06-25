-- /onet/turtle/roles/role_refuel.lua
-- RefuelRole: a dedicated coal runner. Repeatedly runs the RTB_FUEL sequence —
-- ask the overseer for the nearest coal, mine it, refuel, dump excess into base.

local cfg       = require("config")
local state     = require("state")
local fuel      = require("fuel")
local vec       = require("vec")
local task_fuel = require("task_fuel")
local task_park = require("task_park")

local M = {}
M.name = cfg.ROLES.REFUEL

function M:assignTask(agent)
    if not state.started then
        state.current_state = "PARKED"
        agent.task = task_park.new()
        return
    end
    state.current_state = "RTB_FUEL"
    agent.task = task_fuel.new(vec.copy(state.pos))
end

return M
