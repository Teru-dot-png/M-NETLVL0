-- /onet/turtle/tasks/task_scan.lua
-- One geo-scanner sweep + report ores + push a solid snapshot to the overseer.

local Task    = require("task")
local scanner = require("scanner")
local state   = require("state")

local M = {}

function M.new(opts)
    local t = Task.new("scan", true, opts)
    function t:isValidTarget() return state.HW.has_scanner == true end
    function t:work()
        local scan = scanner.scanAround()
        scanner.reportOres(scan)
        scanner.sendSnapshot(scan)
        self.data.found = scanner.scanForWanted(scan)
        self.done = true
        return true
    end
    return t
end

return M
