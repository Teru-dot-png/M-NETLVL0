# turtle/network.lua — Modem, handshake & listener

Source: [../../onet/turtle/network.lua](../../onet/turtle/network.lua)

## Purpose

`network` is the turtle's nervous system: it opens the modem, runs the AUTH
handshake, and runs the listener thread that dispatches every inbound message.
CORE — the AUTH handshake, `RESERVE_ACK`, the `PUSH_REQ` yield, and the direct
`YIELD` handlers are ported **verbatim** from the debugged V1 listener; the V2
handlers (`ROLE_ASSIGN`, `SEGMENT_GRANT`, `SEARCH_JOB`, `COAL_LOC`,
`PICK_ANSWER`, `CRAFT_AUTH`) are layered alongside. Every handler type-checks its
payload (§8).

## Place in the architecture

Launched as a supervised thread by [boot_turtle.lua](boot_turtle.md), with
`handshake` run once during boot. It writes overseer-assigned config into
[state.lua](state.md) and uses [movers.lua](movers.md) for facing/yield,
[nav.lua](nav.md) (required) and [cache.lua](cache.md) (seeding chests). All
traffic is on `cfg.PROTOCOL` (`ONET_V2`). See the protocol registry in
[proto.md](../lib/proto.md).

---

## `M.openModem()`

**Signature:** `network.openModem()` (no return; may `error`)

Opens Rednet on `state.HW.modem_side`. Raises a fatal `error` if no modem side was
detected.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** `rednet.open`; `NET` log; fatal error if no modem.

## `applyAssignment(msg)` (module local)

**Signature:** `applyAssignment(msg)` (no return)

Applies an `AUTH_ACK`/`CONFIG`-style payload to state, each field guarded so a
missing key leaves the existing value: `my_dir`, `lane_offset`, `dump`, `base`,
`want_list` (→ `WANT_LIST`), `park_pos`, `overseer_pos`, `zone_chests`, `role`.
Seeds the `dump` and `base` coordinates into the cache as chests.

- **Parameters:** `msg` (table) — the assignment payload.
- **Returns:** nothing.
- **Side effects:** mutates many `state` fields; `cache.cacheSet` for dump/base.
- **Contract:** `overseer_pos` here is also the base-protection geofence centre
  (§4).

## `M.handshake()`

**Signature:** `network.handshake() -> boolean`

Enlistment handshake. Broadcasts an `AUTH_REQ` (`hwid`, `pos` copy, `crafty`
flag) and waits up to 5 s for an `AUTH_ACK` addressed to this `hwid`, retrying up
to 24 attempts. On ACK: records `server_id`, `applyAssignment(msg)`, faces
`state.my_dir`, and logs enlistment.

- **Parameters:** none.
- **Returns:** `true` if enlisted (`server_id` set), else `false`.
- **Side effects:** `rednet.broadcast`/`receive`; mutates `state.server_id` and
  assignment fields; `movers.face`; `NET` logs.
- **Contract (protocol/AUTH):** bounded broadcast-until-ACK handshake; the ACK is
  matched on `hwid` so a turtle only accepts its own assignment.

## `yieldAside(avoid)` (module local)

**Signature:** `yieldAside(avoid) -> boolean`

Steps the turtle out of the way: tries `movers.stepUp()` first, otherwise faces
each of the four cardinal directions and steps forward into the first free tile
that is **not** the `avoid` cell. On success sets `state.block_movement = true` (a
one-shot veto so the navigator re-plans).

- **Parameters:** `avoid` (`{x,z}`|nil) — a tile not to step onto (the pusher's
  position).
- **Returns:** `true` if it moved aside, else `false`.
- **Side effects:** `movers.stepUp`/`face`/`stepForward`; mutates `state.pos` (via
  movers) and `state.block_movement`.

## `M.listenerThread_inner()`

**Signature:** `network.listenerThread_inner()` (infinite loop)

The listener thread (supervised at boot). Blocks on `rednet.receive(cfg.PROTOCOL)`
and dispatches by `msg.type`, type-checking each payload. Handlers:

- **`CMD_START`** — set `started`; send `PARK_RELEASE`; log.
- **`CMD_STOP`** — clear `started`.
- **`CMD_RECALL`** — set `home_requested` (brain short-circuits to PARKED).
- **`ROLE_ASSIGN`** (own hwid) — set `state.role` (live Overmind swap).
- **`SEGMENT_GRANT`** (own hwid) — store `state.segment`.
- **`CONFIG`** — `applyAssignment`; log.
- **`AUTH_ACK`** (own hwid) — late enlistment: set `server_id`, apply, face.
- **`GOTO`** (own hwid, table pos) — queue `state.goto_job`.
- **`SEARCH_JOB`** (own hwid, table pos) — queue `state.search_job`.
- **`COAL_LOC`** (own hwid) — store `state.coal_loc`.
- **`PICK_ANSWER`** (own hwid) — set `state.pick_available`.
- **`CRAFT_AUTH`** (own hwid) — set `state.craft_authorized`; log (Genesis gate).
- **`RESERVE_ACK`** (own hwid) — resolve the pending reservation nonce
  (`done`/`granted`).
- **`PARK_ASSIGN`** (own hwid) — set `park_pos`, clear `started`/`home_requested`,
  resolve the pending park nonce.
- **`PUSH_REQ`** (other hwid) — if we sit on the wanted tile **and our priority is
  ≥ theirs** (i.e. we are not more urgent), `yieldAside`. A more-urgent blocker is
  left alone.
- **`YIELD`** (own hwid) — overseer-directed step aside; reply `YIELD_ACK` with
  ok/pos/state.

- **Parameters:** none.
- **Returns:** never (infinite loop).
- **Side effects:** mutates many `state` fields; network sends
  (`PARK_RELEASE`, `YIELD_ACK`); `movers` calls; `NET`/`PUSH`/`ROLE`/`GENESIS`
  logs.
- **Contract (move priority / push protocol):** the `PUSH_REQ` branch yields only
  when `our_pri >= their_pri`, matching the broker semantics in
  [architecture.md](../architecture.md) §5. Every handler validates payload types
  (§8) and most gate on `msg.hwid == state.hwid`.
