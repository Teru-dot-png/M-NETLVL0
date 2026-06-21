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
- `tablet_console.lua`: Pocket/tablet command and scouting UI.
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

Copy `tablet_console.lua` to any pocket computer or tablet you want to use as a mobile controller.

Fast install via wget:

Overseer computer:

```sh
wget https://raw.githubusercontent.com/Teru-dot-png/M-NETLVL0/refs/heads/main/main_mapper.lua startup.lua
```

Miner turtle:

```sh
wget https://raw.githubusercontent.com/Teru-dot-png/M-NETLVL0/refs/heads/main/scout_node.lua startup.lua
```

Tablet / pocket computer:

```sh
wget https://raw.githubusercontent.com/Teru-dot-png/M-NETLVL0/refs/heads/main/tablet_console.lua tablet_console.lua
```

To auto-run the tablet UI on boot, create a `startup` file on the pocket computer:

```sh
edit startup
```

```lua
shell.run("tablet_console.lua")
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

## 6.4 Tablet Hardware Requirements

The tablet console runs on a **CC:Tweaked Pocket Computer** (advanced recommended for color).

> **Peripheral slot limit:** Pocket computers only accept **one** peripheral upgrade. The wireless modem is mandatory for network communication, so it occupies that slot. A geo scanner upgrade cannot be installed at the same time.

Required:
- **Wireless modem upgrade** installed in the pocket computer (takes the only upgrade slot).
- GPS lock available at the player's position (needed for `come-to-me`).

Geo scanner (`x` key):
- Not available on the tablet due to the single-upgrade slot being taken by the modem.
- Pressing `x` will report "No geo scanner peripheral found." and do nothing.
- To scan an area manually, position a miner turtle there and trigger a scan from it instead.

The tablet does **not** need to be near the overseer. It communicates over the wireless modem network as the miners do.

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

## 7b) Tablet Console Reference

The tablet console (`tablet_console.lua`) provides a live mobile cockpit and per-robot command interface.

### How to launch

Run on the pocket computer:

```sh
tablet_console
```

The UI auto-syncs with the overseer, refreshes the fleet list in real time, and adapts to the tablet's terminal dimensions.

### Layout

```
O-NET Tablet TB-xxxx  linked:<id>
Fleet:3  Scanner:yes  Sync:1s
Selected 2: MN-000F  MINING
1..9/0 select | c come | g goto | t tunnel | m getme
a start | o stop | r recall | x scan | s sync | q quit
#  HWID       ST        AV   FUEL  POS
   1 MN-0014   PARKED    Y  500   (147,0,-314)
>  2 MN-000F   MINING    Y  412   (139,1,-316)
   3 MN-...    RTB_DUMP  N  80    (141,1,-314)
```

- `>` marks the currently selected bot.
- `AV` column shows `Y` (available) or `N` (busy/unavailable) for commands.
- The list scrolls automatically to keep the selection visible.

### Key Bindings

| Key | Action |
|-----|--------|
| `1`..`9` | Select bot by position in fleet list |
| `0` | Select bot #10 |
| `c` | Send selected bot **COME TO ME** (uses your GPS position) |
| `g` | Send selected bot to a **GOTO** coordinate (prompts for `x y z`) |
| `t` | Send selected bot a **TUNNEL FROM** command (prompts for `x y z dir`) |
| `m` | Issue a **GETME** order (prompts for `ore count`) |
| `a` | **Start** all miners |
| `o` | **Stop** all miners (halt in place) |
| `r` | **Recall** all miners (dump and park) |
| `x` | ~~Geo scan upload~~ (not available — modem occupies the only upgrade slot) |
| `s` | Force an immediate fleet **sync** |
| `q` | Quit tablet console |

### Command details

**COME TO ME** (`c`)

Requires GPS lock. Sends the selected bot a GOTO job pointing at your current player position. Useful for retrieving a specific robot or having it meet you in the field.

**GOTO** (`g`)

Prompts for `x y z`. Sends the selected bot directly to those absolute world coordinates as a GOTO job.

**TUNNEL FROM** (`t`)

Prompts for `x y z dir`. Sends the selected bot to the given position, then starts it tunneling in the given cardinal direction.

- Direction accepts: `n`, `north`, `0` → North; `e`, `east`, `1` → East; `s`, `south`, `2` → South; `w`, `west`, `3` → West.
- Example input: `139 1 -320 n`

The bot navigates to the start position, faces the direction, and begins mining its own tunnel from that point.

**GETME** (`m`)

Prompts for `ore count`. Creates or replaces a retrieval order on the overseer.

- Example input: `diamond 64`
- Same behavior as typing `getme diamond 64` on the overseer terminal.

**Geo scan upload** (`x`)

Not usable on a standard wireless tablet. Pocket computers accept only one peripheral upgrade, and the wireless modem must occupy it. Pressing `x` will display an error and do nothing. To scan an area manually, position a miner turtle there instead.

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

1. `recall` fleet (from overseer terminal or tablet `r`).
2. Wait until miners park/dump.
3. Update scripts on overseer, miners, and tablet.
4. Reboot overseer, then miners.
5. Relaunch tablet console if open.
6. Verify `status`, `coords`, and `wants`.
7. `start` (or tablet `a`).

## 17) Minimal Quickstart Checklist

- GPS working in target dimension.
- Overseer has modem and monitor.
- Each miner has modem, pickaxe, scanner in slot 1, and fuel.
- `setdump`, `setbase`, optional `setpark` configured.
- `start` executed.
- `status` shows fleet heartbeats.
- (Optional) Tablet: pocket computer with wireless modem upgrade running `tablet_console.lua`.

## 18) License and Customization

This repository is intended as a practical operations codebase.

Customize constants and command policy to match your world scale, ore goals, and server lag profile.
