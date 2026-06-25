-- /onet/turtle/cache.lua
-- World block cache keyed by (x,y,z). Also owns liveInspect(), which fills the
-- cache from the turtle's three reachable faces without spending a geo scan.

local vec   = require("vec")
local state = require("state")

local M = {}
local floor = math.floor

-- Geo scanner sometimes reports the turtle itself; never let that harden into
-- a map solid.
function M.isScanNoise(name)
    return tostring(name or ""):lower():find("turtle", 1, true) ~= nil
end

function M.cacheSet(x, y, z, name)
    local k = vec.key(x, y, z)
    if not state.world_cache[k] then state.cache_size = state.cache_size + 1 end
    state.world_cache[k] = name
end

function M.cacheGet(x, y, z)
    return state.world_cache[vec.key(x, y, z)]
end

function M.feedCache(scan, origin)
    if type(scan) ~= "table" or type(origin) ~= "table" then return end
    for _, b in ipairs(scan) do
        if type(b) == "table" and type(b.name) == "string" then
            if not M.isScanNoise(b.name) then
                M.cacheSet(
                    floor(origin.x + (b.x or 0)),
                    floor(origin.y + (b.y or 0)),
                    floor(origin.z + (b.z or 0)),
                    b.name)
            end
        end
    end
end

-- Inspect the three immediately reachable faces and write results to cache.
function M.liveInspect()
    local pos    = state.pos
    local facing = state.facing
    local d      = vec.DIRV[facing]

    local function store(ok, data, nx, ny, nz)
        if ok and type(data) == "table" and data.name then
            M.cacheSet(nx, ny, nz, data.name)
        elseif not ok then
            M.cacheSet(nx, ny, nz, "air")
        end
    end

    local ok_f, dat_f = turtle.inspect()
    local ok_u, dat_u = turtle.inspectUp()
    local ok_d, dat_d = turtle.inspectDown()
    store(ok_f, dat_f, pos.x + d.dx, pos.y,     pos.z + d.dz)
    store(ok_u, dat_u, pos.x,        pos.y + 1, pos.z)
    store(ok_d, dat_d, pos.x,        pos.y - 1, pos.z)
end

return M
