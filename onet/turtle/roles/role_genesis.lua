-- /onet/turtle/roles/role_genesis.lua
-- GenesisRole: self-replication (§7). Watches for craft authorization from the
-- overseer's population controller and, when live_count < target_fleet, crafts a
-- new Mining Turtle. CRAFTY TURTLE ONLY — a crafting upgrade exposes
-- turtle.craft (§1.7); a normal miner can't run this role, and the brain falls
-- back to MinerRole if the genesis module is asked of a non-crafty turtle.
--
-- The actual craft (arranging the 3x3 grid from GENESIS_MAT + the single
-- turtle.craft()) is performed by task_craft; this role gates WHEN it runs.

local cfg        = require("config")
local state      = require("state")
local task_craft = require("task_craft")
local task_park  = require("task_park")
local Task       = require("task")
local log        = require("log").log

local M = {}
M.name = cfg.ROLES.GENESIS

function M:assignTask(agent)
    -- Not a crafty turtle? Idle — the brain logs and (on role mismatch) would
    -- normally fall back, but guard here too so we never busy-loop.
    if not state.HW.is_crafty then
        state.current_state = "PARKED"
        agent.task = task_park.new()
        return
    end

    if state.craft_authorized then
        state.current_state = "GENESIS"
        agent.task = task_craft.new()
    else
        -- Authorized? No. Sit on the GENESIS_MAT zone and wait for CRAFT_AUTH.
        state.current_state = "PARKED"
        local t = Task.new("genesis_wait", true)
        function t:work() sleep(1); self.done = true; return true end
        agent.task = t
    end
end

return M
