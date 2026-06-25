# turtle/calibrate.lua — GPS heading calibration

Source: [../../onet/turtle/calibrate.lua](../../onet/turtle/calibrate.lua)

## Purpose

`calibrate` derives the turtle's heading from GPS and caches the calibration to
disk. Split out of [nav.lua](nav.md) (§3). CORE: getting the heading wrong
corrupts every coordinate the turtle subsequently reports, so on restore the
heading is **verified live** by physically stepping and re-reading GPS rather than
trusting the saved value blindly.

## Place in the architecture

`calibrate.calibrate()` runs in the [boot sequence](boot_turtle.md) after fuel
wake-up and before the network handshake — the turtle must know its pose before
it enlists. `gpsSyncPos()` is called opportunistically by [nav.moveTo](nav.md)
(~15% of successful moves) to correct drift mid-route. Depends on
[config.lua](../config.md) (`CAL_FILE`), [state.lua](state.md),
[movers.lua](movers.md) (`isDiggable`), [vec.lua](../lib/vec.md),
[log.lua](../lib/log.md), and the CC `gps`/`fs`/`turtle` APIs.

---

## `M.saveCal()`

**Signature:** `calibrate.saveCal()` (no return)

Serialises `{ pos = state.pos, facing = state.facing }` to `cfg.CAL_FILE` via
`textutils.serialize`.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** file write (`fs.open`/`write`/`close`).

## `loadCal()` (module local)

**Signature:** `loadCal() -> table|nil`

Reads and unserialises `cfg.CAL_FILE`, returning the table only if it has a `pos`
and a numeric `facing`; otherwise `nil` (missing file, unreadable, or malformed).

- **Parameters:** none.
- **Returns:** `{pos, facing}` table or `nil`.
- **Side effects:** file read.

## `M.gpsSyncPos()`

**Signature:** `calibrate.gpsSyncPos()` (no return)

Resyncs position from GPS and, on large drift, re-derives heading. Calls
`gps.locate(2)`; if no fix, returns. Computes the manhattan drift from
`state.pos`; if zero, returns. Otherwise corrects `state.pos` to the GPS reading.
If drift `> 3`, it re-derives heading: tries `turtle.forward()` (turning right up
to four times to find an open face), re-reads GPS, infers facing from the XZ
delta, updates `state.pos`, and calls `saveCal`.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** `gps.locate`; possible physical move/turns; mutates
  `state.pos`/`state.facing`; may write the cal file; `NAV` logs.
- **Contract (live heading verification):** large drift is not trusted — heading
  is re-derived by an actual move + GPS delta, not recomputed from stale state.

## `M.calibrate()`

**Signature:** `calibrate.calibrate()` (no return; may `error` fatally)

Boot calibration. Gets an initial GPS fix `p1` (fatal error if none — a GPS
constellation is required). Then:

- **Restore path:** if a saved cal exists and its position is within 1 block of
  `p1`, adopts the saved `pos`/`facing`, then **verifies live**: steps forward
  once, re-reads GPS, and if the GPS-derived facing disagrees with the saved one,
  overrides with the GPS value. Saves and returns. (If the saved cal is more than
  1 block off, it recalibrates fresh.)
- **Fresh path:** finds an open direction to move (digging a diggable obstacle if
  needed, turning right between attempts; fatal error if all four are blocked),
  re-reads GPS as `p2`, and infers `state.facing` from the `p2 - p1` XZ delta
  (fatal error on a bad delta). Sets `state.pos = p2` and saves.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** `gps.locate`; physical moves/turns/digs; mutates
  `state.pos`/`state.facing`; writes the cal file; `NAV` logs; may raise a fatal
  `error` (no GPS, lost GPS, all directions blocked, bad delta).
- **Contract (GPS heading verified live on restore):** a cached heading is
  re-checked against an actual GPS-confirmed step before it is trusted.
