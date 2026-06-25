# turtle/heartbeat.lua — Status report thread

Source: [../../onet/turtle/heartbeat.lua](../../onet/turtle/heartbeat.lua)

## Purpose

`heartbeat` is the periodic status-report thread. Every `cfg.HEARTBEAT_INT`
seconds it sends a `HEARTBEAT` to the overseer, and every few beats — while idle —
it runs a background geo scan so the overseer's voxel map keeps filling even when
the turtle is parked.

## Place in the architecture

One of the three supervised threads launched by [boot_turtle.lua](boot_turtle.md)
via `parallel.waitForAll`. The overseer uses the heartbeat for roster liveness
(silence beyond `HB_TIMEOUT`/`LOSS_TIMEOUT` marks a turtle dead) and for live
fleet display. Depends on [config.lua](../config.md), [state.lua](state.md),
[fuel.lua](fuel.md), [inventory.lua](inventory.md), [scanner.lua](scanner.md),
[vec.lua](../lib/vec.md).

---

## `M.heartbeatThread_inner()`

**Signature:** `heartbeat.heartbeatThread_inner()` (infinite loop)

The thread body (wrapped in `supervised(...)` at boot so a crash restarts rather
than killing the turtle). Each iteration:
1. Increments the beat counter.
2. If enlisted (`state.server_id` set), `pcall(rednet.send, ...)` a `HEARTBEAT`
   payload to the overseer: `hwid`, `role`, `status` (= `current_state`), `pos`
   (copy), `dir` (= `my_dir`), `fuel` (`turtle.getFuelLevel()`), and `free`
   (`inventory.freeSlots()`).
3. If the turtle has a scanner, is **not** mid-swap (`not state.scanning_now`),
   the beat is a multiple of `cfg.SCAN_EVERY`, and the state is `PARKED` or
   `STANDBY`, runs a background scan: `scanner.scanAround()` then
   `reportOres` + `sendSnapshot`.
4. `sleep(cfg.HEARTBEAT_INT)`.

- **Parameters:** none.
- **Returns:** never returns under normal operation (infinite loop).
- **Side effects:** network sends (`HEARTBEAT`, plus `ORE_REPORT`/`GEO_DATA` via
  the scan helpers); a scanner hot-swap when the idle-scan branch fires; reads
  fuel and free-slot counts.
- **Contract (§1.1 / hot-swap):** guards the idle scan on `not
  state.scanning_now` so it never races an in-progress scanner hot-swap.
