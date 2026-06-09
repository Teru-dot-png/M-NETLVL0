--[[
    M-NET V2 | SCOUT NODE
    ======================
    Role     : Dynamic edge node — geometry mapping, entity scanning,
               heartbeat pulsing.
    Hardware : CC:T Turtle with:
                 - Advanced Modem / Ender Modem (any side)
                   Cross-dimensional, infinite range — no relays required.
                 - Advanced Peripherals Geo Scanner (left peripheral slot)
                 - Advanced Peripherals Entity Detector (right peripheral slot)
                 - Fuel in tank
    Protocol : MNET_V2

    LIFECYCLE:
        SYS_INIT → REQ_AUTH → ACK_AUTH → STREAM_ACTIVE
            STREAM_ACTIVE runs two parallel threads:
                pulseLoop  — heartbeat every 3 s
                mapLoop    — move / scan / transmit every 0.5 s
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
local CFG = {
    HEARTBEAT_INTERVAL    = 3,    -- seconds between HEARTBEAT pulses
    AUTH_RETRY_INTERVAL   = 5,    -- seconds between AUTH_REQ retries
    SCAN_THROTTLE         = 0.5,  -- seconds between mapLoop iterations
    SCAN_RADIUS           = 8,    -- block radius for Geo Scanner
    FUEL_WARN_LEVEL       = 100,  -- fuel level that triggers a halt warning
}

-- ============================================================
-- STATE
-- ============================================================
local server_id   = nil
local local_hwid  = nil
local authorized  = false

-- Peripheral handles (resolved after modem open)
local scanner = nil  -- geoScanner
local radar   = nil  -- entityDetector

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
    if not peripheral.find("modem", rednet.open) then
        error("[FATAL] No Advanced Modem found. Attach one and reboot.")
    end

    -- Advanced Peripherals peripherals — non-fatal if absent
    scanner = peripheral.find("geoScanner")
    if not scanner then
        print("[WARN]  Geo Scanner not attached — block scanning disabled.")
    end

    radar = peripheral.find("entityDetector")
    if not radar then
        print("[WARN]  Entity Detector not attached — entity scanning disabled.")
    end

    local_hwid = generateHWID()
    print("+------------------------------+")
    print("|  M-NET V2  |  SCOUT NODE     |")
    print("+------------------------------+")
    print(string.format("[INIT]  HWID        : %s", local_hwid))
    print(string.format("[INIT]  Computer ID : %d",  os.getComputerID()))
    print(string.format("[INIT]  GeoScanner  : %s",  scanner and "OK" or "ABSENT"))
    print(string.format("[INIT]  EntityRadar : %s",  radar   and "OK" or "ABSENT"))
    print("[INIT]  Protocol    : MNET_V2")
end

-- ============================================================
-- GPS HELPER
-- ============================================================
local function getPosition()
    local x, y, z = gps.locate(2)  -- 2-second timeout
    if x then
        return { x = x, y = y, z = z }
    end
    return { x = 0, y = 0, z = 0 }
end

-- ============================================================
-- MOVEMENT HELPER
-- ============================================================
-- Tries to move forward; digs a block if the path is obstructed,
-- attacks if a mob is in the way.
local function moveForward()
    if turtle.forward() then return true end
    -- Blocked by block — try to dig
    if turtle.dig() then
        os.sleep(0.3)
        return turtle.forward()
    end
    -- Blocked by entity — try to attack
    if turtle.attack() then
        os.sleep(0.5)
        return turtle.forward()
    end
    return false
end

-- ============================================================
-- ENTITY SCANNING
-- ============================================================
-- Returns (threat_found: bool, threat_info: table)
local function scanEntities()
    if not radar then return false, {} end

    local ok, result = pcall(function() return radar.scanEntities() end)
    if not ok or type(result) ~= "table" then return false, {} end

    for _, entity in ipairs(result) do
        local name = entity.name or ""
        -- Treat anything that is not a player or item entity as a threat
        if  entity.type ~= "player"
        and not name:find("minecraft:item")
        and not name:find("experience_orb")
        then
            return true, {
                name     = name,
                distance = entity.distance or 0,
            }
        end
    end

    return false, {}
end

-- ============================================================
-- STATE: REQ_AUTH → ACK_AUTH
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
-- STATE: STREAM_ACTIVE — Thread 1: Heartbeat Pulse
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
-- STATE: STREAM_ACTIVE — Thread 2: Map & Scan Loop
-- ============================================================
local function mapLoop()
    while true do
        -- ── 1. Fuel check ────────────────────────────────────
        local fuel = turtle.getFuelLevel()
        if fuel ~= -1 and fuel < CFG.FUEL_WARN_LEVEL then
            print(string.format(
                "[WARN]  Fuel critical (%d). Halting movement until refuelled.",
                fuel
            ))
            os.sleep(5)
            -- Skip movement this tick but continue scanning in place
        else
            -- ── 2. Movement ──────────────────────────────────
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

        -- ── 3. Geo scan ──────────────────────────────────────
        local scan_data = {}
        if scanner then
            local ok, result = pcall(scanner.scan, CFG.SCAN_RADIUS)
            if ok and type(result) == "table" then
                scan_data = result
            end
        end

        -- ── 4. Entity scan ───────────────────────────────────
        local threat_found, threat_info = scanEntities()

        -- ── 5. Position update ───────────────────────────────
        local pos = getPosition()

        -- ── 6. Construct Payload C (GEO_DATA + Threats) ──────
        local payload = {
            type            = "GEO_DATA",
            hwid            = local_hwid,
            pos             = pos,
            fuel            = turtle.getFuelLevel(),
            scan_results    = scan_data,
            threat_detected = threat_found,
            threat_data     = threat_info,
        }

        -- ── 7. Transmit to Main Mapper ────────────────────────
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
