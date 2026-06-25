-- /onet/turtle/tasks/task_park.lua
-- Navigate to the assigned park slot and idle there. target = state.park_pos.

local Task  = require("task")
local state = require("state")
local nav   = require("nav")
local log   = require("log").log

local M = {}

function M.new(opts)
    local t = Task.new("park", true, opts)
    function t:isValidTarget() return state.park_pos ~= nil end
    function t:work()
        log("NAV", "PARK -> assigned slot.")
        nav.moveTo(state.park_pos)
        self.done = true
        return true
    end
    return t
end

return M
