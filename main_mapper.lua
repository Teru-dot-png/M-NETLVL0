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

-- Two depots. Look at each block, press F3, read the "Targeted Block" coords.
local DUMP_CHEST = { x = 0, y = 64, z = 0 }   -- mined loot is emptied here
local BASE_CHEST = { x = 0, y = 64, z = 2 }   -- emergency coal + spare pickaxes

local WANT_LIST = {                            -- ores worth a detour
    diamond = true, ancient_debris = true, emerald = true,
    gold = true, redstone = true, lapis = true,
}

local DIRECTIONS = { 0, 1, 2, 3 }   -- N, E, S, W assigned round-robin
local HB_TIMEOUT = 12000             -- ms before a miner is declared lost
local DISP_REFRESH = 1               -- seconds between status redraws

-- ============================================================
-- CONFIG PERSISTENCE (typed coords survive reboots)
-- ============================================================
local CONFIG_FILE = "mnet_overseer.cfg"

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    if f then
        f.write(textutils.serialize({ dump = DUMP_CHEST, base = BASE_CHEST, want = WANT_LIST }))
        f.close()
    end
end

local function loadConfig()
    if not fs.exists(CONFIG_FILE) then return end
    local f = fs.open(CONFIG_FILE, "r")
    if not f then return end
    local data = textutils.unserialize(f.readAll() or "")
    f.close()
    if type(data) == "table" then
        if data.dump then DUMP_CHEST = data.dump end
        if data.base then BASE_CHEST = data.base end
        if data.want then WANT_LIST  = data.want end
    end
end

-- Push current chest coords to every miner that is already running.
local function broadcastConfig()
    rednet.broadcast({ type = "CONFIG", dump = DUMP_CHEST, base = BASE_CHEST }, PROTOCOL)
end

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
        dump      = DUMP_CHEST,
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
            elseif msg.type == "ALERT"      then
                print("[ALERT]  " .. tostring(msg.hwid) .. ": " .. tostring(msg.msg))
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

local function splitWords(s)
    local t = {}
    for w in s:gmatch("%S+") do t[#t + 1] = w end
    return t
end

local function parseCoords(a, b, c)
    local x, y, z = tonumber(a), tonumber(b), tonumber(c)
    if x and y and z then return { x = x, y = y, z = z } end
    return nil
end

local function printHelp()
    print("Commands:")
    print("  start | stop | recall   deploy / halt-in-place / call home")
    print("  status                  show fleet + supplies")
    print("  setdump x y z           set the loot dump chest")
    print("  setbase x y z           set the emergency coal chest")
    print("  coords                  show current chest coords")
    print("  want <ore>              add an ore to the fetch list")
    print("  unwant <ore>            remove an ore from the fetch list")
    print("  wants                   show the fetch list")
    print("  help                    this list")
end

local function terminalThread()
    while true do
        local parts = splitWords(read())
        local cmd = parts[1]

        if cmd == "start" then
            rednet.broadcast({ type = "CMD_START" }, PROTOCOL)
            print("[CMD]    Fleet deployed.")

        elseif cmd == "stop" then
            rednet.broadcast({ type = "CMD_STOP" }, PROTOCOL)
            print("[CMD]    Halt-in-place sent.")

        elseif cmd == "recall" then
            rednet.broadcast({ type = "CMD_RECALL" }, PROTOCOL)
            print("[CMD]    Recall sent. Turtles will dump and park.")

        elseif cmd == "status" then
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

        elseif cmd == "setdump" then
            local c = parseCoords(parts[2], parts[3], parts[4])
            if c then
                DUMP_CHEST = c saveConfig() broadcastConfig()
                print(string.format("[CFG]    Dump chest set to (%d,%d,%d).", c.x, c.y, c.z))
            else print("Usage: setdump x y z") end

        elseif cmd == "setbase" then
            local c = parseCoords(parts[2], parts[3], parts[4])
            if c then
                BASE_CHEST = c saveConfig() broadcastConfig()
                print(string.format("[CFG]    Base chest set to (%d,%d,%d).", c.x, c.y, c.z))
            else print("Usage: setbase x y z") end

        elseif cmd == "coords" then
            print(string.format("  Dump: (%d,%d,%d)", DUMP_CHEST.x, DUMP_CHEST.y, DUMP_CHEST.z))
            print(string.format("  Base: (%d,%d,%d)", BASE_CHEST.x, BASE_CHEST.y, BASE_CHEST.z))

        elseif cmd == "want" then
            if parts[2] then WANT_LIST[parts[2]] = true saveConfig()
                print("[CFG]    Now fetching: " .. parts[2])
            else print("Usage: want <ore>") end

        elseif cmd == "unwant" then
            if parts[2] then WANT_LIST[parts[2]] = nil saveConfig()
                print("[CFG]    No longer fetching: " .. parts[2])
            else print("Usage: unwant <ore>") end

        elseif cmd == "wants" then
            write("  Fetching: ")
            local any = false
            for ore in pairs(WANT_LIST) do write(ore .. " ") any = true end
            print(any and "" or "(nothing)")

        elseif cmd == "help" then
            printHelp()

        elseif cmd and cmd ~= "" then
            print("Unknown command: " .. cmd .. "   (type help)")
        end
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
local modem = peripheral.find("modem")
if not modem then error("[FATAL] No modem found. Attach an Ender Modem and reboot.", 0) end
rednet.open(peripheral.getName(modem))

loadConfig()   -- restore any chest coords / want-list typed in a previous session

print("+------------------------------------------+")
print("|   M-NET V3  --  OVERSEER (FLEET COMMAND)  |")
print("+------------------------------------------+")
print("  Computer ID : " .. os.getComputerID())
print("  Dump chest  : (" .. DUMP_CHEST.x .. ", " .. DUMP_CHEST.y .. ", " .. DUMP_CHEST.z .. ")")
print("  Base chest  : (" .. BASE_CHEST.x .. ", " .. BASE_CHEST.y .. ", " .. BASE_CHEST.z .. ")")
print("  Warehouse   : " .. (vault and "linked" or "no chest found"))
print("")
print("  Type  help  for the full command list.")
print("  Waiting for miners to enlist...")
print("")

parallel.waitForAll(listenerThread, prunerThread, terminalThread)
