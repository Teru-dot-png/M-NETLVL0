-- /onet/turtle/brain.lua
-- The agent loop. Holds the current Role and a single Agent (this turtle wrapped
-- as a Zerg-style creep). Each tick: if the agent is idle, ask the role for a
-- task; then drive the task one step. The role sets state.current_state, which
-- is what the push protocol reads for this turtle's move priority.

local cfg   = require("config")
local state = require("state")
local log   = require("log").log

local M = {}

-- Role name -> module basename. pcall-guarded so a not-yet-installed role
-- (e.g. on a miner that never carries the genesis file) falls back to MinerRole
-- instead of crashing the brain.
local ROLE_MODULES = {
    [cfg.ROLES.MINER]   = "role_miner",
    [cfg.ROLES.HAULER]  = "role_hauler",
    [cfg.ROLES.SCOUT]   = "role_scout",
    [cfg.ROLES.REFUEL]  = "role_refuel",
    [cfg.ROLES.BUILDER] = "role_builder",
    [cfg.ROLES.GENESIS] = "role_genesis",
}

local function loadRole(name)
    local modname = ROLE_MODULES[name] or "role_miner"
    local ok, r = pcall(require, modname)
    if ok and type(r) == "table" and r.assignTask then return r end
    log("ROLE", "Role '" .. tostring(name) .. "' unavailable; falling back to MinerRole.")
    return require("role_miner")
end

-- ── Agent wrapper ─────────────────────────────────────────
local Agent = {}
Agent.__index = Agent
function Agent.new()
    return setmetatable({ task = nil, memory = {} }, Agent)
end
function Agent:isIdle()
    local t = self.task
    return t == nil or t.done == true or t.failed == true
end
function Agent:priority()
    return cfg.PRIORITY[state.current_state] or 10
end
function Agent:run()
    if self.task then self.task = self.task:run() end
end

function M.brainThread_inner()
    local agent = Agent.new()
    local role  = loadRole(state.role)
    local roleName = state.role
    log("ROLE", "Brain online as " .. tostring(roleName))

    while true do
        -- Live role swap (Overmind: change behaviour without a reboot).
        if state.role ~= roleName then
            roleName = state.role
            role = loadRole(roleName)
            agent.task = nil
            log("ROLE", "Switched to " .. tostring(roleName))
        end

        -- Recall short-circuits everything: drop to PARKED and idle.
        if state.home_requested then
            state.current_state = "PARKED"
            agent.task = nil
            sleep(0.3)
        else
            if agent:isIdle() then role:assignTask(agent) end
            if agent.task then
                agent:run()
            else
                sleep(0.3)  -- nothing assignable right now
            end
        end
        sleep(0)
    end
end

return M
