-- /onet/turtle/tasks/task_dump.lua
-- RTB_DUMP — the hardcoded 6-step dump sequence (§4). NO branching: this exact
-- order was settled by debugging and must not be "optimised". Cargo is slots
-- 3..16; slots 1+2 (scanner, pickaxe) are never dropped (§1.1).
--   1) go to the dump chest
--   2) drop slots 3-16 only
--   3) move `fleet_size` blocks away from the chest
--   4) PARK_REQ to the overseer
--   5) go to the assigned park slot
--   6) wait for a command (handled by the brain after this task completes)

local Task      = require("task")
local cfg       = require("config")
local state     = require("state")
local nav       = require("nav")
local movers    = require("movers")
local inventory = require("inventory")
local vec       = require("vec")
local log       = require("log").log

local M = {}

function M.new(opts)
    local t = Task.new("dump", true, opts)

    function t:isValidTarget() return state.dump ~= nil end

    function t:work()
        local dump = state.dump
        log("DUMP", "RTB_DUMP: heading to dump chest.")

        -- (1) Go to the chest (stand on top of it).
        if not nav.moveTo({ x = dump.x, y = dump.y + 1, z = dump.z }) then
            log("DUMP", "Could not reach dump chest. Parking 10s.")
            sleep(10); self.failed = true; return false
        end

        -- (2) Drop cargo (slots 3-16) downward into the chest.
        local cleared = inventory.dropCargo("down")
        if not cleared then
            log("DUMP", "Dump chest FULL. Cargo remains.")
            pcall(rednet.send, state.server_id, {
                type = "ALERT", hwid = state.hwid, msg = "CHEST_FULL", pos = vec.copy(state.pos),
            }, cfg.PROTOCOL)
        end

        -- (3) Move fleet_size blocks away so the chest tile is free for others.
        local away = math.max(1, tonumber(state.fleet_size) or 2)
        local clear_target = { x = dump.x + away, y = dump.y + 1, z = dump.z }
        nav.moveTo(clear_target)

        -- (4) PARK_REQ.
        if state.server_id then
            state.park_req_nonce = state.park_req_nonce + 1
            pcall(rednet.send, state.server_id, {
                type  = "PARK_REQ", hwid = state.hwid,
                nonce = state.park_req_nonce, pos = vec.copy(state.pos),
            }, cfg.PROTOCOL)
        end

        -- (5) Go to the assigned park slot (wait briefly for an assignment).
        local deadline = os.epoch("utc") + 3000
        while not state.park_pos and os.epoch("utc") < deadline do sleep(0.2) end
        if state.park_pos then
            nav.moveTo(state.park_pos)
        end

        -- (6) Done — brain transitions to PARKED and waits for CMD_START.
        self.done = true
        return true
    end

    return t
end

return M
