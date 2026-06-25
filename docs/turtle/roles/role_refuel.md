# turtle/roles/role_refuel.lua — RefuelRole

Source: [../../../onet/turtle/roles/role_refuel.lua](../../../onet/turtle/roles/role_refuel.lua)

## Purpose

`RefuelRole` is a dedicated coal runner. It repeatedly runs the RTB_FUEL
sequence — ask the overseer for the nearest coal, mine it, refuel, dump the
excess into base — by handing the agent a `task_fuel` on every assignment.

## Place in the task-chain model

The simplest role. `assignTask` produces either a `task_park` (not started) or a
`task_fuel` (running). No `.parent` chaining; the whole behaviour lives in
[`task_fuel`](../tasks/task_fuel.md), and because the role always re-issues it,
the turtle becomes an endless fuel shuttle.

`M.name = cfg.ROLES.REFUEL`. Depends on [config](../../config.md),
[state](../state.md), [fuel](../fuel.md), [vec](../../lib/vec.md),
[task_fuel](../tasks/task_fuel.md), [task_park](../tasks/task_park.md).

> Note: `fuel` is required but not directly referenced in `assignTask`; the role
> delegates all fuel logic to `task_fuel`.

---

## `M:assignTask(agent)`

**Signature:** `role:assignTask(agent)` (no return; sets `agent.task`)

Selection ladder:
1. **Not started** — `state.current_state = "PARKED"`;
   `agent.task = task_park.new()`. (Unlike the miner/hauler/scout, this role
   always uses **PARKED**, not STANDBY, when stopped.)
2. **Default** — `state.current_state = "RTB_FUEL"`;
   `agent.task = task_fuel.new(vec.copy(state.pos))`.

- **Parameters:** `agent` — agent loop object; `.task` is set.
- **Returns:** none.
- **Side effects:** mutates `state.current_state`; reads `state.started`,
  `state.pos`.
- **State mapping:** PARKED (9), RTB_FUEL (2).
- **Contracts touched:** the RTB_FUEL fuelling/dumping contracts are all in
  `task_fuel` (refuel up to but not over `FUEL_TARGET`; only cargo slots 3..16
  are dumped). This role only chooses *when* to run it.

---

## Functions documented: 1

`M:assignTask`.
