# turtle/tasks/task_dump.lua — RTB_DUMP task

Source: [../../../onet/turtle/tasks/task_dump.lua](../../../onet/turtle/tasks/task_dump.lua)

## Purpose

The hardcoded **6-step dump sequence** (§4). There is deliberately **no
branching**: this exact order was settled by debugging and must not be
"optimised". Cargo is slots 3..16; slots 1 (scanner) and 2 (pickaxe) are never
dropped (§1.1).

The six steps:
1. go to the dump chest;
2. drop slots 3–16 only;
3. move `fleet_size` blocks away from the chest;
4. send `PARK_REQ` to the overseer;
5. go to the assigned park slot;
6. wait for a command (handled by the brain after this task completes).

## Place in the task-chain model

A leaf sequence task built on [`Task`](task.md), issued by `role_miner` when
cargo is full. Maps to **RTB_DUMP** (priority 3), set by the role. It is a single
long `work()` rather than a chain because the ordering is a fixed contract.

Depends on [task](task.md), [config](../../config.md), [state](../state.md),
[nav](../nav.md), [movers](../movers.md), [inventory](../inventory.md),
[vec](../../lib/vec.md), [log](../../lib/log.md).

> Note: `movers` is required for symmetry but `work` relies on `nav`/`inventory`
> for its actions.

---

## `M.new(opts)`

**Signature:** `task_dump.new(opts) -> task`

Constructs the dump task via `Task.new("dump", true, opts)` (target is the
literal `true`) with two instance overrides:

- **`t:isValidTarget()`** — returns `state.dump ~= nil`; dumping needs a known
  dump chest. *(Intentional instance override; "duplicate field" lint is a false
  positive.)*
- **`t:work()`** — the six steps in order:
  1. **Go to chest.** `nav.moveTo({dump.x, dump.y+1, dump.z})` (stand on top).
     On failure: log, `sleep(10)`, `self.failed = true`, return `false`.
  2. **Drop cargo.** `inventory.dropCargo("down")` drops slots 3–16 into the
     chest. If it returns false (chest full), log `DUMP: Dump chest FULL...` and
     send `{ type="ALERT", hwid, msg="CHEST_FULL", pos }`.
  3. **Clear the tile.** `away = math.max(1, tonumber(state.fleet_size) or 2)`;
     `nav.moveTo({dump.x + away, dump.y+1, dump.z})` so the chest tile is free
     for other turtles.
  4. **PARK_REQ.** If `state.server_id`: increment `state.park_req_nonce`, send
     `{ type="PARK_REQ", hwid, nonce, pos }`.
  5. **Go to park.** Wait up to 3000 ms (`os.epoch("utc")` deadline, polling
     `sleep(0.2)`) for `state.park_pos`; if assigned, `nav.moveTo(state.park_pos)`.
  6. **Done.** `self.done = true`, return `true` — the brain then transitions to
     PARKED and waits for `CMD_START`.

- **Parameters:** `opts` (optional) — passed to `Task.new`.
- **Returns:** the task.
- **Side effects (when run):** navigation; `inventory.dropCargo` (drops slots
  3–16); network sends (`ALERT` on full chest, `PARK_REQ`); mutates
  `state.park_req_nonce`; reads `state.dump`, `state.fleet_size`,
  `state.park_pos`; `DUMP` logs; `sleep` on the park-wait and the
  chest-unreachable path.
- **State mapping:** **RTB_DUMP** (3) — set by the issuing role.
- **Contracts touched:**
  - **Slot protection (§1.1)** — `inventory.dropCargo` drops only cargo slots
    3..16 (`CARGO_FIRST..CARGO_LAST`); the scanner (slot 1) and pickaxe (slot 2)
    are never dropped. The slot-number guard runs before any `getItemDetail`.
  - **Fixed 6-step order (§4)** — must not be reordered or "optimised".

---

## Functions documented: 1

`M.new` (with `isValidTarget`/`work` overrides).
