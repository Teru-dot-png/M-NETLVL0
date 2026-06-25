# overseer/orders.lua — `getme` orders & ore-cluster dispatch

Source: [../../onet/overseer/orders.lua](../../onet/overseer/orders.lua)

## Purpose

`orders` handles operator `getme` retrieval orders and turtle ore reports. Its
**CORE** routine is `mergeOrCluster`: it collapses a swarm of individual ore
voxels into one running-average centroid so the overseer sends **one** turtle to a
vein instead of forty turtles to forty blocks. Port that math exactly — it's the
difference between a fleet and a mob.

### Key constants

- `cfg.CLUSTER_RADIUS` (4) — manhattan radius within which separate ore sightings
  of the same ore merge into one cluster.
- `cfg.ORE_FEED_MAX` (8) — size of the live ore-feed ring buffer.

## Place in the architecture

`handleOreReport`/`handleOreMined` are driven by `ORE_REPORT`/`ORE_MINED` via
[director](director.md). `orderThread` is launched supervised by
[overseer.run](overseer.md). Dispatch picks targets with
[fleet.nearestIdle](fleet.md) and locates ore with
[voxelmap.findOreInMap](voxelmap.md); ore names are normalized via
[lib/blocks.md](../lib/blocks.md). The turtle-side recipients are the `GOTO`
([role_miner](../turtle/roles/role_miner.md)/[task_goto](../turtle/tasks/task_goto.md))
and `SEARCH_JOB` ([role_scout](../turtle/roles/role_scout.md)) handlers. State:
`state.ORE_FEED`, `state.clusters`, `state.ore_log`, `state.active_orders`,
`state.WANT_LIST`.

---

## `M.pushOreFeed(ore, hwid, x, y, z)`

**Signature:** `orders.pushOreFeed(ore, hwid, x, y, z)`

Appends a timestamped entry to the `state.ORE_FEED` display ring buffer, trimming
to `cfg.ORE_FEED_MAX`.

- **Parameters:** `ore` (string); `hwid` (string); `x`, `y`, `z` (number).
- **Returns:** nothing.
- **Side effects:** mutates `state.ORE_FEED` (bounded).
- **Used by:** [cockpit](cockpit.md) ticker, [terminal](terminal.md) `feed`.

## `M.mergeOrCluster(ore, x, y, z)` (CORE)

**Signature:** `orders.mergeOrCluster(ore, x, y, z) -> cluster`

Running-average centroid clustering. Searches `state.clusters` for an existing
cluster of the same `ore` within `cfg.CLUSTER_RADIUS` (manhattan). If found, it
increments `count` and updates the centroid `(cx,cy,cz)` to the rounded running
mean. Otherwise it creates a new cluster `{ore, cx, cy, cz, count=1,
dispatched=false}`.

- **Parameters:** `ore` (string, normalized); `x`, `y`, `z` (number).
- **Returns:** the merged or newly-created cluster.
- **Side effects:** mutates `state.clusters`.
- **Contract/invariant:** the centroid is the *incremental* mean
  `floor((cx*(n-1)+x)/n + 0.5)`, so one turtle is sent to the vein's centre rather
  than many to scattered blocks. The `+0.5` rounds to nearest integer.

## `M.handleOreReport(msg)`

**Signature:** `orders.handleOreReport(msg)`

Handles `ORE_REPORT`. Validates `msg.ore`/`msg.pos`; normalizes the ore name;
bumps `state.ore_log[ore]`; pushes the ore feed. If the ore is on
`state.WANT_LIST`, it clusters the sighting and — if that cluster is not yet
`dispatched` — marks it dispatched, finds the nearest idle turtle
([fleet.nearestIdle](fleet.md)), and sends it a `GOTO` to the cluster centroid.

- **Parameters:** `msg` (table) — `msg.ore`, `msg.pos {x,y,z}`, `msg.hwid`.
- **Returns:** nothing.
- **Side effects:** mutates `state.ore_log`, `state.ORE_FEED`, `state.clusters`;
  may `rednet.send` of `GOTO`; logs on dispatch.
- **Contract:** the `dispatched` latch ensures one turtle per vein; it is cleared
  again by `handleOreMined` when that area is mined, allowing re-dispatch.

## `M.handleOreMined(msg)`

**Signature:** `orders.handleOreMined(msg)`

Handles `ORE_MINED`. For every active `getme` order whose ore name overlaps the
mined ore, if the mined cell key matches a pending job it clears that job and
increments `order.got`. It then re-opens any cluster of that ore within
`cfg.CLUSTER_RADIUS` of the mined cell (`cl.dispatched = false`) so the area can
be re-dispatched.

- **Parameters:** `msg` (table) — `msg.ore`, `msg.pos {x,y,z}`.
- **Returns:** nothing.
- **Side effects:** mutates `state.active_orders[*].jobs/got` and
  `state.clusters[*].dispatched`; logs order progress.

## `M.countInDump(ore)`

**Signature:** `orders.countInDump(ore) -> number`

Counts how many of `ore` are currently in the operator vault (`state.vault`),
matching by substring. Returns 0 if no vault or the `list` call fails.

- **Parameters:** `ore` (string).
- **Returns:** integer count.
- **Side effects:** none (read-only `pcall(vault.list)`).

## `M.startGetme(ore, target)`

**Signature:** `orders.startGetme(ore, target) -> ok, err`

Begins a `getme` order. Normalizes the ore, validates `target > 0`, creates
`state.active_orders[ore] = {target, got=0, jobs={}}`, logs current dump/map
counts, and — if the dump already has enough — completes the order immediately
(clears it).

- **Parameters:** `ore` (string); `target` (number|string).
- **Returns:** `true`, or `false, "Usage: getme <ore> <count>"` on bad input.
- **Side effects:** mutates `state.active_orders`; `log("OVERSEER", …)`.
- **Used by:** [terminal](terminal.md) `getme` command.

## `M.orderThread()`

**Signature:** `orders.orderThread()` (loops forever)

The order driver. Every 3 s, for each active order: if `max(got, dumpCount) >=
target` the order is complete and removed. Otherwise it computes how many more
jobs to issue (`target - have - pending`), pulls nearest-first ore locations from
[voxelmap.findOreInMap](voxelmap.md) (relative to the view centre), and for each
un-jobbed location dispatches a `SEARCH_JOB` to the nearest idle turtle, marking
that location pending.

- **Parameters:** none.
- **Returns:** nothing (loops forever).
- **Side effects:** mutates `state.active_orders[*].jobs`; `rednet.send` of
  `SEARCH_JOB`; logs completion.
- **Contract:** `slots = (target - have) - pending` bounds outstanding jobs so the
  overseer never over-dispatches a `getme`; jobs are keyed by cell so the same
  block isn't assigned twice.
