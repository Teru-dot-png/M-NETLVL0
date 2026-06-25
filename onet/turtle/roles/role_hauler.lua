-- /onet/turtle/roles/role_hauler.lua
-- HaulerRole: carry loot out of the dump chest and sort it into the zoned
-- storage chests (§6). Zone classification uses the SHARED lib/blocks.zoneFor so
-- the hauler and the overseer agree on what goes where. Zone chest coordinates
-- arrive via CONFIG/AUTH_ACK (state.zone_chests); unmapped items fall back to
-- the base chest.

local cfg       = require("config")
local state     = require("state")
local fuel      = require("fuel")
local nav       = require("nav")
local inventory = require("inventory")
local blocks    = require("blocks")
local vec       = require("vec")
local Task      = require("task")
local task_fuel = require("task_fuel")
local task_park = require("task_park")
local log       = require("log").log

local M = {}
M.name = cfg.ROLES.HAULER

local function haulTask()
    local t = Task.new("haul", true)
    function t:isValidTarget() return state.dump ~= nil end
    function t:work()
        -- (1) Collect from the dump chest.
        if not nav.moveTo({ x = state.dump.x, y = state.dump.y + 1, z = state.dump.z }) then
            log("BUILD", "Hauler can't reach dump."); self.failed = true; return false
        end
        inventory.suckInto("down")

        -- (2) Sort each cargo slot to its zone chest.
        for s = cfg.CARGO_FIRST, cfg.CARGO_LAST do
            local d = turtle.getItemDetail(s)
            if d then
                local zone = blocks.zoneFor(d.name)
                local chest = (state.zone_chests and state.zone_chests[zone]) or state.base
                if chest then
                    if nav.moveTo({ x = chest.x, y = chest.y + 1, z = chest.z }) then
                        turtle.select(s); turtle.dropDown()
                    end
                end
            end
        end
        turtle.select(cfg.CARGO_FIRST)
        self.done = true
        return true
    end
    return t
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
    state.current_state = "RTB_DUMP"   -- hauling shares the dump priority band
    agent.task = haulTask()
end

return M
