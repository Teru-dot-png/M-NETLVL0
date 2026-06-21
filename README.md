# O-NET V1 Robot Mesh Network

A deployable CC:Tweaked swarm mining system with:

- One overseer computer (`main_mapper.lua`) that manages the fleet, map, parking, orders, and collision brokering.
- Many miner turtles (`scout_node.lua`) that mine lanes, scan geometry, report ore, and execute targeted ore jobs.
- A mesh-like behavior model over Rednet with push/yield and tile reservation coordination.

This guide is written so someone can deploy their own network from scratch.

## 1) What You Get

- Fleet orchestration over `ONET_V1` protocol.
- Automatic lane assignment and re-assignment (`newrun`).
- Live monitor cockpit with map, fleet state, ore feed, and supplies.
- Persistent map storage across overseer restarts (`mnet_map.dat`).
- Ore target workflows:
- Passive mining scan reports.
- WANT-list detours (`want`, `unwant`).
- Explicit order queue (`getme <ore> <count>`).
- Multi-robot deconfliction:
- Priority push protocol (`PUSH_REQ` / `YIELD`).
- Overseer arbitration by state priority.
- Tile reservation protocol (`RESERVE_REQ` / `RESERVE_ACK` / `RESERVE_REL`).
- Miner survivability:
- Stuck detection and bounded recovery.
- Adaptive A* detours.
- Inventory, fuel, and pickaxe recovery flows.

## 2) Repository Layout

- `main_mapper.lua`: Overseer runtime.
- `scout_node.lua`: Miner turtle runtime.
- `README.md`: This deployment and operations guide.

## 3) Software and Mod Requirements

Minimum practical stack:

- Minecraft with ComputerCraft: Tweaked (CC:Tweaked).
- Ender modem support (from your pack setup).
- Advanced Peripherals geo scanner support.
- GPS availability in the mining dimension.

Expected miner equipment behavior assumes:

- Geo scanner item id: `advancedperipherals:geo_scanner`.
- Pickaxe item matching: contains `pickaxe` in item name.

## 4) Physical Topology

### Overseer Computer

Attach:

- Ender modem (any side).
- Advanced monitor (recommended for cockpit visibility).
- Optional inventory/chest peripheral for supply readout and dump counting.

Place near your base logistics.

### Miner Turtles

Per miner:

- Ender modem on one side.
- Pickaxe on opposite side (hot-swapped during scans).
- Geo scanner in slot 1 (reserved).
- Fuel in slots 2-15 (or supply path via BASE chest).

### Chests and Coordinates

- `DUMP_CHEST`: where ore payload is dropped.
- `BASE_CHEST`: where emergency fuel and replacement pickaxe are sourced.
- Optional parking rectangle (`setpark`) for orderly recall parking.

## 5) GPS Requirement (Critical)

Miners call `gps.locate()` during calibration and drift correction.

If GPS is missing or unstable:

- Miners cannot reliably calibrate heading.
- Navigation quality drops severely.
- Boot can fail with calibration fatal errors.

Set up a robust GPS constellation in the active dimension before fleet rollout.

## 6) First-Time Deployment

## 6.1 Load Scripts

Copy `main_mapper.lua` to the overseer computer.

Copy `scout_node.lua` to every miner turtle.

Fast install via wget:

Overseer computer:

```sh
wget https://raw.githubusercontent.com/Teru-dot-png/M-NETLVL0/refs/heads/main/main_mapper.lua startup.lua
```

Miner turtle:

```sh
wget https://raw.githubusercontent.com/Teru-dot-png/M-NETLVL0/refs/heads/main/scout_node.lua startup.lua
```

Recommended startup files:

Overseer `startup`:

```lua
shell.run("main_mapper.lua")
```

Miner `startup`:

```lua
shell.run("scout_node.lua")
```

## 6.2 Boot Order

1. Boot overseer first.
2. Boot miners.
3. Wait for miner `AUTH_REQ` / overseer `AUTH_ACK` enlistment.
4. Set base coordinates and policy commands.
5. Start fleet.

## 6.3 Mandatory Initial Config

On overseer terminal:

1. `setdump x y z`
2. `setbase x y z`
3. Optional: `setpark x1 y1 z1 x2 y2 z2`
4. Verify: `coords`
5. Start operation: `start`

## 7) Overseer Command Reference

Core control:

- `start`: deploy fleet into active mining behavior.
- `stop`: halt mining progression.
- `recall`: force return-home behavior (dump then park).
- `status`: per-miner state, fuel, free slots, and position summary.

Configuration:

- `setdump x y z`: set dump chest coordinate.
- `setbase x y z`: set base chest coordinate.
- `setpark x1 y1 z1 x2 y2 z2`: set parking rectangle.
- `coords`: print configured coordinates.

Want-list:

- `want <ore>`: add ore to auto-detour fetch list.
- `unwant <ore>`: remove ore from auto-detour list.
- `wants`: print active wants.

Orders:

- `getme <ore> <count>`: create/replace active retrieval order for ore.
- `orders`: list active orders and progress.
- `cancelorder <ore>`: cancel one ore order.

Lane and map:

- `zones`: show lane assignment and exhaustion state.
- `newrun <hwid>`: assign a fresh lane to a parked/exhausted miner.
- `map`: map stats.
- `savemap`: force map persistence.
- `clearmap`: wipe map state.
- `feed`: recent ore feed events.
- `help`: command list.

## 8) How Mining and Retrieval Actually Works

Normal mining:

- Miner tunnels its assigned lane.
- Scans environment periodically and reports ore + geometry.
- Overseer ingests map and ore feed.

Want-list behavior:

- If reported ore matches WANT list, overseer can dispatch nearest idle turtle to ore cluster.

`getme` behavior:

- Overseer starts an active order for target ore count.
- Dispatch uses known map ore locations first.
- If no known locations exist, order waits while normal mining discovers new nodes.
- Completion tracks both mined confirmations and dump chest counts.

## 9) Navigation and Collision Model

Miner navigation combines:

- Greedy axis movement for cheap progress.
- A* local detours when blocked.
- Recovery spiral + climb-over if A* fails.
- Waypoint splitting for long routes.

Deconfliction layers:

- Priority push protocol for stuck robots.
- Overseer push broker decides who should yield.
- Reservation protocol prevents simultaneous tile entry intent.
- Short-term anti-oscillation penalties reduce ping-pong loops.

Priority policy (lower is more urgent):

- `GOTO=1`, `RTB_FUEL=2`, `RTB_DUMP=3`, `FETCH_PICK=4`, `MINING=5`, `STANDBY=8`, `PARKED=9`.

## 10) Protocol Summary (`ONET_V1`)

Common miner -> overseer:

- `AUTH_REQ`: miner enrollment request.
- `HEARTBEAT`: state/fuel/position/free slot updates.
- `ORE_REPORT`: ore discovery report.
- `GEO_DATA`: geometry snapshots for map.
- `ORE_MINED`: confirmed ore extraction.
- `ALERT`: runtime warnings/failures.
- `PUSH_REQ`: collision mediation request.
- `RESERVE_REQ`: reserve tile intent.
- `RESERVE_REL`: release tile reservation.

Common overseer -> miner:

- `AUTH_ACK`: enrollment response + config.
- `CONFIG`: runtime config updates (dump/base/want/park/lane).
- `CMD_START`, `CMD_STOP`, `CMD_RECALL`: fleet controls.
- `GOTO`: targeted ore job.
- `YIELD`: move-aside command during push arbitration.
- `RESERVE_ACK`: reservation result.

## 11) Map Rendering Model

Map center tracks fleet centroid and current Y.

Current render intent:

- Unknown/rock defaults to `#`.
- Known tunnel air renders as blank.
- Ores render as ore glyphs.
- Special markers:
- `@` robot.
- `D` dump.
- `B` base.

## 12) Operational Playbook

Typical production loop:

1. Start fleet.
2. Watch `status`, `feed`, and monitor map.
3. Add/remove wants as market or base needs change.
4. Use `getme` for hard quotas.
5. Use `newrun <hwid>` to recycle exhausted lanes.
6. Use `recall` before maintenance windows.

Recommended base policy:

- Keep base chest stocked with coal and fresh pickaxes.
- Keep dump chest capacity high to avoid chest-full parking.
- Keep GPS and rednet coverage stable in all work regions.

## 13) Tuning Knobs

In `scout_node.lua`:

- `SCAN_RADIUS`: scan volume.
- `SCAN_EVERY`: cadence scan frequency.
- `HEARTBEAT_INT`: heartbeat interval.
- `FUEL_*`: fuel behavior thresholds.
- `MAX_TUNNEL`: lane depth per run.
- `STUCK_VALUE`: stuck threshold sensitivity.
- `REPATH_PROB`: GPS sync probability.
- `RESERVE_TTL_MS`, `RESERVE_WAIT_MS`: reservation timing.
- `RECENT_TILE_WINDOW`: anti-oscillation memory window.

In `main_mapper.lua`:

- `HB_TIMEOUT`: lost-miner timeout.
- `LANE_SPACING`: lane separation.
- `WANT_LIST`: default policy.

## 14) Troubleshooting

Miners do not enlist:

- Verify both sides have active modems and same protocol (`ONET_V1`).
- Boot overseer before miners.
- Ensure rednet is open and not blocked by world chunk behavior.

Miners fail calibration:

- GPS missing or unreliable.
- Build/fix constellation in current dimension.

Miners loop around blocks:

- Confirm reservation and push traffic is flowing.
- Increase reservation TTL slightly if network lag is high.
- Increase anti-oscillation window if ping-pong appears.

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

## 15) Safety and Hardening Notes

- Slot 1 is scanner-reserved by policy. Do not repurpose.
- Avoid disabling GPS in active mining dimensions.
- Keep protected infrastructure blocks out of miner dig lanes.
- Use parking zones to prevent base area traffic jams.
- Use `recall` before editing scripts live.

## 16) Updating the Network

Safe update sequence:

1. `recall` fleet.
2. Wait until miners park/dump.
3. Update scripts on overseer and miners.
4. Reboot overseer, then miners.
5. Verify `status`, `coords`, and `wants`.
6. `start`.

## 17) Minimal Quickstart Checklist

- GPS working in target dimension.
- Overseer has modem and monitor.
- Each miner has modem, pickaxe, scanner in slot 1, and fuel.
- `setdump`, `setbase`, optional `setpark` configured.
- `start` executed.
- `status` shows fleet heartbeats.

## 18) License and Customization

This repository is intended as a practical operations codebase.

Customize constants and command policy to match your world scale, ore goals, and server lag profile.
