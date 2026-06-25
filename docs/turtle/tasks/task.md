# turtle/tasks/task.lua — Base Task class (the Overmind model)

Source: [../../../onet/turtle/tasks/task.lua](../../../onet/turtle/tasks/task.lua)

## Purpose

`Task` is the base object for the **Overmind task-chain model**. A Task is an
atomic, composable unit of work with an explicit termination condition
(`isWorking`). Every concrete task module (`task_goto`, `task_mine`, …) builds
on this class, and every role's `assignTask` produces exactly one Task (often a
chain) for the agent loop to drive.

The defining idea: a Task does **one chunk of work per tick** in `:work()` and
sets `self.done = true` when finished. Tasks chain via `.parent`, so a role can
express *"do X, then fall back to Y"* — e.g. a goto task whose `.parent` is a
mine task means *travel to the ore, then mine it*.

## Place in the architecture

This module exports the class table `Task` directly (`return Task`). It is the
common ancestor of all task modules under [tasks/](.) and is `require`d by every
role to build inline tasks (e.g. `role_miner`'s `fetchPickTask`,
`role_hauler`'s `haulTask`). It has **no hardware or network dependencies** of
its own — it is pure control flow. The priority *state* a task maps to is not
set here; the role's `assignTask` sets `state.current_state` (and thus
`cfg.PRIORITY[...]`) before handing the task to the agent.

> **Override pattern (important).** Concrete tasks call `Task.new(...)` and then
> reassign `t:isValidTarget` and `t:work` on the returned instance. The Lua
> language server flags these as "duplicate field" because the base class
> already declares them — that warning is **false**. These are intentional
> per-instance method overrides, the core mechanism of this model, not
> duplicate definitions.

---

## `Task.new(name, target, opts)`

**Signature:** `Task.new(name, target, opts) -> task`

Constructs a new task instance with `Task` as its metatable.

- **Parameters:**
  - `name` (string, optional) — human label; defaults to `"task"`.
  - `target` (any, optional) — the thing the task acts on. Convention: a
    coordinate `{x,y,z}` for movement/mining tasks, or the literal `true` for
    tasks whose validity is environmental rather than positional (e.g. scan,
    park, dump).
  - `opts` (table, optional) — per-task options; defaults to `{}`.
- **Returns:** the new task with fields `name`, `target`, `opts`, `parent=nil`,
  `done=false`, `failed=false`, `data={}`.
- **Side effects:** none (allocation only).
- **State mapping:** none — construction does not choose a priority.

## `Task:isValidTarget()`

**Signature:** `task:isValidTarget() -> boolean`

Base predicate: the target is valid iff `self.target ~= nil`. **Designed to be
overridden** for coordinate or peripheral checks (concrete tasks replace it to
validate `{x,y,z}` shape, scanner presence, dump existence, etc.).

- **Parameters:** none.
- **Returns:** `true` while the target is meaningful.
- **Side effects:** none.

## `Task:isWorking()`

**Signature:** `task:isWorking() -> boolean`

The termination condition for the whole model. Returns
`(not self.done) and (not self.failed) and self:isValidTarget()` — i.e. the task
keeps running while it is neither finished nor failed and its target is still
valid. Subclasses normally do **not** override this; they drive `done`/`failed`
from `:work()` and customise `:isValidTarget()` instead.

- **Parameters:** none.
- **Returns:** boolean.
- **Side effects:** none.

## `Task:work()`

**Signature:** `task:work() -> boolean`

One unit of work. **The primary override point.** The base implementation is a
no-op that immediately marks the task complete (`self.done = true`) and returns
`true`. Concrete tasks replace this to perform navigation, digging, crafting,
etc., setting `self.done = true` when the whole task is finished and returning
`false` on failure.

- **Parameters:** none.
- **Returns:** `true` on progress/success; `false` on failure (which `run`
  promotes to `self.failed = true`).
- **Side effects:** none in the base; arbitrary (hardware/network/state) in
  overrides.

## `Task:run()`

**Signature:** `task:run() -> task | nil`

Drives the task one tick and returns the task that should run next tick. This is
where chaining happens:
- If `isWorking()` is true, it calls `:work()`; if `work` returned `false` it
  sets `self.failed = true`; either way it returns `self` (run me again next
  tick).
- Otherwise it returns `self.parent` — falling back **up** the chain. A `nil`
  parent means the chain is exhausted and the agent is idle.

- **Parameters:** none.
- **Returns:** `self`, `self.parent`, or `nil`.
- **Side effects:** invokes `:work()`, so inherits whatever side effects the
  override has; may set `self.failed`.

## `Task:fork(child)`

**Signature:** `task:fork(child) -> child`

Chains `child` to run **after** `self` finishes by setting `child.parent = self`
and returning `child`. Note the direction: `self:fork(child)` makes `self` the
parent (fallback) of `child`, so `child` runs first and falls back to `self`.
Several roles set `.parent` directly instead of calling `fork` — both are
equivalent ways to build the same chain.

- **Parameters:** `child` — the task to attach.
- **Returns:** `child`.
- **Side effects:** mutates `child.parent`.

---

## Contracts touched

- **Task-chain model** — `parent` chaining + `isWorking` termination is the
  contract every role and task relies on. Do not "simplify" `run`'s fallback or
  the `done`/`failed` semantics; the priority state machine in each role assumes
  exactly this behaviour.
- **Override pattern** — instance-level reassignment of `isValidTarget`/`work`
  is intentional; the "duplicate field" lint is a false positive.
