# turtle/roles/role_miner.lua — MinerRole

Source: [../../../onet/turtle/roles/role_miner.lua](../../../onet/turtle/roles/role_miner.lua)

## Purpose

`MinerRole` is the workhorse role: grid tunnelling driven by the §4 priority
state machine, expressed as **task selection**. It is the CORE behavioural port
of `brain.lua`'s transition logic — instead of a giant `if` ladder inside the
brain, the brain calls `role:assignTask(agent)` whenever the agent goes idle and
the role picks exactly **one** task, setting `state.current_state` so the
push-protocol priority (`cfg.PRIORITY[state.current_state]`) is correct while
that task runs.

## Place in the task-chain model

The role does not run tasks itself; it *produces* the next task (or chain) for
the agent loop to drive via [`Task:run`](../tasks/task.md). Where a job needs
"travel then act", it builds a `.parent` chain — `gotoMineChain` makes a
`task_goto` whose `.parent` is a `task_mine`, so the turtle goes to the ore and
then mines it. The selection order **is** the priority ladder: critical fuel →
GOTO → low fuel → dump → fetch pickaxe → SEARCH → MINING.

`M.name = cfg.ROLES.MINER`. Depends on [config](../../config.md),
[state](../state.md), [fuel](../fuel.md), [inventory](../inventory.md),
[pickaxe](../pickaxe.md), [vec](../../lib/vec.md), [log](../../lib/log.md), and
the tasks [task](../tasks/task.md), [task_goto](../tasks/task_goto.md),
[task_fuel](../tasks/task_fuel.md), [task_dump](../tasks/task_dump.md),
[task_park](../tasks/task_park.md), [task_tunnel](../tasks/task_tunnel.md),
[task_mine](../tasks/task_mine.md), [task_scan](../tasks/task_scan.md).

---

## `fetchPickTask(resume)` (local)

**Signature:** `fetchPickTask(resume) -> task`

Builds an inline FETCH_PICK task. Constructs `Task.new("fetch_pick", true)` and
overrides `:work()` to call `pickaxe.fetchPickaxeFromBase(resume)` (which
lazy-requires `nav` to avoid a load-time cycle), then sets `self.done = true`
and returns `true`.

- **Parameters:** `resume` — the position to return to after fetching (passed
  through to `pickaxe.fetchPickaxeFromBase`).
- **Returns:** the task.
- **Side effects (when run):** navigation to base and back, pickaxe re-equip via
  the `pickaxe` module.
- **State mapping:** **FETCH_PICK** (priority 4) — set by `assignTask` before
  this task is handed over.
- **Contract:** restores the slot-2 pickaxe (§1.1) so mining can resume.

## `requestSegment()` (local)

**Signature:** `requestSegment()` (no return)

Asks the overseer for the next grid segment near the current position. No-op if
`state.server_id` is unset. Sends `{ type="SEGMENT_REQ", hwid, pos }` over
`cfg.PROTOCOL` via a `pcall(rednet.send, ...)`.

- **Parameters:** none.
- **Returns:** none.
- **Side effects:** **network send** (`SEGMENT_REQ`).
- **State mapping:** used inside the **MINING** branch when no segment is held.

## `gotoMineChain(job)` (local)

**Signature:** `gotoMineChain(job) -> task`

Builds a GOTO-then-MINE chain for a job and consumes it. Creates
`task_mine.new({x,y,z,ore})` from `job.pos`/`job.ore`, creates
`task_goto.new(job.pos)`, sets `gt.parent = mt` (run goto, then mine on
arrival), and returns the goto task.

- **Parameters:** `job` — `{ pos = {x,y,z}, ore = <tag> }`.
- **Returns:** the goto task (head of the chain).
- **Side effects:** none at build time.
- **State mapping:** used by both the **GOTO** and **SEARCH** branches.

## `M:assignTask(agent)`

**Signature:** `role:assignTask(agent)` (no return; sets `agent.task`)

The priority state machine. Evaluated top-to-bottom; the first matching branch
sets `state.current_state` and `agent.task`, then returns. Branches in order:

1. **Not started** — if `not state.started`, sit in the park slot waiting for
   `CMD_START`: `state.current_state = state.park_pos and "PARKED" or "STANDBY"`
   and `agent.task = task_park.new()`. (Priority **PARKED**/**STANDBY**, 9/8.)
2. **(critical) Out of fuel** — if `fuel.fuelLevel() < cfg.FUEL_CRITICAL`,
   refuel immediately regardless of anything else: state **RTB_FUEL** (2), task
   `task_fuel.new(vec.copy(state.pos))`.
3. **(1) GOTO job** — if `state.goto_job`, state **GOTO** (1); clears
   `state.goto_job` and assigns `gotoMineChain(job)`.
4. **(2) Low fuel** — if `fuel.fuelLevel() < cfg.FUEL_MIN`, state **RTB_FUEL**
   (2), task `task_fuel.new(...)`.
5. **(3) Cargo full** — if `inventory.inventoryFull()`, state **RTB_DUMP** (3),
   task `task_dump.new()`.
6. **(4) Pickaxe missing** — if `not pickaxe.pickaxeEquipped()`, state
   **FETCH_PICK** (4), task `fetchPickTask(vec.copy(state.pos))`.
7. **(5) SEARCH job** — if `state.search_job` (a "getme" request), state
   **SEARCH** (6); clears `state.search_job` and assigns `gotoMineChain(job)`.
8. **(6) MINING** — default. State **MINING** (5). If `state.segment` is held,
   assign `task_tunnel.new(seg)`; otherwise `requestSegment()` and assign
   `task_scan.new()` (useful work while waiting for a grant).

- **Parameters:** `agent` — the agent loop object; its `.task` field is set.
- **Returns:** none.
- **Side effects:** mutates `state.current_state`, clears `state.goto_job` /
  `state.search_job`, may send `SEGMENT_REQ`; reads `fuel`, `inventory`,
  `pickaxe`, `state`.
- **State mapping:** sets every priority in `cfg.PRIORITY` reachable by a miner
  (GOTO, RTB_FUEL, RTB_DUMP, FETCH_PICK, SEARCH, MINING, PARKED, STANDBY).
- **Contracts touched:** slot-2 pickaxe presence (branch 6, §1.1); cargo-full
  dumping of slots 3..16 (branch 5, via `task_dump`); fuel thresholds
  `FUEL_CRITICAL`/`FUEL_MIN` (branches "critical" and 4). Base-protection radius
  is enforced downstream in `task_tunnel`/`task_mine`, not here.

---

## Functions documented: 4

`fetchPickTask`, `requestSegment`, `gotoMineChain`, `M:assignTask`.
