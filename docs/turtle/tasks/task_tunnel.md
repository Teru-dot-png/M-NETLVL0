# turtle/tasks/task_tunnel.lua — TUNNEL (grid segment) task

Source: [../../../onet/turtle/tasks/task_tunnel.lua](../../../onet/turtle/tasks/task_tunnel.lua)

## Purpose

Dig one grid segment: a 1-wide, 2-tall tunnel of length `len` along direction
`dir`. `target = segment { sx, sy, sz, dir, len }`. Reports the segment as done
and scans periodically so ore is discovered as the tunnel advances.

## Place in the task-chain model

A leaf action task built on [`Task`](task.md). Issued by `role_miner` (full
segments) and `role_scout` (half-length, with a `task_scan` parent). Maps to the
**MINING** priority state (value 5), set by the issuing role.

Depends on [task](task.md), [config](../../config.md), [state](../state.md),
[nav](../nav.md), [movers](../movers.md), [scanner](../scanner.md),
[grid](../../lib/grid.md), [vec](../../lib/vec.md), [log](../../lib/log.md).

---

## `M.new(segment, opts)`

**Signature:** `task_tunnel.new(segment, opts) -> task`

Constructs the tunnel task via `Task.new("tunnel", segment, opts)` with two
instance overrides:

- **`t:isValidTarget()`** — true iff the target is a table with `sx`, `dir`,
  `len`, and `len > 0`. *(Intentional instance override; "duplicate field" lint
  is a false positive.)*
- **`t:work()`** — dig the corridor:
  1. **Reach start.** Compute `startp = {sx, sy, sz}`. If the turtle is not
     already there (`vec.equals`), `nav.moveTo(startp)`; on failure log
     `MINE: Could not reach segment start. Aborting.`, set `self.failed = true`,
     return `false`. Then `movers.face(s.dir)`.
  2. **Advance.** For `i = 1..s.len`:
     - If `state.home_requested`, abort gracefully: `self.done = false`,
       `return false` (lets a recall pre-empt the segment).
     - `movers.forward()`; if it returns false (blocked/protected), log and
       `break`.
     - `movers.digSafeUp()` to clear the 2-tall ceiling block; increment
       `state.tunnelled`.
     - Every `cfg.SCAN_EVERY` blocks (`i % cfg.SCAN_EVERY == 0`) **and** if
       `state.HW.has_scanner`: `scanner.scanAround()`, then
       `scanner.reportOres(scan)` and `scanner.sendSnapshot(scan)`.
  3. **Report + clear.** If `state.server_id`, send `{ type="ORE_MINED", hwid,
     seg=grid.segKey(s), pos=vec.copy(state.pos) }` so the gridmap marks the
     segment done. Set `state.segment = nil`, `self.done = true`, return `true`.

- **Parameters:**
  - `segment` — `{ sx, sy, sz, dir, len }`.
  - `opts` (optional) — passed to `Task.new`.
- **Returns:** the task.
- **Side effects (when run):** navigation; `movers.forward`/`digSafeUp`
  (movement + digging + inventory fills); periodic geo-scanner hot-swap via
  `scanner.scanAround` (see [scanner](../scanner.md)); network sends
  (`ORE_MINED` for ores during scan reporting, and a final segment-done
  `ORE_MINED`); mutates `state.tunnelled` and clears `state.segment`; `MINE`
  logs.
- **State mapping:** **MINING** (5).
- **Contracts touched:**
  - **Base-protection radius (§4)** — `movers.forward`/`digSafeUp` won't break
    protected blocks; hitting protection ends the segment early via the `break`.
  - **Scanner hot-swap** — the periodic scan goes through `scanner.scanAround`,
    which holds the `scanning_now` lock and restores the slot-2 pickaxe (§1.1).
  - **Grid keying** — `grid.segKey(s)` is the shared segment identity the
    overseer's gridmap uses to mark completion.

---

## Functions documented: 1

`M.new` (with `isValidTarget`/`work` overrides).
