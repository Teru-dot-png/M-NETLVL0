-- /onet/config.lua
-- O-NET V2 — single source of truth for all tunable constants.
-- Pure data. No hardware calls, no requires, no mutable runtime state.
--
-- NOTE (§1.2): keep top-level locals minimal. This file declares exactly one
-- local (M) and returns it; everything else is a field, not a local.

local M = {}

-- ── Protocol ──────────────────────────────────────────────
M.PROTOCOL = "ONET_V2"

-- ── Reserved inventory slots (§1.1 — NON-NEGOTIABLE) ──────
-- Slot 1 = geo scanner, slot 2 = diamond pickaxe. Cargo is slots 3..16.
-- Tool protection keys on these slot NUMBERS *before* any getItemDetail call,
-- because NBT/Forge-tagged tools can make getItemDetail return nil and trick a
-- naive "is this a tool?" check into dumping the scanner.
M.SLOT_SCANNER = 1
M.SLOT_PICKAXE = 2
M.CARGO_FIRST  = 3
M.CARGO_LAST   = 16
M.CARGO_COUNT  = 14   -- slots 3..16

M.SCANNER_ITEM = "advancedperipherals:geo_scanner"
M.PICKAXE_ITEM = "minecraft:diamond_pickaxe"

-- ── Sensing ───────────────────────────────────────────────
M.SCAN_RADIUS   = 8
M.SCAN_EVERY    = 4     -- heartbeats between idle background scans
M.HEARTBEAT_INT = 3     -- seconds

-- ── Fuel thresholds ───────────────────────────────────────
M.FUEL_MIN      = 200   -- below this -> RTB_FUEL
M.FUEL_TARGET   = 500   -- refuel up to (not over) this
M.FUEL_CRITICAL = 80    -- emergency forage threshold
M.FORAGE_MAX    = 32

-- ── Grid mining (§5) ──────────────────────────────────────
M.GRID_SPACING  = 5     -- one 1-wide tunnel every 5 blocks -> 4-block pillars
M.SEGMENT_LEN   = 16    -- default segment length handed to a miner
M.MAX_TUNNEL    = 256
M.DIRECTIONS    = { 0, 1, 2, 3 }   -- cardinal lanes for load balancing

-- ── Base protection (§4 MINING) ───────────────────────────
-- No block within this manhattan distance of the overseer position is broken.
M.BASE_PROTECTION_RADIUS = 32

-- ── Navigation tuning ─────────────────────────────────────
M.STUCK_VALUE     = 2
M.REPATH_PROB     = 0.125
M.RESERVE_TTL_MS  = 1400
M.RESERVE_WAIT_MS = 700
M.WAYPOINT_DIST   = 32
M.CAL_FILE        = "onet_cal.cfg"

-- ── Population / self-replication (§7.4) ──────────────────
M.TARGET_FLEET   = 6      -- hard cap; replace-on-loss only
M.LOSS_TIMEOUT   = 60000  -- ms of silence => turtle declared dead

-- ── Overseer timing ───────────────────────────────────────
M.HB_TIMEOUT       = 12000  -- ms; roster prune threshold
M.DISP_REFRESH     = 0.5
M.MAP_SAVE_INTERVAL= 60     -- seconds
M.CONFIG_FILE      = "onet_overseer.cfg"
M.MAP_FILE         = "onet_map.dat"
M.AIR_MARKER       = "__air__"
M.CLUSTER_RADIUS   = 4
M.ORE_FEED_MAX     = 8
M.VOL_SOLID_TTL_MS = 180000

-- ── State priorities (lower = more urgent, never yields) ──
-- Used both by the turtle brain and the overseer push broker.
M.PRIORITY = {
    GOTO       = 1,
    RTB_FUEL   = 2,
    RTB_DUMP   = 3,
    FETCH_PICK = 4,
    MINING     = 5,
    SEARCH     = 6,
    BUILDER    = 7,
    GENESIS    = 7,
    STANDBY    = 8,
    PARKED     = 9,
}

-- ── Storage zones (§6) ────────────────────────────────────
M.ZONES = { "ORES", "FUEL", "BUILDING_MAT", "GENESIS_MAT" }

-- ── Genesis recipe — raw materials required per turtle (§7.1) ──
-- The final assembly is a single turtle.craft(); this table is what the
-- Builder must have smelted/gathered into GENESIS_MAT first.
M.GENESIS_RECIPE = {
    gold_ingot   = 27, -- enough for 1 advanced modem and 1 advanced computer, then turn the advanced computer into turtle
    diamonds     = 3,  -- pickaxe
    stone        = 22,
    planks       = 8,
    sticks       = 2,
    glass_pane   = 1,
    redstone     = 1,
    ender_pearl  = 1,
    ender_eye    = 1,   -- player-supplied; the only manual input necessary for Advanced ender modems, which are required for self-replication.
}

-- ── Roles ─────────────────────────────────────────────────
M.ROLES = {
    MINER   = "MinerRole",
    HAULER  = "HaulerRole",
    SCOUT   = "ScoutRole",
    REFUEL  = "RefuelRole",
    BUILDER = "BuilderRole",
    GENESIS = "GenesisRole",
}

return M
