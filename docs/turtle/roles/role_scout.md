# turtle/roles/role_scout.lua — ScoutRole

Source: [../../../onet/turtle/roles/role_scout.lua](../../../onet/turtle/roles/role_scout.lua)

## Purpose

`ScoutRole` explores unmapped grid cells and reports ore clusters. It is a
lighter cousin of the miner: it cuts **short** tunnel segments and scans
aggressively so the overseer's voxel map and ore clusters fill quickly, leaving
heavy extraction to miners.

## Place in the task-chain model

`assignTask` either parks/refuels, or produces a `task_tunnel` whose `.parent`
is a `task_scan` — i.e. *cut a short corridor, then scan the new frontier*.
When no segment is held it requests one and scans in the meantime. Segment
length is halved versus a miner.

`M.name = cfg.ROLES.SCOUT`. Depends on [config](../../config.md),
[state](../state.md), [fuel](../fuel.md), [vec](../../lib/vec.md),
[task_scan](../tasks/task_scan.md), [task_tunnel](../tasks/task_tunnel.md),
[task_fuel](../tasks/task_fuel.md), [task_park](../tasks/task_park.md),
[log](../../lib/log.md).

---

## `requestSegment()` (local)

**Signature:** `requestSegment()` (no return)

Identical contract to the miner's: asks the overseer for the next grid segment
near the current position. No-op if `state.server_id` is unset; otherwise
`pcall(rednet.send, state.server_id, { type="SEGMENT_REQ", hwid, pos }, cfg.PROTOCOL)`.

- **Parameters:** none.
- **Returns:** none.
- **Side effects:** **network send** (`SEGMENT_REQ`).
- **State mapping:** used in the **MINING** branch when no segment is held.

## `M:assignTask(agent)`

**Signature:** `role:assignTask(agent)` (no return; sets `agent.task`)

Selection ladder:
1. **Not started** — `state.current_state = state.park_pos and "PARKED" or
   "STANDBY"`; `agent.task = task_park.new()`.
2. **Low fuel** — `fuel.fuelLevel() < cfg.FUEL_MIN` → state **RTB_FUEL** (2),
   task `task_fuel.new(vec.copy(state.pos))`.
3. **Default — explore.** State **MINING** (5).
   - If `state.segment`: clamp the segment length to half a miner's —
     `seg.len = math.min(seg.len, math.floor(cfg.SEGMENT_LEN / 2))` — build
     `scan = task_scan.new()` and `tunnel = task_tunnel.new(seg)`, set
     `tunnel.parent = scan` (tunnel, then scan), assign the tunnel task.
   - Else: `requestSegment()` and assign `task_scan.new()`.

- **Parameters:** `agent` — agent loop object; `.task` is set.
- **Returns:** none.
- **Side effects:** mutates `state.current_state`, mutates `seg.len`, may send
  `SEGMENT_REQ`; reads `state.started`, `state.park_pos`, `state.segment`, fuel.
- **State mapping:** PARKED/STANDBY, RTB_FUEL, MINING.
- **Contracts touched:** `FUEL_MIN` threshold; `SEGMENT_LEN` (scouts use half).
  Base-protection radius is enforced downstream in `task_tunnel`.

---

## Functions documented: 2

`requestSegment`, `M:assignTask`.
