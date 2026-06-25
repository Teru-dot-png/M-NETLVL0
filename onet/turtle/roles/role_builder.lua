-- /onet/turtle/roles/role_builder.lua
-- BuilderRole: lay out the storage zones — place a chest for each zone around
-- the base, then broadcast the layout (ZONE_MAP) so haulers + overseer learn
-- the coordinates. Smelting ore->ingot and cobble->stone (for Genesis) is done
-- via task_build furnaces. Skeleton-functional: the layout is a simple ring of
-- chests offset from the base chest.

local cfg        = require("config")
local state      = require("state")
local fuel       = require("fuel")
local vec        = require("vec")
local task_build = require("task_build")
local task_fuel  = require("task_fuel")
local task_park  = require("task_park")
local Task       = require("task")
local log        = require("log").log

local M = {}
M.name = cfg.ROLES.BUILDER

-- Build a one-time placement plan: one chest per zone, offset around the base.
local function ensurePlan()
    if state.build_plan then return end
    state.build_plan  = {}
    state.built_zones = {}
    local b = state.base or state.overseer_pos
    if not b then return end
    local offsets = {
        ORES         = { dx =  2, dz =  0 },
        FUEL         = { dx = -2, dz =  0 },
        BUILDING_MAT = { dx =  0, dz =  2 },
        GENESIS_MAT  = { dx =  0, dz = -2 },
    }
    for _, zone in ipairs(cfg.ZONES) do
        local o = offsets[zone] or { dx = 0, dz = 0 }
        local pos = { x = b.x + o.dx, y = b.y, z = b.z + o.dz }
        state.build_plan[#state.build_plan + 1] = { kind = "chest", pos = pos, zone = zone }
        state.built_zones[zone] = pos
    end
end

-- After the plan is placed, announce the layout to the overseer.
local function broadcastZoneMap()
    if not state.server_id or not state.built_zones then return end
    pcall(rednet.send, state.server_id, {
        type = "ZONE_MAP", hwid = state.hwid, zones = state.built_zones,
    }, cfg.PROTOCOL)
    log("BUILD", "ZONE_MAP broadcast.")
end

function M:assignTask(agent)
    if not state.started then
        state.current_state = "PARKED"
        agent.task = task_park.new()
        return
    end
    if fuel.fuelLevel() < cfg.FUEL_MIN then
        state.current_state = "RTB_FUEL"
        agent.task = task_fuel.new(vec.copy(state.pos))
        return
    end

    state.current_state = "BUILDER"
    ensurePlan()
    if state.build_plan and #state.build_plan > 0 then
        local job = table.remove(state.build_plan, 1)
        agent.task = task_build.new({ kind = job.kind, pos = job.pos })
    else
        -- Plan complete: announce zones, then idle in park.
        local t = Task.new("zone_announce", true)
        function t:work() broadcastZoneMap(); self.done = true; return true end
        agent.task = t
    end
end

return M
