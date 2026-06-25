# overseer/director.lua — Listener, dispatch & pruner

Source: [../../onet/overseer/director.lua](../../onet/overseer/director.lua)

## Purpose

`director` is the event-driven coordination layer ("Overmind Directive"). It owns
the rednet listener and routes every inbound message type to the correct
subsystem, reacting to events (ore found, fuel query, segment request, turtle
lost) rather than polling. It also assigns roles on enlistment and runs the
roster pruner that drives replace-on-loss.

## Place in the architecture

Two threads — `listenerThread` and `prunerThread` — are launched supervised by
[overseer.run](overseer.md). The director delegates to nearly every other
overseer module: [fleet](fleet.md), [gridmap](gridmap.md), [park](park.md),
[voxelmap](voxelmap.md), [orders](orders.md), [zones](zones.md),
[population](population.md) and [push_broker](push_broker.md). All sends use
`cfg.PROTOCOL` (`ONET_V2`). The turtle-side counterpart is
[turtle/network.md](../turtle/network.md), which issues the requests the handlers
below answer.

---

## `reserveKey(x, y, z)` (module local)

**Signature:** `reserveKey(x, y, z) -> string`

Builds the canonical reservation key `"x:y:z"` from floored integer coordinates.

- **Parameters:** `x`, `y`, `z` (number) — world coordinates.
- **Returns:** the floored `"x:y:z"` string key.
- **Side effects:** none.
- **Contract:** must match the same flooring the turtle uses so a turtle's
  `RESERVE_REQ` and the overseer's record collide on the same tile.

## `M.expireReservations()`

**Signature:** `director.expireReservations()`

Sweeps `state.reservations`, deleting any entry older than `cfg.RESERVE_TTL_MS`
(1400 ms). Called after every received message in the listener loop.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** mutates `state.reservations`.
- **Contract:** time-based expiry guarantees a crashed/teleported turtle cannot
  hold a tile reservation forever.

## `clearReservationsFor(hwid)` (module local)

**Signature:** `clearReservationsFor(hwid)`

Removes every reservation owned by `hwid` (used when a turtle is pruned).

- **Parameters:** `hwid` (string) — the turtle whose reservations to drop.
- **Returns:** nothing.
- **Side effects:** mutates `state.reservations`.

## `decideRole(hwid, f)` (module local)

**Signature:** `decideRole(hwid, f) -> string`

Role decision at enlistment: the **first** crafty turtle (and only while no
Genesis seed exists yet) becomes the Genesis seed; everyone else is a Miner.

- **Parameters:**
  - `hwid` (string) — the enlisting turtle.
  - `f` (table) — its fleet record; `f.crafty` is read.
- **Returns:** `cfg.ROLES.GENESIS` for the first crafty turtle, otherwise
  `cfg.ROLES.MINER`.
- **Side effects:** sets `state.genesis_hwid = hwid` when it elects the seed.
- **Contract:** at most one Genesis seed is elected; later reassignment is the
  operator's job (`role` command) or future auto-balancing.

## `handleAuthReq(sender, msg)` (module local)

**Signature:** `handleAuthReq(sender, msg)`

Handles `AUTH_REQ`. Enlists the turtle ([fleet.enlist](fleet.md)), assigns a lane
([gridmap.assignLane](gridmap.md)) if it has none (or zones aren't assigned yet),
decides its role, claims a park slot ([park.assignUnclaimedSlot](park.md)), then
replies with an `AUTH_ACK` carrying the turtle's whole assignment, and finally
runs [population.tick](population.md).

- **Parameters:**
  - `sender` (number) — rednet id to reply to.
  - `msg` (table) — the `AUTH_REQ`; `msg.hwid`, `msg.pos`, `msg.crafty` are read.
- **Returns:** nothing.
- **Side effects:** mutates the fleet record (`dir`, `lane_offset`, `role`);
  `rednet.send` of `AUTH_ACK`; calls `population.tick`.
- **`AUTH_ACK` payload:** `hwid`, `dir`, `lane_offset`, `base` (=`state.BASE_CHEST`),
  `dump` (=`state.DUMP_CHEST`), `park_pos`, `want_list`, `overseer_pos`,
  `zone_chests` (zone → chest map), `role`.
- **Contract (AUTH handshake):** the ACK is keyed on `hwid` so a turtle only
  accepts its own assignment; see [turtle/network.handshake](../turtle/network.md).

## `handleSegmentReq(sender, msg)` (module local)

**Signature:** `handleSegmentReq(sender, msg)`

Handles `SEGMENT_REQ`: pulls the next segment for the turtle's lane
([gridmap.nextSegment](gridmap.md)) and, if one exists, replies `SEGMENT_GRANT`.

- **Parameters:** `sender` (number); `msg` (table) — `msg.hwid` read.
- **Returns:** nothing.
- **Side effects:** `rednet.send` of `SEGMENT_GRANT { hwid, segment }` (only when a
  segment is available).

## `handleParkReq(sender, msg)` (module local)

**Signature:** `handleParkReq(sender, msg)`

Handles `PARK_REQ`: tries [park.assignUnclaimedSlot](park.md); if that yields
nothing it falls back to a sequential `park.getSlot(state.fleet_slot)` (and
increments the slot). Replies `PARK_ASSIGN` echoing the request `nonce`.

- **Parameters:** `sender` (number); `msg` (table) — `msg.hwid`, `msg.nonce` read.
- **Returns:** nothing.
- **Side effects:** may mutate `state.fleet_slot`; `rednet.send` of `PARK_ASSIGN`.

## `handleReserveReq(sender, msg)` (module local)

**Signature:** `handleReserveReq(sender, msg)`

Handles `RESERVE_REQ` — the per-tile reservation grant. Computes the key from
`msg.want`; grants if the tile is free, already owned by this `hwid`, or its prior
reservation has expired past `cfg.RESERVE_TTL_MS`. On grant it records
`{hwid, ts}`. Always replies `RESERVE_ACK` with `granted` and the echoed `nonce`.

- **Parameters:** `sender` (number); `msg` (table) — `msg.hwid`, `msg.want {x,y,z}`,
  `msg.nonce` read.
- **Returns:** nothing.
- **Side effects:** may set `state.reservations[k]`; `rednet.send` of `RESERVE_ACK`.
- **Contract (RESERVE protocol):** this is the grant half of the
  RESERVE_REQ/ACK/REL tile lock — short-TTL, owner-renewable, race-safe; pairs
  with the navigator's reservation calls on the turtle side.

## `handleReserveRel(sender, msg)` (module local)

**Signature:** `handleReserveRel(sender, msg)`

Handles `RESERVE_REL`: releases the tile only if it is still owned by the
releasing `hwid` (so a stale release can't free someone else's lock).

- **Parameters:** `sender` (number); `msg` (table) — `msg.hwid`, `msg.want` read.
- **Returns:** nothing.
- **Side effects:** may clear `state.reservations[k]`.
- **Contract:** ownership check prevents a late release from stealing another
  turtle's reservation.

## `handleCoalQuery(sender, msg)` (module local)

**Signature:** `handleCoalQuery(sender, msg)`

Handles `COAL_QUERY`: finds the nearest known `coal_ore` voxel
([voxelmap.findOreInMap](voxelmap.md)) relative to the turtle's position (or the
overseer origin) and replies `COAL_LOC` with that position (or `nil` if none
known).

- **Parameters:** `sender` (number); `msg` (table) — `msg.hwid`, `msg.pos` read.
- **Returns:** nothing.
- **Side effects:** `rednet.send` of `COAL_LOC { hwid, pos }`.

## `handlePickQuery(sender, msg)` (module local)

**Signature:** `handlePickQuery(sender, msg)`

Handles `PICK_QUERY`: answers `PICK_ANSWER { available = true }` optimistically —
the base chest is operator-stocked, so availability isn't tracked.

- **Parameters:** `sender` (number); `msg` (table) — `msg.hwid` read.
- **Returns:** nothing.
- **Side effects:** `rednet.send` of `PICK_ANSWER`.

## `M.listenerThread()`

**Signature:** `director.listenerThread()` (loops forever)

The rednet event loop. Receives on `cfg.PROTOCOL` (5 s timeout), type-checks the
payload is a table, then dispatches by `msg.type`. After every iteration it calls
`expireReservations`.

Dispatch table:

| `msg.type` | Action |
|------------|--------|
| `AUTH_REQ` | `handleAuthReq` |
| `HEARTBEAT` | [fleet.updateFromHeartbeat](fleet.md) |
| `GEO_DATA` | [voxelmap.ingestGeoData](voxelmap.md) |
| `ORE_REPORT` | [orders.handleOreReport](orders.md) |
| `ORE_MINED` | [orders.handleOreMined](orders.md); `gridmap.markMined` if `msg.seg` |
| `SEGMENT_REQ` | `handleSegmentReq` |
| `PARK_REQ` | `handleParkReq` |
| `PARK_RELEASE` | [park.clearParkClaim](park.md) |
| `RESERVE_REQ` | `handleReserveReq` |
| `RESERVE_REL` | `handleReserveRel` |
| `COAL_QUERY` | `handleCoalQuery` |
| `PICK_QUERY` | `handlePickQuery` |
| `PUSH_REQ` | [push_broker.handlePushReq](push_broker.md) |
| `ZONE_MAP` | [zones.ingestZoneMap](zones.md) |
| `ALERT` | append to `state.alert_log` (capped at 8 entries) |
| `CRAFT_DONE` | log GENESIS; [population.tick](population.md) |
| `YIELD_ACK` | noted; no action |

- **Parameters:** none.
- **Returns:** nothing (loops forever).
- **Side effects:** receives rednet; all handler side effects above; trims
  `state.alert_log` to 8.

## `M.prunerThread()`

**Signature:** `director.prunerThread()` (loops forever)

Every 2 s calls [fleet.pruneLost](fleet.md). For each lost `hwid` it clears its
reservations and park claim, and clears `state.genesis_hwid` if the Genesis seed
itself was lost. If anything was pruned it runs [population.tick](population.md) —
this is the replace-on-loss trigger.

- **Parameters:** none.
- **Returns:** nothing (loops forever).
- **Side effects:** mutates `state.reservations`, park claims, `state.genesis_hwid`;
  may send `CRAFT_AUTH` via `population.tick`.
- **Contract (replace-on-loss):** a craft is only re-authorized after a turtle is
  declared dead, so the fleet replaces losses without ever exceeding
  `TARGET_FLEET` — see [population.md](population.md).
