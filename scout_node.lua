--[[
    M-NET V3 | MINER NODE  (geo-seek worker)
    =========================================
    Role : Tunnels in an assigned direction, hot-swap geo-scans for ore,
           reports finds to the Overseer, detours to mine GOTO targets,
           refuels itself from mined coal, and returns to a base chest to
           dump loot when full.

    HARDWARE (exact layout matters):
        RIGHT slot : Ender Modem      (permanent, comms)
        LEFT  slot : Diamond Pickaxe  (default; swapped with scanner)
        SLOT 16    : Geo Scanner ITEM (reserved; never used for loot)
        Fuel       : a little coal to start; it sustains itself after that

    REQUIRES : a working GPS constellation in this dimension. Navigation is
               dead-reckoning calibrated by GPS at boot, so no GPS = no movement.

    INSTALL  : save as startup.lua on each mining turtle, then reboot.

    NAV NOTE : the navigator is a pragmatic greedy digger (straight lines,
               digs through stone, avoids lava/bedrock by bailing). It is not
               full A* pathfinding, so in heavy lava/cave terrain a GOTO may
               report STUCK rather than reaching the block.
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
local PROTOCOL      = "MNET_V3"
local SCAN_RADIUS   = 8      -- geo scanner radius (8 is the free tier)
local SCAN_EVERY    = 4      -- tunnel this many blocks between scans
local HEARTBEAT_INT = 3      -- seconds between heartbeats
local FUEL_MIN      = 200    -- refuel from inventory below this level
local MAX_TUNNEL    = 256    -- blocks to tunnel before turning back
local SCANNER_SLOT  = 16     -- reserved inventory slot holding the scanner

-- ============================================================
-- STATE
-- ============================================================
local hwid        = string.format("MN-%04X", os.getComputerID() % 0xFFFF)
local server_id   = nil
local base        = nil           -- { x, y, z } of the drop chest
local my_dir      = 0             -- assigned facing (0=N,1=E,2=S,3=W)
local started     = false
local has_scanner = false

-- Position + heading, maintained by dead reckoning
local pos    = { x = 0, y = 0, z = 0 }
local facing = 0                  -- 0=N(-z) 1=E(+x) 2=S(+z) 3=W(-x)
local DIRV   = { [0]={dx=0,dz=-1}, [1]={dx=1,dz=0}, [2]={dx=0,dz=1}, [3]={dx=-1,dz=0} }

local jobs     = {}               -- queue of GOTO targets
local reported = {}               -- de-dupe set of reported ore coords

-- ============================================================
-- SMALL HELPERS
-- ============================================================
local function copy(p) return { x = p.x, y = p.y, z = p.z } end
local function key(p) return p.x .. ":" .. p.y .. ":" .. p.z end
local function shortName(n) return (n:match(":(.+)") or n) end

-- ============================================================
-- GPS + HEADING CALIBRATION
-- ============================================================
local function gpsPos()
    local x, y, z = gps.locate(2)
    if x then return { x = x, y = y, z = z } end
    return nil
end

local function calibrate()
    local p1 = gpsPos()
    if not p1 then error("[FATAL] No GPS fix. Build a GPS constellation first.", 0) end

    -- Move one block to read a heading. Dig/attack if the way is blocked.
    local moved = false
    for _ = 1, 12 do
        if turtle.forward() then moved = true break end
        if not turtle.dig() then turtle.attack() end
        sleep(0.2)
    end
    if not moved then error("[FATAL] Boxed in. Cannot calibrate heading.", 0) end

    local p2 = gpsPos()
    if not p2 then error("[FATAL] Lost GPS during calibration.", 0) end

    local dx, dz = p2.x - p1.x, p2.z - p1.z
    if     dx ==  1 then facing = 1
    elseif dx == -1 then facing = 3
    elseif dz ==  1 then facing = 2
    elseif dz == -1 then facing = 0
    else error("[FATAL] Calibration move was not a single horizontal step.", 0) end

    pos = copy(p2)
    print(string.format("[NAV]   Calibrated at (%d,%d,%d) facing %d", pos.x, pos.y, pos.z, facing))
end

-- ============================================================
-- MOVEMENT (maintains pos + facing)
-- ============================================================
local function turnRight() turtle.turnRight() facing = (facing + 1) % 4 end
local function turnLeft()  turtle.turnLeft()  facing = (facing + 3) % 4 end

local function face(target)
    while facing ~= target do
        if (target - facing) % 4 == 1 then turnRight() else turnLeft() end
    end
end

local function isLava(ok, data)
    return ok and data and data.name and data.name:find("lava") ~= nil
end

local function forward()
    if isLava(turtle.inspect()) then return false end  -- never bore into lava
    if not turtle.forward() then
        local tries = 0
        while turtle.detect() do
            if not turtle.dig() then turtle.attack() end
            tries = tries + 1
            if tries > 64 then return false end          -- bedrock or endless source
            sleep(0.2)
        end
        if not turtle.forward() then return false end
    end
    pos.x = pos.x + DIRV[facing].dx
    pos.z = pos.z + DIRV[facing].dz
    return true
end

local function up()
    if isLava(turtle.inspectUp()) then return false end
    if not turtle.up() then
        if not turtle.digUp() then turtle.attackUp() end
        if not turtle.up() then return false end
    end
    pos.y = pos.y + 1
    return true
end

local function down()
    if isLava(turtle.inspectDown()) then return false end
    if not turtle.down() then
        if not turtle.digDown() then turtle.attackDown() end
        if not turtle.down() then return false end
    end
    pos.y = pos.y - 1
    return true
end

-- Greedy axis movers
local function moveX(tx)
    while pos.x ~= tx do
        face(pos.x < tx and 1 or 3)
        if not forward() then return false end
    end
    return true
end
local function moveZ(tz)
    while pos.z ~= tz do
        face(pos.z < tz and 2 or 0)
        if not forward() then return false end
    end
    return true
end
local function moveY(ty)
    while pos.y ~= ty do
        if pos.y < ty then if not up() then return false end
        else                if not down() then return false end end
    end
    return true
end

-- Try two axis orderings; good enough for stone, bails on lava/bedrock.
local function moveTo(t)
    if moveY(t.y) and moveX(t.x) and moveZ(t.z) then return true end
    if moveX(t.x) and moveZ(t.z) and moveY(t.y) then return true end
    return pos.x == t.x and pos.y == t.y and pos.z == t.z
end

-- ============================================================
-- FUEL (self-sustaining)
-- ============================================================
local function refuelSelf()
    if turtle.getFuelLevel() == "unlimited" then return end
    if turtle.getFuelLevel() >= FUEL_MIN then return end
    for slot = 1, 15 do
        turtle.select(slot)
        if turtle.refuel(0) then turtle.refuel() end
        if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() >= FUEL_MIN then break end
    end
    turtle.select(1)
end

-- ============================================================
-- INVENTORY
-- ============================================================
local function inventoryFull()
    for i = 1, 15 do if turtle.getItemCount(i) == 0 then return false end end
    return true
end

-- ============================================================
-- GEO SCAN via hot-swap (pickaxe <-> scanner on the LEFT slot)
-- ============================================================
local function scanAround()
    if not has_scanner then return {} end

    turtle.select(SCANNER_SLOT)
    turtle.equipLeft()                 -- scanner -> left, pickaxe -> slot 16
    local scanner = peripheral.wrap("left")

    local results = {}
    if scanner and scanner.scan then
        local ok, r = pcall(scanner.scan, SCAN_RADIUS)
        if ok and type(r) == "table" then results = r end
    end

    turtle.select(SCANNER_SLOT)
    turtle.equipLeft()                 -- pickaxe -> left, scanner -> slot 16
    turtle.select(1)
    return results
end

-- Report any new ore blocks to the overseer (absolute coords, de-duped)
local function reportOres(scan)
    for _, b in ipairs(scan) do
        local name = b.name or ""
        if name:find("_ore") then
            local ax = pos.x + (b.x or 0)
            local ay = pos.y + (b.y or 0)
            local az = pos.z + (b.z or 0)
            local abs = { x = ax, y = ay, z = az }
            if not reported[key(abs)] then
                reported[key(abs)] = true
                pcall(rednet.send, server_id, {
                    type = "ORE_REPORT",
                    hwid = hwid,
                    ore  = shortName(name),
                    pos  = abs,
                }, PROTOCOL)
            end
        end
    end
end

-- ============================================================
-- RETURN TO BASE + DUMP
-- ============================================================
local function returnAndDump(resume)
    print("[RTB]   Inventory full. Returning to base chest...")
    refuelSelf()
    if not base then print("[RTB]   No base set, cannot dump.") return end

    -- Dock one block above the chest and drop down into it.
    if not moveTo({ x = base.x, y = base.y + 1, z = base.z }) then
        print("[RTB]   Could not reach base. Parking.")
        return
    end

    for i = 1, 15 do
        turtle.select(i)
        turtle.dropDown()
    end
    turtle.select(1)
    refuelSelf()
    print("[RTB]   Dump complete. Returning to work face...")

    if resume then
        moveTo(resume)
        face(my_dir)
    end
end

-- ============================================================
-- GOTO JOB: detour, mine the ore, come back
-- ============================================================
local function doJob(job)
    local resume = copy(pos)
    print(string.format("[GOTO]  Fetching %s at (%d,%d,%d)", job.ore or "ore", job.pos.x, job.pos.y, job.pos.z))

    if moveTo(job.pos) then
        -- arriving dug the block; it is now in inventory
        pcall(rednet.send, server_id, { type = "ORE_MINED", hwid = hwid, ore = job.ore, pos = job.pos }, PROTOCOL)
    else
        print("[GOTO]  Could not reach target (lava/bedrock). Skipping.")
    end

    if not moveTo(resume) then print("[GOTO]  Could not return to work face.") end
    face(my_dir)
end

-- ============================================================
-- NETWORK
-- ============================================================
local function openModem()
    local modem = peripheral.find("modem")
    if not modem then error("[FATAL] No Ender Modem on the turtle. Equip one and reboot.", 0) end
    rednet.open(peripheral.getName(modem))
end

local function handshake()
    print("[AUTH]  Requesting orders from Overseer...")
    while not server_id do
        rednet.broadcast({ type = "AUTH_REQ", hwid = hwid, pos = pos }, PROTOCOL)
        local sender, msg = rednet.receive(PROTOCOL, 5)
        if sender and type(msg) == "table" and msg.type == "AUTH_ACK" and msg.hwid == hwid then
            server_id = sender
            my_dir    = msg.direction or 0
            base      = msg.base
            facing    = my_dir
            face(my_dir)
            print(string.format("[AUTH]  Orders received. Direction=%d  Server=%d", my_dir, server_id))
        else
            print("[AUTH]  No reply. Retrying...")
        end
    end
end

-- ============================================================
-- THREADS
-- ============================================================
local function listenerThread()
    while true do
        local sender, msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            if msg.type == "CMD_START" then
                started = true
            elseif msg.type == "GOTO" and msg.hwid == hwid and type(msg.pos) == "table" then
                table.insert(jobs, msg)
            elseif msg.type == "CMD_STOP" then
                started = false
            end
        end
    end
end

local function heartbeatThread()
    while true do
        local free = 0
        for i = 1, 15 do if turtle.getItemCount(i) == 0 then free = free + 1 end end
        pcall(rednet.send, server_id, {
            type   = "HEARTBEAT",
            hwid   = hwid,
            fuel   = turtle.getFuelLevel(),
            pos    = pos,
            free   = free,
            status = started and "MINING" or "STANDBY",
        }, PROTOCOL)
        sleep(HEARTBEAT_INT)
    end
end

local function brainThread()
    print("[STANDBY] Awaiting CMD_START...")
    while not started do sleep(0.5) end
    print("[ACTIVE]  Mining commenced.")

    local tunnelled = 0
    while true do
        -- 1. Pending GOTO jobs take priority
        while #jobs > 0 do
            doJob(table.remove(jobs, 1))
        end

        -- 2. Housekeeping
        refuelSelf()
        if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() <= 0 then
            print("[FUEL]  Out of fuel and nothing to burn. Halting.")
            sleep(5)
        elseif inventoryFull() then
            returnAndDump(copy(pos))
            tunnelled = 0
        else
            -- 3. Tunnel one block forward in the assigned direction
            face(my_dir)
            if forward() then
                tunnelled = tunnelled + 1
            else
                -- blocked by lava/bedrock: step up and over
                if not up() then turnRight() end
            end

            -- 4. Periodic scan + ore report
            if tunnelled % SCAN_EVERY == 0 then
                reportOres(scanAround())
            end

            -- 5. End of run: head home, then stop
            if tunnelled >= MAX_TUNNEL then
                print("[DONE]  Reached max tunnel length. Returning home.")
                returnAndDump(nil)
                pcall(rednet.send, server_id, { type = "HEARTBEAT", hwid = hwid, status = "DONE", pos = pos }, PROTOCOL)
                return
            end
        end
        sleep(0)  -- yield so the listener and heartbeat threads run
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
print("+------------------------------+")
print("|  M-NET V3  |  MINER NODE      |")
print("+------------------------------+")
print("[INIT]  HWID: " .. hwid)

openModem()

has_scanner = turtle.getItemCount(SCANNER_SLOT) > 0
print("[INIT]  Geo Scanner (slot 16): " .. (has_scanner and "OK" or "MISSING — scanning disabled"))

calibrate()
handshake()

parallel.waitForAll(brainThread, listenerThread, heartbeatThread)
