# turtle/tasks/task_fuel.lua — RTB_FUEL task

Source: [../../../onet/turtle/tasks/task_fuel.lua](../../../onet/turtle/tasks/task_fuel.lua)

## Purpose

The RTB_FUEL sequence (§4): ask the overseer for the nearest coal, mine it,
return to base, refuel up to (**not over**) `FUEL_TARGET`, dump the excess coal
into the base chest, then return to the position the turtle left. Falls back to
local foraging if the overseer has no coal location yet.

## Place in the task-chain model

A leaf sequence task built on [`Task`](task.md), issued by `role_miner`,
`role_hauler`, `role_scout`, `role_builder` (low-fuel branch) and re-issued
continuously by `role_refuel`. Maps to **RTB_FUEL** (priority 2), set by the
role. The whole flow is one `work()` with a `resume_pos` capture so the turtle
goes back to exactly where it was.

Depends on [task](task.md), [config](../../config.md), [state](../state.md),
[nav](../nav.md), [movers](../movers.md), [fuel](../fuel.md),
[vec](../../lib/vec.md), [log](../../lib/log.md). `blocks` is lazy-required
inside `work` (`require("blocks")`) for the burnable check.

---

## `M.new(resume_pos, opts)`

**Signature:** `task_fuel.new(resume_pos, opts) -> task`

Constructs the fuel task via `Task.new("fuel", true, opts)` (target is the
literal `true`). It overrides only **`t:work()`** (no `isValidTarget` override —
it inherits the base, which is true while `target ~= nil`, i.e. always). Steps:

1. **Capture resume.** `resume = resume_pos or vec.copy(state.pos)`; log the
   current fuel level.
2. **Query coal.** Clear `state.coal_loc = nil`. If `state.server_id`, send
   `{ type="COAL_QUERY", hwid, pos }` and wait up to 2500 ms (epoch deadline,
   `sleep(0.2)` poll) for `state.coal_loc` to arrive.
3. **Mine coal.** If `state.coal_loc`: log it, `nav.moveTo({x, y+1, z})` above
   it and `movers.digSafeDown()`, then `fuel.burnAboard(cfg.FUEL_TARGET)`. If
   still below target (`fuel.fuelLevel() < cfg.FUEL_TARGET`),
   `fuel.forageForCoal()` as a fallback.
4. **Base top-up + dump excess.** If `state.base`: `nav.moveTo({x, y+1, z})`
   above the base chest; `fuel.burnAboard(cfg.FUEL_TARGET)` (refuel up to, not
   over, target); then for each cargo slot 3..16, `turtle.getItemDetail(s)` and
   if `require("blocks").isFuel(d.name)`, `turtle.select(s)` + `turtle.dropDown()`
   to deposit leftover burnables; finally `turtle.select(cfg.CARGO_FIRST)`.
5. **Resume.** `nav.moveTo(resume)`, `movers.face(state.my_dir)`,
   `self.done = true`, return `true`.

- **Parameters:**
  - `resume_pos` (optional) — where to return after refuelling; defaults to the
    current position at construction-call time inside `work`.
  - `opts` (optional) — passed to `Task.new`.
- **Returns:** the task.
- **Side effects (when run):** navigation; `movers.digSafeDown`; `fuel.burnAboard`
  / `fuel.forageForCoal` (consumes fuel items, raises fuel level);
  `turtle.select`/`getItemDetail`/`dropDown` for excess-coal deposit; network
  send (`COAL_QUERY`); mutates `state.coal_loc`; `FUEL` logs; `sleep` on the
  coal-query wait.
- **State mapping:** **RTB_FUEL** (2) — set by the issuing role.
- **Contracts touched:**
  - **Refuel cap** — `fuel.burnAboard(cfg.FUEL_TARGET)` tops up to but not over
    `FUEL_TARGET`.
  - **Slot protection (§1.1)** — the excess-coal dump loop iterates only cargo
    slots `CARGO_FIRST..CARGO_LAST` (3..16); slot 1 (scanner) and slot 2
    (pickaxe) are never selected/dropped. `getItemDetail` is only ever called on
    cargo slot numbers here.

---

## Functions documented: 1

`M.new` (with the `work` override).
