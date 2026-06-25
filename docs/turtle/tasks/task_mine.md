# turtle/tasks/task_mine.lua — MINE (vein-sweep) task

Source: [../../../onet/turtle/tasks/task_mine.lua](../../../onet/turtle/tasks/task_mine.lua)

## Purpose

Vein-sweep an ore at a position. `target = {x,y,z[,ore]}`. The task navigates
adjacent, breaks the ore, then **flood-fills** neighbouring ore cells using the
world cache so a whole vein is collected from one report. Reports each broken
ore to the overseer.

## Place in the task-chain model

A leaf action task built on [`Task`](task.md), typically the **tail** of a chain
(a `task_goto` parents into it — go there, then mine). Maps to **MINING**
(priority 5) when issued from the grid loop, or to **GOTO**/**SEARCH** when it is
the action half of a job chain; the priority state is set by the calling role,
not here.

Depends on [task](task.md), [config](../../config.md), [state](../state.md),
[nav](../nav.md), [movers](../movers.md), [cache](../cache.md),
[scanner](../scanner.md), [blocks](../../lib/blocks.md), [vec](../../lib/vec.md),
[log](../../lib/log.md).

> Note: `scanner` is required but not directly referenced in `work` (ore
> discovery here comes from the cache populated by earlier scans).

---

## `reportMined(ore, pos)` (local)

**Signature:** `reportMined(ore, pos)` (no return)

Notifies the overseer that an ore was mined. No-op if `state.server_id` is
unset; otherwise `pcall(rednet.send, state.server_id, { type="ORE_MINED", hwid,
ore, pos=vec.copy(pos) }, cfg.PROTOCOL)`.

- **Parameters:** `ore` (tag/name string), `pos` (`{x,y,z}`).
- **Returns:** none.
- **Side effects:** **network send** (`ORE_MINED`).

## `M.new(target, opts)`

**Signature:** `task_mine.new(target, opts) -> task`

Constructs the mine task via `Task.new("mine", target, opts)` with two instance
overrides:

- **`t:isValidTarget()`** — true iff `self.target` is a table with `x`, `y`, `z`.
  *(Intentional instance override; "duplicate field" lint is a false positive.)*
- **`t:work()`** — one full vein sweep:
  1. **Approach.** Compute `stand = {x, y+1, z}` (above the ore). If
     `nav.moveTo(stand)` fails, log `MINE: Cannot reach ore...`, set
     `self.failed = true`, return `false`.
  2. **Break the seed ore.** `ore_tag = self.target.ore or "ore"`. If
     `movers.digSafeDown()` succeeds, `reportMined(ore_tag, goal)` and log.
  3. **Flood-fill the vein.** Maintain a `frontier` (seeded with `goal`) and a
     `seen` set keyed by `vec.key`. While the frontier is non-empty and
     `swept < 24`: pop a cell, examine all six neighbours (`vec.DIRS6`); for each
     unseen neighbour, look up its block name with `cache.cacheGet`; if
     `blocks.isOre(name)`, move above it and `movers.digSafeDown()`, then
     `reportMined(blocks.normalizeOreName(name), np)`, increment `swept`, and add
     the cell to the frontier.
  4. Set `self.done = true`, return `true`.

- **Parameters:**
  - `target` — `{x,y,z}` plus optional `ore` tag.
  - `opts` (optional) — passed to `Task.new`.
- **Returns:** the task.
- **Side effects (when run):** navigation; `movers.digSafeDown` (digging,
  inventory fills); cache reads; up to one `ORE_MINED` send per broken block;
  `MINE` logs. The `swept < 24` cap bounds work per `work()` call.
- **State mapping:** **MINING** (5) / **SEARCH** (6) / **GOTO** (1) depending on
  the issuing role; not set here.
- **Contracts touched:** `movers.digSafeDown` enforces the base-protection
  radius (§4) — protected blocks are not broken. Shared ore identity via
  `blocks.isOre` / `blocks.normalizeOreName` keeps turtle and overseer in sync.

---

## Functions documented: 2

`reportMined`, `M.new` (with `isValidTarget`/`work` overrides).
