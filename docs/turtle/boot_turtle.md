# boot_turtle.lua — Turtle boot & thread supervision

Source: [../../onet/boot_turtle.lua](../../onet/boot_turtle.lua)

## Purpose

`boot_turtle` is the turtle entry point. It sets the module search path, runs the
ordered boot sequence (detect hardware → calibrate from GPS → enlist → equip the
pickaxe), then launches the brain, listener, and heartbeat threads. Every thread
is `pcall`-wrapped with auto-restart so a transient error never drops the turtle
to the shell (§10).

## Place in the architecture

This is the top-level script `startup.lua` dispatches to when a `turtle` global is
present (see [architecture.md](../architecture.md) §1). It wires together the CORE
modules: [hardware.lua](hardware.md), [fuel.lua](fuel.md),
[calibrate.lua](calibrate.md), [network.lua](network.md), [pickaxe.lua](pickaxe.md),
[heartbeat.lua](heartbeat.md), and [brain.lua](brain.md), all sharing
[state.lua](state.md) and [config.lua](../config.md).

---

## Module path setup (top level)

Prepends `/onet/?.lua`, `/onet/lib/?.lua`, `/onet/turtle/?.lua`,
`/onet/turtle/tasks/?.lua`, and `/onet/turtle/roles/?.lua` to `package.path`, so
every module across the tree resolves by basename (`require("config")`,
`require("nav")`, …).

- **Side effects:** mutates `package.path`.

## `boot()` (script local)

**Signature:** `boot()` (no return)

The ordered boot sequence: clears the terminal and logs the banner/HWID, then runs
`hardware.detectHardware()`, `network.openModem()`, `fuel.wakeUp()`,
`calibrate.calibrate()`, `network.handshake()`, `pickaxe.bootEquipPickaxe()`, and
`fuel.forageForCoal()`, finishing with a boot-complete log line.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** the union of all those calls — hardware reads, modem open, fuel
  burn, GPS calibration + cal-file write, network enlistment, pickaxe equip,
  foraging movement; `BOOT` logs.
- **Note:** `calibrate.calibrate()` and `network.openModem()` can raise fatal
  errors (no GPS / no modem), which abort boot intentionally.

## `supervised(name, inner)` (script local)

**Signature:** `supervised(name, inner) -> function`

Wraps a thread body so a crash logs an `ALERT` and restarts after 2 s instead of
killing the turtle. The returned function loops `pcall(inner)`; on error it logs
and sleeps before retrying, and on a clean return it exits (not expected for the
infinite loops).

- **Parameters:** `name` (string) — label for the log line; `inner` (function) —
  the thread body.
- **Returns:** a wrapped thread function for `parallel.waitForAll`.
- **Side effects:** (when run) `pcall`, `ALERT` logs, `sleep`.
- **Contract (§10, pcall-wrapped threads):** every long-lived thread is supervised
  so transient faults self-heal rather than dropping to the shell.

## Top-level execution

Calls `boot()` once, then `parallel.waitForAll(...)` over the three supervised
threads: `brain.brainThread_inner`, `network.listenerThread_inner`, and
`heartbeat.heartbeatThread_inner`.

- **Side effects:** runs the turtle's full lifecycle; never returns under normal
  operation.
