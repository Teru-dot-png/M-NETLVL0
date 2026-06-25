# turtle/tasks/task_goto.lua — GOTO task

Source: [../../../onet/turtle/tasks/task_goto.lua](../../../onet/turtle/tasks/task_goto.lua)

## Purpose

Travel to a coordinate. `target = {x,y,z}`. Maps to the **GOTO** priority state
(value 1 — the most urgent band, never yields). Optionally faces a direction on
arrival.

## Place in the task-chain model

A leaf movement task built on [`Task`](task.md). It is frequently the **head** of
a chain — e.g. `role_miner`'s `gotoMineChain` sets a `task_goto`'s `.parent` to a
`task_mine` so the turtle travels, then mines on arrival. The module exposes a
factory `M.new`; the priority state itself is set by the calling role.

Depends on [task](task.md), [nav](../nav.md), [movers](../movers.md),
[state](../state.md), [log](../../lib/log.md).

---

## `M.new(target, opts)`

**Signature:** `task_goto.new(target, opts) -> task`

Constructs the goto task via `Task.new("goto", target, opts)` with two instance
overrides:

- **`t:isValidTarget()`** — returns true iff `self.target` is a table with `x`,
  `y`, and `z` fields. *(Intentional instance override of the base method; the
  "duplicate field" lint is a false positive.)*
- **`t:work()`** — logs a `NAV` line with the destination, calls
  `nav.moveTo(self.target)`; if it arrived **and** `self.opts.face ~= nil`,
  calls `movers.face(self.opts.face)`. Sets `self.done = arrived` and returns
  `arrived`.

- **Parameters:**
  - `target` — `{x,y,z}` destination.
  - `opts` (optional) — may contain `face` (a direction to turn to on arrival).
- **Returns:** the task.
- **Side effects (when run):** navigation via `nav.moveTo` (movement, possible
  re-path/digging per `nav`'s rules); optional `movers.face`; `NAV` log.
- **State mapping:** **GOTO** (priority 1) — set by the calling role
  (`state.current_state = "GOTO"`).
- **Contracts touched:** none directly (no inventory/slot handling); relies on
  `nav` for base-protection / stuck handling.

---

## Functions documented: 1

`M.new` (with `isValidTarget`/`work` overrides).
