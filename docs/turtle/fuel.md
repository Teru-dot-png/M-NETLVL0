# turtle/fuel.lua — Fuel, wake-up & foraging

Source: [../../onet/turtle/fuel.lua](../../onet/turtle/fuel.lua)

## Purpose

`fuel` handles fuel level checks, burning fuel carried aboard, the boot wake-up
sequence, and emergency coal foraging. SURVIVAL tier: it burns **only cargo slots
3..16** — slots 1 and 2 are the scanner and pickaxe and must never be fed to the
furnace (§1.1).

## Place in the architecture

`wakeUp` runs early in the [boot sequence](boot_turtle.md) (before calibration);
`forageForCoal` runs at the end of boot to top up. `refuelSelf`/`burnAboard`
support the in-mission RTB_FUEL flow. Thresholds come from
[config.lua](../config.md) (`FUEL_MIN`, `FUEL_TARGET`, `FORAGE_MAX`). Depends on
[state.lua](state.md), [movers.lua](movers.md) (for `forward` while foraging),
[log.lua](../lib/log.md).

---

## `M.fuelLevel()`

**Signature:** `fuel.fuelLevel() -> number`

Normalised fuel reading: returns `math.huge` when `turtle.getFuelLevel()` is the
string `"unlimited"`, otherwise the numeric level (or 0).

- **Parameters:** none.
- **Returns:** a number (possibly `math.huge`).
- **Side effects:** reads `turtle.getFuelLevel`.

## `M.burnAboard(target)`

**Signature:** `fuel.burnAboard(target)` (no return)

Walks cargo slots 3..16 and refuels from any burnable item until `fuelLevel()`
reaches `target`. For each slot it probes `turtle.refuel(0)` (does this item
burn?) and, if so, calls `turtle.refuel()` to consume it. Restores
`turtle.select(cfg.CARGO_FIRST)` at the end.

- **Parameters:** `target` (number) — fuel level to stop at.
- **Returns:** nothing.
- **Side effects:** `turtle.select`, `turtle.refuel`; consumes cargo items.
- **Contract (§1.1):** iterates 3..16 only, never burns slots 1/2.

## `M.refuelSelf()`

**Signature:** `fuel.refuelSelf()` (no return)

If current fuel is below `cfg.FUEL_MIN`, burns aboard up to `cfg.FUEL_TARGET`.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** may call `burnAboard` (consumes cargo, hardware refuel).

## `M.wakeUp()`

**Signature:** `fuel.wakeUp() -> boolean`

Boot fuel sequence. Burns aboard up to `FUEL_TARGET`; if still completely empty,
prompts the operator to drop coal into slots 3–16 and retries `burnAboard` every
2 s for up to 30 attempts (~60 s). Logs whether the target was met, below target,
or fuel remained zero.

- **Parameters:** none.
- **Returns:** `true` if any fuel was obtained, `false` if still empty after the
  wait (the turtle continues in passive mode).
- **Side effects:** `burnAboard`, `sleep`, `FUEL` log lines; reads
  `turtle.getFuelLevel`.

## `M.forageForCoal()`

**Signature:** `fuel.forageForCoal()` (no return)

Emergency forage: while below `FUEL_TARGET` and fewer than `cfg.FORAGE_MAX`
steps taken, mines forward (via [movers.forward](movers.md)) and burns any
burnables picked up. Stops when the target is met, the cap is hit, or a forward
move fails.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** physical movement/digging via `movers.forward` (which also
  emits a `GEO_DATA` air report), `burnAboard`, `FUEL` log lines.
