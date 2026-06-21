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
    store(turtle.inspect(),     pos.x+dx, pos.y,   pos.z+dz)
    store(turtle.inspectUp(),   pos.x,    pos.y+1, pos.z)
    store(turtle.inspectDown(), pos.x,    pos.y-1, pos.z)
end

-- ============================================================
-- PICKAXE DETECTION
-- ============================================================
local function leftIsPeripheral()
    return peripheral.wrap("left") ~= nil
end

local function pickaxeEquipped()
    if leftIsPeripheral() then return false end
    if turtle.getEquippedLeft then
        local info = turtle.getEquippedLeft()
        if info == nil then return false end
        return tostring(info.name or ""):find("pickaxe") ~= nil
    end
    return true  -- older CC:T: assume non-peripheral left = pickaxe
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
-- A* PATHFINDER
-- Plans through the world cache. Unknown = assume diggable stone.
-- Protected blocks = infinite cost (never entered).
-- Returns a list of step tables { dx, dy, dz, dir } or nil.
-- ============================================================
local function navCost(nx, ny, nz)
    local name = cacheGet(nx, ny, nz)
    if name == nil        then return 2  end  -- unknown: assume diggable, small penalty
    if isPassable(name)   then return 1  end  -- air: free
    if isDiggable(name)   then return 4  end  -- rock: costs a dig
    return nil                                -- protected or fluid: impassable
end

-- Tiny binary min-heap
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
    { dx=0, dy=0, dz=-1, dir=0  },   -- N
    { dx=1, dy=0, dz=0,  dir=1  },   -- E
    { dx=0, dy=0, dz=1,  dir=2  },   -- S
    { dx=-1,dy=0, dz=0,  dir=3  },   -- W
    { dx=0, dy=1, dz=0,  dir=-1 },   -- up
    { dx=0, dy=-1,dz=0,  dir=-2 },   -- down
}

local function astar(start, goal)
    local dist = math.abs(start.x-goal.x)+math.abs(start.y-goal.y)+math.abs(start.z-goal.z)
    if dist == 0 then return {} end
    if dist > NAV_MAX_RANGE then
        log("NAV", string.format("Goal %d blocks away, exceeds NAV_MAX_RANGE=%d.", dist, NAV_MAX_RANGE))
        return nil
    end

    local function h(n) return math.abs(n.x-goal.x)+math.abs(n.y-goal.y)+math.abs(n.z-goal.z) end

    local open   = newHeap()
    local g_cost = {}   -- g_cost[k] = best g-score
    local came   = {}   -- came[k] = { pk=parentKey, step=actionTable }
    local sk     = key(start)

    g_cost[sk] = 0
    heapPush(open, start, h(start))

    local expanded = 0
    while open.n > 0 do
        local cur = heapPop(open)
        local ck  = key(cur)
        expanded  = expanded + 1

        if expanded > NAV_MAX_NODES then
            log("NAV", string.format("A* budget exhausted (%d nodes). Partial cache; will replan on move.", expanded))
            return nil
        end

        if cur.x == goal.x and cur.y == goal.y and cur.z == goal.z then
            -- Reconstruct
            local path = {}
            local k = ck
            while came[k] do
                table.insert(path, 1, came[k].step)
                k = came[k].pk
            end
            log("NAV", string.format("Path: %d steps via %d nodes expanded.", #path, expanded))
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
                    came[nk] = { pk = ck, step = { dx=nb.dx, dy=nb.dy, dz=nb.dz, dir=nb.dir } }
                    heapPush(open, {x=nx,y=ny,z=nz}, ng + h({x=nx,y=ny,z=nz}))
                end
            end
        end
    end

    log("NAV", "A*: no path found (all routes blocked by protected blocks or lava).")
    return nil
end

-- ============================================================
-- PATH EXECUTOR
-- Executes a list of steps from astar(). Re-plans up to 5 times
-- if a step fails because the world differed from the cached model.
-- ============================================================
local function executePath(path, goal)
    local replans = 0
    local MAX_REPLANS = 5

    while #path > 0 do
        local step = table.remove(path, 1)
        local ok

        if step.dy == 1 then
            ok = stepUp()
        elseif step.dy == -1 then
            ok = stepDown()
        else
            face(step.dir)
            ok = stepForward()
        end

        if not ok then
            replans = replans + 1
            log("NAV", string.format("Step failed (replan %d/%d). Updating cache...", replans, MAX_REPLANS))
            liveInspect()

            if replans > MAX_REPLANS then
                log("NAV", "Max replans exceeded. Giving up.")
                return false
            end

            path = astar(pos, goal)
            if not path then
                log("NAV", "Re-plan produced no path.")
                return false
            end
            log("NAV", string.format("Re-planned: %d steps remaining.", #path))
        end

        -- Yield so heartbeat + listener threads stay alive
        sleep(0)
    end

    return pos.x == goal.x and pos.y == goal.y and pos.z == goal.z
end

-- ============================================================
-- moveTo  (the only navigation entry point used by all other code)
-- ============================================================
function moveTo(goal)
    if pos.x == goal.x and pos.y == goal.y and pos.z == goal.z then return true end

    log("NAV", string.format("Route to (%d,%d,%d) from (%d,%d,%d)...",
        goal.x, goal.y, goal.z, pos.x, pos.y, pos.z))

    -- Seed cache with a scan if goal is nearby and scanner is ready
    local dist = math.abs(pos.x-goal.x)+math.abs(pos.y-goal.y)+math.abs(pos.z-goal.z)
    if dist <= SCAN_RADIUS * 2 and has_scanner and not leftIsPeripheral() then
        log("NAV", "Goal in scan range. Scanning to seed world cache...")
        -- inline scan so we don't call scanAround recursively
        if turtle.getItemCount(SCANNER_SLOT) > 0 then
            turtle.select(SCANNER_SLOT)
            turtle.equipLeft()
            local sc = peripheral.wrap("left")
            if sc and sc.scan then
                local ok, r = pcall(sc.scan, SCAN_RADIUS)
                if ok and type(r) == "table" then feedCache(r, pos) end
            end
            turtle.select(SCANNER_SLOT)
            turtle.equipLeft()
            turtle.select(1)
        end
    end

    local path = astar(pos, goal)
    if not path then
        log("NAV", "No initial path found. Reporting STUCK.")
        pcall(rednet.send, server_id, {
            type = "ALERT", hwid = hwid,
            msg  = string.format("STUCK: no path to (%d,%d,%d)", goal.x, goal.y, goal.z),
            pos  = copy(pos),
        }, PROTOCOL)
        return false
    end

    local reached = executePath(path, goal)
    if not reached then
        log("NAV", "Could not reach goal after replans.")
        pcall(rednet.send, server_id, {
            type = "ALERT", hwid = hwid,
            msg  = string.format("STUCK mid-path to (%d,%d,%d)", goal.x, goal.y, goal.z),
            pos  = copy(pos),
        }, PROTOCOL)
    end
    return reached
end

-- ============================================================
-- GPS
-- ============================================================
local function gpsPos()
    local x, y, z = gps.locate(2)
    if x then return { x = x, y = y, z = z } end
    return nil
end

-- ============================================================
-- PICKAXE FETCH FROM BASE_CHEST
-- ============================================================
local function fetchPickaxeFromBase(resumePos)
    if not base then
        log("PICK", "No BASE_CHEST set. Cannot fetch pickaxe. Halting.")
        while true do sleep(5) end
    end
    log("PICK", "No pickaxe on left. Heading to BASE_CHEST...")

    if not moveTo({ x = base.x, y = base.y + 1, z = base.z }) then
        log("PICK", "Could not reach BASE_CHEST. Parking until rebooted.")
        while true do sleep(5) end
    end

    local fetched = false
    for _ = 1, 54 do
        for s = 1, 15 do
            if turtle.getItemCount(s) == 0 then
                turtle.select(s)
                if turtle.suckDown(1) then
                    local d = turtle.getItemDetail(s)
                    if d and tostring(d.name or ""):find("pickaxe") then
                        turtle.select(s); turtle.equipLeft()
                        if pickaxeEquipped() then
                            log("PICK", "Pickaxe equipped from BASE_CHEST.")
                            fetched = true; break
                        end
                    end
                    turtle.dropDown()
                else break end
            end
        end
        if fetched then break end
    end

    if not fetched then
        log("PICK", "No pickaxe in BASE_CHEST. Waiting every 10s...")
        while not fetched do
            sleep(10)
            for s = 1, 15 do
                if turtle.getItemCount(s) == 0 then
                    turtle.select(s)
                    if turtle.suckDown(1) then
                        local d = turtle.getItemDetail(s)
                        if d and tostring(d.name or ""):find("pickaxe") then
                            turtle.select(s); turtle.equipLeft()
                            if pickaxeEquipped() then
                                log("PICK","Pickaxe found. Resuming.")
                                fetched = true; break
                            end
                        end
                        turtle.dropDown()
                    end
                end
            end
        end
    end

    if resumePos then moveTo(resumePos); face(my_dir) end
end

-- ============================================================
-- STEP 1: PICKAXE CHECK AT BOOT
-- Scans every inventory slot for a pickaxe item and equips it
-- on the left. Does not assume slot 16 is the scanner.
-- ============================================================
local function checkPickaxeAtBoot()
    -- Already equipped: nothing to do.
    if pickaxeEquipped() then
        log("INIT", "Pickaxe: equipped on left. OK")
        return true
    end

    -- Search all 16 slots for anything named *pickaxe*.
    log("INIT", "No pickaxe on left. Scanning all slots...")
    for s = 1, 16 do
        local detail = turtle.getItemDetail(s)
        if detail and tostring(detail.name or ""):find("pickaxe") then
            log("INIT", string.format("Pickaxe found in slot %d (%s). Equipping...", s, detail.name))
            turtle.select(s)
            turtle.equipLeft()
            if pickaxeEquipped() then
                log("INIT", "Pickaxe equipped. OK")
                turtle.select(1)
                -- Whatever was on the left before went into slot s.
                -- If slot s now holds the scanner item, reassign SCANNER_SLOT.
                local swapped = turtle.getItemDetail(s)
                if swapped and tostring(swapped.name or ""):find("scanner") then
                    log("INIT", "Scanner item landed in slot " .. s .. ". Noted.")
                end
                return true
            end
        end
    end

    log("INIT", "No pickaxe found anywhere in inventory.")
    log("INIT", "Will fetch one from BASE_CHEST after GPS calibration + enlistment.")
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
local function scanAround()
    if not has_scanner then return {} end

    local scannerOnLeft = leftIsPeripheral()

    if not scannerOnLeft then
        if turtle.getItemCount(SCANNER_SLOT) == 0 then
            log("SCAN", "Scanner item missing from slot 16. Skipping scan.")
            return {}
        end
        turtle.select(SCANNER_SLOT)
        turtle.equipLeft()   -- scanner to left, pickaxe to slot 16
    end

    local results = {}
    local sc = peripheral.wrap("left")
    if sc and sc.scan then
        local ok, r = pcall(sc.scan, SCAN_RADIUS)
        if ok and type(r) == "table" then
            results = r
            -- Feed world model so A* knows what is around us
            feedCache(results, pos)
            log("SCAN", string.format("Scanned %d blocks. Cache: %d entries.", #results, cache_size))
        else
            log("SCAN", "Scan error: " .. tostring(r))
        end
    else
        log("SCAN", "No scanner peripheral on left after swap.")
    end

    -- Always swap back regardless of scan success
    turtle.select(SCANNER_SLOT)
    turtle.equipLeft()   -- pickaxe back to left, scanner to slot 16
    turtle.select(1)

    if not pickaxeEquipped() then
        log("WARN", "Pickaxe not restored after scan swap. Correcting next move.")
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
    while true do
        pcall(rednet.send, server_id, {
            type   = "HEARTBEAT", hwid = hwid,
            fuel   = turtle.getFuelLevel(),
            pos    = copy(pos), free = freeSlots(),
            status = started and "MINING" or "STANDBY",
        }, PROTOCOL)
        sleep(HEARTBEAT_INT)
    end
end

local function brainThread()
    local tunnelled   = 0
    local was_started = false

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

-- STEP 6: Fetch pickaxe NOW if boot check failed (base coords arrived in step 5)
if not pickaxeEquipped() then
    log("INIT", "Pickaxe still missing. Fetching from BASE_CHEST...")
    fetchPickaxeFromBase(copy(pos))
end

log("BOOT", string.format(
    "All systems ready. Pickaxe=%s Scanner=%s Fuel=%s Pos=(%d,%d,%d) Facing=%s",
    pickaxeEquipped() and "OK" or "MISSING",
    has_scanner and "OK" or "OFF",
    tostring(turtle.getFuelLevel()),
    pos.x, pos.y, pos.z,
    ({"N","E","S","W"})[facing+1]
))

parallel.waitForAll(brainThread, listenerThread, heartbeatThread)
