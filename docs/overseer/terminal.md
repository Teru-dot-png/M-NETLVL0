# overseer/terminal.lua — Operator command console

Source: [../../onet/overseer/terminal.lua](../../onet/overseer/terminal.lua)

## Purpose

`terminal` is the operator command console. It mirrors the V1 command set plus V2
additions (`setzone`, `setpop`, `role`). Every fleet-wide command either
broadcasts or targets a single `hwid`. Each config-changing command persists and,
where relevant, broadcasts the new config.

## Place in the architecture

`terminalThread` is launched supervised by [overseer.run](overseer.md). It is the
operator's edge into nearly every subsystem: [fleet](fleet.md), [zones](zones.md),
[orders](orders.md), [population](population.md), [persist](persist.md),
[voxelmap](voxelmap.md), and [lib/blocks](../lib/blocks.md). Commands that send
messages use `cfg.PROTOCOL`. State touched spans the whole operator-config surface
(`DUMP_CHEST`, `BASE_CHEST`, `PARK_ZONE`, `WANT_LIST`, `active_orders`, zones,
`target_fleet`, fleet roles, the voxel map).

---

## `words(line)` (module local)

**Signature:** `words(line) -> string[]`

Splits a line into whitespace-separated tokens.

- **Parameters:** `line` (string|nil).
- **Returns:** list of tokens (empty list for nil/blank).
- **Side effects:** none.

## `coords(w, i)` (module local)

**Signature:** `coords(w, i) -> x, y, z`

Reads three numeric coordinates from token list `w` starting at index `i`.

- **Parameters:** `w` (string[]) — tokens; `i` (number) — start index.
- **Returns:** `x`, `y`, `z` as numbers (any may be `nil` if unparseable).
- **Side effects:** none.

## `sendAll(mtype, hwid_filter)` (module local)

**Signature:** `sendAll(mtype, hwid_filter)`

Sends a `{type = mtype, hwid}` message to every fleet member, or only to
`hwid_filter` when given.

- **Parameters:** `mtype` (string) — message type; `hwid_filter` (string|nil).
- **Returns:** nothing.
- **Side effects:** `rednet.send` to one or all turtles on `cfg.PROTOCOL`.

## `help()` (module local)

**Signature:** `help()`

Prints the command reference to the local terminal.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** terminal `print`.

## `M.terminalThread()`

**Signature:** `terminal.terminalThread()` (loops until EOF)

The read-eval loop. Prompts `> `, reads a line, tokenizes it, and dispatches the
first token as a command. Recognized commands:

| Command | Effect | Side effects |
|---------|--------|--------------|
| `start` / `stop` / `recall [hwid]` | `sendAll` `CMD_START`/`CMD_STOP`/`CMD_RECALL` | rednet send |
| `status` | print fleet counts + [fleet.snapshot](fleet.md) | terminal |
| `setdump x y z` | set `state.DUMP_CHEST` | [persist.saveConfig](persist.md) + `broadcastConfig` |
| `setbase x y z` | set `state.BASE_CHEST` | persist + broadcast |
| `setpark x1 y1 z1 x2 y2 z2` | set `state.PARK_ZONE` | persist |
| `setzone ZONE x y z` | [zones.setChest](zones.md) | persist on success |
| `zones` | print [zones.fillSnapshot](zones.md) | terminal |
| `want <ore>` / `unwant <ore>` | edit `state.WANT_LIST` (name via [blocks.normalizeOreName](../lib/blocks.md)) | persist + broadcast |
| `wants` | list the want list | terminal |
| `getme <ore> <n>` | [orders.startGetme](orders.md) | starts an order |
| `orders` | list `state.active_orders` with dump counts | terminal |
| `cancelorder <ore>` | drop an active order | mutate `active_orders` |
| `setpop <n>` | [population.setTarget](population.md) then `population.tick` | may send `CRAFT_AUTH` |
| `role <hwid> <ROLE>` | set the turtle's role + send `ROLE_ASSIGN` | mutate record, rednet send |
| `map [y]` | print a voxel slice via [voxelmap.getVoxel](voxelmap.md) | terminal |
| `savemap` | [persist.saveMap](persist.md) | file write |
| `clearmap` | empty `state.master_voxels`, zero `total_voxels` | state mutation |
| `feed` | print the ore feed | terminal |
| `help` / `?` | `help()` | terminal |
| _other non-empty_ | `unknown; 'help'` | terminal |

- **Parameters:** none.
- **Returns:** nothing (loops until `io.read` returns nil/EOF).
- **Side effects:** as tabulated — terminal IO, state mutation, config
  persistence, rednet sends.
- **Map rendering:** the `map` command draws a top-down slice at `y` (default
  `state.view_y`) across the view centre, marking ` `=unknown, `.`=air, `O`=ore,
  `#`=other solid.
- **Contract:** every config edit that turtles must see (`setdump`, `setbase`,
  `want`/`unwant`) both persists *and* broadcasts; park slots are intentionally not
  broadcast (see [persist.broadcastConfig](persist.md)).
