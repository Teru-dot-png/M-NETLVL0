--[[
    M-NET V3 | MINER NODE  (with A* pathfinding + protected block list)
    ====================================================================
    Hardware:
        RIGHT slot : Ender Modem     (permanent, comms)
        LEFT  slot : Diamond Pickaxe (default; hot-swapped with scanner during scans)
        SLOT 16    : Geo Scanner item (reserved; never used for cargo)
        Fuel       : start with some coal; turtle sustains itself after boot

    Navigation:
        All movement goes through moveTo() which plans via A* on a live world
        cache, executes step by step, and re-plans on any mid-path failure.
        Protected blocks (computers, chests, Create machines, etc.) are hard
        walls in the planner and are never broken.

    Boot order:
        1. Check pickaxe is equipped (swap-recover from slot 16 if possible)
        2. Burn any coal aboard; wait/forage until FUEL_TARGET reached
        3. GPS calibrate heading (one forward step)
        4. Post-calibrate coal forage if still below target
        5. Enlist with Overseer, broadcast position
        6. Standby until CMD_START

    REQUIRES: working GPS constellation in this dimension.
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
local PROTOCOL      = "MNET_V3"
local SCAN_RADIUS   = 8      -- geo scanner radius
local SCAN_EVERY    = 4      -- tunnel blocks between each geo scan
local HEARTBEAT_INT = 3      -- seconds between heartbeats
local FUEL_MIN      = 200    -- top up from mined coal below this
local FUEL_TARGET   = 500    -- wake-up goal before starting work
local FORAGE_MAX    = 32     -- max blocks to dig hunting coal at wake-up
local FUEL_CRITICAL = 80     -- crawl to BASE_CHEST if below this with nothing to burn
local MAX_TUNNEL    = 256    -- blocks before heading home
local SCANNER_SLOT  = 16     -- reserved slot for the geo scanner item
local NAV_MAX_NODES = 6000   -- A* node budget per search
local NAV_MAX_RANGE = 320    -- refuse to plan beyond this many blocks

-- ============================================================
-- STATE
-- ============================================================
local hwid           = string.format("MN-%04X", os.getComputerID() % 0xFFFF)
local server_id      = nil
local dump           = nil
local base           = nil
local my_dir         = 0
local started        = false
local home_requested = false
local has_scanner    = false
local jobs           = {}
local reported       = {}

-- Dead-reckoning position + facing
local pos    = { x = 0, y = 0, z = 0 }
local facing = 0
-- facing: 0=N(-z)  1=E(+x)  2=S(+z)  3=W(-x)
local DIRV = {
    [0] = { dx = 0,  dz = -1 },
    [1] = { dx = 1,  dz =  0 },
    [2] = { dx = 0,  dz =  1 },
    [3] = { dx = -1, dz =  0 },
}

-- ============================================================
-- HELPERS
-- ============================================================
local function copy(p) return { x = p.x, y = p.y, z = p.z } end
local function key(p)  return p.x .. ":" .. p.y .. ":" .. p.z end
local function shortName(n) return (n:match(":(.+)") or n) end

local function log(tag, msg)
    print(string.format("[%-6s] %s", tag, msg))
end

-- ============================================================
-- FUEL
-- ============================================================
local function fuelLevel()
    local f = turtle.getFuelLevel()
    return f == "unlimited" and math.huge or (tonumber(f) or 0)
end

local function burnAboard(target)
    for slot = 1, 15 do
        if fuelLevel() >= target then break end
        turtle.select(slot)
        if turtle.refuel(0) then turtle.refuel() end
    end
    turtle.select(1)
end

local function refuelSelf()
    if fuelLevel() < FUEL_MIN then burnAboard(FUEL_MIN) end
end

-- ============================================================
-- LAVA / FLUID DETECTION  (correct two-return handling)
-- ============================================================
local function blockIsFluid(ok, data)
    if not ok or type(data) ~= "table" then return false end
    local n = data.name or ""
    return n:find("lava") ~= nil or n:find("water") ~= nil
end

local function isLavaAhead()  local ok,d = turtle.inspect()    return blockIsFluid(ok,d) end
local function isLavaUp()     local ok,d = turtle.inspectUp()  return blockIsFluid(ok,d) end
local function isLavaDown()   local ok,d = turtle.inspectDown() return blockIsFluid(ok,d) end

-- ============================================================
-- PROTECTED BLOCK CLASSIFIER
-- Diggable  = stone variants, rock, ores, dirt, sand, gravel.
-- Protected = everything else; turtle never breaks these.
-- ============================================================
local DIGGABLE_PATTERNS = {
    "stone","granite","diorite","andesite","deepslate","tuff","calcite",
    "dripstone","basalt","blackstone","netherrack","end_stone","sandstone",
    "cobblestone","mossy_cobblestone","cobbled_deepslate",
    "gravel","dirt","sand","clay","mud","soul_sand","soul_soil",
    "_ore","raw_block",
}
local NEVER_BREAK_PATTERNS = {
    -- ComputerCraft
    "computer","turtle","monitor","speaker","printer","disk_drive","modem",
    "cable","wired_modem",
    -- Storage
    "chest","barrel","hopper","dropper","dispenser","shulker","ender_chest",
    -- Create
    "create:","mechanical_","cogwheel","shaft","gearbox","bearing",
    "deployer","encased","schematic","contraption","fluid_tank",
    "valve","pump","funnel","chute","belt","vault","interface",
    "andesite_casing","brass_casing","copper_casing",
    -- AE2 / RS
    "appeng:","refinedstorage:","bus","drive","controller","terminal",
    -- Misc dangerous / irreplaceable
    "lava","water","fire","portal","bedrock","barrier",
    "command_block","structure_block","spawner","mob_spawner",
    "reinforced_deepslate",
}

local function isDiggable(name)
    if not name or name == "" or name:find("air") then return false end
    for _, pat in ipairs(NEVER_BREAK_PATTERNS) do
        if name:find(pat, 1, true) then return false end
    end
    for _, pat in ipairs(DIGGABLE_PATTERNS) do
        if name:find(pat, 1, true) then return true end
    end
    return false   -- unknown block: safe default is "do not break"
end

local function isPassable(name)
    return name == nil or name == "" or name:find("air") ~= nil
end

-- ============================================================
-- WORLD MODEL CACHE
-- Fed by geo scanner snapshots. A* queries this to know what
-- is at a coordinate before deciding to include it in a path.
-- ============================================================
local world_cache = {}
local cache_size  = 0

local function cacheSet(x, y, z, name)
    local k = x..":"..y..":"..z
    if not world_cache[k] then cache_size = cache_size + 1 end
    world_cache[k] = name
end

local function cacheGet(x, y, z)
    return world_cache[x..":"..y..":"..z]
end

-- Feed a geo scan result table into the cache (offsets relative to origin).
local function feedCache(scan, origin)
    if type(scan) ~= "table" or type(origin) ~= "table" then return end
    for _, b in ipairs(scan) do
        if type(b) == "table" and type(b.name) == "string" then
            cacheSet(
                math.floor(origin.x + (b.x or 0)),
                math.floor(origin.y + (b.y or 0)),
                math.floor(origin.z + (b.z or 0)),
                b.name)
        end
    end
end

-- Live-inspect the three faces the turtle can see and cache them.
local function liveInspect()
    local function store(ok, data, nx, ny, nz)
        if ok and type(data) == "table" and data.name then
            cacheSet(nx, ny, nz, data.name)
        elseif not ok then
            cacheSet(nx, ny, nz, "air")
        end
    end
    local dx = DIRV[facing].dx
    local dz = DIRV[facing].dz
    -- Capture both return values explicitly so they do not bleed into nx/ny/nz.
    local ok_f, dat_f = turtle.inspect()
    local ok_u, dat_u = turtle.inspectUp()
    local ok_d, dat_d = turtle.inspectDown()
    store(ok_f, dat_f, pos.x+dx, pos.y,   pos.z+dz)
    store(ok_u, dat_u, pos.x,    pos.y+1, pos.z)
    store(ok_d, dat_d, pos.x,    pos.y-1, pos.z)
end

-- ============================================================
-- PICKAXE / MODEM SLOT DETECTION
-- The modem can be on left OR right. The pickaxe goes on the
-- other side. We detect which is which at runtime.
-- ============================================================

-- Returns "left", "right", or nil depending on which side has the modem.
local function modemSide()
    if peripheral.wrap("left")  and peripheral.getType("left")  == "modem" then return "left"  end
    if peripheral.wrap("right") and peripheral.getType("right") == "modem" then return "right" end
    -- Ender modem may report a different type string; check both sides for any modem.
    if peripheral.wrap("left")  then return "left"  end
    if peripheral.wrap("right") then return "right" end
    return nil
end

-- The pickaxe side is whichever side does NOT have the modem.
local function pickaxeSide()
    local ms = modemSide()
    if ms == "left"  then return "right" end
    if ms == "right" then return "left"  end
    return "left"   -- no modem found: default to left
end

local function leftIsPeripheral()
    return peripheral.wrap("left") ~= nil
end

-- Returns true if the pickaxe side currently holds a pickaxe (not a peripheral).
local function pickaxeEquipped()
    local pside = pickaxeSide()
    -- If the pickaxe side has a peripheral on it, it is NOT a pickaxe.
    if peripheral.wrap(pside) ~= nil then return false end
    -- CC:T 1.109+ exposes getEquippedLeft / getEquippedRight
    local getEquipped = pside == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
    if getEquipped then
        local info = getEquipped()
        if info == nil then return false end
        return tostring(info.name or ""):find("pickaxe") ~= nil
    end
    -- Older CC:T: non-peripheral side assumed to hold the pickaxe.
    return true
end

-- Equip item from the currently selected slot onto the pickaxe side.
local function equipOnPickaxeSide()
    if pickaxeSide() == "left" then
        return turtle.equipLeft()
    else
        return turtle.equipRight()
    end
end

-- ============================================================
-- PRIMITIVE MOVERS  (used by A* executor only; respect protected blocks)
-- ============================================================
local function turnRight() turtle.turnRight(); facing = (facing + 1) % 4 end
local function turnLeft()  turtle.turnLeft();  facing = (facing + 3) % 4 end

local function face(target)
    if facing == target then return end
    while facing ~= target do
        if (target - facing) % 4 == 1 then turnRight() else turnLeft() end
    end
end

-- Dig in front if safe (never breaks protected blocks). Returns true if clear.
local function digSafe()
    local ok, data = turtle.inspect()
    if not ok then return true end
    local name = type(data) == "table" and data.name or ""
    cacheSet(pos.x + DIRV[facing].dx, pos.y, pos.z + DIRV[facing].dz, name)
    if isPassable(name) then return true end
    if not isDiggable(name) then
        log("NAV", "PROTECTED: will not break [" .. name .. "]")
        cacheSet(pos.x + DIRV[facing].dx, pos.y, pos.z + DIRV[facing].dz, name) -- keep as wall
        return false
    end
    for _ = 1, 10 do
        turtle.dig()
        local ok2, _ = turtle.inspect()
        if not ok2 then
            cacheSet(pos.x + DIRV[facing].dx, pos.y, pos.z + DIRV[facing].dz, "air")
            return true
        end
        sleep(0.1)
    end
    return false
end

local function digSafeUp()
    local ok, data = turtle.inspectUp()
    if not ok then return true end
    local name = type(data) == "table" and data.name or ""
    cacheSet(pos.x, pos.y + 1, pos.z, name)
    if isPassable(name) then return true end
    if not isDiggable(name) then
        log("NAV", "PROTECTED (up): will not break [" .. name .. "]")
        return false
    end
    for _ = 1, 10 do
        turtle.digUp()
        local ok2, _ = turtle.inspectUp()
        if not ok2 then cacheSet(pos.x, pos.y + 1, pos.z, "air"); return true end
        sleep(0.1)
    end
    return false
end

local function digSafeDown()
    local ok, data = turtle.inspectDown()
    if not ok then return true end
    local name = type(data) == "table" and data.name or ""
    cacheSet(pos.x, pos.y - 1, pos.z, name)
    if isPassable(name) then return true end
    if not isDiggable(name) then
        log("NAV", "PROTECTED (dn): will not break [" .. name .. "]")
        return false
    end
    for _ = 1, 10 do
        turtle.digDown()
        local ok2, _ = turtle.inspectDown()
        if not ok2 then cacheSet(pos.x, pos.y - 1, pos.z, "air"); return true end
        sleep(0.1)
    end
    return false
end

local function stepForward()
    liveInspect()
    if isLavaAhead() then return false end
    if turtle.forward() then
        pos.x = pos.x + DIRV[facing].dx
        pos.z = pos.z + DIRV[facing].dz
        return true
    end
    if not digSafe() then return false end
    if turtle.forward() then
        pos.x = pos.x + DIRV[facing].dx
        pos.z = pos.z + DIRV[facing].dz
        return true
    end
    return false
end

local function stepUp()
    if isLavaUp() then return false end
    if turtle.up() then pos.y = pos.y + 1; return true end
    if not digSafeUp() then return false end
    if turtle.up() then pos.y = pos.y + 1; return true end
    return false
end

local function stepDown()
    if isLavaDown() then return false end
    if turtle.down() then pos.y = pos.y - 1; return true end
    if not digSafeDown() then return false end
    if turtle.down() then pos.y = pos.y - 1; return true end
    return false
end

-- ============================================================
-- TUNNEL FORWARD  (during mining: digs anything that isn't lava/fluid)
-- Separate from nav movers so protected-block logic never fires during mining.
-- ============================================================
local function forward()
    liveInspect()
    if isLavaAhead() then log("MINE","Lava ahead. Skipping."); return false end
    if turtle.forward() then
        pos.x = pos.x + DIRV[facing].dx
        pos.z = pos.z + DIRV[facing].dz
        return true
    end
    if not turtle.detect() then return false end
    for i = 1, 64 do
        if not turtle.dig() then turtle.attack() end
        if turtle.forward() then
            pos.x = pos.x + DIRV[facing].dx
            pos.z = pos.z + DIRV[facing].dz
            return true
        end
        sleep(0.15)
    end
    return false
end

-- ============================================================
-- NAVIGATION CORE  (refactored)
-- ============================================================
-- Philosophy: move greedily toward the goal using GPS as ground
-- truth. Each step:
--   1. Check the block ahead with inspect() BEFORE moving.
--   2. If air -> move freely.
--   3. If diggable stone/ore -> dig and move.
--   4. If protected -> try a different axis.
--   5. Only use A* for short-range detours (<=16 blocks) around
--      a cluster of protected blocks.
-- This means the turtle navigates ANY pre-dug tunnel instantly
-- because it sees air, moves, no planning needed.
-- Unknown blocks are treated as diggable (optimistic), which
-- is correct for a mining turtle in natural terrain.
-- ============================================================

-- ── Cost function for the short-range A* detour only ──────
-- Unknown = 1 (treat as air; we will discover it on arrival)
-- Air     = 1
-- Diggable= 3
-- Protected/fluid = nil (never enter)
local function navCost(nx, ny, nz)
    local name = cacheGet(nx, ny, nz)
    if name == nil        then return 1  end  -- unknown: assume passable
    if isPassable(name)   then return 1  end  -- air: free
    if isDiggable(name)   then return 3  end  -- stone: costs a dig
    return nil                                -- protected: never enter
end

-- ── Tiny binary min-heap ──────────────────────────────────
local function newHeap() return { n = 0 } end
local function heapPush(h, node, pri)
    local i = h.n + 1; h.n = i; h[i] = { node = node, p = pri }
    while i > 1 do
        local p = math.floor(i / 2)
        if h[p].p > h[i].p then h[p], h[i] = h[i], h[p]; i = p else break end
    end
end
local function heapPop(h)
    if h.n == 0 then return nil end
    local top = h[1].node
    h[1] = h[h.n]; h[h.n] = nil; h.n = h.n - 1
    local i = 1
    while true do
        local l, r, s = i*2, i*2+1, i
        if l <= h.n and h[l].p < h[s].p then s = l end
        if r <= h.n and h[r].p < h[s].p then s = r end
        if s == i then break end
        h[i], h[s] = h[s], h[i]; i = s
    end
    return top
end

local DIRS6 = {
    {dx=0,dy=0,dz=-1,dir=0},{dx=1,dy=0,dz=0,dir=1},
    {dx=0,dy=0,dz=1,dir=2},{dx=-1,dy=0,dz=0,dir=3},
    {dx=0,dy=1,dz=0,dir=-1},{dx=0,dy=-1,dz=0,dir=-2},
}

-- Short-range A* for detours around obstacles (max 16 block radius).
local DETOUR_BUDGET = 512
local function astarLocal(start, goal)
    local function h(n)
        return math.abs(n.x-goal.x)+math.abs(n.y-goal.y)+math.abs(n.z-goal.z)
    end
    local open = newHeap()
    local g_cost, came = {}, {}
    local sk = key(start)
    g_cost[sk] = 0
    heapPush(open, start, h(start))
    local expanded = 0
    while open.n > 0 do
        local cur = heapPop(open)
        local ck  = key(cur)
        expanded  = expanded + 1
        if expanded > DETOUR_BUDGET then return nil end
        if cur.x==goal.x and cur.y==goal.y and cur.z==goal.z then
            local path, k = {}, ck
            while came[k] do table.insert(path,1,came[k].step); k=came[k].pk end
            return path
        end
        local g = g_cost[ck]
        for _, nb in ipairs(DIRS6) do
            local nx,ny,nz = cur.x+nb.dx, cur.y+nb.dy, cur.z+nb.dz
            local nc = navCost(nx,ny,nz)
            if nc then
                local nk = nx..":"..ny..":"..nz
                local ng = g + nc
                if not g_cost[nk] or ng < g_cost[nk] then
                    g_cost[nk] = ng
                    came[nk] = { pk=ck, step={dx=nb.dx,dy=nb.dy,dz=nb.dz,dir=nb.dir} }
                    heapPush(open, {x=nx,y=ny,z=nz}, ng+h({x=nx,y=ny,z=nz}))
                end
            end
        end
    end
    return nil
end

-- Execute a short A* path (used only for local detours).
local function executeDetour(path, goal)
    for _, step in ipairs(path) do
        local ok
        if     step.dy ==  1 then ok = stepUp()
        elseif step.dy == -1 then ok = stepDown()
        else face(step.dir);  ok = stepForward() end
        if not ok then return false end
        sleep(0)
    end
    return pos.x==goal.x and pos.y==goal.y and pos.z==goal.z
end

-- ── GREEDY AXIS NAVIGATOR ────────────────────────────────
-- Tries each axis largest-first. Inspects before moving.
-- Skips an axis if a protected block is in the way.
-- Returns "moved", "stuck", or "arrived".
local function greedyStep(goal)
    if pos.x==goal.x and pos.y==goal.y and pos.z==goal.z then return "arrived" end

    local dx = goal.x - pos.x
    local dy = goal.y - pos.y
    local dz = goal.z - pos.z

    -- axes: { distance, facing_dir_or_nil, "h"/"u"/"d" }
    local axes = {
        { math.abs(dx), dx~=0 and (dx>0 and 1 or 3) or nil, "h" },
        { math.abs(dz), dz~=0 and (dz>0 and 2 or 0) or nil, "h" },
        { math.abs(dy), nil, dy>0 and "u" or "d" },
    }
    table.sort(axes, function(a,b) return a[1]>b[1] end)

    for _, ax in ipairs(axes) do
        if ax[1] > 0 then
            local skip = false
            if ax[3] == "u" then
                if stepUp() then return "moved" end
            elseif ax[3] == "d" then
                if stepDown() then return "moved" end
            else
                face(ax[2])
                local ok_i, dat_i = turtle.inspect()
                if ok_i and type(dat_i) == "table" then
                    local name = dat_i.name or ""
                    cacheSet(pos.x+DIRV[facing].dx, pos.y, pos.z+DIRV[facing].dz, name)
                    if not isPassable(name) and not isDiggable(name) then
                        log("NAV", "Protected ["..name.."] on axis. Trying next.")
                        skip = true
                    end
                end
                if not skip then
                    if stepForward() then return "moved" end
                end
            end
        end
    end
    return "stuck"
end

-- ── MAIN moveTo ──────────────────────────────────────────
-- Greedy navigation with local A* detours for obstacles.
-- Never gives up on a long tunnel: just keeps stepping.
function moveTo(goal)
    if pos.x==goal.x and pos.y==goal.y and pos.z==goal.z then return true end

    log("NAV", string.format("Nav to (%d,%d,%d) from (%d,%d,%d)",
        goal.x, goal.y, goal.z, pos.x, pos.y, pos.z))

    local stuck_count = 0
    local MAX_STUCK   = 6      -- consecutive stuck steps before trying A* detour
    local MAX_DETOURS = 8      -- total detours before giving up
    local detours     = 0
    local last_pos    = nil

    while pos.x~=goal.x or pos.y~=goal.y or pos.z~=goal.z do

        -- Check for CMD_RECALL mid-journey
        if home_requested then return false end

        liveInspect()
        local result = greedyStep(goal)

        if result == "arrived" then
            break
        elseif result == "moved" then
            stuck_count = 0
            last_pos    = copy(pos)
            sleep(0)
        else
            stuck_count = stuck_count + 1
            log("NAV", string.format("Stuck step %d/%d at (%d,%d,%d)",
                stuck_count, MAX_STUCK, pos.x, pos.y, pos.z))

            if stuck_count >= MAX_STUCK then
                stuck_count = 0
                detours     = detours + 1
                log("NAV", string.format("Trying A* detour %d/%d...", detours, MAX_DETOURS))

                -- Scan to populate the local cache before planning
                if has_scanner then
                    local snap = scanAround()
                    feedCache(snap, pos)
                end

                -- Plan a short detour to a waypoint 3 blocks past the goal
                -- in the goal direction, to get around whatever is blocking
                local path = astarLocal(pos, goal)
                if path and #path > 0 then
                    log("NAV", string.format("Detour: %d steps.", #path))
                    if not executeDetour(path, goal) then
                        log("NAV", "Detour execution failed. Retrying greedy.")
                    end
                else
                    log("NAV", "A* detour found no path. All routes protected or blocked.")
                    if detours >= MAX_DETOURS then
                        log("NAV", "Max detours reached. Reporting STUCK.")
                        pcall(rednet.send, server_id, {
                            type = "ALERT", hwid = hwid,
                            msg  = string.format("STUCK at (%d,%d,%d) -> (%d,%d,%d)",
                                pos.x, pos.y, pos.z, goal.x, goal.y, goal.z),
                            pos  = copy(pos),
                        }, PROTOCOL)
                        return false
                    end
                    -- Wait and retry; something might clear
                    sleep(2)
                end
            else
                sleep(0.3)
            end
        end
    end

    local arrived = pos.x==goal.x and pos.y==goal.y and pos.z==goal.z
    if arrived then
        log("NAV", string.format("Arrived at (%d,%d,%d).", goal.x, goal.y, goal.z))
    end
    return arrived
end

-- ============================================================
-- GPS
-- ============================================================
local function gpsPos()
    local x, y, z = gps.locate(2)
    if x then return { x = x, y = y, z = z } end
    return nil
end

-- Returns true if a pickaxe item detail is fresh enough for CC:T to equip.
-- CC:Tweaked ONLY equips undamaged, unenchanted diamond pickaxes.
-- A damaged or NBT-tagged pick will be silently rejected by equipLeft().
local function isEquippable(detail)
    if not detail then return false end
    if not tostring(detail.name or ""):find("pickaxe") then return false end
    -- Check for damage (durability loss). The field is named "damage" in CC:T.
    if (detail.damage or 0) > 0 then
        log("PICK", string.format("Pickaxe in slot has %d damage. CC:T needs a fresh, undamaged pick.", detail.damage))
        return false
    end
    -- Check for enchantments / NBT: enchanted picks are also unequippable.
    if detail.enchantments and #detail.enchantments > 0 then
        log("PICK", "Pickaxe is enchanted. CC:T cannot equip enchanted tools.")
        return false
    end
    return true
end
local function fetchPickaxeFromBase(resumePos)
    if not base then
        log("PICK", "No BASE_CHEST set. Cannot fetch pickaxe. Halting.")
        while true do sleep(5) end
    end
    log("PICK", "Heading to BASE_CHEST for a pickaxe...")

    if not moveTo({ x = base.x, y = base.y + 1, z = base.z }) then
        log("PICK", "Could not reach BASE_CHEST. Parking until rebooted.")
        while true do sleep(5) end
    end

    local function tryFetch()
        local chest = peripheral.wrap("bottom")
        if chest and chest.list then
            local contents = chest.list()
            for chestSlot, item in pairs(contents) do
                if tostring(item.name or ""):find("pickaxe") then
                    -- Read full detail to check damage/enchants before pulling.
                    local detail = chest.getItemDetail and chest.getItemDetail(chestSlot)
                    if detail and not isEquippable(detail) then
                        log("PICK", string.format("Slot %d: pickaxe rejected (damaged or enchanted). Need a fresh unenchanted one.", chestSlot))
                    else
                        log("PICK", string.format("Pickaxe in chest slot %d (%s). Pulling...", chestSlot, item.name))
                        for ts = 1, 15 do
                            if turtle.getItemCount(ts) == 0 then
                                turtle.select(ts)
                                turtle.suckDown(1)
                                local got = turtle.getItemDetail(ts)
                                if got and isEquippable(got) then
                                    turtle.select(ts)
                                    equipOnPickaxeSide()
                                    if pickaxeEquipped() then
                                        log("PICK", "Pickaxe equipped. OK")
                                        turtle.select(1)
                                        return true
                                    else
                                        log("PICK", "equipLeft silently failed (item still ineligible). Putting back.")
                                        turtle.dropDown()
                                    end
                                else
                                    log("PICK", "Pulled item is damaged/enchanted. Putting back.")
                                    turtle.select(ts)
                                    turtle.dropDown()
                                end
                                break
                            end
                        end
                    end
                end
            end
        else
            -- Fallback: no chest peripheral. Suck one at a time.
            for ts = 1, 15 do
                if turtle.getItemCount(ts) == 0 then
                    turtle.select(ts)
                    if not turtle.suckDown(1) then break end
                    local got = turtle.getItemDetail(ts)
                    if got and isEquippable(got) then
                        equipOnPickaxeSide()
                        if pickaxeEquipped() then
                            log("PICK", "Pickaxe equipped (fallback). OK")
                            turtle.select(1)
                            return true
                        end
                    end
                    log("PICK", "Item not usable as pickaxe upgrade. Putting back.")
                    turtle.dropDown()
                    break
                end
            end
        end
        return false
    end

    local fetched = tryFetch()
    if not fetched then
        log("PICK", "No pickaxe found in BASE_CHEST.")
        log("PICK", "Add a diamond pickaxe to the BASE_CHEST. Retrying every 10s...")
        while not fetched do
            sleep(10)
            fetched = tryFetch()
        end
    end

    if resumePos then moveTo(resumePos); face(my_dir) end
end

-- ============================================================
-- STEP 1: PICKAXE CHECK AT BOOT
-- Scans every inventory slot for a pickaxe by item name and equips it.
-- Whatever was previously on the left (e.g. the scanner) lands in that
-- slot; we then move it back to SCANNER_SLOT if it is the scanner.
-- ============================================================
local function checkPickaxeAtBoot()
    -- Already correctly equipped.
    if pickaxeEquipped() then
        log("INIT", "Pickaxe: equipped on left. OK")
        return true
    end

    -- If something is on the pickaxe side (scanner), unequip it to a free slot first.
    local pside = pickaxeSide()
    if peripheral.wrap(pside) ~= nil then
        log("INIT", "Peripheral on " .. pside .. " side. Moving to free slot...")
        for s = 1, 16 do
            if turtle.getItemCount(s) == 0 then
                turtle.select(s)
                if pside == "left" then turtle.equipLeft() else turtle.equipRight() end
                log("INIT", "Peripheral moved to slot " .. s)
                break
            end
        end
    end

    -- Now search all slots for an equippable pickaxe.
    log("INIT", "Searching all slots for a fresh pickaxe...")
    for s = 1, 16 do
        local detail = turtle.getItemDetail(s)
        if detail and tostring(detail.name or ""):find("pickaxe") then
            if not isEquippable(detail) then
                log("INIT", string.format("Slot %d: pickaxe rejected (damaged/enchanted). Need a fresh one.", s))
            else
                log("INIT", string.format("Pickaxe in slot %d. Equipping on %s side...", s, pside))
                turtle.select(s)
                equipOnPickaxeSide()
                if pickaxeEquipped() then
                    log("INIT", "Pickaxe equipped. OK")
                    turtle.select(1)
                    return true
                end
            end
        end
    end

    log("INIT", "No pickaxe found in inventory.")
    log("INIT", "Will fetch from BASE_CHEST after GPS + enlistment.")
    return false
end

-- ============================================================
-- STEP 2: FUEL WAKE-UP
-- ============================================================
local function wakeUp()
    log("WAKE", "Fuel check. Current = " .. tostring(turtle.getFuelLevel()))
    burnAboard(FUEL_TARGET)
    log("WAKE", "After burn. Fuel = " .. tostring(turtle.getFuelLevel()))

    if fuelLevel() == 0 then
        log("WAKE", "EMPTY. Drop coal in any cargo slot to continue...")
        while fuelLevel() == 0 do burnAboard(FUEL_TARGET); sleep(2) end
        log("WAKE", "Got fuel. Fuel = " .. tostring(turtle.getFuelLevel()))
    end

    if fuelLevel() < FUEL_TARGET then
        log("WAKE", string.format("Below target (%d). Will forage after GPS calibration.", FUEL_TARGET))
    else
        log("WAKE", "Fuel target reached.")
    end
end

-- Post-calibrate forage (heading is now known so pos tracking is safe)
local function forageForCoal()
    if fuelLevel() >= FUEL_TARGET then return end
    log("FUEL", string.format("Foraging for coal (up to %d blocks)...", FORAGE_MAX))
    local steps = 0
    while fuelLevel() < FUEL_TARGET and steps < FORAGE_MAX do
        if not forward() then break end
        steps = steps + 1
        burnAboard(FUEL_TARGET)
        if steps % 4 == 0 then
            log("FUEL", string.format("Foraging step %d fuel=%s", steps, tostring(turtle.getFuelLevel())))
        end
    end
    log("FUEL", string.format("Foraged %d blocks. Fuel = %s", steps, tostring(turtle.getFuelLevel())))
end

-- ============================================================
-- STEP 3: CALIBRATE HEADING
-- Strategy:
--   1. Get GPS fix before moving (p1).
--   2. Try each of the four cardinal directions in turn.
--      For each: attempt to move forward (dig if blocked by diggable rock).
--   3. Get GPS fix after the successful step (p2).
--   4. Derive heading from (p2 - p1). The facing variable does not
--      matter during the search; GPS tells us the truth afterwards.
-- ============================================================
local function calibrate()
    log("NAV", "Calibrating heading via GPS...")
    local p1 = gpsPos()
    if not p1 then
        error("[FATAL] No GPS fix. Build a GPS constellation first.", 0)
    end
    log("NAV", string.format("Pre-move GPS: (%d,%d,%d)", p1.x, p1.y, p1.z))

    local moved = false

    -- Try all four cardinal directions. Stop as soon as one works.
    for attempt = 0, 3 do
        log("NAV", string.format("Calibration attempt %d: trying to move forward...", attempt + 1))

        -- Attempt to move; if blocked, try digging once.
        local ok = turtle.forward()
        if not ok then
            local has_block, data = turtle.inspect()
            if has_block and type(data) == "table" then
                local name = data.name or ""
                if isDiggable(name) then
                    log("NAV", "Block ahead (" .. name .. "). Digging...")
                    turtle.dig()
                    sleep(0.2)
                    ok = turtle.forward()
                else
                    log("NAV", "Block ahead is protected or fluid: [" .. name .. "]. Turning.")
                end
            end
        end

        if ok then
            moved = true
            break
        end

        -- Could not move this direction. Turn right and try next.
        turtle.turnRight()
        -- We will fix `facing` from the GPS result, not from counting turns.
    end

    if not moved then
        -- Last resort: try up and down.
        if turtle.up() then
            -- Record as a vertical move; set a temporary known position.
            local p2 = gpsPos()
            if p2 then
                pos = copy(p2)
                -- Heading is unknown after a vertical move. Try moving horizontal now.
                for _ = 0, 3 do
                    if turtle.forward() then
                        local p3 = gpsPos()
                        if p3 then
                            local dx, dz = p3.x - p2.x, p3.z - p2.z
                            if     dx ==  1 then facing = 1
                            elseif dx == -1 then facing = 3
                            elseif dz ==  1 then facing = 2
                            elseif dz == -1 then facing = 0 end
                            pos = copy(p3)
                            log("NAV", string.format("Calibrated (via up+fwd): facing=%d pos=(%d,%d,%d)", facing, pos.x, pos.y, pos.z))
                            return
                        end
                    end
                    turtle.turnRight()
                end
            end
        end
        error("[FATAL] All six directions blocked. Clear a path and reboot.", 0)
    end

    -- We moved. Derive heading from GPS delta.
    local p2 = gpsPos()
    if not p2 then
        error("[FATAL] Lost GPS signal during calibration step.", 0)
    end
    log("NAV", string.format("Post-move GPS: (%d,%d,%d)", p2.x, p2.y, p2.z))

    local dx, dz = p2.x - p1.x, p2.z - p1.z
    if     dx ==  1 then facing = 1
    elseif dx == -1 then facing = 3
    elseif dz ==  1 then facing = 2
    elseif dz == -1 then facing = 0
    else
        error(string.format("[FATAL] GPS delta (%d,_,%d) was not a clean cardinal step.", dx, dz), 0)
    end

    pos = copy(p2)
    log("NAV", string.format("Calibrated: facing=%d (%s) pos=(%d,%d,%d)",
        facing, ({"N","E","S","W"})[facing+1], pos.x, pos.y, pos.z))
end

-- ============================================================
-- GEO SCAN: hot-swap pickaxe <-> scanner on left slot
-- ============================================================
-- GEO SCAN: hot-swap pickaxe <-> scanner on the pickaxe side
-- The scanner goes onto whichever side does NOT have the modem.
-- ============================================================
local function scanAround()
    if not has_scanner then return {} end

    local pside = pickaxeSide()
    local scannerAlreadyOn = peripheral.wrap(pside) ~= nil

    if not scannerAlreadyOn then
        if turtle.getItemCount(SCANNER_SLOT) == 0 then
            log("SCAN", "Scanner item missing from slot 16. Skipping scan.")
            return {}
        end
        turtle.select(SCANNER_SLOT)
        -- Equip scanner onto the pickaxe side; pickaxe goes into slot 16.
        if pside == "left" then turtle.equipLeft() else turtle.equipRight() end
    end

    local results = {}
    local sc = peripheral.wrap(pside)
    if sc and sc.scan then
        local ok, r = pcall(sc.scan, SCAN_RADIUS)
        if ok and type(r) == "table" then
            results = r
            feedCache(results, pos)
            log("SCAN", string.format("Scanned %d blocks. Cache: %d entries.", #results, cache_size))
        else
            log("SCAN", "Scan error: " .. tostring(r))
        end
    else
        log("SCAN", "No scanner peripheral on " .. pside .. " after swap.")
    end

    -- Swap back: pickaxe is in slot 16, put it back on the pickaxe side.
    turtle.select(SCANNER_SLOT)
    if pside == "left" then turtle.equipLeft() else turtle.equipRight() end
    turtle.select(1)

    if not pickaxeEquipped() then
        log("WARN", "Pickaxe not restored after scan swap.")
    end

    return results
end

-- ============================================================
-- INVENTORY
-- ============================================================
local function inventoryFull()
    for i = 1, 15 do if turtle.getItemCount(i) == 0 then return false end end
    return true
end

local function freeSlots()
    local n = 0
    for i = 1, 15 do if turtle.getItemCount(i) == 0 then n = n + 1 end end
    return n
end

-- ============================================================
-- ORE REPORTING + MAP SNAPSHOT
-- ============================================================
local function reportOres(scan)
    for _, b in ipairs(scan) do
        local name = b.name or ""
        if name:find("_ore") then
            local abs = {
                x = pos.x + (b.x or 0),
                y = pos.y + (b.y or 0),
                z = pos.z + (b.z or 0),
            }
            if not reported[key(abs)] then
                reported[key(abs)] = true
                log("ORE", string.format("%s at (%d,%d,%d)", shortName(name), abs.x, abs.y, abs.z))
                pcall(rednet.send, server_id, {
                    type = "ORE_REPORT", hwid = hwid,
                    ore  = shortName(name), pos = abs,
                }, PROTOCOL)
            end
        end
    end
end

local function sendSnapshot(scan)
    local solids = {}
    for _, b in ipairs(scan) do
        local n = b.name or ""
        if n ~= "" and not n:find("air") then
            solids[#solids+1] = { x=b.x, y=b.y, z=b.z, name=n }
        end
    end
    if #solids > 0 then
        pcall(rednet.send, server_id, {
            type = "GEO_DATA", hwid = hwid,
            pos  = copy(pos), scan_data = solids,
        }, PROTOCOL)
    end
end

-- ============================================================
-- DUMP LOOT
-- ============================================================
local function returnAndDump(resumePos)
    log("DUMP", "Cargo full. Heading to DUMP_CHEST...")
    refuelSelf()
    if not dump then log("DUMP", "No dump chest set."); return end

    if not moveTo({ x=dump.x, y=dump.y+1, z=dump.z }) then
        log("DUMP", "Could not reach DUMP_CHEST. Parking 10s.")
        sleep(10); return
    end

    for i = 1, 15 do
        turtle.select(i)
        if turtle.getItemCount(i) > 0 then turtle.dropDown() end
    end
    turtle.select(1)

    local leftover = false
    for i = 1, 15 do if turtle.getItemCount(i) > 0 then leftover = true; break end end
    if leftover then
        log("DUMP", "DUMP_CHEST FULL. Cargo remains. Parking 10s.")
        pcall(rednet.send, server_id, { type="ALERT", hwid=hwid, msg="CHEST_FULL", pos=copy(pos) }, PROTOCOL)
        sleep(10); return
    end

    refuelSelf()
    log("DUMP", "Emptied successfully.")
    if resumePos then moveTo(resumePos); face(my_dir) end
end

-- ============================================================
-- EMERGENCY FUEL FROM BASE
-- ============================================================
local function grabFuelFromBase()
    if not base then return end
    local resume = copy(pos)
    log("FUEL", "Critical fuel. Heading to BASE_CHEST...")

    if not moveTo({ x=base.x, y=base.y+1, z=base.z }) then
        log("FUEL", "Could not reach BASE_CHEST. Parking 10s.")
        sleep(10); return
    end

    for s = 1, 15 do
        if turtle.getItemCount(s) == 0 then
            turtle.select(s)
            if not turtle.suckDown(64) then break end
        end
    end
    burnAboard(FUEL_TARGET)
    for s = 1, 15 do
        turtle.select(s)
        if turtle.getItemCount(s) > 0 and not turtle.refuel(0) then
            turtle.dropDown()
        end
    end
    turtle.select(1)

    moveTo(resume); face(my_dir)
    log("FUEL", "Back from base. Fuel = " .. tostring(turtle.getFuelLevel()))
end

-- ============================================================
-- GOTO JOB  (mine a specific ore block and return)
-- ============================================================
local function doJob(job)
    local resume = copy(pos)
    log("GOTO", string.format("Fetching %s at (%d,%d,%d)", job.ore or "ore", job.pos.x, job.pos.y, job.pos.z))

    if not pickaxeEquipped() then
        log("GOTO", "No pickaxe. Skipping job.")
        return
    end

    if moveTo(job.pos) then
        pcall(rednet.send, server_id, { type="ORE_MINED", hwid=hwid, ore=job.ore, pos=job.pos }, PROTOCOL)
        log("GOTO", "Mined " .. (job.ore or "ore") .. ". Returning.")
    else
        log("GOTO", "Could not reach ore block. Skipping.")
    end

    moveTo(resume); face(my_dir)
end

-- ============================================================
-- NETWORK
-- ============================================================
local function openModem()
    local modem = peripheral.find("modem")
    if not modem then error("[FATAL] No Ender Modem equipped. Attach one and reboot.", 0) end
    rednet.open(peripheral.getName(modem))
    log("INIT", "Modem opened.")
end

local function handshake()
    log("AUTH", string.format("Broadcasting pos (%d,%d,%d) to Overseer...", pos.x, pos.y, pos.z))
    while not server_id do
        rednet.broadcast({ type="AUTH_REQ", hwid=hwid, pos=copy(pos) }, PROTOCOL)
        local sender, msg = rednet.receive(PROTOCOL, 5)
        if sender and type(msg) == "table" and msg.type == "AUTH_ACK" and msg.hwid == hwid then
            server_id = sender
            my_dir    = msg.direction or 0
            dump      = msg.dump
            base      = msg.base
            -- Seed protected positions into cache so A* never routes through them
            if dump then cacheSet(dump.x, dump.y, dump.z, "minecraft:chest") end
            if base then cacheSet(base.x, base.y, base.z, "minecraft:chest") end
            face(my_dir)
            log("AUTH", string.format("Enlisted. Dir=%d Server=%d", my_dir, server_id))
            log("AUTH", "Awaiting CMD_START from Overseer.")
        else
            log("AUTH", "No reply. Retrying...")
        end
    end
end

-- ============================================================
-- THREADS
-- ============================================================
local function listenerThread()
    while true do
        local _, msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            if     msg.type == "CMD_START"  then started = true;  log("CMD","Start received.")
            elseif msg.type == "CMD_STOP"   then started = false; log("CMD","Stop received.")
            elseif msg.type == "CMD_RECALL" then home_requested = true; log("CMD","Recall received.")
            elseif msg.type == "CONFIG" then
                if msg.dump then
                    dump = msg.dump
                    cacheSet(dump.x, dump.y, dump.z, "minecraft:chest")
                end
                if msg.base then
                    base = msg.base
                    cacheSet(base.x, base.y, base.z, "minecraft:chest")
                end
                log("CFG","Chest coords updated.")
            elseif msg.type == "GOTO" and msg.hwid == hwid and type(msg.pos) == "table" then
                log("GOTO","Job queued: " .. (msg.ore or "ore"))
                table.insert(jobs, msg)
            end
        end
    end
end

local function heartbeatThread()
    local scan_ticker = 0
    while true do
        -- Heartbeat: always send current status to overseer
        pcall(rednet.send, server_id, {
            type   = "HEARTBEAT",
            hwid   = hwid,
            fuel   = turtle.getFuelLevel(),
            pos    = copy(pos),
            free   = freeSlots(),
            status = started and "MINING" or "STANDBY",
        }, PROTOCOL)

        -- Passive scan: broadcast surrounding blocks to overseer map
        -- even when standing by or navigating, not just when mining.
        -- Only scan if pickaxe is on its side (scanner is available to swap).
        scan_ticker = scan_ticker + 1
        if scan_ticker >= 5 and has_scanner and not peripheral.wrap(pickaxeSide()) then
            scan_ticker = 0
            local snap = scanAround()
            if #snap > 0 then
                reportOres(snap)
                sendSnapshot(snap)
            end
        end

        sleep(HEARTBEAT_INT)
    end
end

local function brainThread()
    local tunnelled   = 0
    local was_started = false

    -- If we booted without a pickaxe (e.g. only damaged ones were available),
    -- fetch one now while the listener thread is already running and can
    -- receive CMD_START. The fetch will block here but at least the heartbeat
    -- keeps the overseer informed.
    if not pickaxeEquipped() then
        log("PICK", "Fetching pickaxe from BASE_CHEST before starting work...")
        log("PICK", "IMPORTANT: Put a FRESH, UNDAMAGED, UNENCHANTED diamond pickaxe in the BASE_CHEST.")
        fetchPickaxeFromBase(copy(pos))
    end

    log("STAND","Ready. Awaiting CMD_START from Overseer.")

    while true do
        if home_requested then
            home_requested = false
            log("RECALL","Returning home to park...")
            returnAndDump(nil)
            started = false
            log("RECALL","Parked. Send 'start' to resume.")
        end

        if started and not was_started then
            log("ACTIVE","Mining commenced.")
            was_started = true
        elseif not started and was_started then
            log("HALT","Halted. Awaiting 'start'.")
            was_started = false
        end

        if not started then
            sleep(0.5)
        else
            -- Priority 1: GOTO jobs
            while #jobs > 0 do doJob(table.remove(jobs, 1)) end

            -- Priority 2: Pickaxe check
            if not pickaxeEquipped() then
                log("PICK","Pickaxe missing. Fetching from base...")
                fetchPickaxeFromBase(copy(pos))
            end

            -- Priority 3: Fuel
            refuelSelf()
            if fuelLevel() > 0 and fuelLevel() < FUEL_CRITICAL then
                grabFuelFromBase()
            end

            -- Priority 4: Mine
            if fuelLevel() <= 0 then
                log("FUEL","Zero fuel. Halting. Add coal manually.")
                sleep(10)
            elseif inventoryFull() then
                log("CARGO","Holds full. Heading to dump.")
                returnAndDump(copy(pos))
                tunnelled = 0
            else
                face(my_dir)
                if forward() then
                    tunnelled = tunnelled + 1
                    if tunnelled % 8 == 0 then
                        log("MINE", string.format(
                            "t=%d fuel=%s free=%d pos=(%d,%d,%d)",
                            tunnelled, tostring(turtle.getFuelLevel()),
                            freeSlots(), pos.x, pos.y, pos.z))
                    end
                else
                    log("MOVE","Blocked (lava/bedrock). Going up/turning.")
                    if not stepUp() then turnRight() end
                end

                if tunnelled > 0 and tunnelled % SCAN_EVERY == 0 then
                    local snap = scanAround()
                    reportOres(snap)
                    sendSnapshot(snap)
                end

                if tunnelled >= MAX_TUNNEL then
                    log("DONE","Max tunnel length. Returning home.")
                    returnAndDump(nil)
                    started = false; was_started = false; tunnelled = 0
                    log("DONE","Parked. Send 'start' to deploy again.")
                end
            end
        end

        sleep(0)
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
print("+-------------------------------+")
print("|   M-NET V3  |  MINER NODE     |")
print("+-------------------------------+")
log("INIT", "HWID: " .. hwid)

openModem()

-- Detect scanner: look in slot 16 but verify by item name, not just count.
-- The pickaxe might also be in slot 16, so we check what is actually there.
local slot16 = turtle.getItemDetail(SCANNER_SLOT)
if slot16 and tostring(slot16.name or ""):find("scanner") then
    has_scanner = true
    log("INIT", "Geo Scanner confirmed in slot 16. READY")
elseif slot16 and tostring(slot16.name or ""):find("pickaxe") then
    has_scanner = false
    log("INIT", "Slot 16 holds a pickaxe, not a scanner. Scanning DISABLED.")
    log("INIT", "Place the Geo Scanner item in slot 16 if you want scanning.")
else
    -- Unknown item or empty; do a broader search for scanner in any slot.
    has_scanner = false
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and tostring(d.name or ""):find("scanner") then
            if s ~= SCANNER_SLOT then
                log("INIT", string.format("Scanner found in slot %d, not 16. Moving...", s))
                -- Move it: select, swap, etc. is complex; just note and accept.
            end
            has_scanner = true
            log("INIT", "Geo Scanner found in slot " .. s .. ". READY")
            break
        end
    end
    if not has_scanner then
        log("INIT", "No Geo Scanner found. Scanning DISABLED.")
    end
end

-- STEP 1: Pickaxe check (scans all slots, no assumptions about slot 16)
local pick_ok = checkPickaxeAtBoot()

-- STEP 2: Fuel
wakeUp()

-- STEP 3: GPS calibration (tries all 4 directions, derives heading from delta)
calibrate()

-- STEP 4: Forage for coal if still below target (heading now known)
forageForCoal()

-- STEP 5: Enlist with Overseer (this is when base + dump coords arrive)
handshake()

-- STEP 6: Fetch pickaxe is now handled inside the brain thread,
-- AFTER the parallel threads start, so CMD_START is never missed.
-- Just log the status here.
if not pickaxeEquipped() then
    log("INIT", "Pickaxe missing. Will fetch from BASE_CHEST once threads start.")
end

log("BOOT", string.format(
    "All systems ready. Pickaxe=%s Scanner=%s Fuel=%s Pos=(%d,%d,%d) Facing=%s",
    pickaxeEquipped() and "OK" or "MISSING",
    has_scanner and "OK" or "OFF",
    tostring(turtle.getFuelLevel()),
    pos.x, pos.y, pos.z,
    ({"N","E","S","W"})[facing+1]
))

-- ============================================================
-- A* PATHFINDER
-- Only called on a well-seeded cache (scan first, plan second).
-- Unknown cells cost 2. Protected = impassable.
-- ============================================================
local function navCost(nx, ny, nz)
    local name = cacheGet(nx, ny, nz)
    if name == nil        then return 2  end
    if isPassable(name)   then return 1  end
    if isDiggable(name)   then return 4  end
    return nil
end

local function newHeap() return { n = 0 } end
local function heapPush(h, node, pri)
    local i = h.n + 1; h.n = i; h[i] = { node = node, p = pri }
    while i > 1 do
        local p = math.floor(i / 2)
        if h[p].p > h[i].p then h[p], h[i] = h[i], h[p]; i = p else break end
    end
end
local function heapPop(h)
    if h.n == 0 then return nil end
    local top = h[1].node
    h[1] = h[h.n]; h[h.n] = nil; h.n = h.n - 1
    local i = 1
    while true do
        local l, r, s = i*2, i*2+1, i
        if l <= h.n and h[l].p < h[s].p then s = l end
        if r <= h.n and h[r].p < h[s].p then s = r end
        if s == i then break end
        h[i], h[s] = h[s], h[i]; i = s
    end
    return top
end

local DIRS6 = {
    { dx=0,  dy=0,  dz=-1, dir=0  },
    { dx=1,  dy=0,  dz=0,  dir=1  },
    { dx=0,  dy=0,  dz=1,  dir=2  },
    { dx=-1, dy=0,  dz=0,  dir=3  },
    { dx=0,  dy=1,  dz=0,  dir=-1 },
    { dx=0,  dy=-1, dz=0,  dir=-2 },
}

local function astar(start, goal, budget)
    budget = budget or NAV_MAX_NODES
    local dist = math.abs(start.x-goal.x)+math.abs(start.y-goal.y)+math.abs(start.z-goal.z)
    if dist == 0 then return {} end
    local function h(n)
        return math.abs(n.x-goal.x)+math.abs(n.y-goal.y)+math.abs(n.z-goal.z)
    end
    local open = newHeap()
    local g_cost, came = {}, {}
    local sk = key(start)
    g_cost[sk] = 0
    heapPush(open, start, h(start))
    local expanded = 0
    while open.n > 0 do
        local cur = heapPop(open)
        local ck  = key(cur)
        expanded  = expanded + 1
        if expanded > budget then return nil end
        if cur.x == goal.x and cur.y == goal.y and cur.z == goal.z then
            local path = {}
            local k = ck
            while came[k] do table.insert(path, 1, came[k].step); k = came[k].pk end
            log("NAV", string.format("Path: %d steps, %d nodes.", #path, expanded))
            return path
        end
        local g = g_cost[ck]
        for _, nb in ipairs(DIRS6) do
            local nx, ny, nz = cur.x+nb.dx, cur.y+nb.dy, cur.z+nb.dz
            local nc = navCost(nx, ny, nz)
            if nc then
                local nk = nx..":"..ny..":"..nz
                local ng = g + nc
                if not g_cost[nk] or ng < g_cost[nk] then
                    g_cost[nk] = ng
                    came[nk]   = { pk=ck, step={ dx=nb.dx, dy=nb.dy, dz=nb.dz, dir=nb.dir } }
                    heapPush(open, {x=nx,y=ny,z=nz}, ng + h({x=nx,y=ny,z=nz}))
                end
            end
        end
    end
    return nil
end

-- ============================================================
-- SCAN-SEED: scan + live-inspect before every plan
-- ============================================================
local function seedCacheHere()
    liveInspect()
    if has_scanner and not peripheral.wrap(pickaxeSide()) then
        scanAround()   -- scanAround calls feedCache internally
    end
end

-- ============================================================
-- PATH EXECUTOR
-- ============================================================
local function executePath(path, goal)
    local replans, MAX_REPLANS = 0, 8
    while #path > 0 do
        local step = table.remove(path, 1)
        local ok
        if     step.dy ==  1 then ok = stepUp()
        elseif step.dy == -1 then ok = stepDown()
        else face(step.dir);  ok = stepForward() end

        if not ok then
            replans = replans + 1
            log("NAV", string.format("Step failed (replan %d/%d). Scanning...", replans, MAX_REPLANS))
            seedCacheHere()
            if replans > MAX_REPLANS then log("NAV","Max replans."); return false end
            path = astar(pos, goal)
            if not path then log("NAV","Replan blocked."); return false end
            log("NAV", string.format("Replanned: %d steps.", #path))
        end
        sleep(0)
    end
    return pos.x==goal.x and pos.y==goal.y and pos.z==goal.z
end

-- ============================================================
-- moveTo  (scan-first waypoint navigator)
-- Breaks long trips into SCAN_RADIUS-length legs.
-- Scans at the start of each leg so A* always works on known terrain.
-- Falls back to greedy one-step movement when A* cannot plan.
-- ============================================================
local WAYPOINT_STEP = SCAN_RADIUS

local function greedyStep(goal)
    local dx = goal.x - pos.x
    local dy = goal.y - pos.y
    local dz = goal.z - pos.z
    -- Try the dominant axis first
    if     math.abs(dy) >= math.abs(dx) and math.abs(dy) >= math.abs(dz) then
        if dy > 0 and stepUp()   then return true end
        if dy < 0 and stepDown() then return true end
    elseif math.abs(dx) >= math.abs(dz) then
        face(dx > 0 and 1 or 3)
        if stepForward() then return true end
    else
        face(dz > 0 and 2 or 0)
        if stepForward() then return true end
    end
    -- Try all 6 directions
    for _, d in ipairs({0,1,2,3}) do face(d); if stepForward() then return true end end
    if stepUp()   then return true end
    if stepDown() then return true end
    return false
end

function moveTo(goal)
    if pos.x==goal.x and pos.y==goal.y and pos.z==goal.z then return true end

    local function dist() return math.abs(pos.x-goal.x)+math.abs(pos.y-goal.y)+math.abs(pos.z-goal.z) end
    local function alert(msg)
        log("NAV", msg)
        pcall(rednet.send, server_id, { type="ALERT", hwid=hwid, msg=msg, pos=copy(pos) }, PROTOCOL)
    end

    log("NAV", string.format("Navigate (%d,%d,%d) -> (%d,%d,%d) dist=%d",
        pos.x, pos.y, pos.z, goal.x, goal.y, goal.z, dist()))

    local leg = 0
    while dist() > 0 do
        leg = leg + 1
        if leg > NAV_MAX_RANGE then
            alert(string.format("STUCK: too many legs to (%d,%d,%d)", goal.x, goal.y, goal.z))
            return false
        end

        local d = dist()

        -- Scan here to seed cache before planning this leg
        seedCacheHere()

        -- Determine waypoint for this leg
        local wp
        if d <= WAYPOINT_STEP then
            wp = goal
        else
            local ratio = WAYPOINT_STEP / d
            wp = {
                x = pos.x + math.floor((goal.x - pos.x) * ratio + 0.5),
                y = pos.y + math.floor((goal.y - pos.y) * ratio + 0.5),
                z = pos.z + math.floor((goal.z - pos.z) * ratio + 0.5),
            }
            -- Avoid planning to exact same pos
            if wp.x==pos.x and wp.y==pos.y and wp.z==pos.z then
                wp = goal
            end
        end

        log("NAV", string.format("Leg %d -> wp(%d,%d,%d) remaining=%d", leg, wp.x, wp.y, wp.z, d))

        local path = astar(pos, wp)
        if path then
            local ok = executePath(path, wp)
            if not ok then
                log("NAV", "Leg execution failed. Trying greedy step...")
                if not greedyStep(goal) then
                    alert(string.format("STUCK at (%d,%d,%d)", pos.x, pos.y, pos.z))
                    return false
                end
            end
        else
            log("NAV", "A* failed for this leg. Trying greedy step...")
            if not greedyStep(goal) then
                alert(string.format("STUCK at (%d,%d,%d)", pos.x, pos.y, pos.z))
                return false
            end
        end

        sleep(0)
    end

    return true
end
