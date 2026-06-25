# O-NET V2 — Documentation Index

This folder is the full documentation set for the O-NET V2 turtle-swarm
codebase. It complements the top-level [README.md](../README.md), which covers
deployment and the high-level picture.

## How these docs are organized

The documentation **mirrors the source tree**. The plan is one Markdown file per
source module, laid out under matching folders:

```
docs/
  README.md            This index
  architecture.md      System-level overview (read this first)
  config.md            config.lua — the constant contract

  lib/                 docs for onet/lib/*
  turtle/              docs for onet/turtle/*
  turtle/roles/        docs for onet/turtle/roles/*
  turtle/tasks/        docs for onet/turtle/tasks/*
  overseer/            docs for onet/overseer/*
```

Each per-module page covers its responsibility, every function (signature,
behavior, parameters, returns, side effects), the state it reads/writes, the
protocol messages it sends or handles, and any non-obvious invariants.

Start with **[architecture.md](architecture.md)** for the runtime model, then
drill into the module that interests you using the table of contents below.

---

## Table of Contents — All 52 Modules

### Entry points

| Module | Doc | One-line description |
|--------|-----|----------------------|
| [startup.lua](../startup.lua) | _system_ | Detects turtle vs overseer and runs the matching boot file. |
| [onet/boot_turtle.lua](../onet/boot_turtle.lua) | _system_ | Turtle boot: hardware → calibrate → enlist → supervised brain/listener/heartbeat. |
| [onet/boot_overseer.lua](../onet/boot_overseer.lua) | _system_ | Overseer boot: peripherals → GPS origin → load persisted state → main loop. |
| [onet/config.lua](../onet/config.lua) | [config.md](config.md) | Single source of truth for every tunable constant and contract. |

### Libraries — `onet/lib/` (5)

| Module | Doc | One-line description |
|--------|-----|----------------------|
| vec.lua | [lib/vec.md](lib/vec.md) | Vector/coordinate helpers, direction vectors, world-key hashing. |
| grid.lua | [lib/grid.md](lib/grid.md) | Grid-coordinate math: segments, lanes, and pillar spacing. |
| blocks.lua | [lib/blocks.md](lib/blocks.md) | Block-name classification (ore / air / hazard / fixture). |
| proto.lua | [lib/proto.md](lib/proto.md) | Protocol message helpers and shared protocol constants. |
| log.lua | [lib/log.md](lib/log.md) | Tagged logging used on every state transition and action. |

### Turtle CORE — `onet/turtle/` (14)

| Module | Doc | One-line description |
|--------|-----|----------------------|
| brain.lua | [turtle/brain.md](turtle/brain.md) | Agent loop: hold a Role, ask it for a Task, drive one tick at a time. |
| network.lua | [turtle/network.md](turtle/network.md) | Modem, AUTH handshake, listener thread, and all message handlers. |
| nav.lua | [turtle/nav.md](turtle/nav.md) | Pathing: greedy axis moves, A* detours, recovery, waypoint splitting. |
| movers.lua | [turtle/movers.md](turtle/movers.md) | Primitive movement, facing, and dig-step operations. |
| scanner.lua | [turtle/scanner.md](turtle/scanner.md) | Geo-scanner hot-swap and ore reporting (with the anti-race lock). |
| calibrate.lua | [turtle/calibrate.md](turtle/calibrate.md) | GPS heading calibration, verified live on restore. |
| cache.lua | [turtle/cache.md](turtle/cache.md) | Local block cache fed by scans; navigator's view of the world. |
| state.lua | [turtle/state.md](turtle/state.md) | Turtle runtime state with forward-declared fields. |
| hardware.lua | [turtle/hardware.md](turtle/hardware.md) | Peripheral and slot detection, scanner-slot refresh. |
| inventory.lua | [turtle/inventory.md](turtle/inventory.md) | Cargo management and slot-number tool protection. |
| fuel.lua | [turtle/fuel.md](turtle/fuel.md) | Wake-up, refuel-to-target, and emergency coal forage. |
| pickaxe.lua | [turtle/pickaxe.md](turtle/pickaxe.md) | Pickaxe equip and restore after a scanner swap. |
| heartbeat.lua | [turtle/heartbeat.md](turtle/heartbeat.md) | Periodic status report thread to the overseer. |
| boot_turtle.lua | [turtle/boot_turtle.md](turtle/boot_turtle.md) | Turtle boot sequence and thread supervision. |

### Roles — `onet/turtle/roles/` (6)

| Module | Doc | One-line description |
|--------|-----|----------------------|
| role_miner.lua | [turtle/roles/role_miner.md](turtle/roles/role_miner.md) | Default role: grid mining and passive scanning. |
| role_hauler.lua | [turtle/roles/role_hauler.md](turtle/roles/role_hauler.md) | Move cargo between storage zones and the dump. |
| role_scout.lua | [turtle/roles/role_scout.md](turtle/roles/role_scout.md) | Explore and execute search jobs. |
| role_refuel.lua | [turtle/roles/role_refuel.md](turtle/roles/role_refuel.md) | Refuel-focused behavior for the fleet. |
| role_builder.lua | [turtle/roles/role_builder.md](turtle/roles/role_builder.md) | Build structures and smelt/gather Genesis materials. |
| role_genesis.lua | [turtle/roles/role_genesis.md](turtle/roles/role_genesis.md) | Self-replication; crafty-turtle-only, gated by CRAFT_AUTH. |

### Tasks — `onet/turtle/tasks/` (10)

| Module | Doc | One-line description |
|--------|-----|----------------------|
| task.lua | [turtle/tasks/task.md](turtle/tasks/task.md) | Base Task object: `.parent` chaining and `isWorking` termination. |
| task_goto.lua | [turtle/tasks/task_goto.md](turtle/tasks/task_goto.md) | Navigate to an absolute coordinate. |
| task_mine.lua | [turtle/tasks/task_mine.md](turtle/tasks/task_mine.md) | Mine a target ore/block. |
| task_tunnel.lua | [turtle/tasks/task_tunnel.md](turtle/tasks/task_tunnel.md) | Dig a straight grid segment. |
| task_scan.lua | [turtle/tasks/task_scan.md](turtle/tasks/task_scan.md) | Perform a geo scan and report results. |
| task_park.lua | [turtle/tasks/task_park.md](turtle/tasks/task_park.md) | Go to and hold a parking position. |
| task_dump.lua | [turtle/tasks/task_dump.md](turtle/tasks/task_dump.md) | Deposit cargo into the dump or zone chest. |
| task_fuel.lua | [turtle/tasks/task_fuel.md](turtle/tasks/task_fuel.md) | Return to base and refuel. |
| task_craft.lua | [turtle/tasks/task_craft.md](turtle/tasks/task_craft.md) | Run the single `turtle.craft()` (grid pre-arranged by role_genesis), place the turtle, signal `CRAFT_DONE`. |
| task_build.lua | [turtle/tasks/task_build.md](turtle/tasks/task_build.md) | Place blocks for a build job. |

### Overseer — `onet/overseer/` (15)

| Module | Doc | One-line description |
|--------|-----|----------------------|
| overseer.lua | [overseer/overseer.md](overseer/overseer.md) | Main loop: run every overseer thread, each supervised. |
| director.lua | [overseer/director.md](overseer/director.md) | Network listener thread and roster-pruner thread. |
| cockpit.lua | [overseer/cockpit.md](overseer/cockpit.md) | Monitor cockpit: map, fleet, ore feed, supplies. |
| terminal.lua | [overseer/terminal.md](overseer/terminal.md) | Operator command terminal thread. |
| fleet.lua | [overseer/fleet.md](overseer/fleet.md) | Fleet roster model and per-turtle records. |
| population.lua | [overseer/population.md](overseer/population.md) | Enforce TARGET_FLEET; authorize Genesis crafting. |
| push_broker.lua | [overseer/push_broker.md](overseer/push_broker.md) | Arbitrate PUSH_REQ by move priority (who yields). |
| orders.lua | [overseer/orders.md](overseer/orders.md) | `getme`-style retrieval order queue and worker thread. |
| zones.lua | [overseer/zones.md](overseer/zones.md) | Storage-zone (ORES/FUEL/...) chest assignment. |
| park.lua | [overseer/park.md](overseer/park.md) | Parking-slot allocation for recalled turtles. |
| gridmap.lua | [overseer/gridmap.md](overseer/gridmap.md) | Grid origin and segment/lane assignment. |
| voxelmap.lua | [overseer/voxelmap.md](overseer/voxelmap.md) | Authoritative voxel DB with volatile-solid air inference. |
| persist.lua | [overseer/persist.md](overseer/persist.md) | Config and map load/save, plus the periodic save thread. |
| state.lua | [overseer/state.md](overseer/state.md) | Overseer runtime state. |
| boot_overseer.lua | [overseer/boot_overseer.md](overseer/boot_overseer.md) | Overseer boot entry (see also /onet/boot_overseer.lua). |

---

> **Status:** Documentation complete. The index, the constant-contract
> reference [config.md](config.md), the system-level
> [architecture.md](architecture.md), and every per-module page linked above
> (lib, turtle CORE, roles, tasks, and the 15 overseer modules) are written —
> all 52 modules plus `config.lua` are covered.
