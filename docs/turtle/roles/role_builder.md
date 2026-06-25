# turtle/roles/role_builder.lua — BuilderRole

Source: [../../../onet/turtle/roles/role_builder.lua](../../../onet/turtle/roles/role_builder.lua)

## Purpose

`BuilderRole` lays out the storage zones: it places one chest per zone around
the base, then broadcasts the layout (`ZONE_MAP`) so haulers and the overseer
learn the coordinates. Smelting (ore→ingot, cobble→stone for Genesis) is done
via `task_build` furnaces. It is skeleton-functional — the layout is a simple
ring of chests offset from the base chest.

## Place in the task-chain model

`assignTask` consumes a one-time `state.build_plan` queue, emitting one
`task_build` per planned placement. When the plan is exhausted it emits a small
inline `Task` that broadcasts the zone map and completes. Park/refuel guards come
first. No `.parent` chaining — each placement is an independent task, re-issued
across successive idle ticks until the plan empties.

`M.name = cfg.ROLES.BUILDER`. Depends on [config](../../config.md),
[state](../state.md), [fuel](../fuel.md), [vec](../../lib/vec.md),
[task_build](../tasks/task_build.md), [task_fuel](../tasks/task_fuel.md),
[task_park](../tasks/task_park.md), [task](../tasks/task.md),
[log](../../lib/log.md).

---

## `ensurePlan()` (local)

**Signature:** `ensurePlan()` (no return)

Builds the one-time placement plan if `state.build_plan` is not already set.
Returns early if a plan exists. Initialises `state.build_plan = {}` and
`state.built_zones = {}`, resolves the base `b = state.base or state.overseer_pos`
(returns if neither is known), and for each zone in `cfg.ZONES` computes a fixed
offset:

| Zone | dx | dz |
|------|----|----|
| ORES | +2 | 0 |
| FUEL | −2 | 0 |
| BUILDING_MAT | 0 | +2 |
| GENESIS_MAT | 0 | −2 |

Each entry is appended to `state.build_plan` as
`{ kind="chest", pos={x,y,z}, zone }` and recorded in `state.built_zones[zone]`.

- **Parameters:** none.
- **Returns:** none.
- **Side effects:** mutates `state.build_plan`, `state.built_zones`; reads
  `state.base`/`state.overseer_pos` and `cfg.ZONES`.
- **State mapping:** runs inside the **BUILDER** branch.
- **Contracts touched:** `cfg.ZONES` set (ORES, FUEL, BUILDING_MAT,
  GENESIS_MAT) — one chest per declared zone.

## `broadcastZoneMap()` (local)

**Signature:** `broadcastZoneMap()` (no return)

Announces the finished layout to the overseer. No-op if `state.server_id` or
`state.built_zones` is missing. Sends
`{ type="ZONE_MAP", hwid, zones=state.built_zones }` over `cfg.PROTOCOL` and logs
`BUILD: ZONE_MAP broadcast.`

- **Parameters:** none.
- **Returns:** none.
- **Side effects:** **network send** (`ZONE_MAP`); `BUILD` log.
- **State mapping:** runs at the tail of the **BUILDER** phase.

## `M:assignTask(agent)`

**Signature:** `role:assignTask(agent)` (no return; sets `agent.task`)

Selection ladder:
1. **Not started** — `state.current_state = "PARKED"`;
   `agent.task = task_park.new()`.
2. **Low fuel** — `fuel.fuelLevel() < cfg.FUEL_MIN` → state **RTB_FUEL** (2),
   task `task_fuel.new(vec.copy(state.pos))`.
3. **Default — build.** State **BUILDER** (7). Calls `ensurePlan()`, then:
   - If `state.build_plan` has entries: `table.remove(state.build_plan, 1)` and
     assign `task_build.new({ kind=job.kind, pos=job.pos })`.
   - Else (plan complete): build an inline `Task.new("zone_announce", true)`
     whose `:work()` calls `broadcastZoneMap()`, sets `self.done = true`, returns
     `true`; then the turtle idles.

- **Parameters:** `agent` — agent loop object; `.task` is set.
- **Returns:** none.
- **Side effects:** mutates `state.current_state`, pops from `state.build_plan`;
  may send `ZONE_MAP` (via the inline task); reads fuel and start state.
- **State mapping:** PARKED (9), RTB_FUEL (2), BUILDER (7).
- **Contracts touched:** `FUEL_MIN`; `cfg.ZONES`. Note **BUILDER** and
  **GENESIS** share priority value 7 in `cfg.PRIORITY`.

---

## Functions documented: 3

`ensurePlan`, `broadcastZoneMap`, `M:assignTask` (incl. the inline
`zone_announce` task override).
