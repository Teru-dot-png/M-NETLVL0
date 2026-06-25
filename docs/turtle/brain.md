# turtle/brain.lua — Agent loop

Source: [../../onet/turtle/brain.lua](../../onet/turtle/brain.lua)

## Purpose

`brain` is the turtle's agent loop. It holds one `Agent` (this turtle wrapped as
a Zerg-style creep) and the current `Role`. Each tick: if the agent is idle, ask
the role for a task; then drive the current task one step. The role sets
`state.current_state`, which is what the push/reservation protocol reads for this
turtle's move priority.

## Place in the architecture

The brain is the top of the Role → Task → Nav/Movers layering (see
[architecture.md](../architecture.md)). It is launched as a supervised thread by
[boot_turtle.lua](boot_turtle.md). It loads role modules from
[turtle/roles/](../../onet/turtle/roles/) and supports the live **Overmind** role
swap. Depends on [config.lua](../config.md), [state.lua](state.md),
[log.lua](../lib/log.md), and (lazily, via `require`) the role modules.

---

## `ROLE_MODULES` (module local)

A table mapping role name (`cfg.ROLES.*`) to its module basename
(`role_miner`, `role_hauler`, …). The lookup defaults to `role_miner`.

## `loadRole(name)` (module local)

**Signature:** `loadRole(name) -> roleModule`

Resolves a role name to a module basename and `pcall(require, ...)`s it. Returns
the module only if it is a table exposing `assignTask`; otherwise logs a `ROLE`
fallback line and returns `require("role_miner")`.

- **Parameters:** `name` (string) — role name.
- **Returns:** a role module table (guaranteed to have `assignTask`).
- **Side effects:** `require` (module load); `ROLE` log on fallback.
- **Contract (pcall-guarded role load):** a role a turtle does not carry (e.g.
  `role_genesis` on a plain miner) falls back to `MinerRole` instead of crashing
  the brain.

## `Agent.new()`

**Signature:** `Agent.new() -> Agent`

Constructs an agent with `task = nil` and an empty `memory` table.

- **Parameters:** none. **Returns:** a new `Agent` (metatable-backed).
- **Side effects:** none.

## `Agent:isIdle()`

**Signature:** `agent:isIdle() -> boolean`

True if the agent has no task, or its task is `done` or `failed`.

- **Parameters:** none (method on `self`).
- **Returns:** boolean.
- **Side effects:** none.

## `Agent:priority()`

**Signature:** `agent:priority() -> number`

Returns `cfg.PRIORITY[state.current_state]`, defaulting to 10 (lowest urgency)
for an unknown state.

- **Parameters:** none.
- **Returns:** the numeric move priority.
- **Side effects:** none (reads `state.current_state`).

## `Agent:run()`

**Signature:** `agent:run()` (no return)

Drives the current task one step: if a task exists, replaces it with the result
of `task:run()` (tasks return their successor — typically `self`, their `.parent`,
or `nil`).

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** whatever the task's `run` does (movement, mining, network,
  etc.); mutates `self.task`.

## `M.brainThread_inner()`

**Signature:** `brain.brainThread_inner()` (infinite loop)

The brain thread body (supervised at boot). Creates an agent, loads the role for
`state.role`, and loops:
1. **Live role swap** — if `state.role` differs from the loaded role's name,
   reloads the role, clears the in-flight task, and logs the switch.
2. **Recall short-circuit** — if `state.home_requested`, forces
   `current_state = "PARKED"`, drops the task, and idles.
3. **Normal tick** — if the agent is idle, calls `role:assignTask(agent)`; if a
   task exists, `agent:run()`; otherwise sleeps briefly (nothing assignable).
4. `sleep(0)` to yield.

- **Parameters:** none.
- **Returns:** never (infinite loop).
- **Side effects:** role loads; task execution side effects; mutates
  `state.current_state`, `agent.task`; `ROLE` logs.
- **Contract (Overmind live swap):** behaviour changes on a `ROLE_ASSIGN` without
  a reboot, discarding the in-flight task.
