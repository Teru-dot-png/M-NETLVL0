# turtle/hardware.lua — Hardware & slot detection

Source: [../../onet/turtle/hardware.lua](../../onet/turtle/hardware.lua)

## Purpose

`hardware` detects the turtle's physical configuration at boot: which side has
the modem, which side is the tool side, which inventory slot holds the geo
scanner, and whether this is a Crafty Turtle (GenesisRole capable). It writes its
findings once into `state.HW`. Pickaxe equip/fetch logic is deliberately split
into [pickaxe.lua](pickaxe.md) (§3 file split); this module is the CORE pairing
partner of [scanner.lua](scanner.md).

## Place in the architecture

Runs first in the [boot sequence](boot_turtle.md) (`detectHardware`) before the
modem opens. The slot it records (`state.HW.scanner_slot`) underpins the scanner
hot-swap and the slot-number tool protection in [inventory.lua](inventory.md).
Depends on [config.lua](../config.md) (item ids, reserved slots),
[state.lua](state.md), and [log.lua](../lib/log.md).

---

## `M.isScannerName(name)`

**Signature:** `hardware.isScannerName(name) -> boolean`

Recognises the geo scanner by item id. True if `name` equals `cfg.SCANNER_ITEM`
or contains the substring `geo_scanner`. Coerces non-strings via `tostring`.

- **Parameters:** `name` (any) — candidate item id.
- **Returns:** boolean.
- **Side effects:** none (pure). Reused by [inventory.isTool](inventory.md),
  [pickaxe.lua](pickaxe.md), and [scanner.lua](scanner.md).

## `M.detectHardware()`

**Signature:** `hardware.detectHardware()` (no return)

Full boot-time hardware scan. Steps:
1. **Modem side** — checks `left`/`right` for a peripheral whose type matches
   `modem` or is `ender_modem`; falls back to whichever side simply has a
   peripheral present.
2. **Tool side** — set to the side opposite the modem (`HW.pick_side`).
3. **Pickaxe pre-check** — if a pickaxe is already equipped on the tool side
   (via `turtle.getEquippedLeft/Right`), or nothing is present on that side,
   marks `HW.has_pickaxe`.
4. **Crafty** — `HW.is_crafty = type(turtle.craft) == "function"`.
5. **Slot scan** — loops slots **1..16** calling `turtle.getItemDetail`; a
   scanner found in slot 1 logs OK, a scanner in any other slot logs a loud
   `ALERT` (§1.1 says it belongs in slot 1) but is **not** moved here; a pickaxe
   item sets `HW.has_pickaxe`.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:**
  - Mutates `state.HW` (`modem_side`, `pick_side`, `has_pickaxe`,
    `is_crafty`, `scanner_slot`, `has_scanner`).
  - Hardware reads: `peripheral.isPresent/getType`, `turtle.getEquipped*`,
    `turtle.getItemDetail`.
  - Logs `BOOT`/`ALERT` lines.
- **Contract (§1.1):** records but does not relocate a misplaced scanner; the
  reserved-slot expectation (scanner = slot 1) is surfaced as an alert.

## `M.refreshScannerSlot()`

**Signature:** `hardware.refreshScannerSlot() -> number|nil`

Re-locates the scanner slot after a hot-swap can have moved the scanner item.
Scans slots 1..16 for an item whose name `isScannerName` matches; updates
`HW.scanner_slot`/`HW.has_scanner` and returns the slot, or `nil` if not found.

- **Parameters:** none.
- **Returns:** the slot number, or `nil`.
- **Side effects:** mutates `state.HW.scanner_slot`/`has_scanner`; reads
  `turtle.getItemDetail`.
- **Called by:** [scanner.scanAround](scanner.md) before and after the swap, and
  [pickaxe.bootEquipPickaxe](pickaxe.md) when it relocates a scanner.
