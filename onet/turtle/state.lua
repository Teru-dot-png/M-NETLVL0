-- /onet/turtle/state.lua
-- Mutable runtime state for a turtle. INFRA tier — reshaped to the V2 layout.
-- Every turtle module require()s this table and mutates it in place; Lua caches
-- the module result so all share one instance.

local M = {}

M.hwid      = string.format("MN-%04X", os.getComputerID() % 0xFFFF)
M.server_id = nil
M.pos       = { x = 0, y = 0, z = 0 }
M.facing    = 0    -- 0=N 1=E 2=S 3=W

-- Role (assigned by overseer ROLE_ASSIGN; defaults to MINER on cold boot).
M.role      = "MinerRole"

-- ── Hardware map (written once by hardware.detectHardware) ─
M.HW = {
    modem_side   = nil,
    pick_side    = nil,
    scanner_slot = nil,   -- should be 1 (§1.1)
    has_scanner  = false,
    has_pickaxe  = false,
    is_crafty    = false, -- crafting-table upgrade (GenesisRole only)
}

-- ── Overseer-assigned coordinates / lane / grid ───────────
M.dump            = nil
M.base            = nil
M.overseer_pos    = nil   -- for base-protection geofence (§4 MINING)
M.zone_chests     = {}    -- zone name -> {x,y,z} (for HaulerRole sorting)
M.my_dir          = 0
M.lane_offset     = 0
M.lane_positioned = false
M.park_pos        = nil
M.segment         = nil   -- current grid segment {sx,sy,sz,dir,len}

-- ── Run control ───────────────────────────────────────────
M.started         = false
M.home_requested  = false

-- ── Job queue (local autonomy: §2 agents queue their own tasks) ──
M.jobs            = {}
M.goto_job        = nil
M.search_job      = nil
M.reported        = {}    -- ore keys already reported this run
M.WANT_LIST       = {}

-- ── Misc counters ─────────────────────────────────────────
M.probe_ticks       = 0
M.fuel_retry_streak = 0

-- ── Move reservation / park request tracking ──────────────
M.reservation_nonce   = 0
M.reservation_pending = {}
M.park_req_nonce      = 0
M.park_req_pending    = {}

-- ── Navigation state (module-level so it survives a pcall) ─
M.nav_last_want      = nil
M.recent_tiles       = {}
M.recent_tile_index  = 1
M.RECENT_TILE_WINDOW = 24
M.nav_stuck_cnt      = 0
M.nav_prev_pos       = nil
M.block_movement     = false

-- ── State machine ─────────────────────────────────────────
M.current_state      = "STANDBY"
M.tunnelled          = 0
M.manual_goto_active = false

-- ── Scanner hot-swap lock (§1.1 / §11: prevents the pickaxe check
--    from racing the scanner swap and dumping the scanner) ──
M.scanning_now = false

-- ── World cache ───────────────────────────────────────────
M.world_cache = {}
M.cache_size  = 0

return M
