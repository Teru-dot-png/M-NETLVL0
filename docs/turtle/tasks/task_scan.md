# turtle/tasks/task_scan.lua — SCAN task

Source: [../../../onet/turtle/tasks/task_scan.lua](../../../onet/turtle/tasks/task_scan.lua)

## Purpose

One geo-scanner sweep, plus reporting ores and pushing a solid snapshot to the
overseer. The lightest sensing task — it is the "useful work while waiting"
filler a miner/scout runs when it has no segment yet.

## Place in the task-chain model

A leaf sensing task built on [`Task`](task.md). Used standalone (miner waiting
for a segment grant) or as the **parent** of a `task_tunnel` (scout: tunnel,
then scan the new frontier). It carries no movement of its own. The priority
state in effect is whatever the issuing role set (typically **MINING**).

Depends on [task](task.md), [scanner](../scanner.md), [state](../state.md).

---

## `M.new(opts)`

**Signature:** `task_scan.new(opts) -> task`

Constructs the scan task via `Task.new("scan", true, opts)` (target is the
literal `true`) with two instance overrides:

- **`t:isValidTarget()`** — returns `state.HW.has_scanner == true`; the task is
  only meaningful on a turtle that actually has a geo-scanner. *(Intentional
  instance override; "duplicate field" lint is a false positive.)*
- **`t:work()`** — one sweep:
  1. `scan = scanner.scanAround()` — the full hot-swap scan.
  2. `scanner.reportOres(scan)` — report newly-seen ores to the overseer.
  3. `scanner.sendSnapshot(scan)` — push the solid/air voxel snapshot.
  4. `self.data.found = scanner.scanForWanted(scan)` — stash any wanted-ore hits
     on the task's `data` table for the caller to read.
  5. `self.done = true`, return `true`.

- **Parameters:** `opts` (optional) — passed to `Task.new`.
- **Returns:** the task.
- **Side effects (when run):** geo-scanner hot-swap via `scanner.scanAround`
  (equip/scan/re-equip — see [scanner](../scanner.md)); network sends from
  `reportOres` (`ORE_*` reports) and `sendSnapshot` (voxel snapshot); mutates
  `self.data.found`.
- **State mapping:** typically **MINING** (5); set by the issuing role, not here.
- **Contracts touched:**
  - **Scanner hot-swap (§1.1 / §11)** — `scanner.scanAround` brackets the
    equip/scan/re-equip with the `scanning_now` lock and restores the slot-2
    pickaxe afterward; this task never touches the slots directly.
  - Sensing requires the slot-1 scanner to be present, gated by
    `state.HW.has_scanner` in `isValidTarget`.

---

## Functions documented: 1

`M.new` (with `isValidTarget`/`work` overrides).
