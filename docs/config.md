# config.lua — The Constant Contract

[`onet/config.lua`](../onet/config.lua) is the **single source of truth** for
every tunable constant in O-NET V2. It is pure data: no hardware calls, no
`require`s, and no mutable runtime state. The module declares exactly one local
(`M`), sets every value as a field on it, and returns it. Both runtimes
(`require("config")`) read the same table, so a turtle and the overseer can
never disagree about a constant.

> **Do not** put runtime state here. Things that change while the system runs
> (rosters, want lists, anti-oscillation history) live in the `state.lua`
> modules, not in `config.lua`. See [Not in this file](#not-in-this-file).

This page lists every constant/table the file defines, with its value, units or
meaning, and which subsystem consumes it.

---

## Non-negotiable contracts (read first)

Three things in this file are **contracts, not preferences**. Changing them
without changing the code that depends on them will break the system:

- **`PROTOCOL`** must equal the protocol string both runtimes broadcast under.
  It is mirrored in [`onet/lib/proto.lua`](../onet/lib/proto.lua) (`M.PROTOCOL`)
  and the two must stay byte-identical, or no message is ever received.
- **Reserved slots** `SLOT_SCANNER = 1` and `SLOT_PICKAXE = 2`. Tool protection
  keys on these **slot numbers** *before* any `getItemDetail` call, because
  NBT/Forge-tagged tools can make `getItemDetail` return `nil` and trick a naive
  "is this a tool?" check into dumping the scanner or pickaxe.
- **`TARGET_FLEET`** is a **hard cap**. Population control is replace-on-loss
  only — it never exceeds this number, and Genesis never consumes the last
  turtle base.

---

## Protocol

| Constant | Value | Meaning | Consumed by |
|----------|-------|---------|-------------|
| `PROTOCOL` | `"ONET_V2"` | Rednet protocol string stamped on every message. **Must match `proto.PROTOCOL`.** | `network.lua`, `heartbeat.lua`, every overseer sender/handler, `proto.lua` |

---

## Reserved inventory slots (NON-NEGOTIABLE)

Mining turtles use a fixed inventory layout: slot 1 = geo scanner, slot 2 =
diamond pickaxe, slots 3..16 = cargo.

| Constant | Value | Meaning | Consumed by |
|----------|-------|---------|-------------|
| `SLOT_SCANNER` | `1` | Reserved slot number holding the geo scanner. | `inventory.lua`, `scanner.lua`, `hardware.lua` |
| `SLOT_PICKAXE` | `2` | Reserved slot number holding the diamond pickaxe. | `inventory.lua`, `pickaxe.lua`, `hardware.lua` |
| `CARGO_FIRST` | `3` | First free cargo slot. | `inventory.lua`, `task_dump.lua`, `task_craft.lua` |
| `CARGO_LAST` | `16` | Last free cargo slot. | `inventory.lua`, `task_dump.lua` |
| `CARGO_COUNT` | `14` | Number of cargo slots (slots 3..16). | `inventory.lua` (fullness checks) |

> The protection logic keys on these **slot numbers** before inspecting item
> details — see the contract note above.

---

## Item identifiers

| Constant | Value | Meaning | Consumed by |
|----------|-------|---------|-------------|
| `SCANNER_ITEM` | `"advancedperipherals:geo_scanner"` | Item id of the geo scanner the turtle hot-swaps onto the tool side. | `hardware.lua`, `scanner.lua` |
| `PICKAXE_ITEM` | `"minecraft:diamond_pickaxe"` | Item id of the mining pickaxe. | `hardware.lua`, `pickaxe.lua`, `inventory.lua` |

---

## Sensing

| Constant | Value | Units | Meaning | Consumed by |
|----------|-------|-------|---------|-------------|
| `SCAN_RADIUS` | `8` | blocks | Geo-scan radius. | `scanner.lua`, `task_scan.lua` |
| `SCAN_EVERY` | `4` | heartbeats | Heartbeats between idle background scans. | `role_miner.lua`, `scanner.lua` |
| `HEARTBEAT_INT` | `3` | seconds | Period of the turtle heartbeat thread. | `heartbeat.lua` |

---

## Fuel thresholds

| Constant | Value | Units | Meaning | Consumed by |
|----------|-------|-------|---------|-------------|
| `FUEL_MIN` | `200` | fuel | Below this the turtle returns to base (`RTB_FUEL`). | `fuel.lua`, `role_miner.lua`, `task_fuel.lua` |
| `FUEL_TARGET` | `500` | fuel | Refuel up to (not over) this. | `fuel.lua`, `task_fuel.lua` |
| `FUEL_CRITICAL` | `80` | fuel | Emergency-forage threshold; below this the turtle forages coal instead of pathing home. | `fuel.lua` |
| `FORAGE_MAX` | `32` | blocks | Maximum search distance when foraging for emergency coal. | `fuel.lua` |

---

## Grid mining

| Constant | Value | Units | Meaning | Consumed by |
|----------|-------|-------|---------|-------------|
| `GRID_SPACING` | `5` | blocks | One 1-wide tunnel every 5 blocks → 4-block pillars between lanes. **This is the lane spacing** (there is no `LANE_SPACING`). | `grid.lua`, `gridmap.lua`, `task_tunnel.lua` |
| `SEGMENT_LEN` | `16` | blocks | Default segment length handed to a miner. | `gridmap.lua`, `task_tunnel.lua`, `role_miner.lua` |
| `MAX_TUNNEL` | `256` | blocks | Maximum length of a single mined tunnel. | `task_tunnel.lua` |
| `DIRECTIONS` | `{ 0, 1, 2, 3 }` | cardinals | Cardinal lane directions used to load-balance miners. | `gridmap.lua` |

---

## Base protection

| Constant | Value | Units | Meaning | Consumed by |
|----------|-------|-------|---------|-------------|
| `BASE_PROTECTION_RADIUS` | `32` | blocks (manhattan) | No block within this distance of the overseer position is broken. | `task_mine.lua`, `task_tunnel.lua`, `movers.lua` |

---

## Navigation tuning

| Constant | Value | Units | Meaning | Consumed by |
|----------|-------|-------|---------|-------------|
| `STUCK_VALUE` | `2` | count | Failed-move count that flags the turtle as stuck and triggers recovery. | `nav.lua` |
| `REPATH_PROB` | `0.125` | probability | Chance of a random re-path to break livelocks. | `nav.lua` |
| `RESERVE_TTL_MS` | `1400` | ms | Lifetime of a tile reservation granted by the overseer. | `nav.lua`, `network.lua`, `push_broker.lua` |
| `RESERVE_WAIT_MS` | `700` | ms | How long a turtle waits for a `RESERVE_ACK` before proceeding. | `nav.lua` |
| `WAYPOINT_DIST` | `32` | blocks | Long routes are split into waypoints of at most this length. | `nav.lua` |
| `CAL_FILE` | `"onet_cal.cfg"` | filename | On-disk heading-calibration cache. | `calibrate.lua` |

---

## Population / self-replication

| Constant | Value | Units | Meaning | Consumed by |
|----------|-------|-------|---------|-------------|
| `TARGET_FLEET` | `6` | turtles | **Hard cap** on live turtles; replace-on-loss only. | `population.lua` |
| `LOSS_TIMEOUT` | `60000` | ms | Silence longer than this declares a turtle dead. | `population.lua` |

---

## Overseer timing & persistence

| Constant | Value | Units | Meaning | Consumed by |
|----------|-------|-------|---------|-------------|
| `HB_TIMEOUT` | `12000` | ms | Roster-prune threshold: a turtle silent past it is dropped from the live roster. (Overseer timing value — **not** a turtle field.) | `director.lua` (pruner), `fleet.lua` |
| `DISP_REFRESH` | `0.5` | seconds | Cockpit redraw interval. | `cockpit.lua` |
| `MAP_SAVE_INTERVAL` | `60` | seconds | Period of the background map-save thread. | `persist.lua` |
| `CONFIG_FILE` | `"onet_overseer.cfg"` | filename | Persisted overseer config (dump/base/zones/want list). | `persist.lua` |
| `MAP_FILE` | `"onet_map.dat"` | filename | Persisted voxel/grid map. | `persist.lua`, `voxelmap.lua` |
| `AIR_MARKER` | `"__air__"` | sentinel | Marker stored in the voxel DB for an inferred-air cell. | `voxelmap.lua` |
| `CLUSTER_RADIUS` | `4` | blocks | Reported ores within this distance are grouped into one cluster/vein. | `voxelmap.lua`, `orders.lua` |
| `ORE_FEED_MAX` | `8` | entries | Length of the bounded recent-ore feed shown on the cockpit. | `voxelmap.lua`, `cockpit.lua` |
| `VOL_SOLID_TTL_MS` | `180000` | ms | Time-to-live for a "volatile solid" cell before air inference may promote it to air. | `voxelmap.lua` |

---

## State priorities

`PRIORITY` maps a turtle's `state.current_state` to a move-priority number.
**Lower = more urgent**, and an equal-or-lower-urgency blocker is the one asked
to yield by the push broker. Read by both the turtle brain and the overseer's
`push_broker.lua`.

| Key | Value | Meaning |
|-----|-------|---------|
| `GOTO` | `1` | Directed move from the overseer — most urgent, never yields. |
| `RTB_FUEL` | `2` | Returning to base low on fuel. |
| `RTB_DUMP` | `3` | Returning to dump full cargo. |
| `FETCH_PICK` | `4` | Going to fetch a replacement pickaxe. |
| `MINING` | `5` | Actively mining a segment. |
| `SEARCH` | `6` | Executing a search/scout job. |
| `BUILDER` | `7` | Building / smelting Genesis materials. |
| `GENESIS` | `7` | Crafting a new turtle (ties with `BUILDER`). |
| `STANDBY` | `8` | Idle but available. |
| `PARKED` | `9` | Parked — least urgent, always yields. |

> The ordering **is** the contract: the push broker compares these numbers, so
> renumbering changes who steps aside. Keep `GOTO` lowest and `PARKED` highest.

---

## Storage zones

| Constant | Value | Meaning | Consumed by |
|----------|-------|---------|-------------|
| `ZONES` | `{ "ORES", "FUEL", "BUILDING_MAT", "GENESIS_MAT" }` | Named storage zones the overseer assigns chests to and haulers/builders sort cargo into. | `zones.lua`, `role_hauler.lua`, `role_builder.lua`, `task_dump.lua` |

---

## Genesis recipe

`GENESIS_RECIPE` is the table of raw materials the Builder must gather/smelt into
the `GENESIS_MAT` zone before a new turtle can be crafted. The final assembly is
a single `turtle.craft()` (the 3×3 grid is arranged by `role_genesis`; see
[task_craft](turtle/tasks/task_craft.md)).

| Material | Quantity | Note |
|----------|----------|------|
| `gold_ingot` | `27` | Enough for an advanced modem + advanced computer (which becomes the turtle). |
| `diamonds` | `3` | Pickaxe. |
| `stone` | `22` | Turtle/computer body. |
| `planks` | `8` | |
| `sticks` | `2` | |
| `glass_pane` | `1` | |
| `redstone` | `1` | |
| `ender_pearl` | `1` | |
| `ender_eye` | `1` | **Player-supplied** — the only manual input, needed for the advanced ender modem that self-replication requires. |

Consumed by `population.lua` (authorization), `role_builder.lua`/`role_genesis.lua`
(gather + arrange), and `task_craft.lua` (craft).

---

## Roles

`ROLES` maps short keys to the role-module names the brain hot-swaps between.
Each value matches `M.name` in the corresponding `onet/turtle/roles/*` module.

| Key | Value | Module |
|-----|-------|--------|
| `MINER` | `"MinerRole"` | [role_miner](turtle/roles/role_miner.md) |
| `HAULER` | `"HaulerRole"` | [role_hauler](turtle/roles/role_hauler.md) |
| `SCOUT` | `"ScoutRole"` | [role_scout](turtle/roles/role_scout.md) |
| `REFUEL` | `"RefuelRole"` | [role_refuel](turtle/roles/role_refuel.md) |
| `BUILDER` | `"BuilderRole"` | [role_builder](turtle/roles/role_builder.md) |
| `GENESIS` | `"GenesisRole"` | [role_genesis](turtle/roles/role_genesis.md) |

Consumed by `brain.lua` (role swap), `population.lua`, and the overseer
`ROLE_ASSIGN` flow.

---

## Not in this file

These names appear in the system but are **runtime state**, defined in the
`state.lua` modules — not constants here:

- `WANT_LIST` — operator retrieval policy (which ores to fetch), in
  [`onet/turtle/state.lua`](../onet/turtle/state.lua) and
  [`onet/overseer/state.lua`](../onet/overseer/state.lua); edited from the
  overseer terminal (`want`/`unwant`/`wants`).
- `RECENT_TILE_WINDOW` / `recent_tiles` — anti-oscillation memory window, in
  [`onet/turtle/state.lua`](../onet/turtle/state.lua).

There is also **no** `LANE_SPACING` constant — lane spacing is `GRID_SPACING`.

---

See [architecture.md](architecture.md) for how these constants flow through the
runtime, and the top-level [README.md](../README.md) for deployment.
