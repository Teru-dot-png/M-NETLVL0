# turtle/scanner.lua — Geo-scanner hot-swap & ore reporting

Source: [../../onet/turtle/scanner.lua](../../onet/turtle/scanner.lua)

## Purpose

`scanner` performs the geo-scanner **hot-swap** and ore reporting. CORE module
(pairs with [hardware.lua](hardware.md)). The trick: a mining turtle has one tool
side and one reserved scanner slot, so to sense its surroundings it equips the
scanner onto the tool side, scans, then re-equips the pickaxe. The
`state.scanning_now` lock is **essential** — without it the inventory/pickaxe
protection could race the swap and dump the scanner (§1.1, §11). The lock must
not be removed.

## Place in the architecture

Called by [nav.lua](nav.md) (a snapshot scan when stuck), the
[heartbeat](heartbeat.md) (idle background scans), and scan tasks. Reports flow to
the overseer's voxel map and ore clustering. Depends on [config.lua](../config.md),
[state.lua](state.md), [cache.lua](cache.md), [hardware.lua](hardware.md),
[pickaxe.lua](pickaxe.md), [vec.lua](../lib/vec.md), [blocks.lua](../lib/blocks.md),
[log.lua](../lib/log.md).

---

## `M.scanAround()`

**Signature:** `scanner.scanAround() -> table`

Executes the full hot-swap scan and returns the raw scan result array (empty
table if scanning is impossible). Sequence:
1. Bail (return `{}`) if no scanner, no scanner slot, or no tool side.
2. If the scanner is not already on the tool side: confirm the scanner slot still
   holds the scanner (refreshing the slot if empty, bailing if truly missing),
   **set `state.scanning_now = true` (LOCK)**, select the scanner slot, and equip
   it onto the tool side.
3. Wrap the tool side as a peripheral and `pcall(sc.scan, cfg.SCAN_RADIUS)`; on
   success feed the result into the cache and log the block/cache counts.
4. Swap the scanner back out (re-equip — the pickaxe returns to the tool side),
   select the scanner slot, **set `state.scanning_now = false` (UNLOCK)**.
5. `hardware.refreshScannerSlot()`, then verify the pickaxe is restored via
   [pickaxe.pickaxeEquipped](pickaxe.md); if not, try `ensurePickaxeOnSide` and
   log recovery or an `ALERT`.

- **Parameters:** none.
- **Returns:** the scan array (each entry `{x,y,z,name}` relative to the turtle),
  or `{}`.
- **Side effects:** `turtle.select`/`equipLeft`/`equipRight`, `peripheral.wrap`,
  the scanner's `scan`; mutates `state.scanning_now`, `HW.scanner_slot`; feeds the
  cache; `SCAN`/`ALERT` logs.
- **Contract (§1.1 / §11 — scanner hot-swap lock):** `scanning_now` brackets the
  whole swap so the inventory/pickaxe protection cannot run during it. The
  pickaxe is explicitly verified and recovered afterward.

## `M.reportOres(scan)`

**Signature:** `scanner.reportOres(scan)` (no return)

Reports newly-seen ores to the overseer, deduplicated by world key for the
current run. For each scan entry whose name contains `_ore`, computes the absolute
position, and if its `vec.key` is not already in `state.reported`, marks it
reported, normalises the ore name, logs it, and `pcall(rednet.send, ...)` an
`ORE_REPORT` (`hwid`, short `ore`, `pos`).

- **Parameters:** `scan` (array of `{x,y,z,name}` relative entries, or `nil`).
- **Returns:** nothing.
- **Side effects:** mutates `state.reported`; network `ORE_REPORT` sends; `SCAN`
  logs.

## `M.sendSnapshot(scan)`

**Signature:** `scanner.sendSnapshot(scan)` (no return)

Sends a full solid-block snapshot to the overseer voxel map. No-ops if `scan` or
`state.server_id` is missing. Filters out empty names, anything containing `air`,
and `isScanNoise` (turtle) entries, then `pcall(rednet.send, ...)` a `GEO_DATA`
with `pos`, the filtered `scan_data`, and `scan_radius`.

- **Parameters:** `scan` (array of relative entries, or `nil`).
- **Returns:** nothing.
- **Side effects:** network `GEO_DATA` send.
- **Note:** sending only solids lets the overseer's volatile-solid air inference
  promote absent cells to air (§7).

## `M.scanForWanted(scan)`

**Signature:** `scanner.scanForWanted(scan) -> string|nil`

Returns the normalised name of the first scanned ore that is present on the
operator `state.WANT_LIST`, or `nil` if none match. Tolerates a `nil` scan.

- **Parameters:** `scan` (array of relative entries, or `nil`).
- **Returns:** a matched normalised ore name, or `nil`.
- **Side effects:** none (reads `state.WANT_LIST`).
