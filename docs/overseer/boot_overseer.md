# boot_overseer.lua — Overseer boot entry

Source: [../../onet/boot_overseer.lua](../../onet/boot_overseer.lua)

## Purpose

`boot_overseer` is the overseer boot script (run from the top-level
[startup.lua](../../startup.lua) when the computer is **not** a turtle). It sets
the module search path, finds peripherals, derives the grid origin from GPS, loads
persisted config and map, prints a banner, and hands off to the
[overseer main loop](overseer.md). It declares **no functions** — it is a linear
boot sequence executed at load time.

## Place in the architecture

This is the overseer's entry point. After it completes its setup it calls
`overseer.run()`, which never returns. It is the producer of the runtime
peripherals and origin that the rest of the overseer ([state.md](state.md),
[gridmap.md](gridmap.md), [persist.md](persist.md)) depends on.

## Boot sequence

1. **Module path.** Prepends `/onet/?.lua`, `/onet/lib/?.lua`,
   `/onet/overseer/?.lua` to `package.path` so bare `require("…")` resolves the
   config, libraries and overseer modules.
2. **Requires.** Loads `config`, `state`, `log`, `gridmap`, `persist`, `overseer`.
3. **Peripherals.**
   - `modem = peripheral.find("modem")` — **asserted**; boot fails hard if no
     modem is attached. Opens rednet on its side.
   - `state.mon = peripheral.find("monitor")` — optional cockpit display.
   - `state.vault = peripheral.find("chest")` (or `minecraft:chest`) — optional
     operator supply chest.
4. **Grid origin from GPS.** `gps.locate(2)`; on a fix, sets the grid origin
   ([gridmap.setOrigin](gridmap.md)) and the view centre to the floored position.
   On **no** fix it logs an `ALERT` and defaults the origin to `(0,64,0)` (and
   advises building a GPS constellation).
5. **Persisted state.** [persist.loadConfig](persist.md) then
   [persist.loadMap](persist.md) restore operator config and the voxel DB.
6. **Banner.** Clears the local terminal and prints protocol, monitor/vault
   presence, loaded voxel count, and target fleet size, plus a `help` hint.
7. **Hand-off.** Calls [overseer.run](overseer.md) — blocks for the life of the
   process.

- **Functions documented:** 0 (top-level boot script).
- **Side effects:** mutates `package.path`; `rednet.open`; sets `state.mon`,
  `state.vault`, grid origin and view centre; file reads via `persist`; terminal
  draw; finally transfers control to the main loop.
- **Contract/invariant:**
  - A modem is mandatory (`assert`); a monitor and vault are optional (LUXURY
    tier).
  - `state.overseer_pos` set here is both the grid origin and the
    base-protection geofence centre (§4/§5); a missing GPS fix degrades to a safe
    default rather than aborting boot.
