-- /onet/lib/grid.lua  (SHARED — byte-identical on turtle + overseer)
-- Grid math for §5 grid mining. The overseer holds an origin (its GPS pos) and
-- GRID_SPACING. Segments are edges between intersections; this module converts
-- between world coords, grid-cell indices, and segment endpoints.
--
-- A segment is described by { sx, sy, sz, dir, len }:
--   start intersection (world coords) + facing dir (0..3) + length in blocks.

local cfg = require("config")
local vec = require("vec")

local M = {}
local floor = math.floor

-- World coordinate -> nearest grid intersection index (integer cell coords).
function M.worldToCell(x, z, origin, spacing)
    spacing = spacing or cfg.GRID_SPACING
    origin  = origin or { x = 0, z = 0 }
    return floor((x - origin.x) / spacing + 0.5),
           floor((z - origin.z) / spacing + 0.5)
end

-- Grid intersection index -> world coordinate of that intersection.
function M.cellToWorld(cx, cz, y, origin, spacing)
    spacing = spacing or cfg.GRID_SPACING
    origin  = origin or { x = 0, z = 0 }
    return {
        x = origin.x + cx * spacing,
        y = y,
        z = origin.z + cz * spacing,
    }
end

-- Canonical key for a segment so the gridmap can mark assigned/mined/exhausted.
function M.segKey(seg)
    return string.format("%d:%d:%d:%d:%d",
        floor(seg.sx), floor(seg.sy), floor(seg.sz),
        floor(seg.dir), floor(seg.len))
end

-- The world endpoint of a segment (where the miner finishes).
function M.segEnd(seg)
    local d = vec.DIRV[seg.dir] or vec.DIRV[0]
    return {
        x = floor(seg.sx) + d.dx * seg.len,
        y = floor(seg.sy),
        z = floor(seg.sz) + d.dz * seg.len,
    }
end

-- Every block coordinate a segment will dig (1-wide; caller handles 2-tall).
function M.segBlocks(seg)
    local d = vec.DIRV[seg.dir] or vec.DIRV[0]
    local out = {}
    for i = 1, seg.len do
        out[#out + 1] = {
            x = floor(seg.sx) + d.dx * i,
            y = floor(seg.sy),
            z = floor(seg.sz) + d.dz * i,
        }
    end
    return out
end

return M
