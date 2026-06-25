-- /onet/overseer/state.lua
-- Mutable overseer state. One instance shared by every overseer module via the
-- require() cache. INFRA tier.

local cfg = require("config")

local M = {}

-- ── Operator-set, persisted config ────────────────────────
M.DUMP_CHEST = nil          -- {x,y,z}
M.BASE_CHEST = nil
M.PARK_ZONE  = nil          -- {x1,y1,z1,x2,y2,z2}
M.WANT_LIST  = {}           -- normalized ore name -> true

-- ── Grid (origin = overseer GPS position) ─────────────────
M.overseer_pos = nil        -- {x,y,z}; also the base-protection centre
M.grid_origin  = nil        -- {x,z}
M.segments     = {}         -- segKey -> { seg, status="assigned"|"mined", hwid }
M.lane_counters= { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }

-- ── Fleet roster ──────────────────────────────────────────
M.fleet      = {}           -- hwid -> {net_id, role, status, pos, dir, fuel, free, last_pulse, crafty}
M.fleet_slot = 0

-- ── Park claims ───────────────────────────────────────────
M.park_claim_by_hwid = {}
M.park_claim_by_key  = {}

-- ── Voxel map ─────────────────────────────────────────────
M.master_voxels   = {}      -- [y][x][z] = name
M.total_voxels    = 0
M.volatile_solids = {}      -- key -> {x,y,z,ts}
M.map_dirty       = false
M.last_map_save   = 0
M.map_persist_enabled = true

-- ── Ore tracking / clustering ─────────────────────────────
M.ore_log    = {}           -- ore -> count
M.clusters   = {}           -- {ore,cx,cy,cz,count,dispatched}
M.ORE_FEED   = {}           -- ring buffer for display
M.dispatched = {}

-- ── getme orders ──────────────────────────────────────────
M.active_orders = {}        -- ore -> {target,got,jobs}

-- ── Reservations ──────────────────────────────────────────
M.reservations = {}         -- key -> {hwid, ts}

-- ── Storage zones (§6) ────────────────────────────────────
-- name -> { chest = {x,y,z}, contents = {item->count} }
M.zones = {}
for _, z in ipairs(cfg.ZONES) do M.zones[z] = { chest = nil, contents = {} } end

-- ── Population / replication ──────────────────────────────
M.target_fleet     = cfg.TARGET_FLEET
M.craft_authorized = false
M.genesis_hwid     = nil

-- ── Display / runtime ─────────────────────────────────────
M.view_cx   = 0
M.view_cz   = 0
M.view_y    = 64
M.BOOT_TIME = os.epoch("utc")
M.alert_log = {}
M.mon       = nil
M.vault     = nil

return M
