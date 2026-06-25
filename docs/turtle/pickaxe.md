# turtle/pickaxe.lua — Pickaxe equip & restore

Source: [../../onet/turtle/pickaxe.lua](../../onet/turtle/pickaxe.lua)

## Purpose

`pickaxe` is the tool-equip logic, split out of [hardware.lua](hardware.md) so
all pickaxe handling lives in one file (§3). The diamond pickaxe occupies **slot
2** when carried (§1.1). This module equips it at boot, restores it after a
scanner hot-swap, and can travel to base to fetch a replacement.

## Place in the architecture

[scanner.lua](scanner.md) calls `pickaxeEquipped`/`ensurePickaxeOnSide` after
every hot-swap to guarantee the tool is back. The [boot sequence](boot_turtle.md)
calls `bootEquipPickaxe`. `fetchPickaxeFromBase` backs the FETCH_PICK state.
Depends on [config.lua](../config.md), [state.lua](state.md),
[hardware.lua](hardware.md) (`isScannerName`), [log.lua](../lib/log.md); it
**lazily** requires [nav.lua](nav.md)/[movers.lua](movers.md)/[vec.lua](../lib/vec.md)
inside `fetchPickaxeFromBase` to avoid the require cycle
`nav → scanner → pickaxe → nav`.

---

## `M.pickaxeEquipped()`

**Signature:** `pickaxe.pickaxeEquipped() -> boolean`

Reports whether a pickaxe is currently equipped on the tool side. Returns `false`
if there is no tool side or a peripheral (e.g. the scanner) is present there;
otherwise inspects `turtle.getEquippedLeft/Right` for a name containing
`"pickaxe"`. If the equipped-getter is unavailable, assumes the pickaxe is on
(no peripheral on the tool side).

- **Parameters:** none.
- **Returns:** boolean.
- **Side effects:** reads `peripheral.isPresent`, `turtle.getEquipped*`,
  `state.HW`.

## `M.equipOnPickaxeSide()`

**Signature:** `pickaxe.equipOnPickaxeSide() -> boolean`

Equips the currently selected slot onto the tool side, dispatching to
`turtle.equipLeft()` or `turtle.equipRight()` based on `state.HW.pick_side`.

- **Parameters:** none.
- **Returns:** the underlying equip call's boolean.
- **Side effects:** hardware equip on the tool side; swaps the selected slot's
  item with whatever is equipped.

## `M.isEquippable(detail)`

**Signature:** `pickaxe.isEquippable(detail) -> boolean`

True if `detail` is non-nil and its name contains `"pickaxe"`.

- **Parameters:** `detail` (table|nil) — a `getItemDetail` result.
- **Returns:** boolean.
- **Side effects:** none (pure).

## `M.ensurePickaxeOnSide()`

**Signature:** `pickaxe.ensurePickaxeOnSide() -> boolean`

Ensures a pickaxe is equipped, pulling one from inventory if needed. Returns
immediately if already equipped. Otherwise tries the canonical pickaxe slot
(`cfg.SLOT_PICKAXE` = 2) first, then cargo slots 3..16: selects a slot holding an
equippable pickaxe, equips it, and verifies. On success restores
`turtle.select(cfg.SLOT_PICKAXE)`.

- **Parameters:** none.
- **Returns:** `true` if a pickaxe is equipped afterward, else `false`.
- **Side effects:** `turtle.select`, equip calls; selects slot 2 on exit.
- **Called by:** [scanner.scanAround](scanner.md) to recover the pickaxe after
  the scanner swap — the restore half of the hot-swap contract.

## `M.bootEquipPickaxe()`

**Signature:** `pickaxe.bootEquipPickaxe() -> boolean`

Boot-time pickaxe equip. If already equipped, logs OK and returns. If a
peripheral (likely the scanner) sits on the tool side, it first moves it into a
free cargo slot — and if the moved item is the scanner, updates
`HW.scanner_slot`. Then scans slots 2..16 for a usable pickaxe, equipping the
first equippable one (skipping damaged/enchanted ones with a log line), updating
`HW.scanner_slot` if a scanner was swapped out, and verifying. Falls back to a
log note that it will fetch from base after enlisting.

- **Parameters:** none.
- **Returns:** `true` if a pickaxe ends up equipped, else `false`.
- **Side effects:** `turtle.select`/equip; mutates `state.HW.scanner_slot`;
  `BOOT` log lines.

## `M.fetchPickaxeFromBase(resume_pos)`

**Signature:** `pickaxe.fetchPickaxeFromBase(resume_pos?) -> boolean`

Travels to the base chest and pulls a pickaxe (the FETCH_PICK behaviour).
**Lazily** requires `nav`, `movers`, `vec` inside the function to avoid a require
cycle (safe because every module is already loaded by call time). Returns
`false` if `state.base` is unset or unreachable. At base (one block above the
chest, looking down) it wraps the `"bottom"` peripheral and, if it lists a
pickaxe, sucks one into a free cargo slot and tries to equip it; if the chest has
no `list`, it blindly sucks and tries. Retries up to 12 times with 10 s sleeps
(~2 min) waiting for a pickaxe to appear. If `resume_pos` is given, navigates back
and re-faces `state.my_dir`.

- **Parameters:** `resume_pos` (`{x,y,z}`|nil) — where to return after fetching.
- **Returns:** `true` if a pickaxe was equipped, else `false`.
- **Side effects:** navigation (`nav.moveTo`), `peripheral.wrap`,
  `turtle.suckDown`/`dropDown`/`select`, equip calls, `sleep`, `BOOT` logs.
