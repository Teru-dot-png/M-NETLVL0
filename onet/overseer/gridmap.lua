-- /onet/overseer/gridmap.lua
-- Authoritative grid state (§5). The origin is the overseer's GPS position. A
-- lane is a direction + perpendicular offset; segments are handed out one at a
-- time along a lane, starting beyond the base-protection radius so the first
-- dig is always legal. Mined segments advance that lane's frontier.

local cfg   = require("config")
local state = require("state")
local grid  = require("grid")
local vec   = require("vec")
local log   = require("log").log

local M = {}

function M.setOrigin(pos)
    state.overseer_pos = { x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z) }
    state.grid_origin  = { x = state.overseer_pos.x, z = state.overseer_pos.z }
    log("OVERSEER", string.format("Grid origin set to (%d,%d,%d)",
        state.overseer_pos.x, state.overseer_pos.y, state.overseer_pos.z))
end

-- Assign a lane (direction + perpendicular offset) to a turtle, load-balanced
-- across the four cardinal directions.
function M.assignLane(hwid)
    local best_dir, best_count = 0, math.huge
    for _, d in ipairs(cfg.DIRECTIONS or { 0, 1, 2, 3 }) do
        if state.lane_counters[d] < best_count then best_count = state.lane_counters[d]; best_dir = d end
    end
    local offset = state.lane_counters[best_dir] * cfg.GRID_SPACING
    state.lane_counters[best_dir] = state.lane_counters[best_dir] + 1
    return best_dir, offset
end

state.lane_progress = state.lane_progress or {}

-- Hand the next unmined segment for a turtle's lane.
function M.nextSegment(hwid)
    local f = state.fleet[hwid]
    if not f or not state.overseer_pos then return nil end
    local dir    = f.dir or 0
    local offset = f.lane_offset or 0
    local key    = dir .. ":" .. offset
    local k      = state.lane_progress[key] or 0

    local o    = state.overseer_pos
    local along= vec.DIRV[dir]
    local perp = vec.DIRV[(dir + 1) % 4]
    local startDist = cfg.BASE_PROTECTION_RADIUS + k * cfg.SEGMENT_LEN

    local seg = {
        sx  = o.x + perp.dx * offset + along.dx * startDist,
        sy  = o.y,
        sz  = o.z + perp.dz * offset + along.dz * startDist,
        dir = dir,
        len = cfg.SEGMENT_LEN,
    }
    state.lane_progress[key] = k + 1
    state.segments[grid.segKey(seg)] = { seg = seg, status = "assigned", hwid = hwid }
    return seg
end

function M.markMined(segKey)
    local rec = state.segments[segKey]
    if rec then rec.status = "mined" end
end

return M
