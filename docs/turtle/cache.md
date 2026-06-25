# turtle/cache.lua — Local world cache

Source: [../../onet/turtle/cache.lua](../../onet/turtle/cache.lua)

## Purpose

`cache` is the turtle's local view of the world, keyed by `(x,y,z)`. It is fed by
geo scans and by `liveInspect()` (which reads the three reachable faces without
spending a scan), and it is the surface the navigator consults. The navigator
treats **unknown as solid**, so the cache only needs to record the interesting
(non-stone) cells. The backing store is `state.world_cache` / `state.cache_size`.

## Place in the architecture

[movers.lua](movers.md) writes the cache on every dig/step (`cacheSet`,
`liveInspect`); [scanner.lua](scanner.md) feeds full scans via `feedCache`;
[nav.lua](nav.md) reads it through `cacheGet` in its cost function;
[network.lua](network.md) seeds the dump/base chests into it on assignment.
Depends only on [vec.lua](../lib/vec.md) (for `key`) and [state.lua](state.md).

---

## `M.isScanNoise(name)`

**Signature:** `cache.isScanNoise(name) -> boolean`

True if the (lowercased) name contains `"turtle"`. The geo scanner sometimes
reports the turtle itself; this filter stops that from hardening into a map solid.

- **Parameters:** `name` (any; coerced) — a scanned block name.
- **Returns:** boolean.
- **Side effects:** none (pure). Also used by
  [scanner.sendSnapshot](scanner.md).

## `M.cacheSet(x, y, z, name)`

**Signature:** `cache.cacheSet(x, y, z, name)` (no return)

Writes `name` into the cache at the floored key for `(x,y,z)`. Increments
`state.cache_size` only when the cell was previously absent.

- **Parameters:** `x, y, z` (number) — world coords; `name` (string) — block id
  (e.g. `"air"`, an ore name).
- **Returns:** nothing.
- **Side effects:** mutates `state.world_cache` and `state.cache_size`.

## `M.cacheGet(x, y, z)`

**Signature:** `cache.cacheGet(x, y, z) -> string|nil`

Looks up the cached block name at `(x,y,z)`, or `nil` if unknown (which the
navigator interprets as solid, cost 4).

- **Parameters:** `x, y, z` (number) — world coords.
- **Returns:** the stored name string, or `nil`.
- **Side effects:** none (read-only).

## `M.feedCache(scan, origin)`

**Signature:** `cache.feedCache(scan, origin)` (no return)

Ingests a scanner result array, writing each block's name at its **absolute**
coordinate (`origin + relative offset`, floored). Skips non-table entries,
non-string names, and `isScanNoise` hits. No-ops if either argument is not a
table.

- **Parameters:** `scan` (array of `{x,y,z,name}` relative entries); `origin`
  (`{x,y,z}`) — the turtle position the scan was taken from.
- **Returns:** nothing.
- **Side effects:** many `cacheSet` writes (mutates `world_cache`/`cache_size`).

## `M.liveInspect()`

**Signature:** `cache.liveInspect()` (no return)

Inspects the three immediately reachable faces — forward (per `state.facing`),
up, and down — and records each result. A solid block writes its name; a failed
inspect (no block) writes `"air"`. This keeps the cache fresh during movement
without spending a geo-scanner hot-swap.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** `turtle.inspect/inspectUp/inspectDown`; `cacheSet` writes.
- **Called by:** [movers.stepForward / forward](movers.md) and
  [nav.moveTo](nav.md) before each greedy step.
