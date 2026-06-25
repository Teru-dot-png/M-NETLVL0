# lib/proto.lua — Protocol message types & helpers

Source: [../../onet/lib/proto.lua](../../onet/lib/proto.lua)

## Purpose

`proto` defines **every Rednet message type exactly once**, in one place, so the
turtle and the overseer can never silently disagree. The header makes the
rationale explicit: a typo in a message-type string is a protocol break, and
centralising the constants makes that impossible to introduce in a handler. It
also provides a tiny set of helpers for building well-formed messages and for the
defensive payload type-checking every handler performs (§8).

It is **byte-identical on turtle and overseer**.

## Place in the architecture

`proto` is the vocabulary for all Rednet traffic under the `ONET_V2` protocol.
The turtle's [network.lua](../turtle/network.md) and the overseer's
`director`/handlers reference these constants when sending and dispatching.
`M.PROTOCOL` mirrors `cfg.PROTOCOL` in [config.lua](../config.md); the two must
match for any device to talk.

> Note: several CORE handlers in the current code compare against **string
> literals** (e.g. `"AUTH_ACK"`, `"PUSH_REQ"`) rather than these constants; the
> constants here remain the canonical registry of the message vocabulary and the
> `msg`/type-check helpers are used when constructing payloads.

---

## Constants

**`M.PROTOCOL`** = `"ONET_V2"` — the Rednet protocol string.

**Turtle → Overseer:** `AUTH_REQ`, `HEARTBEAT`, `GEO_DATA`, `ORE_REPORT`,
`ORE_MINED`, `ALERT`, `PUSH_REQ`, `SEGMENT_REQ`, `PARK_REQ`, `RESERVE_REQ`,
`RESERVE_REL`, `COAL_QUERY`, `PICK_QUERY`, `ZONE_MAP`, `CRAFT_DONE`, `YIELD_ACK`.

**Overseer → Turtle:** `AUTH_ACK`, `CONFIG`, `CMD_START`, `CMD_STOP`,
`CMD_RECALL`, `ROLE_ASSIGN`, `SEGMENT_GRANT`, `GOTO`, `SEARCH_JOB`, `PARK_ASSIGN`,
`RESERVE_ACK`, `COAL_LOC`, `PICK_ANSWER`, `CRAFT_AUTH`, `YIELD`.

Each is a field on `M` whose value is its own name string.

## `M.msg(mtype, fields)`

**Signature:** `proto.msg(mtype, fields?) -> table`

Builds a well-formed message table. It always stamps `type = mtype` and then
merges every key from `fields` (if `fields` is a table) over it. Callers add
`hwid` and other payload data via `fields`.

- **Parameters:** `mtype` (string) — message type; `fields` (table, optional) —
  additional payload fields to merge in.
- **Returns:** a new message table with `type` set.
- **Side effects:** none (pure).

## `M.isTable(x)`

**Signature:** `proto.isTable(x) -> boolean`

`type(x) == "table"`. Defensive guard used by handlers before indexing a payload
(§8: tolerate malformed messages).

- **Parameters:** `x` (any).
- **Returns:** boolean.
- **Side effects:** none (pure).

## `M.num(x, default)`

**Signature:** `proto.num(x, default) -> number`

`tonumber(x)`, returning `default` when the conversion yields `nil`.

- **Parameters:** `x` (any) — value to coerce; `default` (number) — fallback.
- **Returns:** the numeric value or `default`.
- **Side effects:** none (pure).

## `M.str(x, default)`

**Signature:** `proto.str(x, default) -> string`

Returns `x` when it is a string, otherwise `default`.

- **Parameters:** `x` (any); `default` (string) — fallback.
- **Returns:** a string or `default`.
- **Side effects:** none (pure).
