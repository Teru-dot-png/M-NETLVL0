# O-NET V2 — Modular Turtle Swarm

O-NET V2 is a deployable [CC:Tweaked](https://tweaked.cc/) swarm-mining system
for ComputerCraft turtles. A single **overseer** computer commands a fleet of
**mining turtles** that tunnel a shared grid, scan their surroundings, report
ore and geometry, deconflict their movements, refuel and repair themselves, and
— with a crafting turtle in the fleet — **self-replicate** to maintain a target
population.

This is the **V2 modular refactor**. The entire system lives under
[onet/](onet/) as small single-responsibility modules, replacing the old V1
monolith. If you are looking for `main_mapper.lua`, `scout_node.lua`, or
`tablet_console.lua` — those V1 files no longer exist; their behavior has been
ported into the modules described below.

---

## 1) Two-Runtime Architecture

O-NET runs as exactly two kinds of program, dispatched automatically by a single
[startup.lua](startup.lua):

```lua
if turtle then
    shell.run("/onet/boot_turtle.lua")
else
    shell.run("/onet/boot_overseer.lua")
end
```

- **Overseer** — a stationary computer (advanced recommended, with a monitor).
  Boots via [onet/boot_overseer.lua](onet/boot_overseer.lua). It owns the
  authoritative map (voxel + grid), the fleet roster, order queue, push/
  reservation arbitration, population control, and the operator cockpit.
- **Turtle** — a mining turtle. Boots via
  [onet/boot_turtle.lua](onet/boot_turtle.lua). It detects its own hardware,
  calibrates heading from GPS, enlists with the overseer, and then runs three
  pcall-supervised threads in parallel: the **brain** (role → task agent loop),
  the **listener** (network), and the **heartbeat**.

Both boot files install a flat `package.path` across the `/onet` tree and share
[onet/config.lua](onet/config.lua) as the single source of truth for all
constants.

---

## 2) Repository Layout

```
startup.lua                 Entry point: dispatch to turtle or overseer boot
README.md                   This file
docs/                       Full documentation set (see docs/README.md)

onet/
  config.lua                Single source of truth for all tunable constants
  boot_turtle.lua           Turtle boot + supervised brain/listener/heartbeat
  boot_overseer.lua         Overseer boot + peripheral/GPS/persist setup

  lib/                      Shared, hardware-free libraries
    vec.lua                 Vector / coordinate / direction helpers
    grid.lua                Grid-coordinate math (segments, lanes, pillars)
    blocks.lua              Block-name classification (ore/air/hazard/etc.)
    proto.lua               Protocol message helpers / shared constants
    log.lua                 Tagged logging

  turtle/                   Turtle CORE runtime
    brain.lua               Agent loop: hold a Role, drive one Task per tick
    network.lua             Modem, AUTH handshake, listener thread, handlers
    nav.lua                 Pathing (greedy + A* detours + recovery)
    movers.lua              Primitive movement / facing / dig-step
    scanner.lua             Geo-scanner hot-swap + ore reporting
    calibrate.lua           GPS heading calibration (verified live)
    cache.lua               Local block cache fed by scans
    state.lua               Turtle runtime state (forward-declared globals)
    hardware.lua            Peripheral + slot detection, scanner refresh
    inventory.lua           Cargo management, slot-number tool protection
    fuel.lua                Wake/refuel/forage logic
    pickaxe.lua             Pickaxe equip / restore after scan swap
    heartbeat.lua           Periodic status report thread

    roles/                  What a turtle is currently *for*
      role_miner.lua        Grid mining (default role)
      role_hauler.lua       Move cargo between zones / dump
      role_scout.lua        Explore / search jobs
      role_refuel.lua       Refuel-focused behavior
      role_builder.lua      Build structures / smelt Genesis materials
      role_genesis.lua      Self-replication (crafty turtle only)

    tasks/                  Atomic composable units of work (Overmind chain)
      task.lua              Base Task object (.parent chaining, isWorking)
      task_goto.lua         Navigate to a coordinate
      task_mine.lua         Mine ore / a target block
      task_tunnel.lua       Dig a straight segment of the grid
      task_scan.lua         Geo scan + report
      task_park.lua         Go to and hold a parking position
      task_dump.lua         Deposit cargo into the dump/zone chest
      task_fuel.lua         Return-to-base refuel
      task_craft.lua        Arrange grid + single turtle.craft()
      task_build.lua        Place blocks for a build job

  overseer/                 Overseer runtime
    overseer.lua            Main loop: run all overseer threads supervised
    director.lua            Listener + roster pruner threads
    cockpit.lua             Monitor cockpit rendering thread
    terminal.lua            Operator command terminal thread
    fleet.lua               Fleet roster model + per-turtle records
    population.lua          Target-fleet enforcement + Genesis authorization
    push_broker.lua         PUSH_REQ arbitration (who yields)
    orders.lua              getme-style retrieval order queue + thread
    zones.lua               Storage-zone (ORES/FUEL/...) chest assignment
    park.lua                Parking-slot allocation
    gridmap.lua             Grid origin + segment/lane assignment
    voxelmap.lua            Authoritative voxel DB + air inference
    persist.lua             Config + map load/save (and save thread)
    state.lua               Overseer runtime state
    boot_overseer.lua       (boot entry — see /onet/boot_overseer.lua)
```

A complete per-module documentation set lives under [docs/](docs/README.md).

---

## 3) Software & Mod Requirements

- **Minecraft + CC:Tweaked** — the ComputerCraft fork this codebase targets.
- **Advanced Peripherals — Geo Scanner** — item id
  `advancedperipherals:geo_scanner`. Each mining turtle carries one in its
  reserved scanner slot and hot-swaps it onto the tool side to scan.
- **Ender modem** on every turtle and on the overseer, for unbounded-range
  Rednet under protocol `ONET_V2`.
- **GPS constellation** covering the mining dimension. Turtles call
  `gps.locate()` during calibration and verify heading live on restore; the
  overseer derives its grid origin (and the base-protection center) from GPS at
  boot. Without a stable GPS fix, navigation degrades and the overseer falls
  back to a default origin.
- A **diamond pickaxe** (`minecraft:diamond_pickaxe`) per mining turtle.
- A **crafting turtle** ("crafty") in the fleet if you want self-replication;
  only a crafty turtle exposes `turtle.craft` and can run the Genesis role.

---

## 4) The Slot Reservation Contract (NON-NEGOTIABLE)

Mining turtles use a fixed inventory layout, defined in
[onet/config.lua](onet/config.lua):

| Slot | Contents | Status |
|------|----------|--------|
| **1** | Geo scanner (`advancedperipherals:geo_scanner`) | **Reserved** |
| **2** | Diamond pickaxe (`minecraft:diamond_pickaxe`) | **Reserved** |
| **3–16** | Cargo (14 slots) | Free |

Tool protection keys on these **slot numbers** *before* any `getItemDetail`
call. This is deliberate: NBT/Forge-tagged tools can make `getItemDetail`
return `nil`, which would trick a naive "is this a tool?" check into dumping the
scanner or pickaxe. The scanner hot-swap additionally holds a `scanning_now`
lock so the inventory/pickaxe logic cannot race the swap. **Do not** bypass the
slot-number guard or remove the lock.

---

## 5) Deployment & Boot

### 5.1 Install the tree

Every computer in the system runs the **same** `/onet` tree plus `/startup.lua`.
Copy both onto each device (overseer computer and each turtle). The startup
script auto-detects the device type — there is no separate "miner script" vs
"overseer script" to install.

Place on each device:

- `/startup.lua`
- the entire `/onet/` directory

Once Genesis is running, you do not need to install turtles by hand: a crafting
turtle copies the whole `/onet` tree + `/startup.lua` onto each turtle it builds
(see §6).

### 5.2 Hardware setup

**Overseer computer**

- Ender modem (any side) — required.
- Advanced monitor — recommended (drives the cockpit).
- A chest peripheral ("vault") — optional, for supply readout.
- Good GPS coverage at its location (defines the grid origin and base-protection
  center).

**Each mining turtle**

- Ender modem on one side.
- Diamond pickaxe on the opposite (tool) side — hot-swapped during scans.
- Geo scanner in **slot 1**, diamond pickaxe in **slot 2** (see §4).
- Fuel and cargo space in slots 3–16.

### 5.3 Boot order

1. Boot the **overseer** first so it can answer enlistment.
2. Boot the **turtles**. Each broadcasts `AUTH_REQ`; the overseer replies
   `AUTH_ACK` with the turtle's role, direction, dump/base, and zone chests.
3. Configure dump/base/parking and storage zones from the overseer terminal.
4. Start the fleet.

The overseer terminal (`help` lists commands) drives day-to-day operation;
populate dump/base coordinates and zones before starting mining.

---

## 6) Self-Replication (Genesis) — High Level

O-NET can grow and heal its own fleet up to a hard cap defined by
`TARGET_FLEET` in [onet/config.lua](onet/config.lua):

- The overseer's **population controller** tracks live turtles. A turtle that
  goes silent past `LOSS_TIMEOUT` is declared dead.
- Population enforcement is **replace-on-loss only**: the fleet never exceeds
  `TARGET_FLEET`, and Genesis never consumes the **last** turtle base — the
  system cannot replicate itself out of existence.
- When the live count is below target, the overseer authorizes a **crafty**
  turtle (Genesis role) to craft a new turtle. The Builder/Genesis pipeline
  gathers and smelts the raw materials in `GENESIS_RECIPE` into the
  `GENESIS_MAT` storage zone; **`role_genesis` arranges the 3×3 crafting grid**
  from those materials, then `task_craft` performs the single `turtle.craft()`,
  places the new turtle, and signals `CRAFT_DONE`.
- The newly built turtle receives the **entire `/onet` tree + `/startup.lua`**,
  so on first power-on it runs the identical dispatch and enlists like any other
  turtle.

The one manual input the recipe calls for is an **ender eye** (for the advanced
ender modem required for self-replication); everything else is gathered by the
fleet.

---

## 7) Documentation

Detailed, per-module documentation lives under [docs/](docs/README.md):

- [docs/README.md](docs/README.md) — documentation index; one entry per source
  module, mirroring the source tree.
- [docs/architecture.md](docs/architecture.md) — system-level overview: the
  overseer/turtle split, the Task-chain (Overmind) model, role → task →
  nav/movers layering, network/protocol flow, push-broker + reservation
  coordination, scanner hot-swap, ore clustering, voxel inference, and the
  self-replication lifecycle.

---

## 8) Key Invariants (read before editing source)

These contracts are enforced across the codebase and are easy to break by
accident:

- **`PROTOCOL = "ONET_V2"`** for every Rednet message.
- **Slot-number tool protection** before `getItemDetail` (see §4).
- **≤ 200 locals per scope**, with forward declarations where needed (a Lua VM
  limit the modules are structured around).
- **pcall-wrapped supervised threads** on both runtimes — a transient crash logs
  and restarts rather than dropping to the shell or taking the base offline.
- **GPS heading verified live on restore**, not trusted blindly from disk.
- **`TARGET_FLEET` hard cap**, replace-on-loss only; never consume the last
  turtle base.
- **`GRID_SPACING`** (config.lua) sets lane separation — one 1-wide tunnel
  every N blocks, leaving the pillars between lanes.
- **`HB_TIMEOUT`** (config.lua) is the overseer's roster-prune timeout: a turtle
  silent past it is dropped from the live roster.

A few names that look like constants are actually **runtime state fields**, not
`config.lua` values:

- `RECENT_TILE_WINDOW` and `recent_tiles` — anti-oscillation memory window, in
  [onet/turtle/state.lua](onet/turtle/state.lua).
- `WANT_LIST` — the operator's retrieval policy (which ores to fetch), held in
  [onet/turtle/state.lua](onet/turtle/state.lua) and
  [onet/overseer/state.lua](onet/overseer/state.lua) and edited from the
  overseer terminal (`want`/`unwant`/`wants`).

For the full, authoritative list of every constant and contract, see
[docs/config.md](docs/config.md).

## 9) Troubleshooting

Miners do not enlist:

- Verify both sides have active modems and the same protocol (`ONET_V2`).
- Boot overseer before miners.
- Ensure rednet is open and not blocked by world chunk behavior.

Miners fail calibration:

- GPS missing or unreliable.
- Build/fix constellation in current dimension.

Miners loop around blocks:

- Confirm reservation and push traffic is flowing.
- Increase reservation TTL slightly (`RESERVE_TTL_MS`) if network lag is high.
- Increase the anti-oscillation window if ping-pong appears.

No ore retrieval after `getme`:

- Check `orders` output.
- If map has no known ore, miners must discover first.
- Confirm scanner presence in slot 1 and scan operations in logs.

Chest-full stalls:

- Expand dump storage.
- Verify dump coordinate with `coords`.
- Ensure chunk for dump chest stays loaded.

Frequent fuel emergencies:

- Increase on-board fuel stock.
- Verify base chest coordinate and fuel availability.
- Raise `FUEL_TARGET` if routes are long.

Pickaxe fetch failures:

- Ensure base chest contains valid pickaxe items.
- Keep spare fresh pickaxes available.
- Verify base chest coordinate and chunk load.

## 10) Safety and Hardening Notes

- Slot 1 is scanner-reserved by policy. Do not repurpose.
- Avoid disabling GPS in active mining dimensions.
- Keep protected infrastructure blocks out of miner dig lanes.
- Use parking zones to prevent base area traffic jams.
- Use `recall` before editing scripts live.

## 11) Updating the Network

Safe update sequence:

1. `recall` the fleet from the overseer terminal.
2. Wait until miners park/dump.
3. Update the `/onet` tree (and `/startup.lua`) on the overseer and every turtle.
4. Reboot the overseer, then the turtles.
5. Verify `status`, `coords`, and `wants`.
6. `start`.

## 12) Minimal Quickstart Checklist

- GPS working in target dimension.
- Overseer has modem and monitor.
- Each miner has modem, pickaxe, scanner in slot 1, and fuel.
- `setdump`, `setbase`, optional `setpark` configured.
- `start` executed.
- `status` shows fleet heartbeats.

## 13) License and Customization

This repository is intended as a practical operations codebase.

Customize constants and command policy to match your world scale, ore goals, and server lag profile.
