-- /onet/overseer/population.lua
-- TARGET_FLEET tracking + craft authorization (§7.4). Hard cap with
-- replace-on-loss: authorize a Genesis craft only while live_count <
-- target_fleet. A turtle silent past LOSS_TIMEOUT is pruned by fleet.pruneLost,
-- which drops live_count and frees exactly one replacement slot. Never exceeds N.

local cfg   = require("config")
local state = require("state")
local fleet = require("fleet")
local log   = require("log").log

local M = {}

function M.setTarget(n)
    n = tonumber(n)
    if not n or n < 0 then return false, "Usage: setpop <n>" end
    state.target_fleet = math.floor(n)
    log("OVERSEER", "Target fleet -> " .. state.target_fleet)
    return true
end

-- Is a new turtle authorized right now?
function M.shouldCraft()
    return fleet.liveCount() < state.target_fleet
end

-- Find a crafty (Genesis-capable) turtle to task with a craft.
local function findGenesis()
    for hwid, f in pairs(state.fleet) do
        if f.crafty then return hwid, f end
    end
    return nil
end

-- Authorize / deauthorize the Genesis turtle based on current population.
function M.tick()
    local hwid, f = findGenesis()
    if not hwid then return end
    local authorize = M.shouldCraft()
    if authorize ~= state.craft_authorized then
        state.craft_authorized = authorize
        rednet.send(f.net_id, {
            type = "CRAFT_AUTH", hwid = hwid, authorized = authorize,
        }, cfg.PROTOCOL)
        log("GENESIS", string.format("Craft %s (live=%d target=%d)",
            authorize and "AUTHORIZED" or "halted", fleet.liveCount(), state.target_fleet))
    end
end

return M
