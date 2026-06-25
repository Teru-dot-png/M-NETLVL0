-- /onet/turtle/tasks/task_mine.lua
-- Vein-sweep an ore at a position. target = {x,y,z[,ore]}. Navigates adjacent,
-- breaks the ore, then flood-fills neighbouring ore cells using the world cache
-- so a whole vein is collected from one report.

local Task    = require("task")
local cfg     = require("config")
local state   = require("state")
local nav     = require("nav")
local movers  = require("movers")
local cache   = require("cache")
local scanner = require("scanner")
local blocks  = require("blocks")
local vec     = require("vec")
local log     = require("log").log

local M = {}

local function reportMined(ore, pos)
    if state.server_id then
        pcall(rednet.send, state.server_id, {
            type = "ORE_MINED",
            hwid = state.hwid,
            ore  = ore,
            pos  = vec.copy(pos),
        }, cfg.PROTOCOL)
    end
end

function M.new(target, opts)
    local t = Task.new("mine", target, opts)

    function t:isValidTarget()
        return type(self.target) == "table" and self.target.x and self.target.y and self.target.z
    end

    function t:work()
        local goal = self.target
        -- Stand directly above the ore and mine down into it (simple, robust).
        local stand = { x = goal.x, y = goal.y + 1, z = goal.z }
        if not nav.moveTo(stand) then
            log("MINE", "Cannot reach ore at (" .. goal.x .. "," .. goal.y .. "," .. goal.z .. ")")
            self.failed = true
            return false
        end

        local ore_tag = self.target.ore or "ore"
        if movers.digSafeDown() then
            reportMined(ore_tag, goal)
            log("MINE", "Mined " .. ore_tag .. " at (" .. goal.x .. "," .. goal.y .. "," .. goal.z .. ")")
        end

        -- Flood the immediate neighbourhood for connected ore via the cache.
        local frontier = { goal }
        local seen = { [vec.key(goal)] = true }
        local swept = 0
        while #frontier > 0 and swept < 24 do
            local cur = table.remove(frontier)
            for _, n in ipairs(vec.DIRS6) do
                local nx, ny, nz = cur.x + n.dx, cur.y + n.dy, cur.z + n.dz
                local k = vec.key(nx, ny, nz)
                if not seen[k] then
                    seen[k] = true
                    local name = cache.cacheGet(nx, ny, nz)
                    if blocks.isOre(name) then
                        local np = { x = nx, y = ny, z = nz }
                        if nav.moveTo({ x = nx, y = ny + 1, z = nz }) and movers.digSafeDown() then
                            reportMined(blocks.normalizeOreName(name), np)
                            swept = swept + 1
                            frontier[#frontier + 1] = np
                        end
                    end
                end
            end
        end

        self.done = true
        return true
    end

    return t
end

return M
