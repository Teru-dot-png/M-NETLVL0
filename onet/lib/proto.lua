-- /onet/lib/proto.lua  (SHARED — byte-identical on turtle + overseer)
-- Every rednet message TYPE defined ONCE, in one place, so both sides agree.
-- A typo here is a protocol break; centralising it makes that impossible to
-- introduce silently in a handler.

local M = {}

M.PROTOCOL = "ONET_V2"

-- ── Turtle -> Overseer ────────────────────────────────────
M.AUTH_REQ    = "AUTH_REQ"
M.HEARTBEAT   = "HEARTBEAT"
M.GEO_DATA    = "GEO_DATA"
M.ORE_REPORT  = "ORE_REPORT"
M.ORE_MINED   = "ORE_MINED"
M.ALERT       = "ALERT"
M.PUSH_REQ    = "PUSH_REQ"
M.SEGMENT_REQ = "SEGMENT_REQ"
M.PARK_REQ    = "PARK_REQ"
M.RESERVE_REQ = "RESERVE_REQ"
M.RESERVE_REL = "RESERVE_REL"
M.COAL_QUERY  = "COAL_QUERY"
M.PICK_QUERY  = "PICK_QUERY"
M.ZONE_MAP    = "ZONE_MAP"     -- builder broadcasts the storage layout
M.CRAFT_DONE  = "CRAFT_DONE"   -- genesis confirms a new turtle exists
M.YIELD_ACK   = "YIELD_ACK"

-- ── Overseer -> Turtle ────────────────────────────────────
M.AUTH_ACK      = "AUTH_ACK"
M.CONFIG        = "CONFIG"
M.CMD_START     = "CMD_START"
M.CMD_STOP      = "CMD_STOP"
M.CMD_RECALL    = "CMD_RECALL"
M.ROLE_ASSIGN   = "ROLE_ASSIGN"
M.SEGMENT_GRANT = "SEGMENT_GRANT"
M.GOTO          = "GOTO"
M.SEARCH_JOB    = "SEARCH_JOB"
M.PARK_ASSIGN   = "PARK_ASSIGN"
M.RESERVE_ACK   = "RESERVE_ACK"
M.COAL_LOC      = "COAL_LOC"
M.PICK_ANSWER   = "PICK_ANSWER"
M.CRAFT_AUTH    = "CRAFT_AUTH"
M.YIELD         = "YIELD"

-- Build a well-formed message table. `fields` is merged in.
-- Always stamps `type`; callers should add hwid where relevant.
function M.msg(mtype, fields)
    local t = { type = mtype }
    if type(fields) == "table" then
        for k, v in pairs(fields) do t[k] = v end
    end
    return t
end

-- Defensive type-check helper for handlers (§8: tolerate malformed payloads).
function M.isTable(x) return type(x) == "table" end
function M.num(x, default)
    local n = tonumber(x)
    if n == nil then return default end
    return n
end
function M.str(x, default)
    if type(x) == "string" then return x end
    return default
end

return M
