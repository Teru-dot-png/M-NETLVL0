# turtle/roles/role_genesis.lua — GenesisRole

Source: [../../../onet/turtle/roles/role_genesis.lua](../../../onet/turtle/roles/role_genesis.lua)

## Purpose

`GenesisRole` is self-replication (§7). It watches for craft authorization from
the overseer's population controller and, when the fleet is below target, crafts
a new Mining Turtle. **CRAFTY TURTLE ONLY** — a crafting upgrade exposes
`turtle.craft` (§1.7); a normal miner cannot run this role, and the brain falls
back to `MinerRole` if the genesis module is asked of a non-crafty turtle.

The actual craft (arranging the 3×3 grid from GENESIS_MAT and the single
`turtle.craft()`) is performed by [`task_craft`](../tasks/task_craft.md); this
role only **gates when** that runs.

## Place in the task-chain model

`assignTask` is pure gating. It produces either a `task_park`, a `task_craft`, or
a small inline "wait" task. No `.parent` chaining. The crucial population
contract — never exceed `TARGET_FLEET`, never consume the last base turtle — is
decided by the overseer's population controller, which only sets
`state.craft_authorized` when replication is safe; this role trusts that gate.

`M.name = cfg.ROLES.GENESIS`. Depends on [config](../../config.md),
[state](../state.md), [task_craft](../tasks/task_craft.md),
[task_park](../tasks/task_park.md), [task](../tasks/task.md),
[log](../../lib/log.md).

> Note: `log` is required for symmetry with the other roles but `assignTask`
> emits no log line itself; logging happens in `task_craft`.

---

## `M:assignTask(agent)`

**Signature:** `role:assignTask(agent)` (no return; sets `agent.task`)

Selection ladder:
1. **Not crafty** — if `not state.HW.is_crafty`, idle safely:
   `state.current_state = "PARKED"`; `agent.task = task_park.new()`. (Guards
   against busy-looping even though the brain would normally fall back to
   `MinerRole` on the role mismatch.)
2. **Authorized** — if `state.craft_authorized`, state **GENESIS** (7), task
   `task_craft.new()`.
3. **Not authorized** — state **PARKED** (9); build an inline
   `Task.new("genesis_wait", true)` whose `:work()` does `sleep(1)`, sets
   `self.done = true`, returns `true`. The turtle sits on the GENESIS_MAT zone
   waiting for `CRAFT_AUTH`.

- **Parameters:** `agent` — agent loop object; `.task` is set.
- **Returns:** none.
- **Side effects:** mutates `state.current_state`; reads `state.HW.is_crafty`,
  `state.craft_authorized`. The inline wait task calls `sleep(1)` when run.
- **State mapping:** PARKED (9), GENESIS (7).
- **Contracts touched:**
  - **Crafty-turtle requirement (§1.7)** — gated on `state.HW.is_crafty`;
    `task_craft` re-checks `turtle.craft` existence.
  - **Population cap (§7.4)** — `state.craft_authorized` is only set by the
    overseer when `live_count < TARGET_FLEET` **and** replicating won't consume
    the last base turtle; this role never decides that itself.
  - **`GENESIS_RECIPE` materials (§7.1)** — consumed by `task_craft`; gathered
    into the GENESIS_MAT zone by the builder beforehand.
  - **BUILDER/GENESIS share priority 7** in `cfg.PRIORITY`.

---

## Functions documented: 1

`M:assignTask` (incl. the inline `genesis_wait` task override).
