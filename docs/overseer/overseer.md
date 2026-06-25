# overseer/overseer.lua — Main loop & thread supervision

Source: [../../onet/overseer/overseer.lua](../../onet/overseer/overseer.lua)

## Purpose

`overseer` is the top of the overseer runtime. It launches every overseer thread
in parallel, each wrapped so a crash in one subsystem restarts that thread
without taking the base offline (§10). It owns no state of its own — it only
composes the supervised threads exported by the other modules.

## Place in the architecture

Called by [boot_overseer.lua](boot_overseer.md) via `overseer.run()` after
peripherals, GPS origin and persisted state are ready. The six threads it
supervises are:

| Thread | Source | Role |
|--------|--------|------|
| `listener` | [director.listenerThread](director.md) | rednet message dispatch |
| `pruner` | [director.prunerThread](director.md) | loss detection & replace-on-loss |
| `orders` | [orders.orderThread](orders.md) | `getme` order driver |
| `mapsave` | [persist.mapSaveThread](persist.md) | periodic voxel-map save |
| `display` | [cockpit.displayThread](cockpit.md) | monitor cockpit draw |
| `terminal` | [terminal.terminalThread](terminal.md) | operator command console |

---

## `supervised(name, inner)` (module local)

**Signature:** `supervised(name, inner) -> function`

Wraps a thread body so it auto-restarts on error. Returns a closure that loops:
`pcall(inner)`; on failure it logs an `ALERT` tagged with `name` and the error,
sleeps 2 s, then retries; on a clean return it stops (returns from the closure).

- **Parameters:**
  - `name` (string) — label used in the crash log line.
  - `inner` (function) — the thread body to run/supervise.
- **Returns:** a zero-argument function suitable for `parallel.waitForAll`.
- **Side effects:** `log("ALERT", …)` on crash; `sleep(2)` between restarts.
- **Contract/invariant:** a thread that returns normally is **not** restarted;
  only an error triggers a restart. This is what keeps the base alive when one
  subsystem faults (§10).

## `M.run()`

**Signature:** `overseer.run()` (does not return; blocks forever)

Starts all six supervised threads with `parallel.waitForAll`. Because each thread
loops internally and is wrapped by `supervised`, this call blocks for the life of
the overseer.

- **Parameters:** none.
- **Returns:** nothing (never returns under normal operation).
- **Side effects:** spawns the listener, pruner, orders, mapsave, display and
  terminal threads.
- **Contract/invariant:** the order of arguments to `waitForAll` is not
  significant; all run concurrently and cooperatively.
