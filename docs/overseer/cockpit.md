# overseer/cockpit.lua — Monitor cockpit

Source: [../../onet/overseer/cockpit.lua](../../onet/overseer/cockpit.lua)

## Purpose

`cockpit` is the monitor display. LUXURY tier (§11.2): if the monitor breaks,
mining continues. It draws three panels — fleet roster, a map slice, and zones +
an ore-feed ticker — plus a header with population status. Every draw is defensive
and the whole thing runs headless (no-op) when no monitor is attached.

### Key constant

- `cfg.DISP_REFRESH` (0.5 s) — redraw cadence.

## Place in the architecture

`displayThread` is launched supervised by [overseer.run](overseer.md). It reads
[fleet](fleet.md) (roster + view centre), [zones.fillSnapshot](zones.md),
[voxelmap.getVoxel/isAir/isOre](voxelmap.md), and `state.ORE_FEED`. The render is
itself `pcall`-wrapped so a monitor fault never crashes the thread. Output target
is `state.mon`.

---

## `pad(s, w)` (module local)

**Signature:** `pad(s, w) -> string`

Fixed-width field helper: stringifies `s`, truncates to `w`, or right-pads with
spaces to exactly `w`.

- **Parameters:** `s` (any); `w` (number) — column width.
- **Returns:** a string exactly `w` wide.
- **Side effects:** none.

## `statusColor(st)` (module local)

**Signature:** `statusColor(st) -> color`

Maps an (upper-cased) turtle status to a CC `colors` value: MINING→lime,
STANDBY→yellow, PARKED→gray, RTB_DUMP→orange, RTB_FUEL→red, else lightGray.

- **Parameters:** `st` (string|nil).
- **Returns:** a `colors.*` constant.
- **Side effects:** none.

## `M.render()`

**Signature:** `cockpit.render()`

Draws one full frame. No-op if `state.mon` is nil. Clears the monitor, then:

- **Header (rows 1–2):** computer id, clock, uptime; then live/target fleet,
  total voxels, and craft-authorization state.
- **Fleet panel (from row 4):** for each turtle, `hwid`, colour-coded status, and
  `(x,z)` — bounded so it never overruns the panel.
- **Zones panel (bottom block):** each `cfg.ZONES` entry with `set/----` and its
  fill total from [zones.fillSnapshot](zones.md).
- **Ore-feed ticker (last line):** the newest `state.ORE_FEED` entry, or
  `(no ore yet)`.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** draws to `state.mon` (background/clear/cursor/colour/write);
  reads fleet, zones, voxel and ore-feed state. No mutation of shared state.

## `M.displayThread()`

**Signature:** `cockpit.displayThread()` (loops forever when a monitor exists)

Returns immediately if no monitor is attached. Otherwise loops: refresh the view
centre ([fleet.updateViewCenter](fleet.md)), `pcall(M.render)`, sleep
`cfg.DISP_REFRESH`.

- **Parameters:** none.
- **Returns:** nothing (loops, or returns early when headless).
- **Side effects:** calls `updateViewCenter` (mutates view-centre state) and
  `render` (draws). The `pcall` guard is the §11.2 contract that a monitor fault
  can't take the base down.
