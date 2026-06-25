# overseer/gridmap.lua — Grid origin, lanes & segment assignment

Source: [../../onet/overseer/gridmap.lua](../../onet/overseer/gridmap.lua)

## Purpose

`gridmap` owns the authoritative grid state (§5). The grid origin is the
overseer's own GPS position (which doubles as the base-protection centre). A
**lane** is a cardinal direction plus a perpendicular offset; **segments** are
handed out one at a time along a lane, always starting *beyond* the
base-protection radius so the first dig is legal. Mined segments advance that
lane's frontier.

### Key constants

- `cfg.GRID_SPACING` (5) — perpendicular spacing between lanes (4-block pillars
  between 1-wide tunnels).
- `cfg.SEGMENT_LEN` (16) — length of each handed-out segment.
- `cfg.BASE_PROTECTION_RADIUS` (32) — the first segment of any lane begins this
  far out so no dig occurs inside the protected base sphere.
- `cfg.DIRECTIONS` (`{0,1,2,3}`) — the four cardinal lanes used for load
  balancing.

## Place in the architecture

Called from [director](director.md): `assignLane` during `AUTH_REQ`,
`nextSegment` during `SEGMENT_REQ`, and `markMined` when an `ORE_MINED` message
carries a `seg`. `setOrigin` is called once by [boot_overseer.md](boot_overseer.md)
after the GPS fix. Lane geometry uses `vec.DIRV` direction vectors
([lib/vec.md](../lib/vec.md)) and `grid.segKey` ([lib/grid.md](../lib/grid.md)).
State lives in `state.overseer_pos`, `state.grid_origin`, `state.lane_counters`,
`state.lane_progress` and `state.segments`. The turtle-side consumer of segments
is [task_tunnel.md](../turtle/tasks/task_tunnel.md).

---

## `M.setOrigin(pos)`

**Signature:** `gridmap.setOrigin(pos)`

Sets the grid origin from a position. Floors the coordinates into
`state.overseer_pos` and derives `state.grid_origin = {x,z}`. Logs the origin.

- **Parameters:** `pos` (`{x,y,z}`) — usually the overseer's GPS fix.
- **Returns:** nothing.
- **Side effects:** mutates `state.overseer_pos` and `state.grid_origin`;
  `log("OVERSEER", …)`.
- **Contract:** `overseer_pos` is both the grid origin and the base-protection
  centre, so every lane's start distance is measured from here.

## `M.assignLane(hwid)`

**Signature:** `gridmap.assignLane(hwid) -> dir, offset`

Load-balanced lane assignment. Picks the cardinal direction with the **fewest**
lanes assigned so far (from `state.lane_counters`), computes that lane's
perpendicular `offset = counter * cfg.GRID_SPACING`, then increments the chosen
direction's counter.

- **Parameters:** `hwid` (string) — the turtle (used only as context; the choice
  is purely counter-driven).
- **Returns:** `dir` (0–3) and `offset` (number) — the assigned lane.
- **Side effects:** increments `state.lane_counters[dir]`.
- **Contract:** balancing keeps the four directions within one lane of each
  other, fanning the fleet out evenly around the base.

## `M.nextSegment(hwid)`

**Signature:** `gridmap.nextSegment(hwid) -> segment|nil`

Hands the next unmined segment along a turtle's lane. Returns `nil` if the turtle
isn't enlisted or no origin is set. Otherwise, using the turtle's `dir`/`offset`
and the lane's progress counter `k` (`state.lane_progress[dir:offset]`):

- `along = vec.DIRV[dir]`, `perp = vec.DIRV[(dir+1)%4]`.
- `startDist = BASE_PROTECTION_RADIUS + k * SEGMENT_LEN`.
- builds `seg = { sx, sy, sz, dir, len = SEGMENT_LEN }` where the start point is
  `origin + perp*offset + along*startDist`.

It then advances the lane progress to `k+1` and records the segment in
`state.segments[grid.segKey(seg)] = { seg, status = "assigned", hwid }`.

- **Parameters:** `hwid` (string) — the requesting turtle.
- **Returns:** the `seg` table, or `nil`.
- **Side effects:** increments `state.lane_progress[key]`; inserts into
  `state.segments`.
- **Contract:** segments march outward from the protection radius, never
  overlapping within a lane; the first segment of every lane begins at
  `BASE_PROTECTION_RADIUS` so the initial dig is always legal.

## `M.markMined(segKey)`

**Signature:** `gridmap.markMined(segKey)`

Marks a recorded segment as mined.

- **Parameters:** `segKey` (string) — the `grid.segKey` of an existing segment.
- **Returns:** nothing.
- **Side effects:** sets `state.segments[segKey].status = "mined"` (no-op if the
  key is unknown).
- **Note on clustering:** segment-frontier advancement is distinct from ore
  *clustering* (`cfg.CLUSTER_RADIUS`), which lives in [orders.md](orders.md);
  gridmap handles lane geometry, orders handles vein grouping.
