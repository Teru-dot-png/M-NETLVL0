# overseer/persist.lua — Config & voxel-map durability

Source: [../../onet/overseer/persist.lua](../../onet/overseer/persist.lua)

## Purpose

`persist` makes operator config and the voxel map survive reboots (SURVIVAL
tier — invisible until a restart). Config is serialized with `textutils`; the map
uses a compact tab-separated line format (`x\ty\tz\tname`) so a large cave system
doesn't bloat into a multi-megabyte serialized table. The `mapSaveThread` keeps
the DB safe on an interval.

### Key constants & files

- `cfg.CONFIG_FILE` (`onet_overseer.cfg`) — operator config.
- `cfg.MAP_FILE` (`onet_map.dat`) — the TSV voxel dump.
- `cfg.MAP_SAVE_INTERVAL` (60 s) — autosave cadence.

## Place in the architecture

`loadConfig`/`loadMap` run once at boot ([boot_overseer.md](boot_overseer.md)).
`saveConfig`/`broadcastConfig` are called by [terminal](terminal.md) whenever the
operator changes config. `mapSaveThread` is launched supervised by
[overseer.run](overseer.md). Map writes go through [voxelmap.setVoxel](voxelmap.md)
on load. State touched: the persisted config fields, `state.zones`,
`state.master_voxels`, `state.map_dirty`, `state.last_map_save`,
`state.map_persist_enabled`.

---

## `M.saveConfig()`

**Signature:** `persist.saveConfig()`

Serializes operator config — `DUMP_CHEST`, `BASE_CHEST`, `PARK_ZONE`, `WANT_LIST`,
`target_fleet`, and each zone's `chest` — to `cfg.CONFIG_FILE`.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** file write to `CONFIG_FILE` (`textutils.serialize`).

## `M.loadConfig()`

**Signature:** `persist.loadConfig()`

Reads `cfg.CONFIG_FILE` if present and restores the same fields, each guarded so a
missing key keeps the existing default. Zone chests are restored only for known
zones. Logs on success.

- **Parameters:** none.
- **Returns:** nothing (returns early if the file is absent/unreadable/non-table).
- **Side effects:** mutates `state.DUMP_CHEST`, `BASE_CHEST`, `PARK_ZONE`,
  `WANT_LIST`, `target_fleet`, `state.zones[*].chest`; `log("OVERSEER", …)`.

## `M.broadcastConfig()`

**Signature:** `persist.broadcastConfig()`

Broadcasts a `CONFIG` message to the whole fleet with `dump`, `base`, `want_list`,
`overseer_pos`, and the `zone_chests` map.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** `rednet.broadcast` of `CONFIG` on `cfg.PROTOCOL`.
- **Contract:** `park_pos` is deliberately **not** broadcast — each turtle's park
  slot is unique, so a single broadcast value would corrupt every turtle's
  `park_pos`. Park slots are delivered per-turtle via `PARK_ASSIGN`
  ([director.handleParkReq](director.md)).

## `M.saveMap()`

**Signature:** `persist.saveMap()`

Writes every voxel in `state.master_voxels` to `cfg.MAP_FILE` as one
tab-separated `x\ty\tz\tname` line each, then clears `map_dirty` and stamps
`last_map_save`.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** file write to `MAP_FILE`; sets `state.map_dirty = false` and
  `state.last_map_save`.

## `M.loadMap()`

**Signature:** `persist.loadMap()`

Reads `cfg.MAP_FILE` line by line, parsing each `x\ty\tz\tname` (signed integers,
name allowed any characters) and replaying it through `voxelmap.setVoxel`. Clears
`map_dirty` and logs the voxel count.

- **Parameters:** none.
- **Returns:** nothing (returns early if the file is absent/unreadable).
- **Side effects:** many `voxelmap.setVoxel` calls (rebuilds the DB and
  `state.total_voxels`); sets `state.map_dirty = false`; `log("OVERSEER", …)`.
- **Contract:** routing through `setVoxel` means the same `shouldStore` filter and
  counting apply on load as at runtime.

## `M.mapSaveThread()`

**Signature:** `persist.mapSaveThread()` (loops forever)

Every `cfg.MAP_SAVE_INTERVAL` seconds, saves the map **only if** it is dirty and
`state.map_persist_enabled` is true.

- **Parameters:** none.
- **Returns:** nothing (loops forever).
- **Side effects:** periodic `saveMap` (file write) when dirty.
- **Contract:** the dirty flag avoids rewriting an unchanged map every minute;
  `map_persist_enabled` lets the operator suspend autosave.
