-- /onet/lib/vec.lua  (SHARED — byte-identical on turtle + overseer)
-- Coordinate helpers. Positions are plain {x=,y=,z=} tables throughout O-NET.
-- Pure functions, no state, unit-testable.

local M = {}
local floor = math.floor

function M.copy(p)
    return { x = p.x, y = p.y, z = p.z }
end

-- Canonical string key for map/reservation tables. Always integer-floored so
-- "12.0" and "12" collapse to the same cell.
function M.key(x, y, z)
    if type(x) == "table" then
        return floor(x.x)..":"..floor(x.y)..":"..floor(x.z)
    end
    return floor(x)..":"..floor(y)..":"..floor(z)
end

function M.add(a, b)
    return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function M.equals(a, b)
    if not a or not b then return false end
    return floor(a.x) == floor(b.x)
       and floor(a.y) == floor(b.y)
       and floor(a.z) == floor(b.z)
end

-- Manhattan distance — the metric the navigator and dispatcher both use.
function M.manhattan(a, b)
    return math.abs(floor(a.x) - floor(b.x))
         + math.abs(floor(a.y) - floor(b.y))
         + math.abs(floor(a.z) - floor(b.z))
end

-- facing index (0=N,1=E,2=S,3=W) -> unit delta on the XZ plane
M.DIRV = {
    [0] = { dx = 0,  dz = -1 },
    [1] = { dx = 1,  dz = 0  },
    [2] = { dx = 0,  dz = 1  },
    [3] = { dx = -1, dz = 0  },
}

-- 6-neighbourhood used by A*. dir = -1 up, -2 down (no facing change).
M.DIRS6 = {
    { dx = 0,  dy = 0,  dz = -1, dir = 0  },
    { dx = 1,  dy = 0,  dz = 0,  dir = 1  },
    { dx = 0,  dy = 0,  dz = 1,  dir = 2  },
    { dx = -1, dy = 0,  dz = 0,  dir = 3  },
    { dx = 0,  dy = 1,  dz = 0,  dir = -1 },
    { dx = 0,  dy = -1, dz = 0,  dir = -2 },
}

return M
