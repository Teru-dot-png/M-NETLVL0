--[[
    M-NET V2 | SCOUT NODE  (fixed build)
    =====================================
    Role     : Dynamic edge node. Geometry mapping and heartbeat pulsing.
    Hardware : CC:T Turtle with:
                 - Advanced Modem / Ender Modem  (left or right slot)
                 - Advanced Peripherals Geo Scanner (other slot)
                 - Fuel in tank
    Protocol : MNET_V2

    LIFECYCLE:
        SYS_INIT -> REQ_AUTH -> ACK_AUTH -> STREAM_ACTIVE
            STREAM_ACTIVE runs two parallel threads:
                pulseLoop  : heartbeat every 3 s
                mapLoop    : move / scan / transmit every 0.5 s

    WHAT WAS FIXED FROM THE ORIGINAL:
        1. The false "No Advanced Modem found" crash on init.
           The old line used peripheral.find("modem", rednet.open) inside an
           "if not" check. rednet.open returns nil, so the check reported no
           modem even when one was attached. We now find the modem first,
           then open rednet on it.
        2. Entity Detector removed. The build now needs only modem + scanner,
           which fits a turtle's two upgrade slots.
        3. The fuel check now safely handles the "unlimited" fuel mode
           (comparing the string "unlimited" against a number would crash).
        4. Added auto-refuel. When fuel runs low the node now scans every
           inventory slot and burns any valid fuel (coal, charcoal, lava
           buckets, etc.). The original only printed a warning and never
           actually consumed anything.
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
local CFG = {
    HEARTBEAT_INTERVAL  = 3,    -- seconds between HEARTBEAT pulses
    AUTH_RETRY_INTERVAL = 5,    -- seconds between AUTH_REQ retries
    SCAN_THROTTLE       = 0.5,  -- seconds between mapLoop iterations
    SCAN_RADIUS         = 8,    -- block radius for Geo Scanner
    FUEL_WARN_LEVEL     = 100,  -- fuel level that triggers a halt warning
}

-- ============================================================
-- STATE
-- ============================================================
local server_id  = nil
local local_hwid = nil
local authorized = false

-- Peripheral handle (resolved during init)
local scanner = nil  -- geoScanner

-- ============================================================
-- HWID GENERATION
-- ============================================================
-- Produces a deterministic ID like "SC-1A2B" from the computer's ID.
local function generateHWID()
    local id = os.getComputerID()
    return string.format("SC-%04X", id % 0xFFFF)
end

-- ============================================================
-- INITIALISATION
-- ============================================================
local function init()
    -- Find the modem first, THEN open rednet on it.
    local modem = peripheral.find("modem")
    if not modem then
        error("[FATAL] No Advanced Modem found. Attach one and reboot.")
    end
    rednet.open(peripheral.getName(modem))

    -- Geo Scanner is optional. The node still runs without it.
    scanner = peripheral.find("geoScanner")
    if not scanner then
        print("[WARN]  Geo Scanner not attached. Block scanning disabled.")
    end

    local_hwid = generateHWID()
    print("+------------------------------+")
    print("|  M-NET V2  |  SCOUT NODE     |")
    print("+------------------------------+")
    print(string.format("[INIT]  HWID        : %s", local_hwid))
    print(string.format("[INIT]  Computer ID : %d", os.getComputerID()))
    print(string.format("[INIT]  GeoScanner  : %s", scanner and "OK" or "ABSENT"))
    print("[INIT]  Protocol    : MNET_V2")
end

-- ============================================================
-- GPS HELPER
-- ============================================================
local function getPosition()
    local x, y, z = gps.locate(2)  -- 2 second timeout
    if x then
        return { x = x, y = y, z = z }
    end
    return { x = 0, y = 0, z = 0 }
end

-- ============================================================
-- MOVEMENT HELPER
-- ============================================================
-- Tries to move forward. Digs a block if the path is obstructed,
-- attacks if a mob is in the way.
local function moveForward()
    if turtle.forward() then return true end
    -- Blocked by a block, try to dig.
    if turtle.dig() then
        os.sleep(0.3)
        return turtle.forward()
    end
    -- Blocked by an entity, try to attack.
    if turtle.attack() then
        os.sleep(0.5)
        return turtle.forward()
    end
    return false
end

-- ============================================================
-- FUEL HELPER
-- ============================================================
-- Walks every inventory slot and burns anything that is valid fuel.
-- Important: a turtle can only refuel from its CURRENTLY SELECTED slot,
-- so we must select each slot in turn. There is no built-in "scan all
-- slots and auto-burn"; this loop is how you get that behaviour.
local function refuelFromInventory()
    for slot = 1, 16 do
        turtle.select(slot)
        if turtle.refuel(0) then   -- refuel(0) tests the slot without consuming
            turtle.refuel()        -- valid fuel found, consume the whole stack
        end
    end
    turtle.select(1)               -- always return to slot 1 afterwards
end

-- ============================================================
-- STATE: REQ_AUTH -> ACK_AUTH
-- ============================================================
local function performHandshake()
    print("\n[AUTH]  Searching for Main Mapper on MNET_V2...")

    local auth_req = {
        type = "AUTH_REQ",
        hwid = local_hwid,
        pos  = getPosition(),
    }

    while not authorized do
        rednet.broadcast(auth_req, "MNET_V2")
        print(string.format(
            "[AUTH]  AUTH_REQ broadcast sent. Waiting up to %ds for ACK_AUTH...",
            CFG.AUTH_RETRY_INTERVAL
        ))

        local sender, msg = rednet.receive("MNET_V2", CFG.AUTH_RETRY_INTERVAL)

        if sender and type(msg) == "table" then
            if msg.type == "AUTH_ACK" and msg.hwid == local_hwid then
                server_id  = sender
                authorized = true
                print(string.format(
                    "[AUTH]  Authorization confirmed!  Server ID: %d",
                    server_id
                ))
            elseif msg.type == "REAUTH_REQ" then
                print("[AUTH]  Server requested re-auth. Retrying immediately...")
            end
        else
            print(string.format(
                "[AUTH]  No response. Retrying in %ds...",
                CFG.AUTH_RETRY_INTERVAL
            ))
        end
    end
end

-- ============================================================
-- STATE: STREAM_ACTIVE. Thread 1: Heartbeat Pulse
-- ============================================================
local function pulseLoop()
    while true do
        local pulse = {
            type   = "HEARTBEAT",
            hwid   = local_hwid,
            status = "NOMINAL",
        }

        local ok = pcall(rednet.send, server_id, pulse, "MNET_V2")
        if not ok then
            print("[PULSE]  Heartbeat send failed.")
        end

        os.sleep(CFG.HEARTBEAT_INTERVAL)
    end
end

-- ============================================================
-- STATE: STREAM_ACTIVE. Thread 2: Map & Scan Loop
-- ============================================================
local function mapLoop()
    while true do
        -- 1. Fuel check. If low, scan every inventory slot and refuel.
        local fuel = turtle.getFuelLevel()
        if fuel ~= "unlimited" and fuel < CFG.FUEL_WARN_LEVEL then
            print(string.format("[FUEL]  Low (%d). Scanning inventory for fuel...", fuel))
            refuelFromInventory()
            fuel = turtle.getFuelLevel()
        end

        if fuel ~= "unlimited" and fuel < CFG.FUEL_WARN_LEVEL then
            print(string.format(
                "[WARN]  No usable fuel found (%d). Halting movement until refuelled.",
                fuel
            ))
            os.sleep(5)
            -- Skip movement this tick but keep scanning in place.
        else
            -- 2. Movement.
            if not moveForward() then
                print("[MAP]   Path blocked and undiggable. Attempting detour...")
                turtle.turnRight()
                if not moveForward() then
                    turtle.turnLeft()
                    turtle.turnLeft()
                    if not moveForward() then
                        turtle.turnRight() -- reset heading
                        print("[MAP]   Fully blocked. Skipping movement this tick.")
                    end
                end
            end
        end

        -- 3. Geo scan.
        local scan_data = {}
        if scanner then
            local ok, result = pcall(scanner.scan, CFG.SCAN_RADIUS)
            if ok and type(result) == "table" then
                scan_data = result
            end
        end

        -- 4. Position update.
        local pos = getPosition()

        -- 5. Construct GEO_DATA payload.
        --    Key must be "scan_data" so the Main Mapper's handleGeoData
        --    can read it. (This mismatch was why nothing was mapping.)
        local payload = {
            type      = "GEO_DATA",
            hwid      = local_hwid,
            pos       = pos,
            fuel      = turtle.getFuelLevel(),
            scan_data = scan_data,
        }

        -- 6. Transmit to Main Mapper.
        local ok = pcall(rednet.send, server_id, payload, "MNET_V2")
        if not ok then
            print("[MAP]   Telemetry send failed.")
        end

        os.sleep(CFG.SCAN_THROTTLE)
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
init()
performHandshake()

print("\n[M-NET SCOUT]  Entering STREAM_ACTIVE state.")
print("[M-NET SCOUT]  Launching pulseLoop + mapLoop via parallel.waitForAll...")

parallel.waitForAll(pulseLoop, mapLoop)

print("\n[M-NET SCOUT]  All threads terminated. Node offline.")
