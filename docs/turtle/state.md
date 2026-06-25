# turtle/state.lua — Turtle runtime state

Source: [../../onet/turtle/state.lua](../../onet/turtle/state.lua)

## Purpose

`state` is the single mutable runtime-state table for a turtle (INFRA tier).
Every turtle module `require()`s it and mutates it in place; because Lua caches a
module's return value, all modules share **one** instance. There are no functions
here — only fields, several of which are **forward-declared** (initialised to a
neutral value at boot so that modules loaded later can reference them without an
ordering hazard, and so the field survives a `pcall` thread restart).

## Place in the architecture

This is the shared blackboard for the whole turtle runtime. The brain reads/writes
`role`, `current_state`, and job fields; [network.lua](network.md) writes the
overseer-assigned coordinates and flags; [nav.lua](nav.md) keeps its navigation
bookkeeping here (deliberately module-level so it survives a `pcall`);
[scanner.lua](scanner.md) toggles the `scanning_now` hot-swap lock;
[cache.lua](cache.md) owns `world_cache`/`cache_size`. Defaults match
[config.lua](../config.md).

---

## Fields

### Identity & pose
- **`hwid`** (string) — stable hardware id, `string.format("MN-%04X", os.getComputerID() % 0xFFFF)`. Used in every outbound message.
- **`server_id`** (number|nil) — Rednet id of the enlisted overseer; `nil` until the AUTH handshake succeeds.
- **`pos`** (`{x,y,z}`) — current world position, updated by [movers](movers.md)/[calibrate](calibrate.md).
- **`facing`** (number 0–3) — current heading (0=N,1=E,2=S,3=W), updated by `movers.turn*`.

### Role
- **`role`** (string) — current role name; defaults to `"MinerRole"` on cold boot. Set by overseer `ROLE_ASSIGN`/`AUTH_ACK`; the brain hot-swaps when it changes.

### `HW` — hardware map (written once by `hardware.detectHardware`)
- **`modem_side`**, **`pick_side`** (string|nil) — peripheral sides.
- **`scanner_slot`** (number|nil) — should be `1` (§1.1); can move during a hot-swap.
- **`has_scanner`**, **`has_pickaxe`** (boolean) — tool presence flags.
- **`is_crafty`** (boolean) — crafting-table upgrade present (GenesisRole gate).

### Overseer-assigned coordinates / lane / grid
- **`dump`**, **`base`** (`{x,y,z}`|nil) — drop-off and pickaxe-fetch chests.
- **`overseer_pos`** (`{x,y,z}`|nil) — centre of the §4 base-protection geofence.
- **`zone_chests`** (table) — zone name → `{x,y,z}` for Hauler sorting.
- **`my_dir`** (number) — assigned lane facing; **`lane_offset`** (number), **`lane_positioned`** (boolean).
- **`park_pos`** (`{x,y,z}`|nil) — assigned parking slot.
- **`segment`** (table|nil) — current grid segment `{sx,sy,sz,dir,len}`.

### Run control
- **`started`** (boolean) — set by `CMD_START`/`CMD_STOP`.
- **`home_requested`** (boolean) — recall flag; the brain short-circuits to PARKED while true.

### Job queue (local autonomy, §2)
- **`jobs`** (array), **`goto_job`**, **`search_job`** (table|nil) — queued work from the overseer.
- **`reported`** (table) — set of ore world-keys already reported this run (dedup).
- **`WANT_LIST`** (table) — operator-requested ore names.

### Counters
- **`probe_ticks`**, **`fuel_retry_streak`** (number).

### Move reservation / park tracking
- **`reservation_nonce`** (number), **`reservation_pending`** (table) — keyed by nonce, each `{done, granted}`.
- **`park_req_nonce`** (number), **`park_req_pending`** (table) — each `{done, ok}`.

### Navigation state (module-level so it survives a pcall)
- **`nav_last_want`** (`{x,y,z}`|nil) — last tile the greedy step tried; reused for PUSH_REQ.
- **`recent_tiles`** (array), **`recent_tile_index`** (number), **`RECENT_TILE_WINDOW`** = 24 — ring buffer for the A\* recent-tile penalty.
- **`nav_stuck_cnt`** (number), **`nav_prev_pos`** (`{x,y,z}`|nil) — stuck detection.
- **`block_movement`** (boolean) — one-shot movement veto set after a yield.

### State machine
- **`current_state`** (string) — current move state; defaults to `"STANDBY"`. Drives move **priority** via `cfg.PRIORITY` for the push/reservation protocol.
- **`tunnelled`** (number), **`manual_goto_active`** (boolean).

### Scanner hot-swap lock (§1.1 / §11)
- **`scanning_now`** (boolean) — set true by [scanner.lua](scanner.md) around the equip/scan/equip-back sequence. **Invariant:** while true, the inventory/pickaxe protection logic must not act, or it could race the swap and dump the scanner.

### World cache
- **`world_cache`** (table) — `vec.key` → block name, the navigator's view of the world.
- **`cache_size`** (number) — running count of distinct cells, maintained by [cache.cacheSet](cache.md).
