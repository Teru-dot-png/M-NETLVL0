# turtle/tasks/task_build.lua — BUILD (place structure) task

Source: [../../../onet/turtle/tasks/task_build.lua](../../../onet/turtle/tasks/task_build.lua)

## Purpose

The Builder place-structure sequence. Places a chest or furnace from cargo at the
target, and optionally loads ore + fuel into a furnace to smelt. `target =
{ kind="chest"|"furnace", pos={x,y,z}, [smelt=true] }`. Skeleton-functional: the
heavy zone-layout planning lives in `role_builder`.

## Place in the task-chain model

A leaf action task built on [`Task`](task.md), issued once per planned placement
by `role_builder`. Maps to **BUILDER** (priority 7). No chaining — the builder
re-issues one `task_build` per idle tick until its plan queue empties.

Depends on [task](task.md), [config](../../config.md), [state](../state.md),
[nav](../nav.md), [movers](../movers.md), [blocks](../../lib/blocks.md),
[log](../../lib/log.md).

> Note: `movers` is required for symmetry; placement uses `turtle.*` directly.

---

## `selectItem(pred)` (local)

**Signature:** `selectItem(pred) -> boolean`

Selects the first cargo slot holding an item that matches a predicate. Iterates
slots `cfg.CARGO_FIRST..cfg.CARGO_LAST` (3..16); for each, `turtle.getItemDetail(s)`
and if present and `pred(d.name)` is truthy, `turtle.select(s)` and return
`true`. Returns `false` if nothing matched.

- **Parameters:** `pred` — a function `name -> boolean`.
- **Returns:** `true` if a matching slot was selected, else `false`.
- **Side effects:** `turtle.select` on the matching slot.
- **Contract:** scans **only** cargo slots 3..16, so the scanner (slot 1) and
  pickaxe (slot 2) are never selected, and `getItemDetail` is only ever called
  on protected cargo slot numbers (§1.1).

## `M.new(target, opts)`

**Signature:** `task_build.new(target, opts) -> task`

Constructs the build task via `Task.new("build", target, opts)` with two
instance overrides:

- **`t:isValidTarget()`** — true iff `self.target` is a table and
  `self.target.pos` is a table. *(Intentional instance override; "duplicate
  field" lint is a false positive.)*
- **`t:work()`** — place (and optionally smelt):
  1. `kind = self.target.kind or "chest"`, `pos = self.target.pos`.
  2. **Approach.** `nav.moveTo({pos.x, pos.y+1, pos.z})` (stand above the cell).
     On failure: log `BUILD: Cannot reach build site.`, set `self.failed = true`,
     return `false`.
  3. **Place.** Build a name predicate — for `"furnace"`, match names containing
     `"furnace"`; otherwise match `"chest"`. If `selectItem(pred)`,
     `turtle.placeDown()` and log; else log that no such item is in cargo.
  4. **Optional smelt.** If `kind == "furnace"` and `self.target.smelt`: select
     an ore-or-cobblestone item (`blocks.isOre(n) or name:find("cobblestone")`)
     and `turtle.dropDown()`; then select a fuel item (`blocks.isFuel`) and
     `turtle.dropDown()`. (A comment notes the side handling is approximate; the
     role handles exact furnace sides.)
  5. `turtle.select(cfg.CARGO_FIRST)`, `self.done = true`, return `true`.

- **Parameters:**
  - `target` — `{ kind, pos, [smelt] }`.
  - `opts` (optional) — passed to `Task.new`.
- **Returns:** the task.
- **Side effects (when run):** navigation; `turtle.placeDown`/`dropDown`/`select`
  (via `selectItem`); reads cargo via `getItemDetail`; `BUILD` logs.
- **State mapping:** **BUILDER** (7) — set by `role_builder`.
- **Contracts touched:**
  - **Slot protection (§1.1)** — all item selection goes through `selectItem`,
    which restricts to cargo slots 3..16 and calls `getItemDetail` only on those
    slot numbers.
  - **Zone layout (§6)** — placements come from `role_builder`'s plan; smelting
    feeds the GENESIS_MAT pipeline (ore→ingot, cobble→stone) for §7.

---

## Functions documented: 2

`selectItem`, `M.new` (with `isValidTarget`/`work` overrides).
