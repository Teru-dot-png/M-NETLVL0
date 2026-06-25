# overseer/push_broker.lua — Priority push/yield arbitration

Source: [../../onet/overseer/push_broker.lua](../../onet/overseer/push_broker.lua)

## Purpose

`push_broker` is the **CORE** coordination primitive of the whole fleet: it
decides which of two turtles contending for the same tile must move. A turtle
that is stuck behind another broadcasts a `PUSH_REQ` naming the tile it wants and
its own move priority; the broker finds whoever is sitting on that tile and, if
that blocker is **equal-or-lower urgency**, sends it a direct `YIELD`. The whole
arbitration is ~20 lines and is the hardest coordination problem in the system —
port it exactly.

### The priority model

Priorities come from `cfg.PRIORITY` (in [config.lua](../config.md)). **Lower
number = higher urgency.** A turtle with a more urgent task never yields.

```
GOTO=1  RTB_FUEL=2  RTB_DUMP=3  FETCH_PICK=4  MINING=5
SEARCH=6  BUILDER=7  GENESIS=7  STANDBY=8  PARKED=9
```

The same table is consulted on the turtle side, so the pusher's self-reported
priority and the broker's view of the blocker's priority are drawn from one
source of truth.

## Place in the architecture

Invoked by [director.listenerThread](director.md) on every `PUSH_REQ`. It is the
overseer half of the push protocol; the turtle half (broadcasting `PUSH_REQ`,
receiving `YIELD`, stepping aside, replying `YIELD_ACK`) lives in
[turtle/network.md](../turtle/network.md). The broker only sends `YIELD`; it never
moves anything itself.

---

## `M.handlePushReq(sender, msg)`

**Signature:** `push_broker.handlePushReq(sender, msg)`

The arbitration. Validates `msg.want` is a table; floors the wanted tile
`(tx,ty,tz)`; reads the pusher's priority `pusher_pri` (default 10 if absent).
Then it scans `state.fleet` for a turtle (other than the pusher) whose floored
position equals the wanted tile. When found:

1. Look up the blocker's priority from `cfg.PRIORITY[blocker.status:upper()]`
   (default 10).
2. The blocker yields **only if** `blocker_pri >= pusher_pri` — i.e. it is *not*
   strictly more urgent than the pusher.
3. On a yield it `rednet.send`s a `YIELD { type, hwid = blocker, pusher }` to the
   blocker's `net_id` and logs a `PUSH` line.
4. Returns immediately after examining the occupant (only one occupant per tile).

- **Parameters:**
  - `sender` (number) — rednet id of the pusher (unused except as context).
  - `msg` (table) — the `PUSH_REQ`; reads `msg.hwid`, `msg.want {x,y,z}`,
    `msg.priority`.
- **Returns:** nothing.
- **Side effects:** `rednet.send` of `YIELD` to the blocker (when it loses the
  comparison); `log("PUSH", …)`.
- **Contract/invariant (priority push):**
  - Lower priority number = more urgent and **never yields**: a strictly-lower
    `blocker_pri` (`blocker_pri < pusher_pri`) keeps its tile.
  - Ties yield (`>=`), so an equal-priority blocker steps aside for the pusher —
    this breaks symmetric deadlocks.
  - Missing/unknown priorities default to 10, the least-urgent value, so an
    unrecognized status always yields.
  - The broker only ever messages the *blocker*; the pusher learns the outcome by
    the tile clearing (it re-paths), not by a reply.
