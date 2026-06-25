# overseer/fleet.lua — Roster, heartbeats & loss detection

Source: [../../onet/overseer/fleet.lua](../../onet/overseer/fleet.lua)

## Purpose

`fleet` is the roster model: enlistment, per-turtle records, heartbeat tracking,
live counting, and loss detection (`cfg.LOSS_TIMEOUT` of silence ⇒ dead). It also
maintains the cockpit's view centre and answers vault supply queries.

### Key constant

- `cfg.LOSS_TIMEOUT` (60000 ms) — silence threshold for `liveCount`/`pruneLost`.
- `cfg.HB_TIMEOUT` (12000 ms) — the roster prune cadence constant referenced by
  the pruner design; in this build the prune itself keys on `LOSS_TIMEOUT`.

### The fleet record

`state.fleet[hwid]` = `{ net_id, role, status, pos, dir, fuel, free,
last_pulse, crafty }`.

## Place in the architecture

`enlist` is driven by `AUTH_REQ`, `updateFromHeartbeat` by `HEARTBEAT`, both via
[director](director.md). `liveCount` underpins [population](population.md);
`nearestIdle` drives [orders](orders.md) dispatch; `snapshot` feeds
[terminal](terminal.md) `status`; `updateViewCenter`/`checkSupplies` feed
[cockpit](cockpit.md). The matching turtle thread is
[heartbeat.md](../turtle/heartbeat.md).

---

## `M.enlist(hwid, net_id, msg)`

**Signature:** `fleet.enlist(hwid, net_id, msg) -> record`

Adds or refreshes a roster entry. On first sight it builds a full record from the
`AUTH_REQ` (`role` default MINER, `status` `STANDBY`, `pos`, `dir=0`, `fuel`,
`free` default `cfg.CARGO_COUNT`, `crafty`, `last_pulse=now`) and logs the
enlistment. On a re-enlist it only refreshes `net_id`, `last_pulse`, and `pos`.

- **Parameters:**
  - `hwid` (string) — turtle hardware id.
  - `net_id` (number) — rednet id to reach it.
  - `msg` (table) — the `AUTH_REQ` payload.
- **Returns:** the fleet record.
- **Side effects:** mutates `state.fleet[hwid]`; logs on first enlistment.
- **Contract:** `crafty` is recorded here and is what makes a turtle eligible to
  be the Genesis seed (see [director.decideRole](director.md)).

## `M.updateFromHeartbeat(hwid, net_id, msg)`

**Signature:** `fleet.updateFromHeartbeat(hwid, net_id, msg) -> record|nil`

Applies a `HEARTBEAT` to an existing record (returns `nil` if the turtle is not
enlisted). Always refreshes `net_id` and `last_pulse`; conditionally updates
`fuel`, `free`, `pos`, `status`, `dir`, `role` when present.

- **Parameters:** `hwid` (string); `net_id` (number); `msg` (table) — heartbeat
  fields.
- **Returns:** the record, or `nil` if unknown.
- **Side effects:** mutates the fleet record.
- **Contract:** `last_pulse` is the liveness clock everything else keys on.

## `M.count()`

**Signature:** `fleet.count() -> number`

Total enlisted turtles (live or not).

- **Parameters:** none.
- **Returns:** integer count.
- **Side effects:** none.

## `M.liveCount()`

**Signature:** `fleet.liveCount() -> number`

Number of turtles whose last pulse is within `cfg.LOSS_TIMEOUT`.

- **Parameters:** none.
- **Returns:** integer live count.
- **Side effects:** none.
- **Contract:** this is the population-control numerator — see
  [population.shouldCraft](population.md).

## `M.snapshot()`

**Signature:** `fleet.snapshot() -> table[]`

A sorted, display-safe copy of the roster: each entry is
`{hwid, role, status (upper), fuel, free, pos{x,y,z}}`, sorted by `hwid`.

- **Parameters:** none.
- **Returns:** list of normalized records.
- **Side effects:** none.
- **Used by:** [terminal](terminal.md) `status`.

## `M.nearestIdle(x, y, z, exclude)`

**Signature:** `fleet.nearestIdle(x, y, z, exclude) -> hwid|nil`

Finds the nearest turtle (by manhattan distance) whose status is `MINING`,
`STANDBY`, or `PARKED` — i.e. dispatchable — optionally excluding one `hwid`.

- **Parameters:** `x`, `y`, `z` (number) — target; `exclude` (string|nil).
- **Returns:** the chosen `hwid`, or `nil` if none idle.
- **Side effects:** none.
- **Used by:** [orders.handleOreReport](orders.md) and
  [orders.orderThread](orders.md) for vein/`getme` dispatch.

## `M.pruneLost()`

**Signature:** `fleet.pruneLost() -> hwid[]`

Removes every turtle silent past `cfg.LOSS_TIMEOUT`, logging each loss with the
silence duration, and returns the list of removed hwids.

- **Parameters:** none.
- **Returns:** list of lost hwids (possibly empty).
- **Side effects:** deletes `state.fleet[hwid]` entries; `log("ALERT", …)` per loss.
- **Contract (replace-on-loss):** the returned list is what
  [director.prunerThread](director.md) uses to free reservations/park claims and
  trigger [population.tick](population.md) so the lost turtle can be re-crafted —
  never adding beyond the cap.

## `M.updateViewCenter()`

**Signature:** `fleet.updateViewCenter()`

Recomputes the cockpit's view centre as the integer mean of all turtle positions
(`state.view_cx`, `state.view_cz`, `state.view_y`). No-op when the fleet is empty.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** mutates `state.view_cx/view_cz/view_y`.
- **Used by:** [cockpit.displayThread](cockpit.md) before each render.

## `M.checkSupplies()`

**Signature:** `fleet.checkSupplies() -> table`

Tallies the contents of the operator vault (`state.vault`) by short item name
(strips the mod prefix). Returns `{}` if no vault or the `list` call fails.

- **Parameters:** none.
- **Returns:** `{ shortName -> count }`.
- **Side effects:** none (read-only `pcall(vault.list)`).
