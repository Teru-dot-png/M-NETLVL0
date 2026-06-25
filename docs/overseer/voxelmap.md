# overseer/voxelmap.lua — Voxel DB & volatile-solid air inference

Source: [../../onet/overseer/voxelmap.lua](../../onet/overseer/voxelmap.lua)

## Purpose

`voxelmap` is the authoritative world database. It stores **only** the blocks
worth remembering — ores, air, and hazards/fixtures — and never stone (the
navigator already treats "unknown" as solid). Its **CORE** trick is
*volatile-solid air inference*: when a block a turtle previously saw is now
**absent** from a scan that covers its cell, the block is promoted to air. This
gives passive cave-mapping without any explicit "air report" message. Understand
this before touching `ingestGeoData`.

### Key constants

- `cfg.AIR_MARKER` (`"__air__"`) — the stored sentinel for known-empty space.
- `cfg.VOL_SOLID_TTL_MS` (180000 = 3 min) — how long a non-storable solid sighting
  lingers as a "volatile solid" candidate before it is forgotten.

## Place in the architecture

Fed by `GEO_DATA` packets routed from [director.listenerThread](director.md). The
scans themselves originate on the turtle from [turtle/scanner.md](../turtle/scanner.md)
and travel as snapshot tables. The map is persisted by [persist.md](persist.md)
(which calls `setVoxel` on load) and queried by [orders.md](orders.md),
[director](director.md) (coal queries) and [cockpit](cockpit.md) (`map` slice).
State lives in `state.master_voxels`, `state.total_voxels`,
`state.volatile_solids` and `state.map_dirty`.

---

## `M.isAir(n)`

**Signature:** `voxelmap.isAir(n) -> boolean`

True if `n` represents empty space: `nil`, the `AIR_MARKER`, or any of the
recognized air block names (`minecraft:air`, `air`, `minecraft:cave_air`,
`minecraft:void_air`, `""`).

- **Parameters:** `n` (string|nil) — a block name.
- **Returns:** boolean.
- **Side effects:** none.

## `M.isOre(n)`

**Signature:** `voxelmap.isOre(n) -> boolean`

True if `n` is non-nil and contains the literal substring `"_ore"`.

- **Parameters:** `n` (string|nil) — a block name.
- **Returns:** boolean.
- **Side effects:** none.

## `M.shouldStore(name)`

**Signature:** `voxelmap.shouldStore(name) -> boolean`

Decides whether a block name is worth a voxel slot. Stores the `AIR_MARKER` and
any name containing `air`, `_ore`, `lava`, `water`, `chest`, `computer`,
`turtle`, or `furnace`; everything else (notably stone-class blocks) is rejected.

- **Parameters:** `name` (string|nil).
- **Returns:** boolean.
- **Side effects:** none.
- **Contract:** the gatekeeper that keeps the DB small — never store stone.

## `M.isGeoScanNoise(name)`

**Signature:** `voxelmap.isGeoScanNoise(name) -> boolean`

True if the name contains `turtle` (case-insensitive). The geo scanner sees other
turtles; those readings are transient and must not be recorded as solids.

- **Parameters:** `name` (string|nil).
- **Returns:** boolean.
- **Side effects:** none.

## `M.setVoxel(x, y, z, name)`

**Signature:** `voxelmap.setVoxel(x, y, z, name)`

Writes a voxel into the nested `state.master_voxels[y][x][z]` map, but only if
`shouldStore(name)` passes. Lazily creates the `[y]` and `[y][x]` sub-tables;
increments `state.total_voxels` only when the cell was previously empty; marks the
map dirty.

- **Parameters:** `x`, `y`, `z` (number) — coordinates; `name` (string) — block.
- **Returns:** nothing.
- **Side effects:** mutates `state.master_voxels`, `state.total_voxels`; sets
  `state.map_dirty = true`.
- **Contract:** `total_voxels` counts distinct occupied cells; overwriting an
  existing cell does not double-count.

## `M.getVoxel(x, y, z)`

**Signature:** `voxelmap.getVoxel(x, y, z) -> string|nil`

Reads the stored name at `(x,y,z)`, or `nil` if nothing is stored there.

- **Parameters:** `x`, `y`, `z` (number).
- **Returns:** the block name string, or `nil`.
- **Side effects:** none.

## `M.ingestGeoData(msg)`

**Signature:** `voxelmap.ingestGeoData(msg)`

The **CORE** scan-absorption routine. Steps:

1. **Fleet pulse:** if the sender is in the fleet, refresh `f.last_pulse` and
   `f.pos` from `msg.pos`.
2. **Validate:** require `msg.scan_data` and `msg.pos` to be tables; otherwise
   return.
3. **Prune stale candidates:** drop `state.volatile_solids` entries older than
   `cfg.VOL_SOLID_TTL_MS`.
4. **Absorb each scanned block** (offsets are relative to scan origin `p`):
   - geo-scan noise (`turtle`) → store `AIR_MARKER`, clear any volatile entry.
   - air → store `AIR_MARKER`, clear any volatile entry.
   - otherwise mark the cell `seen`; if `shouldStore` passes, store the name;
     else record it as a **volatile solid** `{x,y,z,ts=now}` (a transient solid
     we don't keep but must remember we saw).
5. **Negative-space inference:** using `msg.scan_radius`, for every volatile solid
   now **inside** the scan sphere — if it was **not** seen in this scan it has been
   mined out, so promote it to `AIR_MARKER` and drop it; if it *was* seen, refresh
   its timestamp.

- **Parameters:** `msg` (table) — `msg.hwid`, `msg.pos {x,y,z}`,
  `msg.scan_data` (list of `{name,x,y,z}`), `msg.scan_radius` (number).
- **Returns:** nothing.
- **Side effects:** many `setVoxel` writes; mutates `state.volatile_solids` and the
  sender's fleet record; sets `state.map_dirty` (via `setVoxel`).
- **Contract/invariant (air inference):**
  - The radius-squared test `(dx²+dy²+dz²) <= r²` defines "covered by this scan".
  - A previously-seen solid that is *covered but absent* is now air — this is how
    caves and mined-out veins appear on the map with no explicit air messages.
  - Volatile solids are only ever the *non-storable* solids (e.g. stone), so the
    inference never fights with stored ore/hazard voxels.
  - See the turtle-side snapshot producer in
    [turtle/scanner.md](../turtle/scanner.md).

## `M.findOreInMap(ore, refpos)`

**Signature:** `voxelmap.findOreInMap(ore, refpos) -> table[]`

Scans the entire voxel DB and returns every stored cell whose name contains the
`ore` substring, as `{x,y,z,name}` records. If `refpos` is given, the result is
sorted nearest-first by manhattan distance to it.

- **Parameters:**
  - `ore` (string) — substring to match (e.g. `"diamond_ore"`, `"coal_ore"`).
  - `refpos` (`{x,y,z}`|nil) — sort origin; omit to leave order arbitrary.
- **Returns:** a (possibly empty) list of match records.
- **Side effects:** none (read-only scan).
- **Used by:** [orders.md](orders.md) (`getme` dispatch), [director](director.md)
  (`COAL_QUERY`), [terminal](terminal.md) (`getme` reporting).
