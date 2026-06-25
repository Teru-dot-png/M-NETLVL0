# overseer/zones.lua — Storage-zone registry

Source: [../../onet/overseer/zones.lua](../../onet/overseer/zones.lua)

## Purpose

`zones` is the storage-zone registry (§6). It tracks each zone's chest coordinate
and last-known contents for the four zones in `cfg.ZONES`
(`ORES`, `FUEL`, `BUILDING_MAT`, `GENESIS_MAT`). The decision of **what** goes
where lives in [lib/blocks.zoneFor](../lib/blocks.md), so the Hauler (which sorts)
and the overseer (which displays fill) agree exactly.

### Key constant

- `cfg.ZONES` = `{ "ORES", "FUEL", "BUILDING_MAT", "GENESIS_MAT" }`.

## Place in the architecture

`setChest` is driven by the `setzone` command ([terminal](terminal.md));
`ingestZoneMap` by `ZONE_MAP` from a builder ([director](director.md));
`fillSnapshot` feeds the [cockpit](cockpit.md) zone panel and the `zones`
command. Zone chests are also persisted/broadcast by [persist](persist.md). State:
`state.zones[zone] = { chest = {x,y,z}, contents = {item->count} }`.

---

## `M.setChest(zone, pos)`

**Signature:** `zones.setChest(zone, pos) -> ok, err`

Sets a zone's chest coordinate. Rejects an unknown zone name.

- **Parameters:** `zone` (string, e.g. `"ORES"`); `pos` (`{x,y,z}`).
- **Returns:** `true`, or `false, "Unknown zone: …"`.
- **Side effects:** sets `state.zones[zone].chest`; `log("OVERSEER", …)`.

## `M.ingestZoneMap(msg)`

**Signature:** `zones.ingestZoneMap(msg)`

Records chest positions reported by a builder that has placed the storage layout.
Iterates `msg.zones` and sets the chest for each known zone.

- **Parameters:** `msg` (table) — `msg.zones` = `{ zone -> {x,y,z} }`, `msg.hwid`.
- **Returns:** nothing (returns early if `msg.zones` isn't a table).
- **Side effects:** mutates `state.zones[*].chest`; `log("OVERSEER", …)`.
- **Cross-link:** the builder side is [role_builder.md](../turtle/roles/role_builder.md).

## `M.zoneFor(item_name)`

**Signature:** `zones.zoneFor(item_name) -> zone`

Thin pass-through to [blocks.zoneFor](../lib/blocks.md) — which zone an item
belongs to.

- **Parameters:** `item_name` (string).
- **Returns:** the zone name.
- **Side effects:** none.

## `M.chestFor(item_name)`

**Signature:** `zones.chestFor(item_name) -> chest|nil, zone`

Returns the chest coordinate a hauler should deliver an item to (and the zone),
or `nil` if that zone's chest is unset.

- **Parameters:** `item_name` (string).
- **Returns:** the chest `{x,y,z}` (or `nil`) and the resolved `zone` name.
- **Side effects:** none.

## `M.fillSnapshot()`

**Signature:** `zones.fillSnapshot() -> table`

Builds a per-zone fill summary for the cockpit: `{ zone -> { chest, total } }`,
where `total` sums the zone's recorded `contents`.

- **Parameters:** none.
- **Returns:** `{ ZONE -> { chest = {x,y,z}|nil, total = number } }` for every zone
  in `cfg.ZONES`.
- **Side effects:** none.
- **Used by:** [cockpit.render](cockpit.md) and the `zones` command.
