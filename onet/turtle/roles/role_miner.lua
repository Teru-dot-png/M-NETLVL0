-- /onet/turtle/roles/role_miner.lua
-- MinerRole: grid tunnelling with the §4 priority state machine expressed as
-- task selection. CORE behavioural port of brain.lua's transition logic.
--
-- assignTask() is called by the agent loop whenever the agent goes idle. It
-- picks exactly ONE task and sets state.current_state so the push-protocol
-- priority (cfg.PRIORITY[state.current_state]) is correct while that task runs.

local cfg       = require("config")
local state     = require("state")
local fuel      = require("fuel")
local inventory = require("inventory")
local pickaxe   = require("pickaxe")
local vec       = require("vec")
local log       = require("log").log

local Task      = require("task")
local task_goto = require("task_goto")
local task_fuel = require("task_fuel")
local task_dump = require("task_dump")
local task_park = require("task_park")
local task_tunnel = require("task_tunnel")
local task_mine = require("task_mine")
local task_scan = require("task_scan")

local M = {}
M.name = cfg.ROLES.MINER

-- Inline FETCH_PICK task (uses pickaxe.fetchPickaxeFromBase, which lazy-requires
-- nav to avoid a load-time cycle).
local function fetchPickTask(resume)
    local t = Task.new("fetch_pick", true)
    function t:work()
        pickaxe.fetchPickaxeFromBase(resume)
        self.done = true
        return true
    end
    return t
end

-- Ask the overseer for the next grid segment near our position.
local function requestSegment()
    if not state.server_id then return end
    pcall(rednet.send, state.server_id, {
        type = "SEGMENT_REQ", hwid = state.hwid, pos = vec.copy(state.pos),
    }, cfg.PROTOCOL)
end

-- Build a GOTO-then-MINE chain and consume the job.
local function gotoMineChain(job)
    local mt = task_mine.new({ x = job.pos.x, y = job.pos.y, z = job.pos.z, ore = job.ore })
    local gt = task_goto.new(job.pos)
    gt.parent = mt          -- run goto, then mine on arrival
    return gt
end

function M:assignTask(agent)
    -- Not running yet: sit in the park slot and wait for CMD_START.
    if not state.started then
        state.current_state = state.park_pos and "PARKED" or "STANDBY"
        agent.task = task_park.new()
        return
    end

    -- (critical) Out of fuel -> refuel immediately, whatever else is pending.
    if fuel.fuelLevel() < cfg.FUEL_CRITICAL then
        state.current_state = "RTB_FUEL"
        agent.task = task_fuel.new(vec.copy(state.pos))
        return
    end

    -- (1) Operator/overseer GOTO job.
    if state.goto_job then
        state.current_state = "GOTO"
        local job = state.goto_job
        state.goto_job = nil
        agent.task = gotoMineChain(job)
        return
    end

    -- (2) Low fuel.
    if fuel.fuelLevel() < cfg.FUEL_MIN then
        state.current_state = "RTB_FUEL"
        agent.task = task_fuel.new(vec.copy(state.pos))
        return
    end

    -- (3) Cargo full -> dump.
    if inventory.inventoryFull() then
        state.current_state = "RTB_DUMP"
        agent.task = task_dump.new()
        return
    end

    -- (4) Pickaxe missing -> fetch from base.
    if not pickaxe.pickaxeEquipped() then
        state.current_state = "FETCH_PICK"
        agent.task = fetchPickTask(vec.copy(state.pos))
        return
    end

    -- (5) SEARCH job (getme): go to the ore, mine it.
    if state.search_job then
        state.current_state = "SEARCH"
        local job = state.search_job
        state.search_job = nil
        agent.task = gotoMineChain(job)
        return
    end

    -- (6) MINING: dig the assigned grid segment, else request one and scan.
    state.current_state = "MINING"
    if state.segment then
        local seg = state.segment
        agent.task = task_tunnel.new(seg)
    else
        requestSegment()
        agent.task = task_scan.new()   -- useful work while we wait for a grant
    end
end

return M
