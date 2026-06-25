# overseer/park.lua — Parking-slot allocation

Source: [../../onet/overseer/park.lua](../../onet/overseer/park.lua)

## Purpose

`park` tracks per-slot parking claims inside the operator-defined park rectangle.
SURVIVAL: once the fleet grows past ~3, turtles without distinct claims park on
top of each other and deadlock, so every recalled turtle gets a unique tile. The
park zone is a 2D rectangle (`state.PARK_ZONE = {x1,y1,z1,x2,y2,z2}`) at the
minimum `y` of the two corners.

## Place in the architecture

`assignUnclaimedSlot` is called on `AUTH_REQ` and `PARK_REQ`
([director](director.md)); `getSlot` is the fallback when no claim is free;
`clearParkClaim` runs on `PARK_RELEASE` and on prune. The park rectangle is set by
the `setpark` command ([terminal](terminal.md)) and persisted by
[persist](persist.md). State: `state.park_claim_by_hwid`,
`state.park_claim_by_key`, `state.PARK_ZONE`, `state.fleet_slot`. The turtle-side
consumer is [task_park.md](../turtle/tasks/task_park.md).

---

## `M.parkPosKey(p)`

**Signature:** `park.parkPosKey(p) -> string`

The canonical `"x:y:z"` key (floored) for a park position.

- **Parameters:** `p` (`{x,y,z}`).
- **Returns:** the floored key string.
- **Side effects:** none.

## `M.clearParkClaim(hwid)`

**Signature:** `park.clearParkClaim(hwid)`

Releases a turtle's claim: removes its `by_key` entry (if any) and its `by_hwid`
entry.

- **Parameters:** `hwid` (string).
- **Returns:** nothing.
- **Side effects:** mutates both park-claim tables.

## `M.clearAllParkClaims()`

**Signature:** `park.clearAllParkClaims()`

Resets both park-claim tables to empty.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** replaces `state.park_claim_by_hwid` and `_by_key` with `{}`.

## `M.isOccupiedByOther(pos, requester)`

**Signature:** `park.isOccupiedByOther(pos, requester) -> boolean`

True if any turtle other than `requester` is currently *standing on* `pos`
(floored comparison against live `state.fleet[*].pos`).

- **Parameters:** `pos` (`{x,y,z}`); `requester` (string).
- **Returns:** boolean.
- **Side effects:** none.
- **Contract:** this is a *physical* occupancy check (where turtles actually are),
  complementing the *logical* claim tables — both must be clear to assign a slot.

## `M.assignUnclaimedSlot(hwid, ref)`

**Signature:** `park.assignUnclaimedSlot(hwid, ref) -> pos|nil`

Finds and claims the nearest free park slot to `ref`. Returns `nil` if no park
zone is configured. It normalizes the rectangle bounds, releases the requester's
prior claim, then scans every tile in the rectangle picking the manhattan-nearest
one to `ref` that is (a) unclaimed or already this turtle's, and (b) not physically
occupied by another turtle. Stale claims whose owner left the fleet are reclaimed
during the scan. On success it records the claim in both tables.

- **Parameters:**
  - `hwid` (string) — the turtle to claim for.
  - `ref` (`{x,y,z}`|nil) — proximity reference; defaults to the rectangle corner.
- **Returns:** the claimed `{x,y,z}`, or `nil` if no zone / no free tile.
- **Side effects:** clears the requester's old claim; may reclaim stale claims;
  sets `state.park_claim_by_key[k]` and `state.park_claim_by_hwid[hwid]`.
- **Contract:** the combined unclaimed + unoccupied test is what prevents two
  turtles deadlocking on one tile.

## `M.getSlot(index)`

**Signature:** `park.getSlot(index) -> pos|nil`

The fallback sequential slot when claim-based assignment yields nothing. Maps an
integer `index` deterministically onto a tile in the park rectangle (row-major,
wrapping modulo the rectangle's tile count). Returns `nil` if no park zone.

- **Parameters:** `index` (number) — usually `state.fleet_slot`.
- **Returns:** a `{x,y,z}` tile, or `nil`.
- **Side effects:** none (does **not** claim the tile).
- **Used by:** [director.handleParkReq](director.md) when no unclaimed slot is
  available.
