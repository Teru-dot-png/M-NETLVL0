-- /onet/turtle/tasks/task_craft.lua
-- Genesis craft sequence (Crafty Turtle only, §7.2). Pulls raw materials from
-- the GENESIS_MAT chest, crafts the combined Mining Turtle item in one
-- turtle.craft(), places it, and signals CRAFT_DONE so the overseer/boot can
-- copy software + assign a role to the new turtle.
-- Skeleton-functional: the exact recipe grid is laid out by role_genesis, which
-- arranges ingredients into the 3x3 craft slots before calling work().

local Task   = require("task")
local cfg    = require("config")
local state  = require("state")
local movers = require("movers")
local log    = require("log").log

local M = {}

function M.new(opts)
    local t = Task.new("craft", true, opts)

    function t:isValidTarget()
        -- Only a crafting turtle can craft (§1.7).
        return state.HW.is_crafty == true and type(turtle.craft) == "function"
    end

    function t:work()
        log("GENESIS", "Crafting new Mining Turtle...")
        -- role_genesis has already arranged ingredients in the crafting grid.
        local ok = turtle.craft()
        if not ok then
            log("GENESIS", "Craft failed (ingredients not arranged / incomplete).")
            self.failed = true
            return false
        end

        -- Place the freshly-crafted turtle in front and boot it.
        local placed = false
        for s = 1, 16 do
            local d = turtle.getItemDetail(s)
            if d and tostring(d.name):find("turtle") then
                turtle.select(s)
                if turtle.place() then placed = true end
                break
            end
        end
        turtle.select(cfg.CARGO_FIRST)

        if placed then
            -- Wake the new turtle: a freshly placed turtle runs its startup.
            pcall(peripheral.call, "front", "turnOn")
            if state.server_id then
                pcall(rednet.send, state.server_id, {
                    type = "CRAFT_DONE", hwid = state.hwid,
                }, cfg.PROTOCOL)
            end
            log("GENESIS", "New turtle placed + powered. CRAFT_DONE sent.")
        else
            log("GENESIS", "Crafted item but could not place it.")
        end

        self.done = true
        return placed
    end

    return t
end

return M
