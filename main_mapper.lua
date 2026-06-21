--[[
    M-NET V3 | OVERSEER  (fleet commander + warehouse)
    ===================================================
    Role : Hands out tunnel directions to miners, watches their heartbeats,
           filters incoming ore reports against a want-list, and fires GOTO
           orders for ores it wants. Also sweeps an adjacent chest so you can
           see your supply levels at a glance.

    HARDWARE:
        Ender Modem      : any side (comms with the fleet)
        Supply chest     : adjacent, or wired-modem linked (optional, for the
                           warehouse readout). Found via peripheral.find.

    SETUP YOU MUST DO:
        1. Set BASE_CHEST below to the coords of the DROP chest the miners
           dump into (look at it, press F3, read "Targeted Block").
        2. Edit WANT_LIST to the ores you actually want fetched.

    USAGE:
        Type  start   to deploy the fleet.
        Type  stop    to halt them.
        Type  status  to print the roster.
]]

-- ============================================================
-- CONFIGURATION  (edit these)
-- ============================================================
local PROTOCOL  = "MNET_V3"
local BASE_CHEST = { x = 0, y = 64, z = 0 }   -- <-- coords of the drop chest

local WANT_LIST = {                            -- ores worth a detour
    diamond = true, ancient_debris = true, emerald = true,
    gold = true, redstone = true, lapis = true,
}

local DIRECTIONS = { 0, 1, 2, 3 }   -- N, E, S, W assigned round-robin
local HB_TIMEOUT = 12000             -- ms before a miner is declared lost
local DISP_REFRESH = 1               -- seconds between status redraws

-- ============================================================
-- STATE
-- ============================================================
-- fleet[hwid] = { net_id, last_pulse, fuel, pos, status, dir, free }
local fleet     = {}
local dir_index = 0
local ore_log   = {}    -- ore name -> count seen
local dispatched = {}   -- de-dupe GOTO by coord key

local vault = peripheral.find("inventory")

-- ============================================================
-- HELPERS
-- ============================================================
local function nextDirection()
    dir_index = (dir_index % #DIRECTIONS) + 1
    return DIRECTIONS[dir_index]
end

local function fleetCount()
    local n = 0
    for _ in pairs(fleet) do n = n + 1 end
    return n
end

local function checkSupplies()
    if not vault then return {} end
    local tally = {}
    local ok, list = pcall(vault.list, vault)
    if not ok or type(list) ~= "table" then return {} end
    for _, item in pairs(list) do
        local n = (item.name:match(":(.+)") or item.name)
        tally[n] = (tally[n] or 0) + item.count
    end
    return tally
end

-- ============================================================
-- NETWORK HANDLERS
-- ============================================================
local function handleAuth(net_id, msg)
    if type(msg.hwid) ~= "string" then return end
    local existing = fleet[msg.hwid]
    local dir = existing and existing.dir or nextDirection()

    fleet[msg.hwid] = {
        net_id     = net_id,
        last_pulse = os.epoch("utc"),
        pos        = msg.pos or { x = 0, y = 0, z = 0 },
        status     = "STANDBY",
        dir        = dir,
        fuel       = "?",
        free       = "?",
    }

    rednet.send(net_id, {
        type      = "AUTH_ACK",
        hwid      = msg.hwid,
        direction = dir,
        base      = BASE_CHEST,
    }, PROTOCOL)

    print(string.format("[ENLIST] %s  ->  direction %d", msg.hwid, dir))
end

local function handleHeartbeat(msg)
    local f = fleet[msg.hwid]
    if not f then return end
    f.last_pulse = os.epoch("utc")
    if msg.status then f.status = msg.status end
    if msg.fuel   then f.fuel   = msg.fuel   end
    if msg.pos    then f.pos    = msg.pos    end
    if msg.free   then f.free   = msg.free   end
end

local function handleOreReport(msg)
    if type(msg.ore) ~= "string" or type(msg.pos) ~= "table" then return end
    ore_log[msg.ore] = (ore_log[msg.ore] or 0) + 1

    -- Only chase ores on the want-list, and only once per coordinate.
    if WANT_LIST[msg.ore] then
        local k = msg.pos.x .. ":" .. msg.pos.y .. ":" .. msg.pos.z
        if not dispatched[k] then
            dispatched[k] = true
            local f = fleet[msg.hwid]
            if f then
                rednet.send(f.net_id, {
                    type = "GOTO",
                    hwid = msg.hwid,
                    ore  = msg.ore,
                    pos  = msg.pos,
                }, PROTOCOL)
                print(string.format("[ORDER]  %s -> GOTO %s (%d,%d,%d)",
                    msg.hwid, msg.ore, msg.pos.x, msg.pos.y, msg.pos.z))
            end
        end
    end
end

-- ============================================================
-- THREADS
-- ============================================================
local function listenerThread()
    while true do
        local net_id, msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            if     msg.type == "AUTH_REQ"   then handleAuth(net_id, msg)
            elseif msg.type == "HEARTBEAT"  then handleHeartbeat(msg)
            elseif msg.type == "ORE_REPORT" then handleOreReport(msg)
            end
        end
    end
end

local function prunerThread()
    while true do
        sleep(2)
        local now = os.epoch("utc")
        for hwid, f in pairs(fleet) do
            if (now - f.last_pulse) > HB_TIMEOUT then
                print("[LOST]   " .. hwid .. " went silent (chunk unload or crash).")
                fleet[hwid] = nil
            end
        end
    end
end

local function terminalThread()
    while true do
        local input = read()
        if input == "start" then
            rednet.broadcast({ type = "CMD_START" }, PROTOCOL)
            print("[CMD]    Fleet deployed.")
        elseif input == "stop" then
            rednet.broadcast({ type = "CMD_STOP" }, PROTOCOL)
            print("[CMD]    Halt sent.")
        elseif input == "status" then
            print("---- FLEET ----")
            for hwid, f in pairs(fleet) do
                local p = f.pos or {}
                print(string.format("  %s dir%d %s fuel:%s free:%s (%d,%d,%d)",
                    hwid, f.dir or 0, f.status or "?", tostring(f.fuel),
                    tostring(f.free), p.x or 0, p.y or 0, p.z or 0))
            end
            print("---- SUPPLIES ----")
            for name, count in pairs(checkSupplies()) do
                print(string.format("  %-18s %d", name, count))
            end
        end
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
local modem = peripheral.find("modem")
if not modem then error("[FATAL] No modem found. Attach an Ender Modem and reboot.", 0) end
rednet.open(peripheral.getName(modem))

print("+------------------------------------------+")
print("|   M-NET V3  --  OVERSEER (FLEET COMMAND)  |")
print("+------------------------------------------+")
print("  Computer ID : " .. os.getComputerID())
print("  Base chest  : (" .. BASE_CHEST.x .. ", " .. BASE_CHEST.y .. ", " .. BASE_CHEST.z .. ")")
print("  Warehouse   : " .. (vault and "linked" or "no chest found"))
print("")
print("  Commands: start | stop | status")
print("  Waiting for miners to enlist...")
print("")

parallel.waitForAll(listenerThread, prunerThread, terminalThread)
