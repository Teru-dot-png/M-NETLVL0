--[[
    O-NET V1 | MINER NODE
    =========================================================
    Successor to M-NET V3. Assimilates key patterns from
    bencbartlett/Overmind (Screeps AI) Movement.ts:
        - Position-compare stuck detection  (was: failure counting)
        - Module-level nav state            (was: local vars lost on crash)
        - Random GPS resync probability     (was: fixed step cadence)
        - Priority-based push protocol      (new: turtles yield by role)

    Hardware (auto-detected at boot by detectHardware()):
        Slot 1    : advancedperipherals:geo_scanner  RESERVED — never dumped
        Any side  : Ender Modem       (comms; side found at runtime)
        Other side: Diamond Pickaxe   (hot-swapped with scanner during scans)
        Slots 2-15: Coal or other fuel (self-sustaining after boot)


    Inventory rules:
             Slot 1 is permanently reserved for the geo scanner.
             All dump/fuel/suck loops start at slot 2.
             isTool() returns true for slot 1 unconditionally (no name
             check needed — NBT data can make getItemDetail return nil).

    Boot order:
        1. detectHardware()    find everything, touch nothing
        2. openModem()         open rednet on detected modem side
        3. wakeUp()            burn aboard fuel; wait if empty
        4. calibrate()         restore from disk or GPS-derive heading
        5. handshake()         enlist; receive base+dump+lane+park from overseer
        6. bootEquipPickaxe()  equip pickaxe; fetch from BASE_CHEST if missing
        7. forageForCoal()     mine coal if still below FUEL_TARGET
        8. parallel.waitForAll(brain, listener, heartbeat)

    REQUIRES: working GPS constellation in this dimension.
              Geo scanner in slot 1 before starting.
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
PROTOCOL      = "ONET_V1"   -- upgraded from MNET_V3
SCAN_RADIUS   = 8
SCAN_EVERY    = 4
HEARTBEAT_INT = 3
FUEL_MIN      = 200
FUEL_TARGET   = 500
FORAGE_MAX    = 32
FUEL_CRITICAL = 80
MAX_TUNNEL    = 256
CAL_FILE      = "mnet_cal.cfg"   -- persisted heading + position

-- Exact item names from Advanced Peripherals
SCANNER_ITEM  = "advancedperipherals:geo_scanner"
PICKAXE_ITEM  = "minecraft:diamond_pickaxe"

-- ============================================================
-- O-NET V1 NAVIGATION CONSTANTS
-- Assimilated from bencbartlett/Overmind, src/movement/Movement.ts
-- ============================================================
STUCK_VALUE  = 2      -- unchanged-position ticks before recovery (Overmind: DEFAULT_STUCK_VALUE)
REPATH_PROB  = 0.125  -- GPS resync probability per mining step (Overmind: options.repath)
                      -- 12.5% ≈ same expected frequency as old % 8 cadence but randomised
                      -- so the whole fleet does not hit GPS on the same tick

-- Move priority table (Overmind: MovePriorities).
-- Lower number = higher urgency = never yields to a higher-number turtle.
-- On PUSH_REQ: turtle at the blocked tile yields if its priority >= pusher's.
MOVE_PRIORITY = {
    GOTO       = 1,   -- targeted ore retrieval: highest, never yields
    RTB_FUEL   = 2,   -- critically low fuel: nearly never yields
    RTB_DUMP   = 3,   -- cargo full
    FETCH_PICK = 4,   -- missing pickaxe
    MINING     = 5,   -- normal tunnelling
    STANDBY    = 8,   -- idle, waiting for start
    PARKED     = 9,   -- parked: always yields to any active turtle
}

-- ============================================================
-- HARDWARE MAP  (populated by detectHardware, read-only after)
-- ============================================================
local HW = {
    modem_side    = nil,   -- "left" or "right"
    pick_side     = nil,   -- opposite of modem
    scanner_slot  = nil,   -- 1-16, or nil (always 1 if placed correctly)
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
local fuel_retry_streak = 0
local WANT_LIST      = {}
local probe_ticks    = 0
local reservation_nonce   = 0
local reservation_pending = {}
local RESERVE_TTL_MS      = 1400
local RESERVE_WAIT_MS     = 700
local nav_last_want       = nil
local recent_tiles        = {}
local recent_tile_index   = 1
local RECENT_TILE_WINDOW  = 24

local pos    = { x = 0, y = 0, z = 0 }
local facing = 0
DIRV = {
    [0]={ dx=0,  dz=-1 }, [1]={ dx=1,  dz=0 },
    [2]={ dx=0,  dz=1  }, [3]={ dx=-1, dz=0 },
}

-- Forward declarations: these functions are defined later in the file
-- but called from navigation code that comes first.
local scanAround
local gpsSyncPos

-- ============================================================
-- HELPERS
-- ============================================================
local function copy(p) return { x=p.x, y=p.y, z=p.z } end
local function key(p)  return p.x..":"..p.y..":"..p.z end
local function shortName(n) return (n:match(":(.+)") or n) end

local function isScannerName(name)
    local n = tostring(name or "")
    return n == SCANNER_ITEM or n:find("geo_scanner", 1, true) ~= nil
end

local function noteRecentTile(p)
    if type(p) ~= "table" then return end
    recent_tiles[recent_tile_index] = { x = p.x, y = p.y, z = p.z }
    recent_tile_index = (recent_tile_index % RECENT_TILE_WINDOW) + 1
end

local function recentPenalty(x, y, z)
    local hits = 0
    for _, p in pairs(recent_tiles) do
        if p and p.x == x and p.y == y and p.z == z then
            hits = hits + 1
        end
    end
    return hits * 1.5
end

local function requestMoveReservation(target)
    if not server_id or type(target) ~= "table" then return true end
    reservation_nonce = reservation_nonce + 1
    local nonce = reservation_nonce
    reservation_pending[nonce] = { done = false, granted = false }

    pcall(rednet.send, server_id, {
        type   = "RESERVE_REQ",
        hwid   = hwid,
        nonce  = nonce,
        want   = target,
        ttl_ms = RESERVE_TTL_MS,
    }, PROTOCOL)

    local deadline = os.epoch("utc") + RESERVE_WAIT_MS
    while os.epoch("utc") < deadline do
        local state = reservation_pending[nonce]
        if state and state.done then
            reservation_pending[nonce] = nil
            return state.granted == true
        end
        sleep(0.05)
    end

    reservation_pending[nonce] = nil
    -- Fail open: if comms are laggy, avoid freezing movement.
    return true
end

local function releaseMoveReservation(target)
    if not server_id or type(target) ~= "table" then return end
    pcall(rednet.send, server_id, {
        type = "RESERVE_REL",
        hwid = hwid,
        want = target,
    }, PROTOCOL)
end

local function normalizeOreName(name)
    local n = tostring(name or "")
    n = n:match("deepslate_(.-)_ore$")
     or n:match("nether_(.-)_ore$")
     or n:match("(.-)_ore$")
     or n
    return n
end

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

    -- Scan all 16 inventory slots by exact name.
    -- SLOT 1 IS RESERVED: dump loops always start at slot 2.
    -- Put the geo scanner in slot 1 before starting the turtle.
    -- Do NOT move it programmatically - transferTo fails if slot 1 is occupied.
    for s = 1, 16 do
        local detail = turtle.getItemDetail(s)
        if detail then
            local name = tostring(detail.name or "")
            if isScannerName(name) then
                HW.scanner_slot = s
                HW.has_scanner  = true
                if s == 1 then
                    log("HW", "Geo Scanner: slot 1 (reserved). OK")
                else
                    log("HW", "WARNING: Geo Scanner in slot "..s.." not slot 1!")
                    log("HW", "Move it to slot 1 to keep it safe from dumps.")
                end
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
    -- Slot 1 is reserved for the geo scanner. Start from slot 2.
    for slot = 2, 15 do
        if fuelLevel() >= target then break end
        turtle.select(slot)
        if turtle.refuel(0) then turtle.refuel() end
    end
    turtle.select(2)
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
DIGGABLE_PATTERNS = {
    "stone","granite","diorite","andesite","deepslate","tuff","calcite",
    "dripstone","basalt","blackstone","netherrack","end_stone","sandstone",
    "cobblestone","mossy_cobblestone","cobbled_deepslate",
    "gravel","dirt","sand","clay","mud","soul_sand","soul_soil",
    "_ore","raw_block",
}
NEVER_BREAK_PATTERNS = {
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

local function isScanNoise(name)
    local n = tostring(name or "")
    -- Ignore dynamic turtle entities in scan data so they don't pollute map/cache.
    return n:find("turtle", 1, true) ~= nil
end

-- ============================================================
-- WORLD CACHE
-- ============================================================
world_cache = {}
cache_size  = 0

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
            if not isScanNoise(b.name) then
            cacheSet(
                math.floor(origin.x+(b.x or 0)),
                math.floor(origin.y+(b.y or 0)),
                math.floor(origin.z+(b.z or 0)), b.name)
            end
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

-- Returns true if the pickaxe side currently holds a pickaxe.
-- IMPORTANT: never call this while the scanner is mid-swap.
-- After scanAround() returns, the pickaxe is always back on pick_side.
local function pickaxeEquipped()
    if not HW.pick_side then return false end

    -- If a peripheral is present on the pick side the scanner is there.
    -- However only count it as "not a pickaxe" if we are sure it is the
    -- scanner: the modem is on the OTHER side, so any peripheral on
    -- pick_side is the scanner.
    if peripheral.isPresent(HW.pick_side) then return false end

    -- Try the getEquipped API (CC:T 1.109+)
    local getEq = HW.pick_side == "left" and turtle.getEquippedLeft
                                          or  turtle.getEquippedRight
    if getEq then
        local info = getEq()
        if info == nil then return false end          -- slot is empty
        return tostring(info.name or ""):find("pickaxe") ~= nil
    end

    -- Fallback for older CC:T: no peripheral on pick_side = pickaxe is there.
    -- This is safe because the modem is on the other side.
    return true
end

local function equipOnPickaxeSide()
    if HW.pick_side == "left" then return turtle.equipLeft()
    else                            return turtle.equipRight() end
end

-- Treat any pickaxe as usable. Overly strict damage/enchant filters
-- caused false negatives and fetch dead-loops.
local function isEquippable(detail)
    if not detail then return false end
    if not tostring(detail.name or ""):find("pickaxe") then return false end
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

-- TUNNEL FORWARD (used during mining, not navigation).
-- Digs any non-lava block. On success:
--   1. Marks the entered block as "air" in the local world cache so the
--      return-trip navigator knows the tunnel is clear.
--   2. Sends a single-block GEO_DATA("air") to the overseer so the map
--      shows the tunnel carving out in real time.
-- These two steps are what prevent the "walks through its own wall" bug.
local function forward()
    liveInspect()
    if isLavaAhead() then log("MINE","Lava ahead. Skipping."); return false end
    if turtle.forward() then
        local nx = pos.x+DIRV[facing].dx
        local nz = pos.z+DIRV[facing].dz
        cacheSet(nx, pos.y, nz, "air")
        pos.x = nx; pos.z = nz
        -- Tell overseer this block is now air so the map updates live
        pcall(rednet.send, server_id, {
            type="GEO_DATA", hwid=hwid, pos=copy(pos),
            scan_data={{ x=0, y=0, z=0, name="minecraft:air" }},
        }, PROTOCOL)
        return true
    end
    if not turtle.detect() then return false end
    for i=1,64 do
        if not turtle.dig() then turtle.attack() end
        if turtle.forward() then
            local nx = pos.x+DIRV[facing].dx
            local nz = pos.z+DIRV[facing].dz
            cacheSet(nx, pos.y, nz, "air")
            pos.x = nx; pos.z = nz
            pcall(rednet.send, server_id, {
                type="GEO_DATA", hwid=hwid, pos=copy(pos),
                scan_data={{ x=0, y=0, z=0, name="minecraft:air" }},
            }, PROTOCOL)
            return true
        end
        sleep(0.15)
    end
    return false
end

-- ============================================================
-- NAVIGATION  (O-NET V1 — assimilated from Overmind/Movement.ts)
-- Greedy axis navigator with A* detour on obstacle and spiral
-- recovery. navCost strongly favours known-air (dug tunnels)
-- over unknown or known-solid space: air=1, unknown=4, stone=8.
--
-- O-NET V1 changes vs M-NET V3:
--   Stuck detection  : pos compared before/after each step.
--                      nav_stuck_cnt is module-level (survives pcall).
--                      Threshold = STUCK_VALUE (2), not 6 attempts.
--   GPS resync       : math.random() < REPATH_PROB per step.
--                      Randomised so fleet does not sync simultaneously.
--   Push protocol    : PUSH_REQ broadcast on stuck before spiral.
--                      Blocking turtle yields if its priority >= ours.
--   Climb-over       : if all 6 dirs fail, steps up and tries horizontal
--                      (handles item_vaults, chests, other 1-tall blocks).
-- ============================================================
local function navCost(nx,ny,nz)
    -- unknown=4, air=1, stone=8: dug tunnel costs 1/4 of unknown space
    -- and 1/8 of known stone, so the navigator always takes it.
    local name = cacheGet(nx,ny,nz)
    if name==nil        then return 4  end   -- unknown: assume solid
    if isPassable(name) then return 1  end   -- known air: strongly prefer
    if isDiggable(name) then return 8  end   -- known stone: last resort
    return nil                               -- protected/fluid: impassable
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

DIRS6={
    {dx=0,dy=0,dz=-1,dir=0},{dx=1,dy=0,dz=0,dir=1},
    {dx=0,dy=0,dz=1,dir=2},{dx=-1,dy=0,dz=0,dir=3},
    {dx=0,dy=1,dz=0,dir=-1},{dx=0,dy=-1,dz=0,dir=-2},
}

-- Short-range A* for obstacle detours (512 node budget)
local function astarLocal(start,goal,node_budget)
    local function h(n) return math.abs(n.x-goal.x)+math.abs(n.y-goal.y)+math.abs(n.z-goal.z) end
    local open=newHeap(); local g_cost,came={},{}
    g_cost[key(start)]=0; heapPush(open,{x=start.x,y=start.y,z=start.z,dir=nil},h(start))
    local budget = math.max(128, tonumber(node_budget) or 512)
    local exp=0
    while open.n>0 do
        local cur=heapPop(open); local ck=key(cur); exp=exp+1
        if exp>budget then return nil end
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
                local turn_pen = 0
                if nb.dy ~= 0 then turn_pen = turn_pen + 0.8 end
                if cur.dir and cur.dir >= 0 and nb.dir >= 0 and cur.dir ~= nb.dir then
                    turn_pen = turn_pen + 0.4
                end
                local nk=nx..":"..ny..":"..nz; local ng=g+nc+turn_pen+recentPenalty(nx,ny,nz)
                if not g_cost[nk] or ng<g_cost[nk] then
                    g_cost[nk]=ng
                    came[nk]={pk=ck,step={dx=nb.dx,dy=nb.dy,dz=nb.dz,dir=nb.dir}}
                    heapPush(open,{x=nx,y=ny,z=nz,dir=nb.dir},ng+h({x=nx,y=ny,z=nz}))
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
        noteRecentTile(pos)
        sleep(0)
    end
    return true
end

local function adaptiveAStarBudget(start, goal, detours)
    local dist = math.abs(start.x-goal.x) + math.abs(start.y-goal.y) + math.abs(start.z-goal.z)
    local stuck = tonumber(nav_stuck_cnt) or 0
    local b = dist * 18 + (tonumber(detours) or 0) * 128 + stuck * 96
    if b < 256 then b = 256 end
    if b > 2048 then b = 2048 end
    return math.floor(b)
end

-- ── PHASE 3A: GPS RESYNC ─────────────────────────────────
-- Every 16 steps, compare dead-reckoning pos with GPS.
-- If they disagree by more than 1 block, trust GPS.
-- GPS position sync: correct dead-reckoning drift.
-- Called every 8 steps during mining and every 16 steps during navigation.
-- If pos is off by more than 0 blocks we correct it immediately.
-- If pos is badly off (>3 blocks) we also re-derive facing from two
-- consecutive GPS readings, since that level of drift usually means
-- the heading is wrong, not just accumulated float error.
gpsSyncPos = function()
    local x,y,z = gps.locate(2)
    if not x then return end
    local drift = math.abs(x-pos.x)+math.abs(y-pos.y)+math.abs(z-pos.z)
    if drift == 0 then return end

    log("NAV",string.format("GPS drift %d. Correcting (%d,%d,%d)->(%d,%d,%d)",
        drift, pos.x,pos.y,pos.z, x,y,z))
    pos = {x=x,y=y,z=z}

    if drift > 3 then
        -- Heading is probably wrong. Re-derive it by attempting one move
        -- and reading GPS before and after.
        log("NAV","Large drift detected. Re-deriving heading from GPS...")
        local moved = false
        for _=0,3 do
            if turtle.forward() then moved=true; break end
            turtle.turnRight()
        end
        if moved then
            local x2,y2,z2 = gps.locate(2)
            if x2 then
                local ddx,ddz = x2-x, z2-z
                if     ddx== 1 then facing=1
                elseif ddx==-1 then facing=3
                elseif ddz== 1 then facing=2
                elseif ddz==-1 then facing=0 end
                pos = {x=x2,y=y2,z=z2}
                log("NAV",string.format("Heading re-derived: facing=%d (%s)",
                    facing,({"N","E","S","W"})[facing+1]))
                saveCal()
            end
        else
            log("NAV","Could not move to re-derive heading. Will try again next sync.")
        end
    end
end

-- ── Greedy single step ───────────────────────────────────
local function greedyStep(goal)
    if pos.x==goal.x and pos.y==goal.y and pos.z==goal.z then return "arrived" end
    nav_last_want = nil
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
                local target = { x = pos.x, y = pos.y + 1, z = pos.z }
                nav_last_want = target
                if requestMoveReservation(target) then
                    local ok = stepUp()
                    releaseMoveReservation(target)
                    if ok then return "moved" end
                end
            elseif ax[3]=="d" then
                local target = { x = pos.x, y = pos.y - 1, z = pos.z }
                nav_last_want = target
                if requestMoveReservation(target) then
                    local ok = stepDown()
                    releaseMoveReservation(target)
                    if ok then return "moved" end
                end
            else
                face(ax[2])
                local target = { x = pos.x + DIRV[facing].dx, y = pos.y, z = pos.z + DIRV[facing].dz }
                nav_last_want = target
                local ok_i,dat_i = turtle.inspect()
                if ok_i and type(dat_i)=="table" then
                    local name=dat_i.name or ""
                    cacheSet(pos.x+DIRV[facing].dx,pos.y,pos.z+DIRV[facing].dz,name)
                    if not isPassable(name) and not isDiggable(name) then
                        log("NAV","Protected ["..name.."] on axis. Skipping.")
                        skip=true
                    end
                end
                if not skip and requestMoveReservation(target) then
                    local ok = stepForward()
                    releaseMoveReservation(target)
                    if ok then return "moved" end
                end
            end
        end
    end
    return "stuck"
end

-- ── PHASE 3B: RECOVERY SPIRAL ────────────────────────────
-- When stuck, try all 6 directions sorted by distance to goal.
-- If all horizontal directions are blocked by protected blocks,
-- try climbing over: step up, step forward, step down the other side.
-- This handles item_vaults, chests, and other protected furniture.
local function recoverSpiral(goal)
    log("NAV","Running recovery spiral...")

    local function dist(p)
        return math.abs(p.x-goal.x)+math.abs(p.y-goal.y)+math.abs(p.z-goal.z)
    end

    local dirs = {
        function() face(0); return stepForward() end,
        function() face(1); return stepForward() end,
        function() face(2); return stepForward() end,
        function() face(3); return stepForward() end,
        function() return stepUp()   end,
        function() return stepDown() end,
    }
    local nbpos = {
        {x=pos.x,   y=pos.y,   z=pos.z-1},
        {x=pos.x+1, y=pos.y,   z=pos.z  },
        {x=pos.x,   y=pos.y,   z=pos.z+1},
        {x=pos.x-1, y=pos.y,   z=pos.z  },
        {x=pos.x,   y=pos.y+1, z=pos.z  },
        {x=pos.x,   y=pos.y-1, z=pos.z  },
    }

    local candidates = {}
    for i=1,6 do candidates[i] = {i=i, d=dist(nbpos[i])} end
    table.sort(candidates, function(a,b) return a.d<b.d end)

    for _,c in ipairs(candidates) do
        if dirs[c.i]() then
            log("NAV",string.format("Spiral moved. Now at (%d,%d,%d).", pos.x,pos.y,pos.z))
            return true
        end
    end

    -- All 6 directions failed. Try the "climb over" manoeuvre:
    -- go up one block, then try each horizontal direction.
    -- This gets over a single-block-tall protected obstacle like a vault.
    log("NAV","All 6 directions blocked. Attempting climb-over...")
    if stepUp() then
        for dir = 0, 3 do
            face(dir)
            if stepForward() then
                log("NAV",string.format("Climbed over obstacle. Now at (%d,%d,%d).",
                    pos.x,pos.y,pos.z))
                return true
            end
        end
        -- Could not move horizontally after going up; go back down
        stepDown()
    end

    log("NAV","Spiral and climb-over both failed. Truly blocked.")
    return false
end

-- ── PHASE 3C: WAYPOINT SPLITTING ─────────────────────────
-- For journeys longer than 32 blocks, split into 32-block
-- waypoints. The turtle re-evaluates the path at each one
-- rather than committing to a single route for the whole trip.
WAYPOINT_DIST = 32

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
-- O-NET V1 rewrite inspired by Overmind/Movement.ts:
--
--   Stuck detection: compares pos BEFORE and AFTER each step.
--     If pos didn't change → nav_stuck_cnt++ (threshold = STUCK_VALUE = 2).
--     Previously counted failed stepForward() calls (threshold = 6).
--     Catches cases where a move "succeeds" but another turtle pushes
--     the turtle back to the same square next tick.
--
--   Persistent counter: nav_stuck_cnt is a MODULE-LEVEL variable.
--     It survives brain pcall restarts. Old local variable was reset
--     to 0 on every crash, allowing infinite thrash loops.
--
--   Push protocol: when stuck, broadcast PUSH_REQ before spiralling.
--     Any turtle at the blocked position with lower (or equal) priority
--     will yield by stepping aside.
--
--   Random GPS sync during navigation: Math.random() < repath_prob
--     instead of fixed step cadence. Spreads fleet sync load.
function moveTo(goal)
    if pos.x==goal.x and pos.y==goal.y and pos.z==goal.z then return true end

    -- block_movement: set by a YIELD command. Honour it for one step then clear.
    if block_movement then
        block_movement = false
        return false
    end

    local total_dist = math.abs(pos.x-goal.x)+math.abs(pos.y-goal.y)+math.abs(pos.z-goal.z)
    log("NAV",string.format("Nav to (%d,%d,%d) from (%d,%d,%d) [%d blocks]",
        goal.x,goal.y,goal.z, pos.x,pos.y,pos.z, total_dist))

    local waypoints = waypointsTo(goal)
    if #waypoints > 1 then
        log("NAV",string.format("Split into %d waypoints (%d blocks each).",
            #waypoints, WAYPOINT_DIST))
    end

    local MAX_DETOURS = 6
    nav_prev_pos = copy(pos)

    for wp_i, wp in ipairs(waypoints) do
        if #waypoints > 1 then
            log("NAV",string.format("Leg %d/%d -> (%d,%d,%d)",
                wp_i, #waypoints, wp.x, wp.y, wp.z))
        end

        local detours = 0

        while pos.x~=wp.x or pos.y~=wp.y or pos.z~=wp.z do
            if home_requested then
                nav_stuck_cnt = 0
                nav_prev_pos = nil
                return false
            end

            -- O-NET V1: snapshot position BEFORE the move attempt
            local before = nav_prev_pos or copy(pos)

            liveInspect()
            local result = greedyStep(wp)

            if result == "arrived" then
                nav_stuck_cnt = 0
                nav_prev_pos = copy(pos)
                break
            end

            -- O-NET V1: compare position. If it changed → not stuck, reset counter.
            -- If unchanged → increment. This catches phantom "moved" returns where
            -- another turtle immediately pushed us back.
            local after = copy(pos)
            if after.x ~= before.x or after.y ~= before.y or after.z ~= before.z then
                nav_stuck_cnt = 0
                nav_prev_pos = after
                noteRecentTile(after)
                -- O-NET V1: random repath probability instead of fixed cadence.
                -- Expected frequency same as % 8 but spread across the fleet.
                if math.random() < 0.15 then gpsSyncPos() end
                sleep(0)
            else
                nav_stuck_cnt = nav_stuck_cnt + 1
                nav_prev_pos = after
                log("NAV",string.format("[O-NET] Stuck %d/%d at (%d,%d,%d) -> (%d,%d,%d)",
                    nav_stuck_cnt, STUCK_VALUE,
                    pos.x,pos.y,pos.z, wp.x,wp.y,wp.z))

                if nav_stuck_cnt >= STUCK_VALUE then
                    nav_stuck_cnt = 0
                    detours = detours + 1

                    -- O-NET V1: PUSH protocol (Overmind pushCreep equivalent).
                    -- Broadcast our position and priority so any turtle blocking
                    -- our target tile will yield if their priority is lower urgency.
                    local target = nav_last_want
                    if not target then
                        local dx = wp.x - pos.x
                        local dy = wp.y - pos.y
                        local dz = wp.z - pos.z
                        if math.abs(dx) >= math.abs(dz) and math.abs(dx) >= math.abs(dy) and dx ~= 0 then
                            target = { x = pos.x + (dx > 0 and 1 or -1), y = pos.y, z = pos.z }
                        elseif math.abs(dz) >= math.abs(dy) and dz ~= 0 then
                            target = { x = pos.x, y = pos.y, z = pos.z + (dz > 0 and 1 or -1) }
                        elseif dy ~= 0 then
                            target = { x = pos.x, y = pos.y + (dy > 0 and 1 or -1), z = pos.z }
                        end
                    end
                    pcall(rednet.broadcast, {
                        type     = "PUSH_REQ",
                        hwid     = hwid,
                        priority = getMovePriority(),
                        at       = copy(pos),
                        want     = target,
                    }, PROTOCOL)

                    -- Brief pause so any yielding turtle has time to step aside
                    sleep(0.4)

                    -- Seed cache with a scan before planning
                    local snap = scanAround()
                    if snap and #snap>0 then feedCache(snap,pos) end

                    -- Try A* detour first
                    local budget = adaptiveAStarBudget(pos, wp, detours)
                    local path = astarLocal(pos, wp, budget)
                    if path and #path > 0 then
                        log("NAV","A* detour: "..(#path).." steps (budget="..budget..").")
                        if not executeDetour(path) then
                            log("NAV","Detour execution failed.")
                        end
                    else
                        log("NAV","A* found no path (budget="..budget.."). Trying recovery spiral.")
                        if not recoverSpiral(wp) then
                            if detours >= MAX_DETOURS then
                                log("NAV","All recovery attempts exhausted. Reporting STUCK.")
                                pcall(rednet.send, server_id, {
                                    type = "ALERT", hwid = hwid,
                                    msg  = string.format("STUCK (%d,%d,%d)->(%d,%d,%d)",
                                        pos.x,pos.y,pos.z, goal.x,goal.y,goal.z),
                                    pos  = copy(pos),
                                }, PROTOCOL)
                                nav_stuck_cnt = 0
                                nav_prev_pos = nil
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
        nav_stuck_cnt = 0
        nav_prev_pos = nil
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

    -- Try restoring from saved calibration.
    -- We still verify the heading with one live GPS step because a crashed
    -- turtle may have saved a heading from before it was pushed or turned.
    local saved = loadCal()
    if saved then
        local saved_dist = math.abs(p1.x-saved.pos.x)+math.abs(p1.y-saved.pos.y)+math.abs(p1.z-saved.pos.z)
        if saved_dist <= 1 then
            pos    = copy(p1)
            facing = saved.facing
            log("NAV",string.format("Saved cal matches GPS. Verifying heading..."))

            -- Take one step to confirm facing is actually correct.
            -- This catches the case where the turtle was pushed/rotated after save.
            local step_ok = turtle.forward()
            if step_ok then
                local p2 = gpsPos()
                if p2 then
                    local ddx,ddz = p2.x-p1.x, p2.z-p1.z
                    local derived
                    if     ddx== 1 then derived=1
                    elseif ddx==-1 then derived=3
                    elseif ddz== 1 then derived=2
                    elseif ddz==-1 then derived=0 end
                    if derived ~= nil and derived ~= facing then
                        log("NAV",string.format(
                            "Heading mismatch! Saved=%d GPS says=%d. Using GPS.",
                            facing, derived))
                        facing = derived
                    end
                    pos = copy(p2)
                end
            else
                log("NAV","Could not step to verify heading. Trusting saved cal.")
            end

            saveCal()
            log("NAV",string.format("Calibrated: facing=%d (%s) pos=(%d,%d,%d)",
                facing,({"N","E","S","W"})[facing+1],pos.x,pos.y,pos.z))
            return
        else
            log("NAV","Saved cal is "..saved_dist.." blocks off. Re-calibrating from scratch.")
        end
    end

    -- No valid saved cal: try all 4 directions for a move.
    -- Track how many right-turns we made so we can update facing correctly.
    log("NAV","Pre-move GPS: ("..p1.x..","..p1.y..","..p1.z..")")
    local moved   = false
    local turns   = 0
    for attempt=0,3 do
        log("NAV","Calibration attempt "..(attempt+1).."...")
        local ok = turtle.forward()
        if not ok then
            local has_block,data = turtle.inspect()
            if has_block and type(data)=="table" then
                local name = data.name or ""
                if isDiggable(name) then
                    turtle.dig(); sleep(0.2); ok=turtle.forward()
                else
                    log("NAV","Protected ahead: ["..name.."]. Turning.")
                end
            end
        end
        if ok then moved=true; break end
        turtle.turnRight()
        turns = turns + 1
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
-- Scanning lock: true while the hot-swap is in progress.
-- The brain thread must not check pickaxeEquipped() during this window.
scanning_now = false

scanAround = function()
    if not HW.has_scanner or not HW.scanner_slot then return {} end
    if not HW.pick_side then return {} end

    -- Check if scanner is already equipped on pick_side
    local scannerOnPickSide = peripheral.isPresent(HW.pick_side)
    if not scannerOnPickSide then
        if turtle.getItemCount(HW.scanner_slot)==0 then
            -- Re-search for the scanner in case it moved
            for s=1,16 do
                local d=turtle.getItemDetail(s)
                if d and isScannerName(d.name) then
                    HW.scanner_slot=s; break
                end
            end
            if turtle.getItemCount(HW.scanner_slot)==0 then
                log("SCAN","Scanner not found in slot "..HW.scanner_slot..". Skipping.")
                return {}
            end
        end
        scanning_now = true
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
    scanning_now = false

    -- Update scanner slot in case the swap moved it
    for s=1,16 do
        local d=turtle.getItemDetail(s)
        if d and isScannerName(d.name) then HW.scanner_slot=s; break end
    end

    if not pickaxeEquipped() then log("WARN","Pickaxe not restored after scan swap.") end
    return results
end

-- ============================================================
-- INVENTORY
-- ============================================================
local function inventoryFull()
    for i=2,15 do if turtle.getItemCount(i)==0 then return false end end
    return true
end
local function freeSlots()
    local n=0; for i=2,15 do if turtle.getItemCount(i)==0 then n=n+1 end end; return n
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

local function hasUnknownAhead()
    local dv = DIRV[facing]
    local fx = pos.x + dv.dx
    local fz = pos.z + dv.dz
    -- Probe trigger: any unknown in the immediate forward tunnel prism.
    return cacheGet(fx, pos.y,   fz) == nil
        or cacheGet(fx, pos.y+1, fz) == nil
        or cacheGet(fx, pos.y-1, fz) == nil
end

local function scanForWanted(scan)
    for _, b in ipairs(scan or {}) do
        local name = tostring(b.name or "")
        if name:find("_ore", 1, true) then
            local key = normalizeOreName(shortName(name))
            if WANT_LIST[key] then
                return key
            end
        end
    end
    return nil
end

local function sendSnapshot(scan)
    local solids={}
    for _,b in ipairs(scan) do
        local n=b.name or ""
        if n~="" and not n:find("air") and not isScanNoise(n) then
            solids[#solids+1]={x=b.x,y=b.y,z=b.z,name=n}
        end
    end
    pcall(rednet.send,server_id,{
        type="GEO_DATA", hwid=hwid, pos=copy(pos),
        scan_data=solids, scan_radius=SCAN_RADIUS,
    },PROTOCOL)
end

-- ============================================================
-- DUMP LOOT
-- ============================================================
local function refreshScannerSlot()
    for s=1,16 do
        local d = turtle.getItemDetail(s)
        if d and isScannerName(d.name) then
            HW.scanner_slot = s
            HW.has_scanner = true
            return s
        end
    end
    return nil
end

-- Items that must NEVER be dropped into the dump chest.
-- Checked by name fragment so "diamond_pickaxe" and
-- "advancedperipherals:geo_scanner" are both caught.
-- Slot 1 is permanently reserved for the geo scanner.
-- Pickaxe is protected by name match.
-- Neither is ever dropped regardless of NBT or getItemDetail quirks.
local function isTool(detail, slot)
    if slot == 1 then return true end   -- slot 1 = scanner, always protected
    if HW.scanner_slot and slot == HW.scanner_slot and turtle.getItemCount(slot) > 0 then
        return true
    end
    if not detail then
        -- Fail-safe: never dump an unknown-detail stack.
        -- This prevents scanner loss when getItemDetail intermittently returns nil.
        return turtle.getItemCount(slot) > 0
    end
    local n = tostring(detail.name or "")
    if isScannerName(n) then return true end
    return n:find("pickaxe") ~= nil
end

local function returnAndDump(resumePos)
    log("DUMP","Cargo full. Heading to DUMP_CHEST...")
    refreshScannerSlot()
    refuelSelf()
    if not dump then log("DUMP","No dump chest set."); return end
    if not moveTo({x=dump.x,y=dump.y+1,z=dump.z}) then
        log("DUMP","Could not reach DUMP_CHEST. Parking 10s."); sleep(10); return
    end
    for i=2,15 do
        if turtle.getItemCount(i) > 0 then
            local detail = turtle.getItemDetail(i)
            if isTool(detail, i) then
                log("DUMP","Keeping tool in slot "..i..": "..((detail and detail.name) or "?"))
            else
                turtle.select(i); turtle.dropDown()
            end
        end
    end
    turtle.select(1)
    local leftover = false
    for i=2,15 do
        if turtle.getItemCount(i) > 0 and not isTool(turtle.getItemDetail(i), i) then
            leftover = true; break
        end
    end
    if leftover then
        log("DUMP","DUMP_CHEST FULL.")
        pcall(rednet.send,server_id,{type="ALERT",hwid=hwid,msg="CHEST_FULL",pos=copy(pos)},PROTOCOL)
        sleep(10); return
    end

    -- Hard guard: after a successful dump, vacate the chest tile so
    -- other turtles can access it and parking logic doesn't stall there.
    if dump and pos.x == dump.x and pos.y == (dump.y + 1) and pos.z == dump.z then
        local y = dump.y + 1
        local candidates = {
            {x=dump.x+1, y=y, z=dump.z},
            {x=dump.x-1, y=y, z=dump.z},
            {x=dump.x,   y=y, z=dump.z+1},
            {x=dump.x,   y=y, z=dump.z-1},
            {x=dump.x,   y=y+1, z=dump.z},
        }
        local moved_off = false
        for _, c in ipairs(candidates) do
            if moveTo(c) then
                moved_off = true
                log("DUMP", string.format("Moved off dump tile to (%d,%d,%d).", c.x, c.y, c.z))
                break
            end
        end
        if not moved_off then
            log("DUMP", "Could not move off dump tile after unload.")
        end
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
    refreshScannerSlot()
    if not moveTo({x=base.x,y=base.y+1,z=base.z}) then log("FUEL","Cannot reach base."); sleep(10); return end
    -- Slot 1 is reserved for the scanner. Pull coal into slots 2-15 only.
    for s=2,15 do if turtle.getItemCount(s)==0 then turtle.select(s); if not turtle.suckDown(64) then break end end end
    burnAboard(FUEL_TARGET)
    for s=2,15 do
        turtle.select(s)
        if turtle.getItemCount(s)>0 and not turtle.refuel(0) then
            if not isTool(turtle.getItemDetail(s), s) then
                turtle.dropDown()
            end
        end
    end
    turtle.select(2); moveTo(resume); face(my_dir)
    log("FUEL","Fuel = "..tostring(turtle.getFuelLevel()))
end

-- ============================================================
-- PICKAXE FETCH FROM BASE_CHEST
-- ============================================================
local function fetchPickaxeFromBase(resumePos)
    if not base then
        log("PICK","No BASE_CHEST set. Cannot fetch pickaxe.")
        if server_id then
            pcall(rednet.send, server_id, {type="ALERT", hwid=hwid, msg="NO_BASE_CHEST_FOR_PICK", pos=copy(pos)}, PROTOCOL)
        end
        return false
    end
    log("PICK","Heading to BASE_CHEST for a pickaxe...")
    if not moveTo({x=base.x,y=base.y+1,z=base.z}) then
        log("PICK","Cannot reach BASE_CHEST.")
        if server_id then
            pcall(rednet.send, server_id, {type="ALERT", hwid=hwid, msg="BASE_CHEST_UNREACHABLE", pos=copy(pos)}, PROTOCOL)
        end
        return false
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
                        -- Use slots 2-15 only; slot 1 is reserved for scanner
                        for ts=2,15 do
                            if turtle.getItemCount(ts)==0 then
                                turtle.select(ts); turtle.suckDown(1)
                                local got=turtle.getItemDetail(ts)
                                if got and isEquippable(got) then
                                    equipOnPickaxeSide()
                                    if pickaxeEquipped() then
                                        log("PICK","Pickaxe equipped. OK")
                                        turtle.select(2); return true
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
            for ts=2,15 do
                if turtle.getItemCount(ts)==0 then
                    turtle.select(ts)
                    if not turtle.suckDown(1) then break end
                    local got=turtle.getItemDetail(ts)
                    if got and isEquippable(got) then
                        equipOnPickaxeSide()
                        if pickaxeEquipped() then log("PICK","Pickaxe equipped (fallback). OK"); turtle.select(2); return true end
                    end
                    turtle.dropDown(); break
                end
            end
        end
        return false
    end

    local fetched = tryFetch()
    if not fetched then
        local retries = 0
        local max_retries = 12  -- 2 minutes at 10s each
        log("PICK","No pickaxe available in BASE_CHEST. Retrying up to 2 minutes...")
        while not fetched and retries < max_retries do
            sleep(10)
            retries = retries + 1
            fetched = tryFetch()
        end
    end

    if not fetched then
        log("PICK","Timed out waiting for pickaxe at BASE_CHEST.")
        if resumePos then moveTo(resumePos); face(my_dir) end
        return false
    end

    if resumePos then moveTo(resumePos); face(my_dir) end
    return true
end

-- ============================================================
-- WAKE-UP FUEL SEQUENCE
-- ============================================================
local function wakeUp()
    log("WAKE","Fuel check. Current = "..tostring(turtle.getFuelLevel()))
    burnAboard(FUEL_TARGET)
    log("WAKE","After burn. Fuel = "..tostring(turtle.getFuelLevel()))
    if fuelLevel()==0 then
        log("WAKE","EMPTY. Drop coal in slots 2-15 (slot 1 reserved for scanner)...")
        local retries = 0
        local max_retries = 30  -- 60 seconds
        while fuelLevel()==0 and retries < max_retries do
            burnAboard(FUEL_TARGET)
            sleep(2)
            retries = retries + 1
        end
        if fuelLevel()==0 then
            log("WAKE","No fuel received after 60s. Continuing in passive mode.")
            return false
        end
        log("WAKE","Got fuel = "..tostring(turtle.getFuelLevel()))
    end
    if fuelLevel()<FUEL_TARGET then
        log("WAKE","Below target. Will forage after calibration.")
    else log("WAKE","Fuel target reached.") end
    return true
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

    -- Unequip anything on the pick side first, into slots 2-16 only
    if peripheral.isPresent(HW.pick_side) then
        log("INIT","Peripheral on "..HW.pick_side..". Moving to free slot...")
        for s=2,16 do
            if turtle.getItemCount(s)==0 then
                turtle.select(s); equipOnPickaxeSide()
                local got=turtle.getItemDetail(s)
                if got and isScannerName(got.name) then HW.scanner_slot=s end
                log("INIT","Cleared "..HW.pick_side.." slot -> inventory slot "..s)
                break
            end
        end
    end

    -- Find a pickaxe in inventory slots 2-16 (slot 1 is reserved for scanner)
    for s=2,16 do
        local detail=turtle.getItemDetail(s)
        if detail then
            local name=tostring(detail.name or "")
            if name:find("pickaxe") then
                if not isEquippable(detail) then
                    log("INIT","Slot "..s..": pickaxe is damaged/enchanted. Skipping.")
                else
                    log("INIT","Equipping pickaxe from slot "..s.." onto "..HW.pick_side.."...")
                    turtle.select(s); equipOnPickaxeSide()
                    local swapped=turtle.getItemDetail(s)
                    if swapped and isScannerName(swapped.name) then HW.scanner_slot=s end
                    if pickaxeEquipped() then log("INIT","Pickaxe equipped. OK"); turtle.select(2); return true end
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
    local attempts = 0
    local max_attempts = 24  -- 2 minutes at 5s timeouts
    while not server_id and attempts < max_attempts do
        rednet.broadcast({type="AUTH_REQ",hwid=hwid,pos=copy(pos)},PROTOCOL)
        local sender,msg=rednet.receive(PROTOCOL,5)
        if sender and type(msg)=="table" and msg.type=="AUTH_ACK" and msg.hwid==hwid then
            server_id    = sender
            my_dir       = msg.direction   or 0
            lane_offset  = msg.lane_offset or 0
            dump         = msg.dump
            base         = msg.base
            if type(msg.want) == "table" then WANT_LIST = msg.want end
            park_pos     = msg.park   -- may be nil if no zone set
            if dump then cacheSet(dump.x,dump.y,dump.z,"minecraft:chest") end
            if base then cacheSet(base.x,base.y,base.z,"minecraft:chest") end
            face(my_dir)
            log("AUTH",string.format("Enlisted. Dir=%d Lane=+%d Park=%s Server=%d",
                my_dir, lane_offset,
                park_pos and string.format("(%d,%d,%d)",park_pos.x,park_pos.y,park_pos.z) or "none",
                server_id))
            log("AUTH","Awaiting CMD_START from Overseer.")
        else
            attempts = attempts + 1
            log("AUTH","No reply. Retrying...")
        end
    end
    if not server_id then
        log("AUTH","No overseer after 2 minutes. Entering passive retry mode.")
        return false
    end
    return true
end

-- ============================================================
-- PHASE 2: STATE MACHINE
-- ============================================================
-- States and their O-NET V1 move priorities:
--   STANDBY    (8) waiting for CMD_START
--   MINING     (5) tunnelling forward, scanning, reporting
--   RTB_DUMP   (3) cargo full, returning to dump chest
--   RTB_FUEL   (2) critically low fuel, returning to base chest
--   FETCH_PICK (4) no pickaxe, going to base chest to get one
--   GOTO       (1) executing targeted ore retrieval — never yields
--   PARKED     (9) finished a run, waiting for next start — always yields
--
-- The brain loop calls the current state function each tick.
-- Each state function returns the name of the next state.
-- Every transition is logged locally and sent to the overseer.
-- ============================================================

local current_state   = "STANDBY"
local tunnelled       = 0
local goto_job        = nil
local lane_offset     = 0
local lane_positioned = false
local park_pos        = nil   -- assigned parking slot, nil = park in place

-- O-NET V1: navigation state at module level so it survives brain pcall
-- restarts. In M-NET V3 these were locals inside moveTo — a brain crash
-- mid-navigation reset the stuck counter to zero, allowing infinite
-- thrash loops. Now the counter accumulates across crashes.
-- Mirrors Overmind's STATE_PREV_X/Y and STATE_STUCK in creep memory.
local nav_stuck_cnt  = 0      -- ticks with unchanged position (Overmind: STATE_STUCK)
local nav_prev_pos   = nil    -- position snapshot from previous nav tick (for persistence / serialization)
local block_movement = false  -- set by YIELD handler; cleared after one move attempt

local function setState(new_state)
    if new_state ~= current_state then
        log("STATE", current_state .. " -> " .. new_state)
        current_state = new_state
        -- Broadcast state change in the next heartbeat automatically
    end
end

-- ── STANDBY ──────────────────────────────────────────────
local function state_STANDBY()
    if started then
        reported = {}   -- fresh run, clear ore report cache
        return "MINING"
    end
    if park_pos then
        local dist = math.abs(pos.x-park_pos.x)
                   + math.abs(pos.y-park_pos.y)
                   + math.abs(pos.z-park_pos.z)
        if dist > 0 then
            log("PARK","Moving to park slot ("..park_pos.x..","..park_pos.y..","..park_pos.z..")...")
            local ok = moveTo(park_pos)
            if ok then
                log("PARK","At park slot. Waiting for start.")
            else
                log("PARK","Could not reach park slot from standby.")
                if server_id then
                    pcall(rednet.send, server_id, {
                        type="ALERT", hwid=hwid, msg="PARK_BLOCKED", pos=copy(pos)
                    }, PROTOCOL)
                end
            end
        end
    end
    sleep(0.5)
    return "STANDBY"
end

-- ── PARKED ───────────────────────────────────────────────
local function state_PARKED()
    if park_pos then
        local dist = math.abs(pos.x-park_pos.x)
                   + math.abs(pos.y-park_pos.y)
                   + math.abs(pos.z-park_pos.z)
        if dist > 0 then
            log("PARK","Navigating to park slot ("..park_pos.x..","..park_pos.y..","..park_pos.z..")...")
            local ok = moveTo(park_pos)
            if ok then
                log("PARK","Parked. Awaiting CMD_START.")
            else
                log("PARK","Could not reach park slot; remaining at current position.")
                if server_id then
                    pcall(rednet.send, server_id, {
                        type="ALERT", hwid=hwid, msg="PARK_BLOCKED", pos=copy(pos)
                    }, PROTOCOL)
                end
            end
        end
    end
    if started then
        tunnelled = 0
        reported  = {}   -- clear ore report cache so next run re-reports finds
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
    -- Do not check pickaxe mid-scan: the scanner is temporarily on pick_side
    if not scanning_now and not pickaxeEquipped() then return "FETCH_PICK" end

    refuelSelf()
    if fuelLevel() > 0 and fuelLevel() < FUEL_CRITICAL then return "RTB_FUEL" end
    if fuelLevel() <= 0 then log("FUEL","Zero fuel. Halting."); sleep(10); return "MINING" end
    if inventoryFull()  then return "RTB_DUMP" end

    -- Proactive targeted probe mode:
    -- If we're heading into unknown space, scan before stepping so
    -- wanted ores can be dispatched immediately instead of waiting for
    -- cadence-only scans.
    probe_ticks = probe_ticks + 1
    if HW.has_scanner and not scanning_now and probe_ticks >= 2 and hasUnknownAhead() then
        probe_ticks = 0
        local snap = scanAround()
        if snap and #snap > 0 then
            reportOres(snap)
            sendSnapshot(snap)
            local wanted = scanForWanted(snap)
            if wanted then
                log("PROBE","Wanted ore seen in pre-step probe: "..wanted)
            end
        end
    end

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
                    cacheSet(pos.x, pos.y+1, pos.z, "air")
                    -- Report air above to overseer so map clears
                    pcall(rednet.send, server_id, {
                        type="GEO_DATA", hwid=hwid, pos=copy(pos),
                        scan_data={{ x=0, y=1, z=0, name="minecraft:air" }},
                    }, PROTOCOL)
                else
                    log("MINE","Protected block above ["..name_up.."]. Leaving it.")
                end
            end
        else
            -- Nothing above = already air, mark it so nav knows
            cacheSet(pos.x, pos.y+1, pos.z, "air")
        end

        -- O-NET V1: random GPS sync (Overmind repath probability).
        -- Expected frequency ~1/8 blocks, same as before, but each turtle
        -- rolls independently so the whole fleet doesn't hit GPS simultaneously.
        if math.random() < REPATH_PROB then
            log("MINE", string.format("t=%d fuel=%s free=%d pos=(%d,%d,%d)",
                tunnelled, tostring(turtle.getFuelLevel()), freeSlots(),
                pos.x, pos.y, pos.z))
            gpsSyncPos()
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
    refreshScannerSlot()
    refuelSelf()
    if not dump then
        log("DUMP","No dump chest set. Parking.")
        return "PARKED"
    end

    if moveTo({x=dump.x, y=dump.y+1, z=dump.z}) then
        for i=2,15 do
            if turtle.getItemCount(i) > 0 then
                local detail = turtle.getItemDetail(i)
                if isTool(detail, i) then
                    log("DUMP","Keeping tool in slot "..i..": "..(detail and detail.name or "?"))
                else
                    turtle.select(i); turtle.dropDown()
                end
            end
        end
        turtle.select(1)

        local leftover = false
        for i=2,15 do
            if turtle.getItemCount(i)>0 and not isTool(turtle.getItemDetail(i), i) then
                leftover=true; break
            end
        end
        if leftover then
            log("DUMP","DUMP_CHEST FULL. Cargo remains.")
            pcall(rednet.send, server_id,
                {type="ALERT",hwid=hwid,msg="CHEST_FULL",pos=copy(pos)}, PROTOCOL)
            sleep(10)
            -- Prevent RTB_DUMP <-> MINING thrash when chest is full.
            started = false
            return "PARKED"
        else
            refuelSelf()
            log("DUMP","Emptied successfully.")

            -- Hard guard: move off chest tile after successful unload.
            if dump and pos.x == dump.x and pos.y == (dump.y + 1) and pos.z == dump.z then
                local y = dump.y + 1
                local candidates = {
                    {x=dump.x+1, y=y, z=dump.z},
                    {x=dump.x-1, y=y, z=dump.z},
                    {x=dump.x,   y=y, z=dump.z+1},
                    {x=dump.x,   y=y, z=dump.z-1},
                    {x=dump.x,   y=y+1, z=dump.z},
                }
                local moved_off = false
                for _, c in ipairs(candidates) do
                    if moveTo(c) then
                        moved_off = true
                        log("DUMP", string.format("Moved off dump tile to (%d,%d,%d).", c.x, c.y, c.z))
                        break
                    end
                end
                if not moved_off then
                    log("DUMP", "Could not move off dump tile after unload.")
                end
            end
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
        fuel_retry_streak = fuel_retry_streak + 1
        if fuel_retry_streak >= 6 then
            log("FUEL","No BASE_CHEST persists. Parking to avoid deadlock.")
            started = false
            if server_id then
                pcall(rednet.send, server_id, {
                    type="ALERT", hwid=hwid, msg="RTB_FUEL_NO_BASE", pos=copy(pos)
                }, PROTOCOL)
            end
            return "PARKED"
        end
        return "RTB_FUEL"
    end
    local resume = copy(pos)
    log("FUEL","Critical fuel. Heading to BASE_CHEST...")

    if moveTo({x=base.x, y=base.y+1, z=base.z}) then
        -- Slot 1 is reserved for scanner. Pull coal into slots 2-15 only.
        for s=2,15 do
            if turtle.getItemCount(s)==0 then
                turtle.select(s)
                if not turtle.suckDown(64) then break end
            end
        end
        burnAboard(FUEL_TARGET)
        for s=2,15 do
            turtle.select(s)
            if turtle.getItemCount(s)>0 and not turtle.refuel(0) then
                if not isTool(turtle.getItemDetail(s), s) then turtle.dropDown() end
            end
        end
        turtle.select(2)
        log("FUEL","Refuelled. Fuel = "..tostring(turtle.getFuelLevel()))
        moveTo(resume)
        face(my_dir)
        fuel_retry_streak = 0
    else
        log("FUEL","Could not reach BASE_CHEST. Parking 10s.")
        sleep(10)
        fuel_retry_streak = fuel_retry_streak + 1
    end

    -- Recheck: if still critical after the trip, go back rather than mining dry
    if fuelLevel() < FUEL_CRITICAL then
        log("FUEL","Still critical after refuel attempt. Retrying.")
        fuel_retry_streak = fuel_retry_streak + 1
        if fuel_retry_streak >= 6 then
            log("FUEL","Retry limit reached. Parking to avoid deadlock.")
            started = false
            if server_id then
                pcall(rednet.send, server_id, {
                    type="ALERT", hwid=hwid, msg="RTB_FUEL_STALLED", pos=copy(pos)
                }, PROTOCOL)
            end
            return "PARKED"
        end
        return "RTB_FUEL"
    end
    fuel_retry_streak = 0
    return "MINING"
end

-- ── FETCH_PICK ───────────────────────────────────────────
local function state_FETCH_PICK()
    -- Wait out any in-progress scan before concluding the pick is missing.
    -- The heartbeat scanner hot-swap puts a peripheral on pick_side for ~1s.
    -- Without this wait, a false FETCH_PICK triggers every scan cycle.
    local ticks = 0
    while scanning_now and ticks < 20 do sleep(0.3); ticks=ticks+1 end

    -- Re-check now that we are sure no scan is running
    if pickaxeEquipped() then
        log("PICK","Pickaxe IS equipped (false alarm, scan was mid-swap). Resuming.")
        return started and "MINING" or "STANDBY"
    end

    log("PICK","Pickaxe confirmed missing. Heading to BASE_CHEST...")
    fetchPickaxeFromBase(copy(pos))
    if pickaxeEquipped() then
        return started and "MINING" or "STANDBY"
    end
    log("PICK","Still no pickaxe after fetch. Parking.")
    return "PARKED"
end

-- ── GOTO ─────────────────────────────────────────────────
-- Travels to the ore cluster centroid dispatched by the overseer.
-- Checks inventory full before starting — dig() silently fails when full.
-- Vein sweep: inspects all 6 faces, digs any block matching ore_name,
-- repeats until no more adjacent matches (max MAX_VEIN = 32 blocks).
-- Reports each mined block individually via ORE_MINED to the overseer.
-- Returns to resume position and continues mining.
local function state_GOTO()
    if not goto_job then return "MINING" end
    local job = goto_job
    goto_job  = nil

    local resume = copy(pos)
    local ore_name = job.ore or "ore"
    log("GOTO", string.format("Heading to %s cluster (%d,%d,%d)",
        ore_name, job.pos.x, job.pos.y, job.pos.z))

    if not pickaxeEquipped() then
        log("GOTO","No pickaxe. Skipping job.")
        return "FETCH_PICK"
    end

    if not moveTo(job.pos) then
        log("GOTO","Could not reach cluster. Skipping.")
        moveTo(resume); face(my_dir)
        return started and "MINING" or "STANDBY"
    end

    -- Check inventory before starting the sweep. dig() silently fails when full.
    if inventoryFull() then
        log("GOTO","Inventory full. Dumping before mining vein.")
        moveTo(resume); face(my_dir)
        return "RTB_DUMP"
    end

    -- Vein sweep: check all 6 faces repeatedly until no more ore found.
    -- Limit passes to avoid infinite loops in huge veins.
    local mined_total = 0
    local MAX_VEIN    = 32   -- max blocks to mine in one GOTO job
    local changed     = true

    while changed and mined_total < MAX_VEIN do
        changed = false

        -- Check front (all 4 horizontal faces by rotating)
        for _ = 1, 4 do
            local ok, data = turtle.inspect()
            if ok and type(data) == "table" then
                local n = data.name or ""
                if n:find(ore_name, 1, true) then
                    if turtle.dig() then
                        cacheSet(pos.x+DIRV[facing].dx, pos.y, pos.z+DIRV[facing].dz, "air")
                        pcall(rednet.send, server_id, {
                            type="GEO_DATA", hwid=hwid, pos=copy(pos),
                            scan_data={{x=DIRV[facing].dx, y=0, z=DIRV[facing].dz, name="minecraft:air"}},
                        }, PROTOCOL)
                        pcall(rednet.send, server_id,
                            {type="ORE_MINED", hwid=hwid, ore=ore_name,
                             pos={x=pos.x+DIRV[facing].dx, y=pos.y, z=pos.z+DIRV[facing].dz}},
                            PROTOCOL)
                        mined_total = mined_total + 1
                        changed = true
                    end
                end
            end
            turnRight()
        end

        -- Check above
        local ok_u, dat_u = turtle.inspectUp()
        if ok_u and type(dat_u)=="table" then
            local n = dat_u.name or ""
            if n:find(ore_name, 1, true) then
                if turtle.digUp() then
                    cacheSet(pos.x, pos.y+1, pos.z, "air")
                    pcall(rednet.send, server_id,
                        {type="ORE_MINED", hwid=hwid, ore=ore_name,
                         pos={x=pos.x, y=pos.y+1, z=pos.z}}, PROTOCOL)
                    mined_total = mined_total + 1
                    changed = true
                end
            end
        end

        -- Check below
        local ok_d, dat_d = turtle.inspectDown()
        if ok_d and type(dat_d)=="table" then
            local n = dat_d.name or ""
            if n:find(ore_name, 1, true) then
                if turtle.digDown() then
                    cacheSet(pos.x, pos.y-1, pos.z, "air")
                    pcall(rednet.send, server_id,
                        {type="ORE_MINED", hwid=hwid, ore=ore_name,
                         pos={x=pos.x, y=pos.y-1, z=pos.z}}, PROTOCOL)
                    mined_total = mined_total + 1
                    changed = true
                end
            end
        end
    end

    if mined_total > 0 then
        log("GOTO", string.format("Vein complete: %d %s mined.", mined_total, ore_name))
    else
        log("GOTO", "No matching ore found at cluster location (already mined or wrong coords).")
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

-- O-NET V1: returns this turtle's current move priority.
-- Lower = higher urgency. Used by the push protocol.
local function getMovePriority()
    return MOVE_PRIORITY[current_state] or 10
end

local function brainThread_inner()
    -- Boot pickaxe check: wait for any in-progress scan to finish first,
    -- then check. This prevents the scanner being mid-swap from triggering
    -- a spurious FETCH_PICK loop on every brain thread restart.
    local wait_ticks = 0
    while scanning_now and wait_ticks < 20 do sleep(0.5); wait_ticks=wait_ticks+1 end

    if not pickaxeEquipped() then
        log("PICK","No pickaxe detected at boot. Fetching from BASE_CHEST...")
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
        if server_id then
            -- Send state name so the overseer cockpit shows full state
            pcall(rednet.send, server_id, {
                type   = "HEARTBEAT",
                hwid   = hwid,
                fuel   = turtle.getFuelLevel(),
                pos    = copy(pos),
                free   = freeSlots(),
                status = current_state,
            }, PROTOCOL)
        else
            -- Passive re-enlist if boot handshake timed out.
            pcall(rednet.broadcast, {
                type = "AUTH_REQ",
                hwid = hwid,
                pos  = copy(pos),
                fuel = turtle.getFuelLevel(),
            }, PROTOCOL)
        end

        scan_ticker = scan_ticker + 1
        if scan_ticker >= 5 and HW.has_scanner and not scanning_now then
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
        local sender,msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            if     msg.type=="CMD_START"  then started=true;        log("CMD","Start received.")
            elseif msg.type=="CMD_STOP"   then started=false;       log("CMD","Stop received.")
            elseif msg.type=="CMD_RECALL" then home_requested=true; log("CMD","Recall received.")
            elseif msg.type=="CONFIG" then
                if msg.dump then dump=msg.dump; cacheSet(dump.x,dump.y,dump.z,"minecraft:chest") end
                if msg.base then base=msg.base; cacheSet(base.x,base.y,base.z,"minecraft:chest") end
                                if type(msg.want)=="table" then WANT_LIST=msg.want end
                if msg.direction   then my_dir=msg.direction end
                if msg.park ~= nil then
                    park_pos = msg.park
                    log("CFG","Park slot: "..(park_pos and
                        string.format("(%d,%d,%d)",park_pos.x,park_pos.y,park_pos.z) or "cleared"))
                end
                if msg.lane_offset then
                    lane_offset     = msg.lane_offset
                    lane_positioned = false
                    log("CFG","Lane reassigned. Dir="..my_dir.." offset=+"..lane_offset)
                end
                log("CFG","Config updated from Overseer.")
            elseif msg.type=="GOTO" and msg.hwid==hwid and type(msg.pos)=="table" then
                log("GOTO","Job queued: "..(msg.ore or "ore"))
                table.insert(jobs, msg)

            elseif msg.type=="AUTH_ACK" and msg.hwid==hwid then
                server_id    = sender
                my_dir       = msg.direction   or my_dir
                lane_offset  = msg.lane_offset or lane_offset
                dump         = msg.dump or dump
                base         = msg.base or base
                                if type(msg.want)=="table" then WANT_LIST=msg.want end
                park_pos     = msg.park or park_pos
                if dump then cacheSet(dump.x,dump.y,dump.z,"minecraft:chest") end
                if base then cacheSet(base.x,base.y,base.z,"minecraft:chest") end
                face(my_dir)
                log("AUTH", string.format("Late AUTH_ACK accepted. Server=%d dir=%d lane=+%d",
                    server_id, my_dir, lane_offset))

            elseif msg.type=="RESERVE_ACK" and msg.hwid==hwid then
                local nonce = tonumber(msg.nonce)
                if nonce and reservation_pending[nonce] then
                    reservation_pending[nonce].done = true
                    reservation_pending[nonce].granted = (msg.granted == true)
                end

            -- O-NET V1: PUSH protocol (Overmind pushCreep equivalent).
            -- PUSH_REQ is broadcast by any turtle that is stuck.
            -- If this turtle is at the blocked position AND has lower (higher-number)
            -- priority than the pusher, step aside to yield the tile.
            elseif msg.type=="PUSH_REQ" and msg.hwid~=hwid then
                local want = msg.want
                if want and type(want)=="table" then
                    local at_target = (pos.x==want.x and pos.y==want.y and pos.z==want.z)
                    local our_priority = getMovePriority()
                    local their_priority = tonumber(msg.priority) or 10
                    -- We yield if we are at the tile they want AND our priority <= urgency
                    -- (higher number = less urgent = should yield)
                    if at_target and our_priority >= their_priority then
                        log("PUSH","Yielding to "..tostring(msg.hwid)..
                            " (their pri="..their_priority.." our pri="..our_priority..")")
                        -- Step away: try up first (safest, doesn't block horizontal path),
                        -- then any horizontal direction away from the pusher.
                        local yielded = stepUp()
                        if not yielded then
                            local at = msg.at
                            for dir=0,3 do
                                face(dir)
                                -- Don't step toward the pusher
                                local nx = pos.x + DIRV[dir].dx
                                local nz = pos.z + DIRV[dir].dz
                                if not (at and nx==at.x and nz==at.z) then
                                    if stepForward() then yielded=true; break end
                                end
                            end
                        end
                        if yielded then
                            log("PUSH","Yielded. Moved to ("..pos.x..","..pos.y..","..pos.z..")")
                            block_movement = true  -- don't move back immediately
                        else
                            log("PUSH","Could not yield (all directions blocked).")
                        end
                    end
                end

            -- O-NET V1: YIELD command sent directly by overseer (future expansion).
            -- Overseer can command a specific turtle to move aside.
            elseif msg.type=="YIELD" and msg.hwid==hwid then
                log("PUSH","Overseer YIELD command received. Stepping aside...")
                local yielded = stepUp()
                if not yielded then
                    for dir=0,3 do
                        face(dir)
                        if stepForward() then yielded=true; break end
                    end
                end
                block_movement = true
                log("PUSH","YIELD "..( yielded and "done" or "failed")..".")

                -- Confirm YIELD handling so broker logic can resolve without timeout.
                if sender then
                    pcall(rednet.send, sender, {
                        type  = "YIELD_ACK",
                        hwid  = hwid,
                        ok    = yielded,
                        pos   = copy(pos),
                        state = current_state,
                    }, PROTOCOL)
                end
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
print("+--------------------------------------+")
print("|   O-NET V1  |  MINER  (Phase 1-5)  |")
print("+--------------------------------------+")
log("INIT","HWID: "..hwid)

detectHardware()   -- 1. find everything, touch nothing
openModem()        -- 2. open rednet on detected modem
local woke = wakeUp()   -- 3. burn aboard fuel, wait if empty
calibrate()        -- 4. restore from disk or GPS-derive heading
local authed = handshake() -- 5. enlist, get base+dump coords
bootEquipPickaxe() -- 6. equip pickaxe now that we can navigate
forageForCoal()    -- 7. mine coal if still below target

if not woke then
    log("BOOT","Fuel bootstrap timed out. Waiting for manual fuel or base refuel cycle.")
end
if not authed then
    log("BOOT","Running in passive auth retry mode until overseer responds.")
end

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
