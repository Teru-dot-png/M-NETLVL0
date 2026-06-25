# lib/vec.lua — Coordinate helpers

Source: [../../onet/lib/vec.lua](../../onet/lib/vec.lua)

## Purpose

`vec` is the shared vector/coordinate library. Positions everywhere in O-NET are
plain `{x=, y=, z=}` tables, and this module supplies the pure functions that
manipulate them: copy, add, compare, hash to a canonical string key, and measure
manhattan distance. It also exports the two direction-vector tables the navigator
and grid math depend on.

The file is **byte-identical on the turtle and the overseer** (see the header
comment) so both runtimes agree on coordinate semantics — critical because the
turtle reports positions the overseer stores in its voxel DB. The module is pure
(no state, no hardware calls), which is why it is unit-testable in isolation.

## Place in the architecture

`vec` is a leaf dependency pulled in by nearly every module that touches
coordinates: [grid.lua](grid.md), [cache.lua](../turtle/cache.md),
[movers.lua](../turtle/movers.md), [nav.lua](../turtle/nav.md),
[scanner.lua](../turtle/scanner.md), [network.lua](../turtle/network.md), and the
overseer's voxel/grid maps. The `key()` function is the canonical hash for the
world cache and the reservation tables; `DIRV`/`DIRS6` define the facing and A\*
neighbour models.

---

## `M.copy(p)`

**Signature:** `vec.copy(p) -> {x, y, z}`

Returns a fresh shallow copy of a position table. Used wherever a position must
be snapshotted so later mutation of `state.pos` does not retroactively alter a
stored value (e.g. heartbeat payloads, `nav_prev_pos`).

- **Parameters:** `p` (table `{x,y,z}`) — the position to copy.
- **Returns:** a new table `{x=p.x, y=p.y, z=p.z}`.
- **Side effects:** none (pure).

## `M.key(x, y, z)`

**Signature:** `vec.key(x, y, z) -> string` or `vec.key(p) -> string`

Builds the canonical `"x:y:z"` string key used by all map/reservation tables.
Accepts either three numbers or a single position table (detected via
`type(x) == "table"`). Every coordinate is `math.floor`-ed first, so `12.0` and
`12` collapse to the same cell and float drift can never split one block into two
keys.

- **Parameters:** `x` (number or table) — X coord, or a `{x,y,z}` table; `y`,
  `z` (number) — used only when `x` is a number.
- **Returns:** a string `"fx:fy:fz"` of the floored integer coordinates.
- **Side effects:** none (pure).
- **Invariant:** integer-floored keys keep `world_cache`, `reported`, and the
  overseer's voxel DB single-keyed per cell.

## `M.add(a, b)`

**Signature:** `vec.add(a, b) -> {x, y, z}`

Component-wise vector addition; returns a new table.

- **Parameters:** `a`, `b` (tables `{x,y,z}`).
- **Returns:** `{x=a.x+b.x, y=a.y+b.y, z=a.z+b.z}`.
- **Side effects:** none (pure).

## `M.equals(a, b)`

**Signature:** `vec.equals(a, b) -> boolean`

Floored equality test for two positions. Returns `false` if either argument is
`nil` (defensive), otherwise compares the floored x/y/z of both.

- **Parameters:** `a`, `b` (tables `{x,y,z}` or `nil`).
- **Returns:** `true` iff all three floored coordinates match.
- **Side effects:** none (pure).
- **Used by:** the PUSH handler in [network.lua](../turtle/network.md)
  (`at_target` check) and elsewhere that needs cell-level equality.

## `M.manhattan(a, b)`

**Signature:** `vec.manhattan(a, b) -> number`

Manhattan (L1) distance between two positions, computed on floored coordinates.
This is the single distance metric used by the navigator's cost/heuristic and the
overseer's dispatcher, and it defines the base-protection geofence radius.

- **Parameters:** `a`, `b` (tables `{x,y,z}`).
- **Returns:** `|Δx| + |Δy| + |Δz|` as a number.
- **Side effects:** none (pure).
- **Invariant:** the base-protection check in
  [movers.withinBaseProtection](../turtle/movers.md) keys on this metric vs
  `cfg.BASE_PROTECTION_RADIUS`.

---

## Exported tables

### `M.DIRV`

Facing-index → unit delta on the XZ plane, indexed `0=N, 1=E, 2=S, 3=W`:

| dir | dx | dz |
|-----|----|----|
| 0 (N) | 0 | -1 |
| 1 (E) | 1 | 0 |
| 2 (S) | 0 | 1 |
| 3 (W) | -1 | 0 |

Used by `movers.face`/step functions, `grid.segEnd`/`segBlocks`, and the PUSH
yield logic to translate a facing into a world step.

### `M.DIRS6`

The 6-neighbourhood used by the A\* pathfinder in [nav.lua](../turtle/nav.md).
Each entry carries `dx, dy, dz` and a `dir` field where `dir = -1` means up and
`dir = -2` means down (no facing change). The four horizontal entries reuse the
`DIRV` facing indices 0–3.
