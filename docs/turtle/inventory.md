# turtle/inventory.lua — Cargo management & slot protection

Source: [../../onet/turtle/inventory.lua](../../onet/turtle/inventory.lua)

## Purpose

`inventory` handles inventory queries, the **slot-number tool protection**, and
cargo dumping. It is SURVIVAL tier, and §1.1 is NON-NEGOTIABLE here:

- Slot 1 = geo scanner, slot 2 = pickaxe — both protected **unconditionally**.
- The **slot-number check happens BEFORE any `turtle.getItemDetail` call**,
  because an NBT/Forge-tagged tool can make `getItemDetail` return `nil`, and a
  naive "is this a tool?" check would then dump the scanner. The slot check is
  what keeps that fixed bug fixed.
- Every dump/count loop runs slots **3..16 only** (the 14 cargo slots).

## Place in the architecture

Cargo accounting (`inventoryFull`, `freeSlots`) feeds role decisions and the
heartbeat's `free` field; `dropCargo` is used by dump tasks; `suckInto` by
fetch/forage flows. Depends on [config.lua](../config.md) (slot constants),
[state.lua](state.md), [hardware.lua](hardware.md) (`isScannerName`),
[vec.lua](../lib/vec.md), [log.lua](../lib/log.md).

---

## `M.isTool(detail, slot)`

**Signature:** `inventory.isTool(detail, slot) -> boolean`

The protection gate: returns `true` for any slot that must never be dropped. The
order of checks is the whole point:
1. **Slot-number guard first** — `slot == cfg.SLOT_SCANNER` (1) or
   `cfg.SLOT_PICKAXE` (2) → protected, *before touching `detail`*.
2. **Defensive** — if `HW.scanner_slot` points elsewhere (scanner bumped
   mid-swap) and that slot has items, protect it.
3. **Only now** consult `detail`: if `detail` is `nil` (possible for tagged
   tools), fail safe by protecting any slot that holds items; otherwise match the
   name against `isScannerName` or `"pickaxe"`.

- **Parameters:** `detail` (table|nil) — `turtle.getItemDetail` result; `slot`
  (number) — the slot being considered.
- **Returns:** `true` if the slot is protected.
- **Side effects:** reads `state.HW`, `turtle.getItemCount`.
- **Contract (§1.1):** the slot-number checks precede any `detail` use — the
  central anti-scanner-dump guarantee.

## `M.inventoryFull()`

**Signature:** `inventory.inventoryFull() -> boolean`

True when every cargo slot 3..16 has a non-zero item count.

- **Parameters:** none.
- **Returns:** boolean.
- **Side effects:** reads `turtle.getItemCount`.

## `M.freeSlots()`

**Signature:** `inventory.freeSlots() -> number`

Counts empty cargo slots in 3..16.

- **Parameters:** none.
- **Returns:** number of free cargo slots (0–14).
- **Side effects:** reads `turtle.getItemCount`. Reported in the heartbeat.

## `M.dropCargo(dir)`

**Signature:** `inventory.dropCargo(dir) -> boolean`

Drops all **cargo** (slots 3..16) in the given direction, skipping any slot
`isTool` protects. After dropping, re-scans 3..16: if any non-tool item remains,
returns `false` (the chest was full).

- **Parameters:** `dir` (string) — `"down"` (default), `"forward"`, or `"up"`;
  selects `turtle.dropDown/drop/dropUp`.
- **Returns:** `true` if cargo fully cleared, `false` if leftovers remain.
- **Side effects:** `turtle.select`, the drop call, and a final
  `turtle.select(cfg.CARGO_FIRST)`; logs a `DUMP` line per protected slot kept.
- **Contract (§1.1):** protected slots are kept via `isTool`; never drops slots
  1/2.

## `M.suckInto(dir, max)`

**Signature:** `inventory.suckInto(dir, max?) -> number`

Sucks items into **empty** cargo slots from the given direction, up to `max`
slots, stopping at the first failed suck. Returns the count of slots filled.

- **Parameters:** `dir` (string) — `"down"` (default), `"forward"`, `"up"`;
  selects `turtle.suckDown/suck/suckUp`. `max` (number, optional) — cap on slots
  filled.
- **Returns:** number of slots filled.
- **Side effects:** `turtle.select` + suck calls; restores
  `turtle.select(cfg.CARGO_FIRST)` at the end.
