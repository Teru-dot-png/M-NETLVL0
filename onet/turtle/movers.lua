-- /onet/turtle/movers.lua
-- Raw movement primitives + protected-aware digging. Every function that
-- physically moves the turtle lives here and updates state.pos / state.facing.
-- SURVIVAL tier: the lava/fluid guards and the NEVER_BREAK delegation are the
-- only reason turtles don't die in caves or eat the base.

local cfg    = require("config")
local state  = require("state")
local cache  = require("cache")
local vec    = require("vec")
local blocks = require("blocks")
local log    = require("log").log

local M = {}

-- ── Classifiers (delegate to the shared block library) ────
M.isDiggable = blocks.isDiggable
M.isPassable = blocks.isPassable

-- ── Base-protection geofence (§4 MINING / §5) ─────────────
-- No block within BASE_PROTECTION_RADIUS (manhattan) of the overseer is ever
-- broken, so the fleet can never mine out the computer it depends on.
function M.withinBaseProtection(x, y, z)
    local o = state.overseer_pos
    if not o then return false end
    return vec.manhattan({ x = x, y = y, z = z }, o) < cfg.BASE_PROTECTION_RADIUS
end

local function blockIsFluid(ok, data)
    if not ok or type(data) ~= "table" then return false end
    local n = data.name or ""
    return n:find("lava") ~= nil or n:find("water") ~= nil
end
function M.isLavaAhead() local ok, d = turtle.inspect();     return blockIsFluid(ok, d) end
function M.isLavaUp()    local ok, d = turtle.inspectUp();   return blockIsFluid(ok, d) end
function M.isLavaDown()  local ok, d = turtle.inspectDown(); return blockIsFluid(ok, d) end

-- ── Turning (updates state.facing) ────────────────────────
function M.turnRight() turtle.turnRight(); state.facing = (state.facing + 1) % 4 end
function M.turnLeft()  turtle.turnLeft();  state.facing = (state.facing + 3) % 4 end

function M.face(target)
    if state.facing == target then return end
    while state.facing ~= target do
        if (target - state.facing) % 4 == 1 then M.turnRight() else M.turnLeft() end
    end
end

-- ── Protected-aware dig helpers ───────────────────────────
local function digGeneric(inspectFn, digFn, nx, ny, nz, tag)
    local ok, data = inspectFn()
    if not ok then return true end
    local name = type(data) == "table" and data.name or ""
    cache.cacheSet(nx, ny, nz, name)
    if M.isPassable(name) then return true end
    if M.withinBaseProtection(nx, ny, nz) then
        log("NAV", "BASE-PROTECT: refusing dig at (" .. nx .. "," .. ny .. "," .. nz .. ")")
        return false
    end
    if not M.isDiggable(name) then log("NAV", tag .. " PROTECTED: [" .. name .. "]"); return false end
    for _ = 1, 10 do
        digFn()
        local ok2 = inspectFn()
        if not ok2 then cache.cacheSet(nx, ny, nz, "air"); return true end
        sleep(0.1)
    end
    return false
end

function M.digSafe()
    local d = vec.DIRV[state.facing]; local p = state.pos
    return digGeneric(turtle.inspect, turtle.dig, p.x + d.dx, p.y, p.z + d.dz, "")
end
function M.digSafeUp()
    local p = state.pos
    return digGeneric(turtle.inspectUp, turtle.digUp, p.x, p.y + 1, p.z, "(up)")
end
function M.digSafeDown()
    local p = state.pos
    return digGeneric(turtle.inspectDown, turtle.digDown, p.x, p.y - 1, p.z, "(dn)")
end

-- ── Navigation steps (refuse to punch protected blocks) ───
function M.stepForward()
    cache.liveInspect()
    if M.isLavaAhead() then return false end
    local d = vec.DIRV[state.facing]; local p = state.pos
    if turtle.forward() then p.x = p.x + d.dx; p.z = p.z + d.dz; return true end
    if not M.digSafe() then return false end
    if turtle.forward() then p.x = p.x + d.dx; p.z = p.z + d.dz; return true end
    return false
end

function M.stepUp()
    if M.isLavaUp() then return false end
    if turtle.up() then state.pos.y = state.pos.y + 1; return true end
    if not M.digSafeUp() then return false end
    if turtle.up() then state.pos.y = state.pos.y + 1; return true end
    return false
end

function M.stepDown()
    if M.isLavaDown() then return false end
    if turtle.down() then state.pos.y = state.pos.y - 1; return true end
    if not M.digSafeDown() then return false end
    if turtle.down() then state.pos.y = state.pos.y - 1; return true end
    return false
end

-- ── Mining forward (MINING state, not navigation) ─────────
-- Digs through any diggable block, marks the new cell air, and broadcasts a
-- GEO_DATA(air) so the overseer's voxel map clears it live.
function M.forward()
    cache.liveInspect()
    if M.isLavaAhead() then log("MINE", "Lava ahead. Skipping."); return false end
    local d = vec.DIRV[state.facing]; local p = state.pos
    local nx, nz = p.x + d.dx, p.z + d.dz

    if M.withinBaseProtection(nx, p.y, nz) then
        log("MINE", "BASE-PROTECT zone ahead. Halting mine.")
        return false
    end

    local function onSuccess()
        cache.cacheSet(nx, p.y, nz, "air")
        p.x = nx; p.z = nz
        if state.server_id then
            pcall(rednet.send, state.server_id, {
                type      = "GEO_DATA",
                hwid      = state.hwid,
                pos       = vec.copy(p),
                scan_data = { { x = 0, y = 0, z = 0, name = "minecraft:air" } },
            }, cfg.PROTOCOL)
        end
        return true
    end

    if turtle.forward() then return onSuccess() end
    if not turtle.detect() then return false end
    for _ = 1, 64 do
        if not turtle.dig() then turtle.attack() end
        if turtle.forward() then return onSuccess() end
        sleep(0.15)
    end
    return false
end

return M
