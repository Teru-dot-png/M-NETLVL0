# lib/blocks.lua — Block & item classification

Source: [../../onet/lib/blocks.lua](../../onet/lib/blocks.lua)

## Purpose

`blocks` is the SURVIVAL-tier classifier library. Its `NEVER_BREAK_PATTERNS`
list is the single safeguard that stops a turtle from chewing through the base
computer, a chest, or a Create contraption — the source header explicitly warns
that the pattern lists encode a whole session of "the fleet ate my base"
debugging and must be ported **verbatim**, not trimmed for tidiness. The module
also hosts the §6 storage-zone predicates so the Hauler (sorting) and the
overseer (zone-fill display) classify items identically.

It is **byte-identical on turtle and overseer**. The pattern tables are declared
as **globals on purpose** (§1.2): this keeps them out of the per-scope local pool
and makes them immutable constants shared by every predicate.

## Place in the architecture

The dig predicates back [movers.lua](../turtle/movers.md)'s protected-aware
digging (`isDiggable`/`isPassable` are re-exported there). The ore predicate
feeds [scanner.lua](../turtle/scanner.md) ore reporting; `zoneFor`/zone
predicates drive Hauler sorting and overseer [zones.lua](../overseer/zones.md);
`normalizeOreName` produces the short display/tally keys used across cockpit and
reports. Depends on nothing but the global pattern tables.

---

## Pattern tables (module globals)

- **`DIGGABLE_PATTERNS`** — substrings of block names the fleet is allowed to
  break (stones, deepslate, gravel/dirt/sand families, `_ore`, `raw_block`).
- **`NEVER_BREAK_PATTERNS`** — substrings that are always protected: computers,
  turtles, peripherals, all container types, Create/AE2/RS machinery, fluids,
  bedrock/barrier, spawners, furnaces, etc.

`NEVER_BREAK` takes precedence over `DIGGABLE` everywhere it is consulted.

## `M.matchAny(name, patterns)`

**Signature:** `blocks.matchAny(name, patterns) -> boolean`

Case-insensitive substring test: lowercases `name` and returns `true` if any
pattern is a plain (non-pattern) substring of it. Returns `false` for non-string
input. This is the primitive every other predicate is built on; it is exported so
other modules can reuse it.

- **Parameters:** `name` (any; only strings can match) — block/item id;
  `patterns` (array of strings) — substrings to test.
- **Returns:** boolean.
- **Side effects:** none (pure).

## `M.isProtectedBlock(name)`

**Signature:** `blocks.isProtectedBlock(name) -> boolean`

`matchAny(name, NEVER_BREAK_PATTERNS)`. The authoritative "do not break this"
test.

- **Parameters:** `name` (string) — block id.
- **Returns:** `true` if the block must never be dug.
- **Side effects:** none (pure).
- **Invariant (SURVIVAL):** this is the base-eating safeguard; precedence over
  diggability is enforced in `isDiggable`.

## `M.isDiggable(name)`

**Signature:** `blocks.isDiggable(name) -> boolean`

Returns `true` only if the block is **not** protected **and** matches a diggable
pattern. Protected blocks short-circuit to `false` first.

- **Parameters:** `name` (string) — block id.
- **Returns:** boolean.
- **Side effects:** none (pure).
- **Used by:** [movers.digGeneric / step functions](../turtle/movers.md) and the
  nav cost function.

## `M.isPassable(name)`

**Signature:** `blocks.isPassable(name) -> boolean`

True for air variants, water, the empty string, or `nil` (treated as passable).
Backed by a small `PASSABLE` lookup table rather than substring matching.

- **Parameters:** `name` (string or `nil`) — block id.
- **Returns:** boolean.
- **Side effects:** none (pure).

## `M.isOre(name)`

**Signature:** `blocks.isOre(name) -> boolean`

True if `name` is a string containing the substring `_ore`.

- **Parameters:** `name` (string) — block id.
- **Returns:** boolean.
- **Side effects:** none (pure).

## `M.isFuel(name)`

**Signature:** `blocks.isFuel(name) -> boolean`

`matchAny` against `FUEL_PATTERNS` (`coal`, `charcoal`, `coal_block`,
`lava_bucket`, `blaze_rod`).

- **Parameters:** `name` (string) — item id.
- **Returns:** boolean.
- **Side effects:** none (pure).

## `M.isGenesisMat(name)`

**Signature:** `blocks.isGenesisMat(name) -> boolean`

`matchAny` against `GENESIS_PATTERNS` — processed forms destined for
self-replication (ingots, redstone, ender items, computer/turtle/modem,
diamond pickaxe, glass pane). Checked before the broad ore bin in `zoneFor`.

- **Parameters:** `name` (string) — item id.
- **Returns:** boolean.
- **Side effects:** none (pure).

## `M.isBuildingMat(name)`

**Signature:** `blocks.isBuildingMat(name) -> boolean`

`matchAny` against `BUILDING_PATTERNS` (logs, planks, cobblestone/stone, glass,
sand/gravel/dirt, sticks, chest, furnace, cobbled deepslate).

- **Parameters:** `name` (string) — item id.
- **Returns:** boolean.
- **Side effects:** none (pure).

## `M.zoneFor(name)`

**Signature:** `blocks.zoneFor(name) -> "FUEL"|"GENESIS_MAT"|"ORES"|"BUILDING_MAT"`

Routes an item to its storage zone. **Order matters:** fuel and genesis win over
the broad ore/building patterns, then ore (via `isOre` or `ORE_PATTERNS`), then
building. Anything unrecognised defaults to `"ORES"` (the safe bin).

- **Parameters:** `name` (string) — item id.
- **Returns:** a zone name string from `cfg.ZONES`.
- **Side effects:** none (pure).
- **Invariant (§6):** Hauler and overseer must agree on routing; this single
  function is the shared authority.

## `M.normalizeOreName(name)`

**Signature:** `blocks.normalizeOreName(name) -> string`

Strips namespace and the `deepslate_`/`nether_`/`raw_` prefixes plus the `_ore`
suffix to produce a short display/tally key (e.g.
`minecraft:deepslate_gold_ore` → `gold`). Returns `"unknown"` for non-string
input.

- **Parameters:** `name` (string) — full block id.
- **Returns:** a normalized short name string.
- **Side effects:** none (pure).
- **Used by:** [scanner.reportOres / scanForWanted](../turtle/scanner.md) and
  overseer ore tallies.
