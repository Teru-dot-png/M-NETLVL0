# turtle/tasks/task_park.lua — PARK task

Source: [../../../onet/turtle/tasks/task_park.lua](../../../onet/turtle/tasks/task_park.lua)

## Purpose

Navigate to the assigned park slot and idle there. `target = state.park_pos`
(implicitly — the task reads it directly). This is the "stopped / waiting"
behaviour every role falls back to before `CMD_START` or when a role has nothing
to do.

## Place in the task-chain model

A leaf movement task built on [`Task`](task.md). Issued by every role's
"not started" branch (and the refuel/genesis idle branches). The priority state
it maps to is **PARKED** (9) or **STANDBY** (8), chosen by the role based on
whether `state.park_pos` is known; the task itself does not set the state.

Depends on [task](task.md), [state](../state.md), [nav](../nav.md),
[log](../../lib/log.md).

---

## `M.new(opts)`

**Signature:** `task_park.new(opts) -> task`

Constructs the park task via `Task.new("park", true, opts)` (target is the
literal `true`) with two instance overrides:

- **`t:isValidTarget()`** — returns `state.park_pos ~= nil`; parking is only
  meaningful once a park slot has been assigned. *(Intentional instance
  override; "duplicate field" lint is a false positive.)*
- **`t:work()`** — logs `NAV: PARK -> assigned slot.`, calls
  `nav.moveTo(state.park_pos)`, sets `self.done = true`, returns `true`. Note it
  marks done regardless of whether `moveTo` succeeded (best-effort park).

- **Parameters:** `opts` (optional) — passed to `Task.new`.
- **Returns:** the task.
- **Side effects (when run):** navigation to `state.park_pos`; `NAV` log.
- **State mapping:** **PARKED** (9) / **STANDBY** (8) — set by the issuing role.
- **Contracts touched:** none directly (no inventory/slot handling).

---

## Functions documented: 1

`M.new` (with `isValidTarget`/`work` overrides).
