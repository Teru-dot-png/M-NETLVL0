-- /onet/turtle/tasks/task_tunnel.lua
-- Dig one grid segment: a 1-wide, 2-tall tunnel of length `len` along `dir`.
-- target = segment { sx, sy, sz, dir, len }. Reports SEGMENT done + scans
-- periodically so ore is discovered as the tunnel advances.

local Task    = require("task")
local cfg     = require("config")
local state   = require("state")
local nav     = require("nav")
local movers  = require("movers")
local scanner = require("scanner")
local grid    = require("grid")
local vec     = require("vec")
local log     = require("log").log

local M = {}

function M.new(segment, opts)
    local t = Task.new("tunnel", segment, opts)

    function t:isValidTarget()
        local s = self.target
        return type(s) == "table" and s.sx and s.dir and s.len and s.len > 0
    end

    function t:work()
        local s = self.target
        -- Move to the segment start, then face the dig direction.
        local startp = { x = s.sx, y = s.sy, z = s.sz }
        if not vec.equals(state.pos, startp) then
            if not nav.moveTo(startp) then
                log("MINE", "Could not reach segment start. Aborting.")
                self.failed = true
                return false
            end
        end
        movers.face(s.dir)

        for i = 1, s.len do
            if state.home_requested then self.done = false; return false end
            -- Dig the 2-tall corridor: forward, then clear the ceiling block.
            if not movers.forward() then
                log("MINE", "Blocked/protected at step " .. i .. ". Ending segment.")
                break
            end
            movers.digSafeUp()
            state.tunnelled = state.tunnelled + 1
            -- Scan every few blocks so ore is found mid-tunnel.
            if i % cfg.SCAN_EVERY == 0 and state.HW.has_scanner then
                local scan = scanner.scanAround()
                scanner.reportOres(scan)
                scanner.sendSnapshot(scan)
            end
        end

        -- Tell the overseer this segment is mined so the gridmap marks it done.
        if state.server_id then
            pcall(rednet.send, state.server_id, {
                type = "ORE_MINED",
                hwid = state.hwid,
                seg  = grid.segKey(s),
                pos  = vec.copy(state.pos),
            }, cfg.PROTOCOL)
        end
        state.segment = nil
        self.done = true
        return true
    end

    return t
end

return M
