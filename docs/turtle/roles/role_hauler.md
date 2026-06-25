# turtle/roles/role_hauler.lua — HaulerRole

Source: [../../../onet/turtle/roles/role_hauler.lua](../../../onet/turtle/roles/role_hauler.lua)

## Purpose

`HaulerRole` carries loot out of the dump chest and sorts it into the zoned
storage chests (§6). Zone classification uses the **shared** `blocks.zoneFor`
so the hauler and the overseer agree on what goes where. Zone chest coordinates
arrive via CONFIG/AUTH_ACK (`state.zone_chests`); any item whose zone is
unmapped falls back to the base chest.

## Place in the task-chain model

The hauler's `assignTask` produces a single inline `haulTask` (built on
[`Task`](../tasks/task.md)) that performs one full collect-and-sort cycle per
run. It also short-circuits to `task_fuel`/`task_park` when not started or low on
fuel. There is no `.parent` chaining here — the haul task is self-contained and
sets `self.done = true` at the end.

`M.name = cfg.ROLES.HAULER`. Depends on [config](../../config.md),
[state](../state.md), [fuel](../fuel.md), [nav](../nav.md),
[inventory](../inventory.md), [blocks](../../lib/blocks.md),
[vec](../../lib/vec.md), [task](../tasks/task.md),
[task_fuel](../tasks/task_fuel.md), [task_park](../tasks/task_park.md),
[log](../../lib/log.md).

---

## `haulTask()` (local)

**Signature:** `haulTask() -> task`

Builds the collect-and-sort task. `Task.new("haul", true)` with two instance
overrides:

- **`t:isValidTarget()`** — returns `state.dump ~= nil`; the task is meaningful
  only while a dump chest location is known. *(Intentional instance override of
  the base method; the "duplicate field" lint is a false positive.)*
- **`t:work()`** — one full cycle:
  1. **Collect.** `nav.moveTo` to one block above the dump chest
     (`{dump.x, dump.y+1, dump.z}`); on failure logs a `BUILD` message, sets
     `self.failed = true`, returns `false`. On success `inventory.suckInto("down")`
     pulls items up out of the chest.
  2. **Sort.** For each cargo slot `s` from `cfg.CARGO_FIRST` to
     `cfg.CARGO_LAST` (3..16), `turtle.getItemDetail(s)`; if present, compute
     `zone = blocks.zoneFor(d.name)`, resolve the chest as
     `state.zone_chests[zone]` or fall back to `state.base`. If a chest is
     known, `nav.moveTo` above it, `turtle.select(s)`, `turtle.dropDown()`.
  3. Finish: `turtle.select(cfg.CARGO_FIRST)`, `self.done = true`, return `true`.

- **Parameters:** none.
- **Returns:** the task.
- **Side effects (when run):** navigation; `turtle.suckUp`/`select`/`dropDown`;
  reads `state.dump`, `state.zone_chests`, `state.base`; `BUILD` log on failure.
- **State mapping:** **RTB_DUMP** (priority 3) — set by `assignTask`; hauling
  shares the dump priority band.
- **Contracts touched:** iterates **only** cargo slots 3..16 (`CARGO_FIRST..
  CARGO_LAST`), never touching slot 1 (scanner) or slot 2 (pickaxe) (§1.1); zone
  routing via the shared `blocks.zoneFor` keeps hauler/overseer agreement (§6).

## `M:assignTask(agent)`

**Signature:** `role:assignTask(agent)` (no return; sets `agent.task`)

Selection ladder:
1. **Not started** — `state.current_state = state.park_pos and "PARKED" or
   "STANDBY"`; `agent.task = task_park.new()`.
2. **Low fuel** — `fuel.fuelLevel() < cfg.FUEL_MIN` → state **RTB_FUEL** (2),
   task `task_fuel.new(vec.copy(state.pos))`.
3. **Default** — state **RTB_DUMP** (3), task `haulTask()`.

- **Parameters:** `agent` — agent loop object; `.task` is set.
- **Returns:** none.
- **Side effects:** mutates `state.current_state`; reads `state.started`,
  `state.park_pos`, fuel level.
- **State mapping:** PARKED/STANDBY, RTB_FUEL, RTB_DUMP.
- **Contracts touched:** `FUEL_MIN` threshold; cargo-slot discipline inherited
  from `haulTask`.

---

## Functions documented: 2

`haulTask` (with `isValidTarget`/`work` overrides), `M:assignTask`.
