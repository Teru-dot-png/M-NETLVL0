# turtle/movers.lua — Movement primitives & protected digging

Source: [../../onet/turtle/movers.lua](../../onet/turtle/movers.lua)

## Purpose

`movers` owns every function that physically moves the turtle and updates
`state.pos` / `state.facing`. It is the **only** module that calls the raw
`turtle.forward/up/down/turn/dig` primitives. SURVIVAL tier: the lava/fluid
guards and the delegation to the `NEVER_BREAK` block list are the only reason
turtles don't die in caves or eat the base.

## Place in the architecture

[nav.lua](nav.md) composes these primitives into pathing; [fuel.forageForCoal](fuel.md)
uses `forward`; [network.lua](network.md)'s yield logic uses `stepUp`/`stepForward`/
`face`. The base-protection geofence and the diggability check are enforced here,
at the lowest level, so no higher layer can accidentally bypass them. Depends on
[config.lua](../config.md), [state.lua](state.md), [cache.lua](cache.md),
[vec.lua](../lib/vec.md), [blocks.lua](../lib/blocks.md), [log.lua](../lib/log.md).

---

## Re-exported classifiers

`M.isDiggable = blocks.isDiggable` and `M.isPassable = blocks.isPassable` — the
[blocks](../lib/blocks.md) predicates, surfaced here so nav/movers callers use one
import. See [blocks.md](../lib/blocks.md) for semantics.

## `M.withinBaseProtection(x, y, z)`

**Signature:** `movers.withinBaseProtection(x, y, z) -> boolean`

True if `(x,y,z)` is within `cfg.BASE_PROTECTION_RADIUS` (manhattan) of
`state.overseer_pos`. Returns `false` if no overseer position is known.

- **Parameters:** `x, y, z` (number) — candidate block.
- **Returns:** boolean.
- **Side effects:** none (reads `state.overseer_pos`).
- **Contract (§4/§5):** no block inside the radius is ever broken, so the fleet
  can't mine out the computer it depends on. Enforced by the dig helpers and
  `forward`.

## `blockIsFluid(ok, data)` (module local)

**Signature:** `blockIsFluid(ok, data) -> boolean`

True if an inspect result is a table whose name contains `lava` or `water`.

- **Parameters:** `ok` (boolean) — inspect success; `data` (table) — inspect
  result.
- **Returns:** boolean.
- **Side effects:** none.

## `M.isLavaAhead()` / `M.isLavaUp()` / `M.isLavaDown()`

**Signatures:** `movers.isLavaAhead() -> boolean`, `isLavaUp()`, `isLavaDown()`

Inspect the forward / up / down face respectively and report whether it is a fluid
(lava or water).

- **Parameters:** none.
- **Returns:** boolean.
- **Side effects:** `turtle.inspect`/`inspectUp`/`inspectDown`.

## `M.turnRight()` / `M.turnLeft()`

**Signatures:** `movers.turnRight()`, `movers.turnLeft()`

Turn in place and update `state.facing` (`+1` / `+3` mod 4).

- **Parameters:** none. **Returns:** nothing.
- **Side effects:** `turtle.turnRight/turnLeft`; mutates `state.facing`.

## `M.face(target)`

**Signature:** `movers.face(target)` (no return)

Rotates until `state.facing == target`, choosing the shorter direction each step.

- **Parameters:** `target` (number 0–3) — desired facing.
- **Returns:** nothing.
- **Side effects:** turn calls; mutates `state.facing`.

## `digGeneric(inspectFn, digFn, nx, ny, nz, tag)` (module local)

**Signature:** `digGeneric(inspectFn, digFn, nx, ny, nz, tag) -> boolean`

The shared protected-aware dig routine. Inspects the target face; caches the block
name; returns `true` immediately if passable. **Refuses** (returns `false`) if the
target is within base protection or is not diggable (logging the reason). Otherwise
digs up to 10 times (sleeping between) until the face is clear, caching the cell as
`"air"` on success.

- **Parameters:** `inspectFn`/`digFn` (functions) — the face's inspect/dig
  primitives; `nx, ny, nz` (number) — the target cell; `tag` (string) — log
  prefix.
- **Returns:** `true` if the face is clear/passable, `false` if protected or
  undiggable.
- **Side effects:** inspect/dig hardware calls; `cache.cacheSet`; `NAV` logs.
- **Contract:** enforces both base protection and the `NEVER_BREAK` list before
  any block is broken.

## `M.digSafe()` / `M.digSafeUp()` / `M.digSafeDown()`

**Signatures:** `movers.digSafe() -> boolean`, `digSafeUp()`, `digSafeDown()`

Protected-aware dig of the forward / up / down face, each delegating to
`digGeneric` with the appropriate primitives and target coordinate.

- **Parameters:** none.
- **Returns:** boolean (false if refused, true if cleared).
- **Side effects:** as `digGeneric`.

## `M.stepForward()`

**Signature:** `movers.stepForward() -> boolean`

Navigation step forward. Runs `cache.liveInspect`, refuses on lava ahead, then
tries `turtle.forward()`; if blocked, attempts a `digSafe()` and retries. Updates
`state.pos` on success.

- **Parameters:** none.
- **Returns:** `true` if it moved, else `false`.
- **Side effects:** `liveInspect`, `turtle.forward`, possible dig; mutates
  `state.pos`.

## `M.stepUp()` / `M.stepDown()`

**Signatures:** `movers.stepUp() -> boolean`, `movers.stepDown() -> boolean`

Vertical navigation steps: refuse on lava, try the move, dig (protected-aware) and
retry, updating `state.pos.y` on success.

- **Parameters:** none.
- **Returns:** boolean.
- **Side effects:** lava inspect, `turtle.up/down`, possible dig; mutates
  `state.pos.y`.

## `M.forward()`

**Signature:** `movers.forward() -> boolean`

**Mining** forward (the MINING state, distinct from navigation). Runs
`liveInspect`, refuses on lava ahead, and refuses if the next cell is within base
protection (logging it). On a clear move (or after digging up to 64 times,
attacking mobs that block the dig), marks the new cell `"air"` in the cache,
advances `state.pos`, and — if enlisted — `pcall(rednet.send, ...)` a `GEO_DATA`
carrying a single relative air block so the overseer clears that cell live.

- **Parameters:** none.
- **Returns:** `true` if it advanced, else `false`.
- **Side effects:** `liveInspect`, `turtle.forward/detect/dig/attack`,
  `cache.cacheSet`, a `GEO_DATA` network send; mutates `state.pos`; `MINE` logs.
- **Contract (§4/§5):** halts at the base-protection boundary instead of mining
  through it.
