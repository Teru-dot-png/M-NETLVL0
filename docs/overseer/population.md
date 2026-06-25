# overseer/population.lua — Self-replication population control

Source: [../../onet/overseer/population.lua](../../onet/overseer/population.lua)

## Purpose

`population` enforces the fleet size cap and authorizes Genesis crafting (§7.4).
It is a **hard cap with replace-on-loss**: a Genesis craft is authorized only
while `live_count < target_fleet`. When a turtle goes silent past
`cfg.LOSS_TIMEOUT`, [fleet.pruneLost](fleet.md) drops the live count and frees
exactly one replacement slot. The fleet therefore self-heals to N turtles but
never exceeds N.

### Key constants

- `cfg.TARGET_FLEET` (6) — the default hard cap (mutable at runtime via `setTarget`
  / the `setpop` command; stored in `state.target_fleet`).
- `cfg.LOSS_TIMEOUT` (60000 ms) — silence after which a turtle is declared dead
  (applied in [fleet.liveCount](fleet.md) / `pruneLost`).

## Place in the architecture

`tick` is the single chokepoint that toggles craft authorization. It is called
after `AUTH_REQ` and `CRAFT_DONE` ([director](director.md)), after a prune
([director.prunerThread](director.md)), and after `setpop` ([terminal](terminal.md)).
The `CRAFT_AUTH` message it sends gates the turtle-side
[role_genesis.md](../turtle/roles/role_genesis.md) and its
[task_craft.md](../turtle/tasks/task_craft.md). State touched:
`state.target_fleet`, `state.craft_authorized`, `state.genesis_hwid`.

---

## `M.setTarget(n)`

**Signature:** `population.setTarget(n) -> ok, err`

Sets the target fleet size. Coerces `n` to a number; rejects nil/negative with a
usage string. On success floors it into `state.target_fleet` and logs.

- **Parameters:** `n` (number|string) — the new target.
- **Returns:** `true` on success; `false, "Usage: setpop <n>"` on bad input.
- **Side effects:** mutates `state.target_fleet`; `log("OVERSEER", …)`.
- **Note:** the caller ([terminal](terminal.md)) runs `tick` afterward so the new
  cap takes immediate effect.

## `M.shouldCraft()`

**Signature:** `population.shouldCraft() -> boolean`

Authorization predicate: `fleet.liveCount() < state.target_fleet`.

- **Parameters:** none.
- **Returns:** boolean — whether a new turtle is authorized right now.
- **Side effects:** none.
- **Contract:** the comparison uses the **live** count (LOSS_TIMEOUT-aware), so a
  dead-but-not-yet-pruned turtle still counts until pruned, preventing premature
  over-crafting.

## `findGenesis()` (module local)

**Signature:** `findGenesis() -> hwid, f | nil`

Returns the first crafty (Genesis-capable) turtle in the roster, or `nil` if none
is enlisted.

- **Parameters:** none.
- **Returns:** `hwid` (string) and its fleet record `f`, or `nil`.
- **Side effects:** none.

## `M.tick()`

**Signature:** `population.tick()`

The authorization gate. Finds the Genesis turtle (returns silently if none).
Computes `shouldCraft()`; if that differs from `state.craft_authorized`, it
updates the flag and sends a `CRAFT_AUTH { authorized }` message to the Genesis
turtle, logging the new state with the live/target counts.

- **Parameters:** none.
- **Returns:** nothing.
- **Side effects:** may mutate `state.craft_authorized`; may `rednet.send` of
  `CRAFT_AUTH`; `log("GENESIS", …)` on a change.
- **Contract/invariant (never exceed N):**
  - Authorization is **edge-triggered** — `CRAFT_AUTH` is only resent when the
    boolean flips, so the Genesis turtle isn't spammed.
  - Because authorization keys on `live_count < target_fleet`, Genesis stops the
    instant the fleet reaches N and only resumes after a *loss* re-opens a slot —
    this is the replace-on-loss contract.
  - Genesis must never consume the last turtle base (the operator-supplied
    ender-pearl/eye and base stock are the manual gate); the overseer simply never
    authorizes a craft that would push the population past `target_fleet`.
