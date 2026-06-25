# lib/grid.lua — Grid mining math

Source: [../../onet/lib/grid.lua](../../onet/lib/grid.lua)

## Purpose

`grid` is the coordinate math for §5 grid mining. The overseer owns a grid
origin (its GPS position) and a `GRID_SPACING`; this module converts between
world coordinates, grid-cell intersection indices, and segment endpoints. A
**segment** — the unit of mining work handed to a miner — is the table
`{ sx, sy, sz, dir, len }`: a start intersection in world coords, a facing
`dir` (0..3), and a `len` in blocks.

Like the rest of `lib`, it is **byte-identical on turtle and overseer** so both
sides describe the same tunnel network. It is pure math with no state.

## Place in the architecture

`grid` is required by the overseer's grid map ([gridmap.lua](../overseer/gridmap.md))
to allocate segments and lanes, and the segment shape it defines is what travels
in the `SEGMENT_GRANT` message to a turtle (stored as `state.segment`). It
depends on [config.lua](../config.md) for `GRID_SPACING` and on
[vec.lua](vec.md) for the `DIRV` direction table.

---

## `M.worldToCell(x, z, origin, spacing)`

**Signature:** `grid.worldToCell(x, z, origin?, spacing?) -> cx, cz`

Maps a world XZ coordinate to the **nearest** grid intersection index, rounding
via `+ 0.5` then `floor`.

- **Parameters:** `x`, `z` (number) — world coordinates; `origin` (table with
  `.x`/`.z`, default `{x=0, z=0}`) — grid origin; `spacing` (number, default
  `cfg.GRID_SPACING`) — grid pitch.
- **Returns:** two integers `cx, cz` — the cell indices.
- **Side effects:** none (pure).

## `M.cellToWorld(cx, cz, y, origin, spacing)`

**Signature:** `grid.cellToWorld(cx, cz, y, origin?, spacing?) -> {x, y, z}`

Inverse of `worldToCell`: maps a grid intersection index back to the world
coordinate of that intersection, at the caller-supplied `y`.

- **Parameters:** `cx`, `cz` (number) — cell indices; `y` (number) — vertical
  level to stamp into the result; `origin` (table, default `{x=0,z=0}`);
  `spacing` (number, default `cfg.GRID_SPACING`).
- **Returns:** a position table `{x, y, z}`.
- **Side effects:** none (pure).

## `M.segKey(seg)`

**Signature:** `grid.segKey(seg) -> string`

Builds the canonical string key for a segment so the grid map can mark it
assigned / mined / exhausted without ambiguity. All five fields are floored and
joined as `"sx:sy:sz:dir:len"`.

- **Parameters:** `seg` (table `{sx, sy, sz, dir, len}`).
- **Returns:** a formatted string key.
- **Side effects:** none (pure).

## `M.segEnd(seg)`

**Signature:** `grid.segEnd(seg) -> {x, y, z}`

Computes the world endpoint of a segment — the cell where the miner finishes —
by stepping `len` blocks from the start along the segment's direction vector
(`vec.DIRV[seg.dir]`, falling back to `DIRV[0]` if `dir` is invalid).

- **Parameters:** `seg` (table `{sx, sy, sz, dir, len}`).
- **Returns:** a position table `{x, y, z}` of the final block.
- **Side effects:** none (pure).

## `M.segBlocks(seg)`

**Signature:** `grid.segBlocks(seg) -> { {x,y,z}, ... }`

Enumerates every block coordinate a segment will dig, for `i = 1..len`, as a
1-wide lane (the caller is responsible for the 2-tall profile). Uses the same
direction vector as `segEnd`.

- **Parameters:** `seg` (table `{sx, sy, sz, dir, len}`).
- **Returns:** an array of `len` position tables in dig order.
- **Side effects:** none (pure).
