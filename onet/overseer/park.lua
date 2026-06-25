-- /onet/overseer/park.lua
-- Parking-zone claim tracking. SURVIVAL: once the fleet is bigger than ~3,
-- without per-slot claims turtles park on top of each other and deadlock.

local cfg   = require("config")
local state = require("state")

local M = {}
local floor = math.floor

function M.parkPosKey(p) return floor(p.x)..":"..floor(p.y)..":"..floor(p.z) end

function M.clearParkClaim(hwid)
    local old = state.park_claim_by_hwid[hwid]
    if old and old.key then state.park_claim_by_key[old.key] = nil end
    state.park_claim_by_hwid[hwid] = nil
end

function M.clearAllParkClaims()
    state.park_claim_by_hwid = {}
    state.park_claim_by_key  = {}
end

function M.isOccupiedByOther(pos, requester)
    for hwid, f in pairs(state.fleet) do
        if hwid ~= requester and f.pos then
            if floor(f.pos.x or 0) == floor(pos.x) and floor(f.pos.y or 0) == floor(pos.y)
            and floor(f.pos.z or 0) == floor(pos.z) then
                return true
            end
        end
    end
    return false
end

-- Nearest unclaimed park slot to ref; claims it for hwid.
function M.assignUnclaimedSlot(hwid, ref)
    if not state.PARK_ZONE then return nil end
    local PZ = state.PARK_ZONE
    local x1, x2 = math.min(PZ.x1, PZ.x2), math.max(PZ.x1, PZ.x2)
    local y      = math.min(PZ.y1, PZ.y2)
    local z1, z2 = math.min(PZ.z1, PZ.z2), math.max(PZ.z1, PZ.z2)

    M.clearParkClaim(hwid)
    local best, best_d = nil, math.huge
    local rx = floor((ref and ref.x) or x1)
    local ry = floor((ref and ref.y) or y)
    local rz = floor((ref and ref.z) or z1)

    for z = z1, z2 do
        for x = x1, x2 do
            local p = { x = x, y = y, z = z }
            local k = M.parkPosKey(p)
            local owner = state.park_claim_by_key[k]
            if owner and not state.fleet[owner] then state.park_claim_by_key[k] = nil; owner = nil end
            if (not owner or owner == hwid) and not M.isOccupiedByOther(p, hwid) then
                local d = math.abs(x - rx) + math.abs(y - ry) + math.abs(z - rz)
                if d < best_d then best_d = d; best = p end
            end
        end
    end
    if best then
        local k = M.parkPosKey(best)
        state.park_claim_by_key[k] = hwid
        state.park_claim_by_hwid[hwid] = { key = k, pos = best }
    end
    return best
end

-- Fallback sequential slot when no PARK_ZONE is configured.
function M.getSlot(index)
    if not state.PARK_ZONE then return nil end
    local PZ = state.PARK_ZONE
    local x1, x2 = math.min(PZ.x1, PZ.x2), math.max(PZ.x1, PZ.x2)
    local y      = math.min(PZ.y1, PZ.y2)
    local z1, z2 = math.min(PZ.z1, PZ.z2), math.max(PZ.z1, PZ.z2)
    local cols   = x2 - x1 + 1
    local total  = cols * (z2 - z1 + 1)
    local idx    = index % total
    return { x = x1 + (idx % cols), y = y, z = z1 + floor(idx / cols) }
end

return M
