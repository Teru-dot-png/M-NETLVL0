# turtle/tasks/task_craft.lua — GENESIS craft task

Source: [../../../onet/turtle/tasks/task_craft.lua](../../../onet/turtle/tasks/task_craft.lua)

## Purpose

The Genesis craft sequence (**Crafty Turtle only**, §7.2). Pulls raw materials
from the GENESIS_MAT chest (arranged into the 3×3 grid by `role_genesis`), crafts
the combined Mining Turtle item in one `turtle.craft()`, places it, and signals
`CRAFT_DONE` so the overseer/boot can copy software and assign a role to the new
turtle. Skeleton-functional: the exact recipe-grid layout is done by
`role_genesis` before `work()` runs.

## Place in the task-chain model

A leaf action task built on [`Task`](task.md), issued by `role_genesis` only when
`state.craft_authorized` is set. Maps to **GENESIS** (priority 7). No chaining.

Depends on [task](task.md), [config](../../config.md), [state](../state.md),
[movers](../movers.md), [log](../../lib/log.md).

> Note: `movers` is required for symmetry; `work` uses `turtle.*` and
> `peripheral.*` directly.

---

## `M.new(opts)`

**Signature:** `task_craft.new(opts) -> task`

Constructs the craft task via `Task.new("craft", true, opts)` (target is the
literal `true`) with two instance overrides:

- **`t:isValidTarget()`** — returns `state.HW.is_crafty == true and
  type(turtle.craft) == "function"`; only a crafting turtle can craft (§1.7).
  *(Intentional instance override; "duplicate field" lint is a false positive.)*
- **`t:work()`** — the craft + place + signal flow:
  1. Log `GENESIS: Crafting new Mining Turtle...`. Call `turtle.craft()`
     (ingredients already arranged by `role_genesis`). If it fails, log and set
     `self.failed = true`, return `false`.
  2. **Place.** Scan slots 1..16 for an item whose name contains `"turtle"`;
     `turtle.select(s)` and `turtle.place()`; record `placed`.
  3. `turtle.select(cfg.CARGO_FIRST)`.
  4. **Power + signal.** If placed: `pcall(peripheral.call, "front", "turnOn")`
     to wake the new turtle (it runs its startup), and if `state.server_id`, send
     `{ type="CRAFT_DONE", hwid }`; log success. Else log that it could not be
     placed.
  5. `self.done = true`, return `placed` (true only if it actually placed).

- **Parameters:** `opts` (optional) — passed to `Task.new`.
- **Returns:** the task.
- **Side effects (when run):** `turtle.craft` (consumes ingredients from the
  grid); `turtle.select`/`getItemDetail`/`place`; `peripheral.call("front",
  "turnOn")`; network send (`CRAFT_DONE`); `GENESIS` logs.
- **State mapping:** **GENESIS** (7) — set by `role_genesis`.
- **Contracts touched:**
  - **Crafty-turtle requirement (§1.7)** — both `state.HW.is_crafty` and the
    existence of `turtle.craft` are checked in `isValidTarget`.
  - **`GENESIS_RECIPE` materials (§7.1)** — the ingredients `turtle.craft`
    consumes are the GENESIS_MAT materials gathered/smelted by the builder and
    arranged by `role_genesis`.
  - **Population cap (§7.4)** — enforced upstream: this task only runs when
    `state.craft_authorized` was granted by the overseer (never exceeding
    `TARGET_FLEET`, never consuming the last base turtle).
  - **Slot note** — the place loop scans all 16 slots looking specifically for a
    `"turtle"` item; it selects/places only that item.

---

## Functions documented: 1

`M.new` (with `isValidTarget`/`work` overrides).
