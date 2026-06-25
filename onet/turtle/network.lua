-- /onet/turtle/network.lua
-- The turtle's nervous system: modem open, handshake, park request, and the
-- listener thread. CORE — the AUTH handshake, RESERVE_ACK, PUSH yield and
-- direct YIELD handlers are ported verbatim from the debugged V1 listener; new
-- V2 handlers (ROLE_ASSIGN, SEGMENT_GRANT, SEARCH_JOB, COAL_LOC, PICK_ANSWER,
-- CRAFT_AUTH) are added alongside. Every handler type-checks its payload (§8).

local cfg     = require("config")
local state   = require("state")
local nav     = require("nav")
local movers  = require("movers")
local cache   = require("cache")
local vec     = require("vec")
local log     = require("log").log

local M = {}

-- ── Modem ─────────────────────────────────────────────────
function M.openModem()
    if not state.HW.modem_side then error("[FATAL] No modem found on either side.", 0) end
    rednet.open(state.HW.modem_side)
    log("NET", "Modem opened on " .. state.HW.modem_side .. ".")
end

-- ── Apply an AUTH_ACK / CONFIG style assignment payload ──
local function applyAssignment(msg)
    state.my_dir      = msg.dir         or state.my_dir
    state.lane_offset = msg.lane_offset or state.lane_offset
    state.dump        = msg.dump        or state.dump
    state.base        = msg.base        or state.base
    if type(msg.want_list) == "table" then state.WANT_LIST = msg.want_list end
    if msg.park_pos ~= nil then state.park_pos = msg.park_pos end
    if type(msg.overseer_pos) == "table" then state.overseer_pos = msg.overseer_pos end
    if type(msg.zone_chests) == "table" then state.zone_chests = msg.zone_chests end
    if type(msg.role) == "string" then state.role = msg.role end
    if state.dump then cache.cacheSet(state.dump.x, state.dump.y, state.dump.z, "minecraft:chest") end
    if state.base then cache.cacheSet(state.base.x, state.base.y, state.base.z, "minecraft:chest") end
end

-- ── Handshake (broadcast AUTH_REQ until an overseer ACKs) ─
function M.handshake()
    log("NET", string.format("Broadcasting AUTH_REQ pos (%d,%d,%d)...",
        state.pos.x, state.pos.y, state.pos.z))
    local attempts, max_attempts = 0, 24
    while not state.server_id and attempts < max_attempts do
        rednet.broadcast({
            type = "AUTH_REQ", hwid = state.hwid, pos = vec.copy(state.pos),
            crafty = state.HW.is_crafty,
        }, cfg.PROTOCOL)
        local sender, msg = rednet.receive(cfg.PROTOCOL, 5)
        if sender and type(msg) == "table" and msg.type == "AUTH_ACK" and msg.hwid == state.hwid then
            state.server_id = sender
            applyAssignment(msg)
            movers.face(state.my_dir)
            log("NET", string.format("Enlisted. role=%s dir=%d server=%d",
                state.role, state.my_dir, state.server_id))
        else
            attempts = attempts + 1
        end
    end
    return state.server_id ~= nil
end

-- ── PUSH yield helper (shared by PUSH_REQ + direct YIELD) ─
local function yieldAside(avoid)
    local yielded = movers.stepUp()
    if not yielded then
        for dir = 0, 3 do
            movers.face(dir)
            local nx = state.pos.x + vec.DIRV[dir].dx
            local nz = state.pos.z + vec.DIRV[dir].dz
            if not (avoid and nx == avoid.x and nz == avoid.z) then
                if movers.stepForward() then yielded = true; break end
            end
        end
    end
    if yielded then state.block_movement = true end
    return yielded
end

-- ── Listener thread ───────────────────────────────────────
function M.listenerThread_inner()
    while true do
        local sender, msg = rednet.receive(cfg.PROTOCOL)
        if type(msg) == "table" then
            local mt = msg.type

            -- Run control
            if mt == "CMD_START" then
                state.started = true
                pcall(rednet.send, state.server_id, { type = "PARK_RELEASE", hwid = state.hwid }, cfg.PROTOCOL)
                log("NET", "Start received.")
            elseif mt == "CMD_STOP" then
                state.started = false; log("NET", "Stop received.")
            elseif mt == "CMD_RECALL" then
                state.home_requested = true; log("NET", "Recall received.")

            -- Role assignment (Overmind: a miner can become a builder live)
            elseif mt == "ROLE_ASSIGN" and msg.hwid == state.hwid then
                if type(msg.role) == "string" then
                    state.role = msg.role
                    log("ROLE", "Reassigned to " .. msg.role)
                end

            -- Grid segment grant
            elseif mt == "SEGMENT_GRANT" and msg.hwid == state.hwid then
                if type(msg.segment) == "table" then
                    state.segment = msg.segment
                    log("NET", "Segment granted: " .. tostring(msg.segment.len) .. " blocks.")
                end

            -- Live config update
            elseif mt == "CONFIG" then
                applyAssignment(msg)
                log("NET", "Config updated.")

            -- Late AUTH_ACK
            elseif mt == "AUTH_ACK" and msg.hwid == state.hwid then
                state.server_id = sender
                applyAssignment(msg)
                movers.face(state.my_dir)
                log("NET", "Late AUTH_ACK accepted. Server=" .. state.server_id)

            -- GOTO / SEARCH jobs (consumed by the role's state machine)
            elseif mt == "GOTO" and msg.hwid == state.hwid and type(msg.pos) == "table" then
                state.goto_job = { pos = msg.pos, ore = msg.ore or "ore" }
                log("NET", "GOTO job queued.")
            elseif mt == "SEARCH_JOB" and msg.hwid == state.hwid and type(msg.pos) == "table" then
                state.search_job = { pos = msg.pos, ore = msg.ore or "ore", amount = msg.amount }
                log("NET", "SEARCH job queued: " .. tostring(msg.ore))

            -- Query answers
            elseif mt == "COAL_LOC" and msg.hwid == state.hwid then
                if type(msg.pos) == "table" then state.coal_loc = msg.pos end
            elseif mt == "PICK_ANSWER" and msg.hwid == state.hwid then
                state.pick_available = (msg.available == true)

            -- Genesis authorisation
            elseif mt == "CRAFT_AUTH" and msg.hwid == state.hwid then
                state.craft_authorized = (msg.authorized == true)
                log("GENESIS", "Craft auth: " .. tostring(state.craft_authorized))

            -- Reservation ACK
            elseif mt == "RESERVE_ACK" and msg.hwid == state.hwid then
                local nonce = tonumber(msg.nonce)
                if nonce and state.reservation_pending[nonce] then
                    state.reservation_pending[nonce].done    = true
                    state.reservation_pending[nonce].granted = (msg.granted == true)
                end

            -- Strict park assignment
            elseif mt == "PARK_ASSIGN" and msg.hwid == state.hwid then
                if type(msg.pos) == "table" then
                    state.park_pos = msg.pos; state.started = false; state.home_requested = false
                    log("NET", string.format("Park assigned: (%d,%d,%d)",
                        msg.pos.x, msg.pos.y, msg.pos.z))
                end
                local nonce = tonumber(msg.nonce)
                if nonce and state.park_req_pending[nonce] then
                    state.park_req_pending[nonce].done = true
                    state.park_req_pending[nonce].ok   = (type(msg.pos) == "table")
                end

            -- PUSH protocol: yield if we are blocking a higher-urgency turtle
            elseif mt == "PUSH_REQ" and msg.hwid ~= state.hwid then
                local want = msg.want
                if type(want) == "table" then
                    local at_target = vec.equals(state.pos, want)
                    local our_pri   = cfg.PRIORITY[state.current_state] or 10
                    local their_pri = tonumber(msg.priority) or 10
                    if at_target and our_pri >= their_pri then
                        log("PUSH", "Yielding to " .. tostring(msg.hwid))
                        if not yieldAside(msg.at) then log("PUSH", "Could not yield.") end
                    end
                end

            -- Overseer direct YIELD
            elseif mt == "YIELD" and msg.hwid == state.hwid then
                log("PUSH", "Overseer YIELD. Stepping aside...")
                local ok = yieldAside(nil)
                if sender then
                    pcall(rednet.send, sender, {
                        type = "YIELD_ACK", hwid = state.hwid, ok = ok,
                        pos = vec.copy(state.pos), state = state.current_state,
                    }, cfg.PROTOCOL)
                end
            end
        end
    end
end

return M
