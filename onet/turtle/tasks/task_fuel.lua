-- /onet/turtle/tasks/task_fuel.lua
-- RTB_FUEL (§4): ask the overseer for the nearest coal, mine it, return to base,
-- refuel up to (not over) FUEL_TARGET, dump the excess coal into the base chest,
-- then return to the position we left. Falls back to local foraging if the
-- overseer has no coal location yet.

local Task   = require("task")
local cfg    = require("config")
local state  = require("state")
local nav    = require("nav")
local movers = require("movers")
local fuel   = require("fuel")
local vec    = require("vec")
local log    = require("log").log

local M = {}

function M.new(resume_pos, opts)
    local t = Task.new("fuel", true, opts)

    function t:work()
        local resume = resume_pos or vec.copy(state.pos)
        log("FUEL", "RTB_FUEL: fuel=" .. tostring(turtle.getFuelLevel()))

        -- (1) Ask the overseer where the nearest coal ore is.
        state.coal_loc = nil
        if state.server_id then
            pcall(rednet.send, state.server_id, {
                type = "COAL_QUERY", hwid = state.hwid, pos = vec.copy(state.pos),
            }, cfg.PROTOCOL)
            local deadline = os.epoch("utc") + 2500
            while not state.coal_loc and os.epoch("utc") < deadline do sleep(0.2) end
        end

        -- (2) Mine coal: either at the overseer-supplied location or by foraging.
        if state.coal_loc then
            log("FUEL", "Coal at (" .. state.coal_loc.x .. "," .. state.coal_loc.y .. "," .. state.coal_loc.z .. ")")
            if nav.moveTo({ x = state.coal_loc.x, y = state.coal_loc.y + 1, z = state.coal_loc.z }) then
                movers.digSafeDown()
            end
            fuel.burnAboard(cfg.FUEL_TARGET)
        end
        if fuel.fuelLevel() < cfg.FUEL_TARGET then
            fuel.forageForCoal()
        end

        -- (3) Return to base, top up, dump the excess coal.
        if state.base then
            if nav.moveTo({ x = state.base.x, y = state.base.y + 1, z = state.base.z }) then
                fuel.burnAboard(cfg.FUEL_TARGET)   -- refuel up to, not over, target
                -- Drop leftover burnables into the base chest below.
                for s = cfg.CARGO_FIRST, cfg.CARGO_LAST do
                    local d = turtle.getItemDetail(s)
                    if d and require("blocks").isFuel(d.name) then
                        turtle.select(s); turtle.dropDown()
                    end
                end
                turtle.select(cfg.CARGO_FIRST)
            end
        end

        -- (4) Return to where we left off.
        nav.moveTo(resume)
        movers.face(state.my_dir)
        self.done = true
        return true
    end

    return t
end

return M
