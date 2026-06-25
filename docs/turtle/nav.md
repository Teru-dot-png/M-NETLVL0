# turtle/nav.lua — Pathfinder

Source: [../../onet/turtle/nav.lua](../../onet/turtle/nav.lua)

## Purpose

`nav` is THE pathfinder. CORE — ported **verbatim** from the debugged V1
implementation; only the module boundaries changed (calibration moved to
[calibrate.lua](calibrate.md), coordinate helpers to [vec.lua](../lib/vec.md),
logging to [log.lua](../lib/log.md)). The strategy ladder is: greedy axis step →
local A\* detour → recovery spiral → climb-over, with position-compare stuck
detection, overseer move reservations, a `PUSH_REQ` broadcast on stall, and random
GPS resync. The header warns explicitly: do not "clean this up" — every branch
exists because of a specific failure mode that is no longer visible.

## Place in the architecture

`nav` sits between tasks/roles and [movers.lua](movers.md). It reads the world via
[cache.lua](cache.md), takes opportunistic scans via [scanner.lua](scanner.md),
corrects drift via [calibrate.gpsSyncPos](calibrate.md), and coordinates with the
overseer through `RESERVE_REQ`/`RESERVE_REL` and `PUSH_REQ`. Navigation
bookkeeping lives in [state.lua](state.md) (module-level so it survives a pcall).

---

## `noteRecentTile(p)` (module local)

**Signature:** `noteRecentTile(p)` (no return)

Records a position into the `state.recent_tiles` ring buffer (size
`RECENT_TILE_WINDOW`), advancing `recent_tile_index`. No-ops for non-table input.

- **Parameters:** `p` (`{x,y,z}`).
- **Side effects:** mutates `state.recent_tiles`/`recent_tile_index`.

## `recentPenalty(x, y, z)` (module local)

**Signature:** `recentPenalty(x, y, z) -> number`

Returns `1.5 ×` the number of times `(x,y,z)` appears in the recent-tiles buffer —
an A\* cost penalty that discourages re-treading and breaks oscillation.

- **Parameters:** `x, y, z` (number).
- **Returns:** number.
- **Side effects:** none.

## `navCost(nx, ny, nz)` (module local)

**Signature:** `navCost(nx, ny, nz) -> number|nil`

A\* per-cell cost from the cache: unknown = 4, passable = 1, diggable = 8,
protected = `nil` (impassable, excluded from the search).

- **Parameters:** `nx, ny, nz` (number).
- **Returns:** a cost, or `nil` if the cell must not be entered.
- **Side effects:** none (reads cache via `cache.cacheGet`).
- **Invariant:** "unknown as solid-ish" (cost 4) lets the navigator probe
  unscanned space without treating it as free.

## `newHeap()` / `heapPush(h, node, pri)` / `heapPop(h)` (module locals)

A binary min-heap used as the A\* open set.

- **`newHeap() -> heap`** — fresh heap `{ n = 0 }`.
- **`heapPush(h, node, pri)`** — insert `node` with priority `pri`, sifting up.
- **`heapPop(h) -> node|nil`** — remove and return the lowest-priority node,
  sifting down; `nil` when empty.
- **Side effects:** mutate the heap table only.

## `astarLocal(start, goal, node_budget)` (module local)

**Signature:** `astarLocal(start, goal, node_budget) -> path|nil`

Short-range A\* over the 6-neighbourhood (`vec.DIRS6`) with a manhattan heuristic.
Adds a vertical-move penalty (0.8) and a turn penalty (0.4), plus `recentPenalty`.
Expands up to `max(128, node_budget)` nodes; returns the reconstructed step path
(`{dx,dy,dz,dir}` entries) or `nil` if no path within budget.

- **Parameters:** `start`/`goal` (`{x,y,z}`); `node_budget` (number) — expansion
  cap.
- **Returns:** an array of step deltas, or `nil`.
- **Side effects:** none (pure search over the cache).

## `executeDetour(path)` (module local)

**Signature:** `executeDetour(path) -> boolean`

Walks an A\* step path: vertical steps via `movers.stepUp/stepDown`, horizontal via
`movers.face` + `stepForward`. Records each tile and stops (returns `false`) at the
first failed step.

- **Parameters:** `path` (array of step deltas).
- **Returns:** `true` if the whole path executed, else `false`.
- **Side effects:** physical movement; `noteRecentTile`.

## `adaptiveAStarBudget(start, goal, detours)` (module local)

**Signature:** `adaptiveAStarBudget(start, goal, detours) -> number`

Computes an A\* node budget scaled by distance, detours so far, and the current
stuck count, clamped to `[256, 2048]`.

- **Parameters:** `start`/`goal` (`{x,y,z}`); `detours` (number).
- **Returns:** an integer budget.
- **Side effects:** none.

## `M.requestMoveReservation(target)`

**Signature:** `nav.requestMoveReservation(target) -> boolean`

Asks the overseer to reserve `target` before stepping into it. Returns `true`
immediately if not enlisted or `target` is not a table. Otherwise sends a
`RESERVE_REQ` with a fresh nonce and `cfg.RESERVE_TTL_MS`, then polls
`state.reservation_pending[nonce]` until resolved or `cfg.RESERVE_WAIT_MS` elapses.

- **Parameters:** `target` (`{x,y,z}`) — the cell to reserve.
- **Returns:** `true` if granted (or on timeout/fail-open), `false` if explicitly
  denied.
- **Side effects:** `rednet.send` (`RESERVE_REQ`); mutates
  `state.reservation_nonce`/`reservation_pending`; `sleep` while polling.
- **Contract (tile reservation, §5):** **fails open** — laggy comms must never
  freeze movement, so a timeout is treated as a grant.

## `M.releaseMoveReservation(target)`

**Signature:** `nav.releaseMoveReservation(target)` (no return)

Sends a `RESERVE_REL` for `target` so the overseer can free the hold. No-ops if
not enlisted or `target` is not a table.

- **Parameters:** `target` (`{x,y,z}`).
- **Returns:** nothing.
- **Side effects:** `rednet.send` (`RESERVE_REL`).

## `greedyStep(goal)` (module local)

**Signature:** `greedyStep(goal) -> "arrived"|"moved"|"stuck"`

One greedy move toward `goal`. Returns `"arrived"` if already there. Otherwise
sorts the three axes by remaining distance and tries the largest first: for each it
sets `state.nav_last_want`, reserves the target tile, and steps (up/down/forward).
For horizontal moves it first inspects/caches the block ahead and skips an axis
blocked by a protected (non-passable, non-diggable) block. Returns `"moved"` on the
first successful step, `"stuck"` if none worked.

- **Parameters:** `goal` (`{x,y,z}`).
- **Returns:** a status string.
- **Side effects:** `movers.face`/step calls, reservation request/release,
  `turtle.inspect`, `cache.cacheSet`, mutates `state.nav_last_want`; `NAV` logs.

## `recoverSpiral(goal)` (module local)

**Signature:** `recoverSpiral(goal) -> boolean`

Last-resort escape when greedy + A\* fail. Scores the six neighbours by distance to
`goal`, tries them nearest-first, and on total blockage attempts a climb-over (step
up, try all four facings forward, else step back down).

- **Parameters:** `goal` (`{x,y,z}`).
- **Returns:** `true` if it escaped to any new tile, else `false`.
- **Side effects:** physical movement; `NAV` logs.

## `waypointsTo(goal)` (module local)

**Signature:** `waypointsTo(goal) -> { {x,y,z}, ... }`

Splits a long route into legs of at most `cfg.WAYPOINT_DIST` (32) manhattan
blocks, interpolating intermediate waypoints; the final waypoint is exactly
`goal`. Short routes return `{ goal }`.

- **Parameters:** `goal` (`{x,y,z}`).
- **Returns:** an array of waypoint positions.
- **Side effects:** none.

## `M.moveTo(goal)`

**Signature:** `nav.moveTo(goal) -> boolean`

The main navigation entry point. Returns `true` if already at `goal`. Honours the
one-shot `state.block_movement` veto (clears it and returns `false`). Splits the
route into waypoints and, for each leg, loops greedy steps with stuck detection:

- On a position change, resets the stuck counter, notes the tile, and ~15% of the
  time calls `calibrate.gpsSyncPos()` to correct drift.
- On no movement, increments `nav_stuck_cnt`; once it reaches `cfg.STUCK_VALUE`,
  broadcasts a `PUSH_REQ` (announcing this turtle's priority and wanted tile),
  takes a fresh scan into the cache, then tries an A\* detour (adaptive budget); if
  that fails, a recovery spiral; if `MAX_DETOURS` (6) is exceeded it sends an
  `ALERT` (STUCK) and gives up.

Aborts a leg and returns `false` if `state.home_requested` becomes set.

- **Parameters:** `goal` (`{x,y,z}`).
- **Returns:** `true` if it arrived at `goal`, else `false`.
- **Side effects:** physical movement; reservation traffic; `PUSH_REQ`/`ALERT`
  broadcasts/sends; opportunistic scans and GPS resync; mutates
  `state.nav_stuck_cnt`/`nav_prev_pos`/`block_movement`; `NAV` logs.
- **Contract (push + reservation, §5):** broadcasts move priority on stall and
  reserves tiles per step; recovery is bounded so a truly stuck turtle reports
  rather than spins forever.
