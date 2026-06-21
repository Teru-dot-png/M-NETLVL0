--[[
    M-NET V3 | MINER NODE  (Phase 1 hardened)
    ==========================================
    Phase 1 changes:
        - detectHardware() scans all 16 slots by exact item name
          before touching anything. Finds advancedperipherals:geo_scanner
          and diamond_pickaxe regardless of which slot they are in.
          Modem side auto-detected. No assumptions anywhere.
        - Calibration persists to disk (mnet_cal.cfg). On reboot inside
          a tunnel the saved heading + pos are restored if GPS confirms
          the position matches. The one-step calibration move is skipped.
        - All three threads (brain, listener, heartbeat) run inside
          pcall restart loops. An internal crash logs the full error and
          restarts the thread after 2 seconds. parallel.waitForAll never
          exits to terminal again.

    Boot order:
        1. detectHardware()  -- find everything, touch nothing
        2. openModem()       -- open rednet on detected modem side
        3. wakeUp()          -- burn aboard fuel, wait if empty
        4. calibrate()       -- restore from disk or GPS-derive heading
        5. forageForCoal()   -- mine coal if still below fuel target
        6. handshake()       -- enlist with overseer, get base/dump coords
        7. equip pickaxe     -- now that we can moveTo, fetch if missing
        8. parallel.waitForAll(brain, listener, heartbeat)
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
local PROTOCOL      = "MNET_V3"
local SCAN_RADIUS   = 8
local SCAN_EVERY    = 4
local HEARTBEAT_INT = 3
local FUEL_MIN      = 200
local FUEL_TARGET   = 500
local FORAGE_MAX    = 32
local FUEL_CRITICAL = 80
local MAX_TUNNEL    = 256
local CAL_FILE      = "mnet_cal.cfg"   -- persisted heading + position

-- Exact item names from Advanced Peripherals
local SCANNER_ITEM  = "advancedperipherals:geo_scanner"
local PICKAXE_ITEM  = "minecraft:diamond_pickaxe"

-- ============================================================
-- HARDWARE MAP  (populated by detectHardware, read-only after)
-- ============================================================
local HW = {
    modem_side    = nil,   -- "left" or "right"
    pick_side     = nil,   -- opposite of modem
    scanner_slot  = nil,   -- 1-16, or nil
    has_scanner   = false,
    has_pickaxe   = false, -- true if equipped OR in inventory
}

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
local jobs           = {}
local reported       = {}

local pos    = { x = 0, y = 0, z = 0 }
local facing = 0
local DIRV   = {
    [0]={ dx=0,  dz=-1 }, [1]={ dx=1,  dz=0 },
    [2]={ dx=0,  dz=1  }, [3]={ dx=-1, dz=0 },
}

-- ============================================================
-- HELPERS
-- ============================================================
local function copy(p) return { x=p.x, y=p.y, z=p.z } end
local function key(p)  return p.x..":"..p.y..":"..p.z end
local function shortName(n) return (n:match(":(.+)") or n) end

local function log(tag, msg)
    print(string.format("[%-6s] %s", tag, msg))
end

-- ============================================================
-- PHASE 1: detectHardware()
-- Scans every peripheral slot and all 16 inventory slots by
-- exact item name before anything is moved or equipped.
-- Builds HW map. Called once at the very start of boot.
-- ============================================================
local function detectHardware()
    log("HW", "Scanning hardware...")

    -- Modem side: check both sides, prefer the one that is a modem
    for _, side in ipairs({"left","right"}) do
        if peripheral.isPresent(side) then
            local t = peripheral.getType(side)
            if t and (t:find("modem") or t == "ender_modem") then
                HW.modem_side = side
                break
            end
        end
    end
    -- Fallback: any peripheral on either side
    if not HW.modem_side then
        if peripheral.isPresent("left")  then HW.modem_side = "left"  end
        if peripheral.isPresent("right") then HW.modem_side = "right" end
    end
    HW.pick_side = (HW.modem_side == "left") and "right" or "left"
    log("HW", "Modem side: " .. tostring(HW.modem_side) .. "  Pickaxe side: " .. HW.pick_side)

    -- Check if pickaxe is already equipped on pick_side
    if HW.pick_side then
        local getEq = HW.pick_side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
        if getEq then
            local info = getEq()
            if info and tostring(info.name or ""):find("pickaxe") then
                HW.has_pickaxe = true
                log("HW", "Pickaxe: equipped on " .. HW.pick_side .. " side.")
            end
        elseif not peripheral.isPresent(HW.pick_side) then
            -- No getEquipped API and no peripheral: assume pickaxe is there
            HW.has_pickaxe = true
            log("HW", "Pickaxe: assumed on " .. HW.pick_side .. " (no getEquipped API).")
        end
    end

    -- Scan all 16 inventory slots by exact name
    for s = 1, 16 do
        local detail = turtle.getItemDetail(s)
        if detail then
            local name = tostring(detail.name or "")
            if name == SCANNER_ITEM then
                HW.scanner_slot = s
                HW.has_scanner  = true
                log("HW", "Geo Scanner: slot " .. s)
            elseif name:find("pickaxe") then
                if not HW.has_pickaxe then
                    log("HW", "Pickaxe item: slot " .. s .. " (" .. name .. ")")
                end
                HW.has_pickaxe = true
            end
        end
    end

    if not HW.has_scanner then log("HW", "Geo Scanner: NOT FOUND. Scanning disabled.") end
    if not HW.has_pickaxe then log("HW", "Pickaxe: NOT FOUND in inventory or equipped.") end
    if not HW.modem_side  then log("HW", "WARNING: No modem detected on either side.") end

    log("HW", "Hardware detection complete.")
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
-- LAVA CHECKS
-- ============================================================
local function blockIsFluid(ok, data)
    if not ok or type(data) ~= "table" then return false end
    local n = data.name or ""
    return n:find("lava") ~= nil or n:find("water") ~= nil
end
local function isLavaAhead()  local ok,d = turtle.inspect();    return blockIsFluid(ok,d) end
local function isLavaUp()     local ok,d = turtle.inspectUp();  return blockIsFluid(ok,d) end
local function isLavaDown()   local ok,d = turtle.inspectDown(); return blockIsFluid(ok,d) end

-- ============================================================
-- PROTECTED BLOCK CLASSIFIER
-- ============================================================
local DIGGABLE_PATTERNS = {
    "stone","granite","diorite","andesite","deepslate","tuff","calcite",
    "dripstone","basalt","blackstone","netherrack","end_stone","sandstone",
    "cobblestone","mossy_cobblestone","cobbled_deepslate",
    "gravel","dirt","sand","clay","mud","soul_sand","soul_soil",
    "_ore","raw_block",
}
local NEVER_BREAK_PATTERNS = {
    "computer","turtle","monitor","speaker","printer","disk_drive","modem",
    "cable","wired_modem",
    "chest","barrel","hopper","dropper","dispenser","shulker","ender_chest",
    "create:","mechanical_","cogwheel","shaft","gearbox","bearing",
    "deployer","encased","schematic","contraption","fluid_tank",
    "valve","pump","funnel","chute","belt","vault","interface",
    "andesite_casing","brass_casing","copper_casing",
    "appeng:","refinedstorage:",
    "lava","water","fire","portal","bedrock","barrier",
    "command_block","structure_block","spawner","mob_spawner",
    "reinforced_deepslate",
}

local function isDiggable(name)
    if not name or name == "" or name:find("air") then return false end
    for _, p in ipairs(NEVER_BREAK_PATTERNS) do if name:find(p,1,true) then return false end end
    for _, p in ipairs(DIGGABLE_PATTERNS)   do if name:find(p,1,true) then return true  end end
    return false
end

local function isPassable(name)
    return name == nil or name == "" or name:find("air") ~= nil
end

-- ============================================================
-- WORLD CACHE
-- ============================================================
local world_cache = {}
local cache_size  = 0

local function cacheSet(x, y, z, name)
    local k = x..":"..y..":"..z
    if not world_cache[k] then cache_size = cache_size + 1 end
    world_cache[k] = name
end
local function cacheGet(x, y, z) return world_cache[x..":"..y..":"..z] end

local function feedCache(scan, origin)
    if type(scan) ~= "table" or type(origin) ~= "table" then return end
    for _, b in ipairs(scan) do
        if type(b) == "table" and type(b.name) == "string" then
            cacheSet(
                math.floor(origin.x+(b.x or 0)),
                math.floor(origin.y+(b.y or 0)),
                math.floor(origin.z+(b.z or 0)), b.name)
        end
    end
end

local function liveInspect()
    local function store(ok, data, nx, ny, nz)
        if ok and type(data) == "table" and data.name then cacheSet(nx,ny,nz,data.name)
        elseif not ok then cacheSet(nx,ny,nz,"air") end
    end
    local dx, dz = DIRV[facing].dx, DIRV[facing].dz
    local ok_f,dat_f = turtle.inspect()
    local ok_u,dat_u = turtle.inspectUp()
    local ok_d,dat_d = turtle.inspectDown()
    store(ok_f,dat_f, pos.x+dx, pos.y,   pos.z+dz)
    store(ok_u,dat_u, pos.x,    pos.y+1, pos.z)
    store(ok_d,dat_d, pos.x,    pos.y-1, pos.z)
end

-- ============================================================
-- PICKAXE HELPERS  (uses HW map, never assumes slot numbers)
-- ============================================================
local function pickaxeEquipped()
    if not HW.pick_side then return false end
    if peripheral.isPresent(HW.pick_side) then return false end
    local getEq = HW.pick_side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
    if getEq then
        local info = getEq()
        if not info then return false end
        return tostring(info.name or ""):find("pickaxe") ~= nil
    end
    return true  -- older CC:T fallback
end

local function equipOnPickaxeSide()
    if HW.pick_side == "left" then return turtle.equipLeft() else return turtle.equipRight() end
end

-- isEquippable: CC:T only accepts fresh, undamaged, unenchanted diamond pickaxes
local function isEquippable(detail)
    if not detail then return false end
    if not tostring(detail.name or ""):find("pickaxe") then return false end
    if (detail.damage or 0) > 0 then
        log("PICK", "Pickaxe has "..detail.damage.." damage — needs to be brand new.")
        return false
    end
    if detail.enchantments and #detail.enchantments > 0 then
        log("PICK", "Pickaxe is enchanted — CC:T cannot equip enchanted tools.")
        return false
    end
    return true
end

-- ============================================================
-- PRIMITIVE MOVERS
-- ============================================================
local function turnRight() turtle.turnRight(); facing=(facing+1)%4 end
local function turnLeft()  turtle.turnLeft();  facing=(facing+3)%4 end
local function face(target)
    if facing==target then return end
    while facing~=target do
        if (target-facing)%4==1 then turnRight() else turnLeft() end
    end
end

local function digSafe()
    local ok,data = turtle.inspect()
    if not ok then return true end
    local name = type(data)=="table" and data.name or ""
    cacheSet(pos.x+DIRV[facing].dx, pos.y, pos.z+DIRV[facing].dz, name)
    if isPassable(name) then return true end
    if not isDiggable(name) then log("NAV","PROTECTED: ["..name.."]"); return false end
    for _=1,10 do
        turtle.dig()
        local ok2,_ = turtle.inspect()
        if not ok2 then cacheSet(pos.x+DIRV[facing].dx,pos.y,pos.z+DIRV[facing].dz,"air"); return true end
        sleep(0.1)
    end
    return false
end

local function digSafeUp()
    local ok,data = turtle.inspectUp()
    if not ok then return true end
    local name = type(data)=="table" and data.name or ""
    cacheSet(pos.x,pos.y+1,pos.z,name)
    if isPassable(name) then return true end
    if not isDiggable(name) then log("NAV","PROTECTED (up): ["..name.."]"); return false end
    for _=1,10 do turtle.digUp(); local o,_=turtle.inspectUp(); if not o then cacheSet(pos.x,pos.y+1,pos.z,"air"); return true end; sleep(0.1) end
    return false
end

local function digSafeDown()
    local ok,data = turtle.inspectDown()
    if not ok then return true end
    local name = type(data)=="table" and data.name or ""
    cacheSet(pos.x,pos.y-1,pos.z,name)
    if isPassable(name) then return true end
    if not isDiggable(name) then log("NAV","PROTECTED (dn): ["..name.."]"); return false end
    for _=1,10 do turtle.digDown(); local o,_=turtle.inspectDown(); if not o then cacheSet(pos.x,pos.y-1,pos.z,"air"); return true end; sleep(0.1) end
    return false
end

local function stepForward()
    liveInspect()
    if isLavaAhead() then return false end
    if turtle.forward() then pos.x=pos.x+DIRV[facing].dx; pos.z=pos.z+DIRV[facing].dz; return true end
    if not digSafe() then return false end
    if turtle.forward() then pos.x=pos.x+DIRV[facing].dx; pos.z=pos.z+DIRV[facing].dz; return true end
    return false
end

local function stepUp()
    if isLavaUp() then return false end
    if turtle.up() then pos.y=pos.y+1; return true end
    if not digSafeUp() then return false end
    if turtle.up() then pos.y=pos.y+1; return true end
    return false
end

local function stepDown()
    if isLavaDown() then return false end
    if turtle.down() then pos.y=pos.y-1; return true end
    if not digSafeDown() then return false end
    if turtle.down() then pos.y=pos.y-1; return true end
    return false
end

local function forward()
    liveInspect()
    if isLavaAhead() then log("MINE","Lava ahead. Skipping."); return false end
    if turtle.forward() then pos.x=pos.x+DIRV[facing].dx; pos.z=pos.z+DIRV[facing].dz; return true end
    if not turtle.detect() then return false end
    for i=1,64 do
        if not turtle.dig() then turtle.attack() end
        if turtle.forward() then pos.x=pos.x+DIRV[facing].dx; pos.z=pos.z+DIRV[facing].dz; return true end
        sleep(0.15)
    end
    return false
end

-- ============================================================
-- NAVIGATION  (Phase 3: reliable greedy + GPS resync + spiral recovery + waypoints)
-- ============================================================
local function navCost(nx,ny,nz)
    local name = cacheGet(nx,ny,nz)
    if name==nil        then return 1 end   -- unknown: optimistic, treat as air
    if isPassable(name) then return 1 end
    if isDiggable(name) then return 3 end
    return nil                              -- protected/fluid: impassable
end

-- ── Min-heap ─────────────────────────────────────────────
local function newHeap() return {n=0} end
local function heapPush(h,node,pri)
    local i=h.n+1; h.n=i; h[i]={node=node,p=pri}
    while i>1 do local p=math.floor(i/2)
        if h[p].p>h[i].p then h[p],h[i]=h[i],h[p]; i=p else break end
    end
end
local function heapPop(h)
    if h.n==0 then return nil end
    local top=h[1].node; h[1]=h[h.n]; h[h.n]=nil; h.n=h.n-1
    local i=1
    while true do
        local l,r,s=i*2,i*2+1,i
        if l<=h.n and h[l].p<h[s].p then s=l end
        if r<=h.n and h[r].p<h[s].p then s=r end
        if s==i then break end
        h[i],h[s]=h[s],h[i]; i=s
    end
    return top
end

local DIRS6={
    {dx=0,dy=0,dz=-1,dir=0},{dx=1,dy=0,dz=0,dir=1},
    {dx=0,dy=0,dz=1,dir=2},{dx=-1,dy=0,dz=0,dir=3},
    {dx=0,dy=1,dz=0,dir=-1},{dx=0,dy=-1,dz=0,dir=-2},
}

-- Short-range A* for obstacle detours (512 node budget)
local function astarLocal(start,goal)
    local function h(n) return math.abs(n.x-goal.x)+math.abs(n.y-goal.y)+math.abs(n.z-goal.z) end
    local open=newHeap(); local g_cost,came={},{}
    g_cost[key(start)]=0; heapPush(open,start,h(start))
    local exp=0
    while open.n>0 do
        local cur=heapPop(open); local ck=key(cur); exp=exp+1
        if exp>512 then return nil end
        if cur.x==goal.x and cur.y==goal.y and cur.z==goal.z then
            local path,k={},ck
            while came[k] do table.insert(path,1,came[k].step); k=came[k].pk end
            return path
        end
        local g=g_cost[ck]
        for _,nb in ipairs(DIRS6) do
            local nx,ny,nz=cur.x+nb.dx,cur.y+nb.dy,cur.z+nb.dz
            local nc=navCost(nx,ny,nz)
            if nc then
                local nk=nx..":"..ny..":"..nz; local ng=g+nc
                if not g_cost[nk] or ng<g_cost[nk] then
                    g_cost[nk]=ng
                    came[nk]={pk=ck,step={dx=nb.dx,dy=nb.dy,dz=nb.dz,dir=nb.dir}}
                    heapPush(open,{x=nx,y=ny,z=nz},ng+h({x=nx,y=ny,z=nz}))
                end
            end
        end
    end
    return nil
end

local function executeDetour(path)
    for _,step in ipairs(path) do
        local ok
        if     step.dy== 1 then ok=stepUp()
        elseif step.dy==-1 then ok=stepDown()
        else face(step.dir); ok=stepForward() end
        if not ok then return false end
        sleep(0)
    end
    return true
end

-- ── PHASE 3A: GPS RESYNC ─────────────────────────────────
-- Every 16 steps, compare dead-reckoning pos with GPS.
-- If they disagree by more than 1 block, trust GPS.
local function gpsSyncPos()
    local x,y,z = gps.locate(1)
    if not x then return end
    local drift = math.abs(x-pos.x)+math.abs(y-pos.y)+math.abs(z-pos.z)
    if drift > 1 then
        log("NAV",string.format("GPS resync: drift %d blocks. (%d,%d,%d)->(%d,%d,%d)",
            drift, pos.x,pos.y,pos.z, x,y,z))
        pos = {x=x,y=y,z=z}
    end
end

-- ── Greedy single step ───────────────────────────────────
local function greedyStep(goal)
    if pos.x==goal.x and pos.y==goal.y and pos.z==goal.z then return "arrived" end
    local dx,dy,dz = goal.x-pos.x, goal.y-pos.y, goal.z-pos.z
    local axes = {
        {math.abs(dx), dx~=0 and (dx>0 and 1 or 3) or nil, "h"},
        {math.abs(dz), dz~=0 and (dz>0 and 2 or 0) or nil, "h"},
        {math.abs(dy), nil, dy>0 and "u" or "d"},
    }
    table.sort(axes, function(a,b) return a[1]>b[1] end)
    for _,ax in ipairs(axes) do
        if ax[1]>0 then
            local skip=false
            if ax[3]=="u" then
                if stepUp() then return "moved" end
            elseif ax[3]=="d" then
                if stepDown() then return "moved" end
            else
                face(ax[2])
                local ok_i,dat_i = turtle.inspect()
                if ok_i and type(dat_i)=="table" then
                    local name=dat_i.name or ""
                    cacheSet(pos.x+DIRV[facing].dx,pos.y,pos.z+DIRV[facing].dz,name)
                    if not isPassable(name) and not isDiggable(name) then
                        log("NAV","Protected ["..name.."] on axis. Skipping.")
                        skip=true
                    end
                end
                if not skip then if stepForward() then return "moved" end end
            end
        end
    end
    return "stuck"
end

-- ── PHASE 3B: RECOVERY SPIRAL ────────────────────────────
-- When stuck, try all 6 directions in order of which reduces
-- distance to goal the most. Digs if the block is diggable.
-- Returns true if we broke out of the stuck position.
local function recoverSpiral(goal)
    log("NAV","Running recovery spiral...")

    local function dist(p)
        return math.abs(p.x-goal.x)+math.abs(p.y-goal.y)+math.abs(p.z-goal.z)
    end

    local best_dist = dist(pos)
    local dirs = {
        function() face(0); return stepForward() end, -- N
        function() face(1); return stepForward() end, -- E
        function() face(2); return stepForward() end, -- S
        function() face(3); return stepForward() end, -- W
        function() return stepUp()   end,
        function() return stepDown() end,
    }

    -- Sort by which direction's neighbour is closest to goal
    local candidates = {}
    local nbpos = {
        {x=pos.x,   y=pos.y,   z=pos.z-1}, -- N
        {x=pos.x+1, y=pos.y,   z=pos.z},   -- E
        {x=pos.x,   y=pos.y,   z=pos.z+1}, -- S
        {x=pos.x-1, y=pos.y,   z=pos.z},   -- W
        {x=pos.x,   y=pos.y+1, z=pos.z},   -- up
        {x=pos.x,   y=pos.y-1, z=pos.z},   -- down
    }
    for i=1,6 do candidates[i] = {i=i, d=dist(nbpos[i])} end
    table.sort(candidates, function(a,b) return a.d<b.d end)

    for _,c in ipairs(candidates) do
        local fn = dirs[c.i]
        if fn() then
            log("NAV",string.format("Spiral moved. Now at (%d,%d,%d).",pos.x,pos.y,pos.z))
            return true
        end
    end

    log("NAV","Spiral failed. Truly blocked.")
    return false
end

-- ── PHASE 3C: WAYPOINT SPLITTING ─────────────────────────
-- For journeys longer than 32 blocks, split into 32-block
-- waypoints. The turtle re-evaluates the path at each one
-- rather than committing to a single route for the whole trip.
local WAYPOINT_DIST = 32

local function waypointsTo(goal)
    local total = math.abs(pos.x-goal.x)+math.abs(pos.y-goal.y)+math.abs(pos.z-goal.z)
    if total <= WAYPOINT_DIST then return {goal} end

    local waypoints = {}
    local steps = math.ceil(total / WAYPOINT_DIST)
    for i=1,steps do
        local t = i / steps
        waypoints[i] = {
            x = math.floor(pos.x + (goal.x-pos.x)*t + 0.5),
            y = math.floor(pos.y + (goal.y-pos.y)*t + 0.5),
            z = math.floor(pos.z + (goal.z-pos.z)*t + 0.5),
        }
    end
    -- Ensure last waypoint is exactly the goal
    waypoints[#waypoints] = goal
    return waypoints
end

-- ── MAIN moveTo ──────────────────────────────────────────
-- Splits long journeys into waypoints.
-- Each waypoint leg: greedy steps + GPS resync + A* detour
-- on obstacle + spiral recovery if fully stuck.
function moveTo(goal)
    if pos.x==goal.x and pos.y==goal.y and pos.z==goal.z then return true end

    local total_dist = math.abs(pos.x-goal.x)+math.abs(pos.y-goal.y)+math.abs(pos.z-goal.z)
    log("NAV",string.format("Nav to (%d,%d,%d) from (%d,%d,%d) [%d blocks]",
        goal.x,goal.y,goal.z, pos.x,pos.y,pos.z, total_dist))

    local waypoints = waypointsTo(goal)
    if #waypoints > 1 then
        log("NAV",string.format("Split into %d waypoints (%d blocks each).",
            #waypoints, WAYPOINT_DIST))
    end

    for wp_i, wp in ipairs(waypoints) do
        if #waypoints > 1 then
            log("NAV",string.format("Leg %d/%d -> (%d,%d,%d)",
                wp_i, #waypoints, wp.x, wp.y, wp.z))
        end

        local stuck_count    = 0
        local steps_since_sync = 0
        local detours        = 0
        local MAX_STUCK      = 6
        local MAX_DETOURS    = 6

        while pos.x~=wp.x or pos.y~=wp.y or pos.z~=wp.z do
            if home_requested then return false end

            liveInspect()
            local result = greedyStep(wp)

            if result == "arrived" then
                break
            elseif result == "moved" then
                stuck_count      = 0
                steps_since_sync = steps_since_sync + 1
                -- Phase 3A: GPS resync every 16 steps
                if steps_since_sync >= 16 then
                    steps_since_sync = 0
                    gpsSyncPos()
                end
                sleep(0)
            else
                stuck_count = stuck_count + 1
                log("NAV",string.format("Stuck %d/%d at (%d,%d,%d)",
                    stuck_count, MAX_STUCK, pos.x,pos.y,pos.z))

                if stuck_count >= MAX_STUCK then
                    stuck_count = 0
                    detours     = detours + 1

                    -- Seed the local cache with a scan before planning
                    local snap = scanAround()
                    if snap and #snap>0 then feedCache(snap,pos) end

                    -- Try A* detour first
                    local path = astarLocal(pos, wp)
                    if path and #path > 0 then
                        log("NAV","A* detour: "..(#path).." steps.")
                        if not executeDetour(path) then
                            log("NAV","Detour execution failed.")
                        end
                    else
                        -- Phase 3B: recovery spiral
                        log("NAV","A* found no path. Trying recovery spiral.")
                        if not recoverSpiral(wp) then
                            if detours >= MAX_DETOURS then
                                log("NAV","All recovery attempts exhausted. Reporting STUCK.")
                                pcall(rednet.send, server_id, {
                                    type = "ALERT", hwid = hwid,
                                    msg  = string.format("STUCK (%d,%d,%d)->(%d,%d,%d)",
                                        pos.x,pos.y,pos.z, goal.x,goal.y,goal.z),
                                    pos  = copy(pos),
                                }, PROTOCOL)
                                return false
                            end
                            sleep(2)
                        end
                    end
                else
                    sleep(0.3)
                end
            end
        end
    end

    local arrived = pos.x==goal.x and pos.y==goal.y and pos.z==goal.z
    if arrived then
        log("NAV",string.format("Arrived at (%d,%d,%d).", goal.x,goal.y,goal.z))
    end
    return arrived
end

-- ============================================================
-- GPS
-- ============================================================
local function gpsPos()
    local x,y,z = gps.locate(2)
    if x then return {x=x,y=y,z=z} end
    return nil
end

-- ============================================================
-- PHASE 1: PERSISTENT CALIBRATION
-- Saves heading+pos to disk. On reboot inside a tunnel, restores
-- from the file instead of doing the one-step move calibration.
-- ============================================================
local function saveCal()
    local f = fs.open(CAL_FILE,"w")
    if f then
        f.write(textutils.serialize({pos=pos,facing=facing}))
        f.close()
    end
end

local function loadCal()
    if not fs.exists(CAL_FILE) then return nil end
    local f = fs.open(CAL_FILE,"r")
    if not f then return nil end
    local data = textutils.unserialize(f.readAll() or "")
    f.close()
    if type(data)=="table" and data.pos and type(data.facing)=="number" then
        return data
    end
    return nil
end

local function calibrate()
    log("NAV","Calibrating heading...")
    local p1 = gpsPos()
    if not p1 then error("[FATAL] No GPS fix. Build a GPS constellation first.",0) end

    -- Try restoring from saved calibration
    local saved = loadCal()
    if saved then
        local saved_dist = math.abs(p1.x-saved.pos.x)+math.abs(p1.y-saved.pos.y)+math.abs(p1.z-saved.pos.z)
        if saved_dist <= 1 then
            pos    = copy(p1)       -- use GPS for accuracy
            facing = saved.facing
            log("NAV",string.format("Restored from disk: facing=%d (%s) pos=(%d,%d,%d)",
                facing,({"N","E","S","W"})[facing+1],pos.x,pos.y,pos.z))
            return
        else
            log("NAV","Saved cal is "..saved_dist.." blocks off. Re-calibrating.")
        end
    end

    -- No valid saved cal: try all 4 directions for a move
    log("NAV","Pre-move GPS: ("..p1.x..","..p1.y..","..p1.z..")")
    local moved = false
    for attempt=0,3 do
        log("NAV","Calibration attempt "..(attempt+1).."...")
        local ok = turtle.forward()
        if not ok then
            local has_block,data = turtle.inspect()
            if has_block and type(data)=="table" then
                local name = data.name or ""
                if isDiggable(name) then turtle.dig(); sleep(0.2); ok=turtle.forward()
                else log("NAV","Protected ahead: ["..name.."]. Turning.") end
            end
        end
        if ok then moved=true; break end
        turtle.turnRight()
    end
    if not moved then error("[FATAL] All four directions blocked during calibration.",0) end

    local p2 = gpsPos()
    if not p2 then error("[FATAL] Lost GPS during calibration move.",0) end
    log("NAV","Post-move GPS: ("..p2.x..","..p2.y..","..p2.z..")")

    local dx,dz = p2.x-p1.x, p2.z-p1.z
    if     dx== 1 then facing=1
    elseif dx==-1 then facing=3
    elseif dz== 1 then facing=2
    elseif dz==-1 then facing=0
    else error(string.format("[FATAL] Bad GPS delta (%d,_,%d).",dx,dz),0) end

    pos = copy(p2)
    log("NAV",string.format("Calibrated: facing=%d (%s) pos=(%d,%d,%d)",
        facing,({"N","E","S","W"})[facing+1],pos.x,pos.y,pos.z))
    saveCal()
end

-- ============================================================
-- GEO SCAN  (uses HW.scanner_slot, never assumes slot 16)
-- ============================================================
local function scanAround()
    if not HW.has_scanner or not HW.scanner_slot then return {} end
    if not HW.pick_side then return {} end

    -- Check if scanner is already equipped on pick_side
    local scannerOnPickSide = peripheral.isPresent(HW.pick_side)
    if not scannerOnPickSide then
        if turtle.getItemCount(HW.scanner_slot)==0 then
            -- Re-search for the scanner in case it moved
            for s=1,16 do
                local d=turtle.getItemDetail(s)
                if d and tostring(d.name or "")==SCANNER_ITEM then
                    HW.scanner_slot=s; break
                end
            end
            if turtle.getItemCount(HW.scanner_slot)==0 then
                log("SCAN","Scanner not found in slot "..HW.scanner_slot..". Skipping.")
                return {}
            end
        end
        turtle.select(HW.scanner_slot)
        if HW.pick_side=="left" then turtle.equipLeft() else turtle.equipRight() end
    end

    local results={}
    local sc=peripheral.wrap(HW.pick_side)
    if sc and sc.scan then
        local ok,r=pcall(sc.scan,SCAN_RADIUS)
        if ok and type(r)=="table" then
            results=r; feedCache(results,pos)
            log("SCAN",string.format("Scanned %d blocks. Cache: %d.",#results,cache_size))
        else log("SCAN","Scan error: "..tostring(r)) end
    end

    -- Swap back: pickaxe goes back on pick_side, scanner to inventory
    turtle.select(HW.scanner_slot)
    if HW.pick_side=="left" then turtle.equipLeft() else turtle.equipRight() end
    turtle.select(1)

    -- Update scanner slot in case the swap moved it
    for s=1,16 do
        local d=turtle.getItemDetail(s)
        if d and tostring(d.name or "")==SCANNER_ITEM then HW.scanner_slot=s; break end
    end

    if not pickaxeEquipped() then log("WARN","Pickaxe not restored after scan swap.") end
    return results
end

-- ============================================================
-- INVENTORY
-- ============================================================
local function inventoryFull()
    for i=1,15 do if turtle.getItemCount(i)==0 then return false end end
    return true
end
local function freeSlots()
    local n=0; for i=1,15 do if turtle.getItemCount(i)==0 then n=n+1 end end; return n
end

-- ============================================================
-- ORE REPORTING
-- ============================================================
local function reportOres(scan)
    for _,b in ipairs(scan) do
        local name=b.name or ""
        if name:find("_ore") then
            local abs={x=pos.x+(b.x or 0),y=pos.y+(b.y or 0),z=pos.z+(b.z or 0)}
            if not reported[key(abs)] then
                reported[key(abs)]=true
                log("ORE",string.format("%s at (%d,%d,%d)",shortName(name),abs.x,abs.y,abs.z))
                pcall(rednet.send,server_id,{type="ORE_REPORT",hwid=hwid,ore=shortName(name),pos=abs},PROTOCOL)
            end
        end
    end
end

local function sendSnapshot(scan)
    local solids={}
    for _,b in ipairs(scan) do
        local n=b.name or ""
        if n~="" and not n:find("air") then solids[#solids+1]={x=b.x,y=b.y,z=b.z,name=n} end
    end
    if #solids>0 then
        pcall(rednet.send,server_id,{type="GEO_DATA",hwid=hwid,pos=copy(pos),scan_data=solids},PROTOCOL)
    end
end

-- ============================================================
-- DUMP LOOT
-- ============================================================
local function returnAndDump(resumePos)
    log("DUMP","Cargo full. Heading to DUMP_CHEST...")
    refuelSelf()
    if not dump then log("DUMP","No dump chest set."); return end
    if not moveTo({x=dump.x,y=dump.y+1,z=dump.z}) then
        log("DUMP","Could not reach DUMP_CHEST. Parking 10s."); sleep(10); return
    end
    for i=1,15 do turtle.select(i); if turtle.getItemCount(i)>0 then turtle.dropDown() end end
    turtle.select(1)
    local leftover=false
    for i=1,15 do if turtle.getItemCount(i)>0 then leftover=true; break end end
    if leftover then
        log("DUMP","DUMP_CHEST FULL.")
        pcall(rednet.send,server_id,{type="ALERT",hwid=hwid,msg="CHEST_FULL",pos=copy(pos)},PROTOCOL)
        sleep(10); return
    end
    refuelSelf(); log("DUMP","Emptied.")
    if resumePos then moveTo(resumePos); face(my_dir) end
end

-- ============================================================
-- EMERGENCY FUEL
-- ============================================================
local function grabFuelFromBase()
    if not base then return end
    local resume=copy(pos); log("FUEL","Critical. Heading to BASE_CHEST...")
    if not moveTo({x=base.x,y=base.y+1,z=base.z}) then log("FUEL","Cannot reach base."); sleep(10); return end
    for s=1,15 do if turtle.getItemCount(s)==0 then turtle.select(s); if not turtle.suckDown(64) then break end end end
    burnAboard(FUEL_TARGET)
    for s=1,15 do turtle.select(s); if turtle.getItemCount(s)>0 and not turtle.refuel(0) then turtle.dropDown() end end
    turtle.select(1); moveTo(resume); face(my_dir)
    log("FUEL","Fuel = "..tostring(turtle.getFuelLevel()))
end

-- ============================================================
-- PICKAXE FETCH FROM BASE_CHEST
-- ============================================================
local function fetchPickaxeFromBase(resumePos)
    if not base then log("PICK","No BASE_CHEST set. Halting."); while true do sleep(5) end end
    log("PICK","Heading to BASE_CHEST for a pickaxe...")
    if not moveTo({x=base.x,y=base.y+1,z=base.z}) then
        log("PICK","Cannot reach BASE_CHEST."); while true do sleep(5) end
    end

    local function tryFetch()
        local chest=peripheral.wrap("bottom")
        if chest and chest.list then
            for chestSlot,item in pairs(chest.list()) do
                if tostring(item.name or ""):find("pickaxe") then
                    local detail = chest.getItemDetail and chest.getItemDetail(chestSlot)
                    if detail and not isEquippable(detail) then
                        log("PICK","Slot "..chestSlot..": damaged/enchanted. Need fresh unenchanted pick.")
                    else
                        for ts=1,15 do
                            if turtle.getItemCount(ts)==0 then
                                turtle.select(ts); turtle.suckDown(1)
                                local got=turtle.getItemDetail(ts)
                                if got and isEquippable(got) then
                                    equipOnPickaxeSide()
                                    if pickaxeEquipped() then
                                        log("PICK","Pickaxe equipped. OK")
                                        turtle.select(1); return true
                                    end
                                end
                                log("PICK","Item ineligible. Putting back.")
                                turtle.dropDown(); break
                            end
                        end
                    end
                end
            end
        else
            for ts=1,15 do
                if turtle.getItemCount(ts)==0 then
                    turtle.select(ts)
                    if not turtle.suckDown(1) then break end
                    local got=turtle.getItemDetail(ts)
                    if got and isEquippable(got) then
                        equipOnPickaxeSide()
                        if pickaxeEquipped() then log("PICK","Pickaxe equipped (fallback). OK"); turtle.select(1); return true end
                    end
                    turtle.dropDown(); break
                end
            end
        end
        return false
    end

    local fetched=tryFetch()
    if not fetched then
        log("PICK","No usable pickaxe in BASE_CHEST.")
        log("PICK","Add a FRESH, UNDAMAGED, UNENCHANTED diamond pickaxe. Retrying every 10s...")
        while not fetched do sleep(10); fetched=tryFetch() end
    end
    if resumePos then moveTo(resumePos); face(my_dir) end
end

-- ============================================================
-- WAKE-UP FUEL SEQUENCE
-- ============================================================
local function wakeUp()
    log("WAKE","Fuel check. Current = "..tostring(turtle.getFuelLevel()))
    burnAboard(FUEL_TARGET)
    log("WAKE","After burn. Fuel = "..tostring(turtle.getFuelLevel()))
    if fuelLevel()==0 then
        log("WAKE","EMPTY. Drop coal in any cargo slot...")
        while fuelLevel()==0 do burnAboard(FUEL_TARGET); sleep(2) end
        log("WAKE","Got fuel = "..tostring(turtle.getFuelLevel()))
    end
    if fuelLevel()<FUEL_TARGET then
        log("WAKE","Below target. Will forage after calibration.")
    else log("WAKE","Fuel target reached.") end
end

local function forageForCoal()
    if fuelLevel()>=FUEL_TARGET then return end
    log("FUEL","Foraging (up to "..FORAGE_MAX.." blocks)...")
    local steps=0
    while fuelLevel()<FUEL_TARGET and steps<FORAGE_MAX do
        if not forward() then break end
        steps=steps+1; burnAboard(FUEL_TARGET)
        if steps%4==0 then log("FUEL","Foraging step "..steps.." fuel="..tostring(turtle.getFuelLevel())) end
    end
    log("FUEL","Foraged "..steps.." blocks. Fuel = "..tostring(turtle.getFuelLevel()))
end

-- ============================================================
-- BOOT PICKAXE EQUIP  (uses HW map)
-- ============================================================
local function bootEquipPickaxe()
    if pickaxeEquipped() then log("INIT","Pickaxe already equipped. OK"); return true end

    -- Unequip anything on the pick side first
    if peripheral.isPresent(HW.pick_side) then
        log("INIT","Peripheral on "..HW.pick_side..". Moving to free slot...")
        for s=1,16 do
            if turtle.getItemCount(s)==0 then
                turtle.select(s); equipOnPickaxeSide()
                -- Update scanner slot if we just moved the scanner
                local got=turtle.getItemDetail(s)
                if got and tostring(got.name or "")==SCANNER_ITEM then HW.scanner_slot=s end
                log("INIT","Cleared "..HW.pick_side.." slot -> inventory slot "..s)
                break
            end
        end
    end

    -- Find a pickaxe in inventory by exact check
    for s=1,16 do
        local detail=turtle.getItemDetail(s)
        if detail then
            local name=tostring(detail.name or "")
            if name:find("pickaxe") then
                if not isEquippable(detail) then
                    log("INIT","Slot "..s..": pickaxe is damaged/enchanted. Skipping.")
                else
                    log("INIT","Equipping pickaxe from slot "..s.." onto "..HW.pick_side.."...")
                    turtle.select(s); equipOnPickaxeSide()
                    -- Whatever came off goes to slot s; update scanner slot if needed
                    local swapped=turtle.getItemDetail(s)
                    if swapped and tostring(swapped.name or "")==SCANNER_ITEM then HW.scanner_slot=s end
                    if pickaxeEquipped() then log("INIT","Pickaxe equipped. OK"); turtle.select(1); return true end
                end
            end
        end
    end

    log("INIT","No equippable pickaxe in inventory.")
    log("INIT","Will fetch from BASE_CHEST after enlisting.")
    return false
end

-- ============================================================
-- NETWORK
-- ============================================================
local function openModem()
    if not HW.modem_side then error("[FATAL] No modem found on either side.",0) end
    rednet.open(HW.modem_side)
    log("INIT","Modem opened on "..HW.modem_side..".")
end

local function handshake()
    log("AUTH",string.format("Broadcasting pos (%d,%d,%d)...",pos.x,pos.y,pos.z))
    while not server_id do
        rednet.broadcast({type="AUTH_REQ",hwid=hwid,pos=copy(pos)},PROTOCOL)
        local sender,msg=rednet.receive(PROTOCOL,5)
        if sender and type(msg)=="table" and msg.type=="AUTH_ACK" and msg.hwid==hwid then
            server_id    = sender
            my_dir       = msg.direction   or 0
            lane_offset  = msg.lane_offset or 0
            dump         = msg.dump
            base         = msg.base
            if dump then cacheSet(dump.x,dump.y,dump.z,"minecraft:chest") end
            if base then cacheSet(base.x,base.y,base.z,"minecraft:chest") end
            face(my_dir)
            log("AUTH",string.format("Enlisted. Dir=%d Lane=+%d Server=%d",
                my_dir, lane_offset, server_id))
            log("AUTH","Awaiting CMD_START from Overseer.")
        else log("AUTH","No reply. Retrying...") end
    end
end

-- ============================================================
-- PHASE 2: STATE MACHINE
-- ============================================================
-- States:
--   STANDBY    waiting for CMD_START
--   MINING     tunnelling forward, scanning, reporting
--   RTB_DUMP   cargo full, returning to dump chest
--   RTB_FUEL   critically low fuel, returning to base chest
--   FETCH_PICK no pickaxe, going to base chest to get one
--   GOTO       executing a targeted ore retrieval job
--   PARKED     finished a run, waiting for next start command
--
-- The brain loop calls the current state function each tick.
-- Each state function returns the name of the next state.
-- Every transition is logged locally and sent to the overseer.
-- ============================================================

local current_state   = "STANDBY"
local tunnelled       = 0
local goto_job        = nil
local lane_offset     = 0    -- perpendicular blocks from start, assigned by overseer
local lane_positioned = false -- true once we have moved to our lane start position

local function setState(new_state)
    if new_state ~= current_state then
        log("STATE", current_state .. " -> " .. new_state)
        current_state = new_state
        -- Broadcast state change in the next heartbeat automatically
    end
end

-- ── STANDBY ──────────────────────────────────────────────
local function state_STANDBY()
    if started then return "MINING" end
    sleep(0.5)
    return "STANDBY"
end

-- ── PARKED ───────────────────────────────────────────────
local function state_PARKED()
    if started then
        tunnelled = 0
        return "MINING"
    end
    sleep(0.5)
    return "PARKED"
end

-- ── MINING ───────────────────────────────────────────────
-- Phase 4: positions the turtle into its assigned lane first
-- (a perpendicular offset from the start position), then mines
-- a 1-wide 2-tall tunnel (digs the block above after each step
-- so it always has a full-height corridor to walk back through).
local function state_MINING()
    if not started        then return "STANDBY"    end
    if home_requested     then home_requested=false; return "RTB_DUMP" end
    if #jobs > 0          then goto_job=table.remove(jobs,1); return "GOTO" end
    if not pickaxeEquipped() then return "FETCH_PICK" end

    refuelSelf()
    if fuelLevel() > 0 and fuelLevel() < FUEL_CRITICAL then return "RTB_FUEL" end
    if fuelLevel() <= 0 then log("FUEL","Zero fuel. Halting."); sleep(10); return "MINING" end
    if inventoryFull()  then return "RTB_DUMP" end

    -- Phase 4A: move into assigned lane on first activation
    if not lane_positioned and lane_offset > 0 then
        log("LANE", string.format("Moving to lane offset +%d...", lane_offset))
        -- The perpendicular direction is 90 degrees right of my_dir
        local perp_dir = (my_dir + 1) % 4
        local perp_dv  = DIRV[perp_dir]
        local lane_goal = {
            x = pos.x + perp_dv.dx * lane_offset,
            y = pos.y,
            z = pos.z + perp_dv.dz * lane_offset,
        }
        moveTo(lane_goal)
        face(my_dir)
        lane_positioned = true
        log("LANE", string.format("In lane. Starting tunnel at (%d,%d,%d).",
            pos.x, pos.y, pos.z))
    else
        lane_positioned = true  -- offset 0 means we are already in position
    end

    -- Phase 4B: dig forward (1-wide 2-tall tunnel)
    face(my_dir)
    if forward() then
        tunnelled = tunnelled + 1

        -- Dig the block above to maintain 2-tall clearance
        local ok_up, dat_up = turtle.inspectUp()
        if ok_up then
            local name_up = type(dat_up)=="table" and dat_up.name or ""
            if not isPassable(name_up) then
                if isDiggable(name_up) then
                    turtle.digUp()
                else
                    -- Protected block above — duck and flag but keep going
                    log("MINE","Protected block above ["..name_up.."]. Leaving it.")
                end
            end
        end

        if tunnelled % 8 == 0 then
            log("MINE", string.format("t=%d fuel=%s free=%d pos=(%d,%d,%d)",
                tunnelled, tostring(turtle.getFuelLevel()), freeSlots(),
                pos.x, pos.y, pos.z))
            saveCal()
        end
    else
        log("MOVE","Blocked. Stepping up or turning.")
        if not stepUp() then turnRight() end
    end

    if tunnelled > 0 and tunnelled % SCAN_EVERY == 0 then
        local snap = scanAround()
        reportOres(snap)
        sendSnapshot(snap)
    end

    if tunnelled >= MAX_TUNNEL then
        log("DONE","Max tunnel length reached. Lane exhausted.")
        started = false
        return "RTB_DUMP"
    end

    sleep(0)
    return "MINING"
end

-- ── RTB_DUMP ─────────────────────────────────────────────
local function state_RTB_DUMP()
    log("DUMP","Cargo full or recalled. Heading to DUMP_CHEST...")
    refuelSelf()
    if not dump then
        log("DUMP","No dump chest set. Parking.")
        return "PARKED"
    end

    if moveTo({x=dump.x, y=dump.y+1, z=dump.z}) then
        for i=1,15 do
            turtle.select(i)
            if turtle.getItemCount(i)>0 then turtle.dropDown() end
        end
        turtle.select(1)

        local leftover = false
        for i=1,15 do if turtle.getItemCount(i)>0 then leftover=true; break end end
        if leftover then
            log("DUMP","DUMP_CHEST FULL. Cargo remains.")
            pcall(rednet.send, server_id,
                {type="ALERT",hwid=hwid,msg="CHEST_FULL",pos=copy(pos)}, PROTOCOL)
            sleep(10)
        else
            refuelSelf()
            log("DUMP","Emptied successfully.")
        end
    else
        log("DUMP","Could not reach DUMP_CHEST. Parking 10s.")
        sleep(10)
    end

    if not started then return "PARKED" end
    return "MINING"
end

-- ── RTB_FUEL ─────────────────────────────────────────────
local function state_RTB_FUEL()
    if not base then
        log("FUEL","No BASE_CHEST set. Cannot refuel. Halting 10s.")
        sleep(10)
        return "MINING"
    end
    local resume = copy(pos)
    log("FUEL","Critical fuel. Heading to BASE_CHEST...")

    if moveTo({x=base.x, y=base.y+1, z=base.z}) then
        for s=1,15 do
            if turtle.getItemCount(s)==0 then
                turtle.select(s)
                if not turtle.suckDown(64) then break end
            end
        end
        burnAboard(FUEL_TARGET)
        for s=1,15 do
            turtle.select(s)
            if turtle.getItemCount(s)>0 and not turtle.refuel(0) then turtle.dropDown() end
        end
        turtle.select(1)
        log("FUEL","Refuelled. Fuel = "..tostring(turtle.getFuelLevel()))
        moveTo(resume)
        face(my_dir)
    else
        log("FUEL","Could not reach BASE_CHEST. Parking 10s.")
        sleep(10)
    end

    return "MINING"
end

-- ── FETCH_PICK ───────────────────────────────────────────
local function state_FETCH_PICK()
    log("PICK","Pickaxe missing. Heading to BASE_CHEST...")
    fetchPickaxeFromBase(copy(pos))
    if pickaxeEquipped() then
        return started and "MINING" or "STANDBY"
    end
    log("PICK","Still no pickaxe after fetch. Parking.")
    return "PARKED"
end

-- ── GOTO ─────────────────────────────────────────────────
local function state_GOTO()
    if not goto_job then return "MINING" end
    local job = goto_job
    goto_job  = nil

    local resume = copy(pos)
    log("GOTO", string.format("Fetching %s at (%d,%d,%d)",
        job.ore or "ore", job.pos.x, job.pos.y, job.pos.z))

    if not pickaxeEquipped() then
        log("GOTO","No pickaxe. Skipping job.")
        return "FETCH_PICK"
    end

    if moveTo(job.pos) then
        pcall(rednet.send, server_id,
            {type="ORE_MINED", hwid=hwid, ore=job.ore, pos=job.pos}, PROTOCOL)
        log("GOTO","Mined "..(job.ore or "ore")..".")
    else
        log("GOTO","Could not reach ore. Skipping.")
    end

    moveTo(resume)
    face(my_dir)

    if not started then return "STANDBY" end
    return "MINING"
end

-- ── DISPATCH TABLE ────────────────────────────────────────
local STATE_FN = {
    STANDBY    = state_STANDBY,
    MINING     = state_MINING,
    RTB_DUMP   = state_RTB_DUMP,
    RTB_FUEL   = state_RTB_FUEL,
    FETCH_PICK = state_FETCH_PICK,
    GOTO       = state_GOTO,
    PARKED     = state_PARKED,
}

local function brainThread_inner()
    -- Boot pickaxe fetch if needed before entering the state machine
    if not pickaxeEquipped() then
        log("PICK","No pickaxe at boot. Fetching from BASE_CHEST...")
        log("PICK","Need FRESH, UNDAMAGED, UNENCHANTED diamond pickaxe.")
        setState("FETCH_PICK")
        state_FETCH_PICK()
    end

    setState("STANDBY")
    log("STAND","Ready. Awaiting CMD_START.")

    while true do
        -- Queue a new GOTO job if one arrived and we are mining
        if #jobs > 0 and current_state == "MINING" then
            goto_job = table.remove(jobs, 1)
            setState("GOTO")
        end

        -- Handle recall from any active state
        if home_requested and current_state ~= "RTB_DUMP" and current_state ~= "PARKED" then
            home_requested = false
            log("RECALL","Recall received.")
            started = false
            setState("RTB_DUMP")
        end

        local fn = STATE_FN[current_state]
        if fn then
            local next_state = fn()
            if next_state and next_state ~= current_state then
                setState(next_state)
            end
        else
            log("ERR","Unknown state: "..tostring(current_state)..". Resetting to STANDBY.")
            setState("STANDBY")
        end
    end
end

local function heartbeatThread_inner()
    local scan_ticker = 0
    while true do
        -- Send state name so the overseer cockpit shows full state
        pcall(rednet.send, server_id, {
            type   = "HEARTBEAT",
            hwid   = hwid,
            fuel   = turtle.getFuelLevel(),
            pos    = copy(pos),
            free   = freeSlots(),
            status = current_state,   -- full state name, not just MINING/STANDBY
        }, PROTOCOL)

        scan_ticker = scan_ticker + 1
        if scan_ticker >= 5 and HW.has_scanner
        and not peripheral.isPresent(HW.pick_side) then
            scan_ticker = 0
            local snap = scanAround()
            if snap and #snap > 0 then reportOres(snap); sendSnapshot(snap) end
        end

        sleep(HEARTBEAT_INT)
    end
end

-- ── Phase 1+2: pcall restart wrappers ───────────────────
local function listenerThread_inner()
    while true do
        local _,msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            if     msg.type=="CMD_START"  then started=true;        log("CMD","Start received.")
            elseif msg.type=="CMD_STOP"   then started=false;       log("CMD","Stop received.")
            elseif msg.type=="CMD_RECALL" then home_requested=true; log("CMD","Recall received.")
            elseif msg.type=="CONFIG" then
                if msg.dump then dump=msg.dump; cacheSet(dump.x,dump.y,dump.z,"minecraft:chest") end
                if msg.base then base=msg.base; cacheSet(base.x,base.y,base.z,"minecraft:chest") end
                if msg.direction   then my_dir=msg.direction end
                if msg.lane_offset then
                    lane_offset    = msg.lane_offset
                    lane_positioned = false   -- force re-positioning to new lane
                    log("CFG","Lane reassigned. Dir="..my_dir.." offset=+"..lane_offset)
                end
                log("CFG","Config updated from Overseer.")
            elseif msg.type=="GOTO" and msg.hwid==hwid and type(msg.pos)=="table" then
                log("GOTO","Job queued: "..(msg.ore or "ore"))
                table.insert(jobs, msg)
            end
        end
    end
end
local function brainThread()
    while true do
        local ok, err = pcall(brainThread_inner)
        if not ok then
            log("ERR","Brain crashed: "..tostring(err))
            log("ERR","Restarting brain in 2s...")
            sleep(2)
        end
    end
end

local function listenerThread()
    while true do
        local ok, err = pcall(listenerThread_inner)
        if not ok then
            log("ERR","Listener crashed: "..tostring(err))
            log("ERR","Restarting listener in 2s...")
            sleep(2)
        end
    end
end

local function heartbeatThread()
    while true do
        local ok, err = pcall(heartbeatThread_inner)
        if not ok then
            log("ERR","Heartbeat crashed: "..tostring(err))
            log("ERR","Restarting heartbeat in 2s...")
            sleep(2)
        end
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
print("+----------------------------------------+")
print("|  M-NET V3  |  MINER  (Phase 1+2+3+4)  |")
print("+----------------------------------------+")
log("INIT","HWID: "..hwid)

detectHardware()   -- 1. find everything, touch nothing
openModem()        -- 2. open rednet on detected modem
wakeUp()           -- 3. burn aboard fuel, wait if empty
calibrate()        -- 4. restore from disk or GPS-derive heading
forageForCoal()    -- 5. mine coal if still below target
handshake()        -- 6. enlist, get base+dump coords
bootEquipPickaxe() -- 7. equip pickaxe now that we can navigate

log("BOOT",string.format(
    "Ready. Pickaxe=%s Scanner=%s (slot %s) Fuel=%s Pos=(%d,%d,%d) Facing=%s",
    pickaxeEquipped() and "OK" or "MISSING",
    HW.has_scanner and "OK" or "OFF",
    tostring(HW.scanner_slot),
    tostring(turtle.getFuelLevel()),
    pos.x,pos.y,pos.z,
    ({"N","E","S","W"})[facing+1]
))

parallel.waitForAll(brainThread, listenerThread, heartbeatThread)
