# overseer/state.lua — Overseer runtime state

Source: [../../onet/overseer/state.lua](../../onet/overseer/state.lua)

## Purpose

`state` is the single mutable state object for the overseer, shared by every
overseer module through Lua's `require()` cache (INFRA tier). It declares **no
functions** — it is a pure data module: one table `M`, initialized with defaults
(some derived from [config.lua](../config.md)), returned for every other module to
read and mutate.

## Place in the architecture

Every overseer module `require("state")` and gets the *same* table instance.
There is exactly one overseer process, so this shared-mutable pattern is safe.
[boot_overseer.md](boot_overseer.md) seeds `mon`/`vault`/origin; the threads in
[overseer.md](overseer.md) read and write the rest.

## Field reference

### Operator-set, persisted config (see [persist.md](persist.md))

| Field | Type | Meaning |
|-------|------|---------|
| `DUMP_CHEST` | `{x,y,z}`/nil | cargo dump chest |
| `BASE_CHEST` | `{x,y,z}`/nil | resupply (fuel/pickaxe) chest |
| `PARK_ZONE` | `{x1,y1,z1,x2,y2,z2}`/nil | parking rectangle ([park.md](park.md)) |
| `WANT_LIST` | `{ore->true}` | ores to auto-dispatch on sighting |

### Grid (origin = overseer GPS position; see [gridmap.md](gridmap.md))

| Field | Type | Meaning |
|-------|------|---------|
| `overseer_pos` | `{x,y,z}`/nil | grid origin **and** base-protection centre |
| `grid_origin` | `{x,z}`/nil | horizontal origin |
| `segments` | `segKey -> {seg, status, hwid}` | assigned/mined segment records |
| `lane_counters` | `{[0..3]=n}` | per-direction lane allocation counters |
| `lane_progress` | `{"dir:offset"->k}` | per-lane segment frontier (created in gridmap) |

### Fleet roster (see [fleet.md](fleet.md))

| Field | Type | Meaning |
|-------|------|---------|
| `fleet` | `hwid -> record` | `{net_id, role, status, pos, dir, fuel, free, last_pulse, crafty}` |
| `fleet_slot` | number | fallback sequential park-slot counter |

### Park claims (see [park.md](park.md))

| Field | Type | Meaning |
|-------|------|---------|
| `park_claim_by_hwid` | `hwid -> {key,pos}` | claim owned by each turtle |
| `park_claim_by_key` | `key -> hwid` | reverse map, tile → owner |

### Voxel map (see [voxelmap.md](voxelmap.md))

| Field | Type | Meaning |
|-------|------|---------|
| `master_voxels` | `[y][x][z]=name` | authoritative voxel DB |
| `total_voxels` | number | count of occupied cells |
| `volatile_solids` | `key -> {x,y,z,ts}` | transient solid sightings for air inference |
| `map_dirty` | boolean | unsaved changes pending |
| `last_map_save` | number | epoch ms of last save |
| `map_persist_enabled` | boolean | gate for the autosave thread |

### Ore tracking / clustering (see [orders.md](orders.md))

| Field | Type | Meaning |
|-------|------|---------|
| `ore_log` | `ore->count` | lifetime sighting tally |
| `clusters` | list | `{ore,cx,cy,cz,count,dispatched}` vein centroids |
| `ORE_FEED` | list | display ring buffer |
| `dispatched` | table | dispatch bookkeeping |

### `getme` orders, reservations, zones

| Field | Type | Meaning |
|-------|------|---------|
| `active_orders` | `ore->{target,got,jobs}` | live retrieval orders |
| `reservations` | `key->{hwid,ts}` | per-tile RESERVE locks ([director.md](director.md)) |
| `zones` | `name->{chest,contents}` | storage zones, seeded from `cfg.ZONES` ([zones.md](zones.md)) |

### Population / replication (see [population.md](population.md))

| Field | Type | Meaning |
|-------|------|---------|
| `target_fleet` | number | hard cap, defaults to `cfg.TARGET_FLEET` |
| `craft_authorized` | boolean | current Genesis craft gate |
| `genesis_hwid` | string/nil | the elected Genesis seed |

### Display / runtime (see [cockpit.md](cockpit.md))

| Field | Type | Meaning |
|-------|------|---------|
| `view_cx`, `view_cz`, `view_y` | number | cockpit/map view centre |
| `BOOT_TIME` | number | epoch ms at boot (uptime base) |
| `alert_log` | list | recent `ALERT` messages (capped at 8) |
| `mon` | peripheral/nil | attached monitor |
| `vault` | peripheral/nil | operator supply chest |

- **Functions documented:** 0 (pure data module).
- **Contract/invariant:** treated as a process-global singleton; correctness
  depends on there being exactly one overseer process sharing this table.
