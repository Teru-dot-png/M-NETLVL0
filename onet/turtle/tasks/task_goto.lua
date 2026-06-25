-- /onet/turtle/tasks/task_goto.lua
-- Travel to a coordinate. target = {x,y,z}. Priority state GOTO (never yields).

local Task  = require("task")
local nav   = require("nav")
local movers= require("movers")
local state = require("state")
local log   = require("log").log

local M = {}

function M.new(target, opts)
    local t = Task.new("goto", target, opts)
    function t:isValidTarget()
        return type(self.target) == "table"
            and self.target.x and self.target.y and self.target.z
    end
    function t:work()
        log("NAV", "GOTO task -> (" .. self.target.x .. "," .. self.target.y .. "," .. self.target.z .. ")")
        local arrived = nav.moveTo(self.target)
        if arrived and self.opts.face ~= nil then movers.face(self.opts.face) end
        self.done = arrived
        return arrived
    end
    return t
end

return M
