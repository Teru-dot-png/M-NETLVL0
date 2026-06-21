--[[
    M-NET V3 | MINER NODE
    ======================
    Hardware:
        RIGHT slot : Ender Modem     (permanent, comms)
        LEFT  slot : Diamond Pickaxe (default; swapped with scanner during scans)
        SLOT 16    : Geo Scanner item (reserved; never used for cargo)
        Fuel       : start with a little coal; turtle sustains itself after boot

    Boot order:
        1. Check pickaxe is equipped (fetch from BASE_CHEST if not)
        2. Burn any coal aboard, wait/forage until FUEL_TARGET reached
        3. Calibrate heading from GPS (one forward step)
        4. Enlist with Overseer, broadcast position
        5. Standby until CMD_START

    REQUIRES: working GPS constellation in this dimension
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
local PROTOCOL      = "MNET_V3"
local SCAN_RADIUS   = 8      -- geo scanner radius
local SCAN_EVERY    = 4      -- tunnel blocks between each geo scan
local HEARTBEAT_INT = 3      -- seconds between heartbeats to overseer
local FUEL_MIN      = 200    -- opportunistically top up below this
local FUEL_TARGET   = 500    -- wake-up goal before starting work
local FORAGE_MAX    = 32     -- max blocks to dig hunting coal at wake-up
local FUEL_CRITICAL = 80     -- emergency: crawl to BASE_CHEST if below this
local MAX_TUNNEL    = 256    -- blocks before heading home
local SCANNER_SLOT  = 16     -- reserved slot for the geo scanner item

-- ============================================================
-- STATE
-- ============================================================
local hwid           = string.format("MN-%04X", os.getComputerID() % 0xFFFF)
local server_id      = nil
local dump           = nil       -- { x,y,z } loot drop chest
local base           = nil       -- { x,y,z } emergency coal + spare picks
local my_dir         = 0         -- assigned tunnel direction (0=N 1=E 2=S 3=W)
local started        = false
local home_requested = false
local has_scanner    = false
local jobs           = {}
local reported       = {}

-- Dead-reckoning position + facing
local pos    = { x = 0, y = 0, z = 0 }
local facing = 0
local DIRV   = { [0]={dx=0,dz=-1}, [1]={dx=1,dz=0}, [2]={dx=0,dz=1}, [3]={dx=-1,dz=0} }

-- ============================================================
-- SMALL HELPERS
-- ============================================================
local function copy(p) return { x = p.x, y = p.y, z = p.z } end
local function key(p)  return p.x..":"..p.y..":"..p.z end
local function shortName(n) return (n:match(":(.+)") or n) end

local function log(tag, msg)
    print(string.format("[%-6s] %s", tag, msg))
end

-- ============================================================
-- FUEL
-- ============================================================
local function fuelLevel()
    local f = turtle.getFuelLevel()
    return f == "unlimited" and math.huge or f
end

-- Burn items from cargo slots 1-15, trying to reach `target`.
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
-- LAVA CHECK (correct two-arg handling)
-- ============================================================
local function isLavaAhead()
    local ok, data = turtle.inspect()
    return ok and type(data) == "table" and type(data.name) == "string"
           and data.name:find("lava") ~= nil
end
local function isLavaUp()
    local ok, data = turtle.inspectUp()
    return ok and type(data) == "table" and type(data.name) == "string"
           and data.name:find("lava") ~= nil
end
local function isLavaDown()
    local ok, data = turtle.inspectDown()
    return ok and type(data) == "table" and type(data.name) == "string"
           and data.name:find("lava") ~= nil
end

-- ============================================================
-- PICKAXE DETECTION
-- ============================================================
-- In CC:Tweaked, peripheral.wrap("left") returns a table if the
-- left slot holds a peripheral (i.e. the geo scanner).
-- If it returns nil the slot is a tool (pickaxe) or empty.
-- We disambiguate empty vs pickaxe by testing turtle.dig() on air
-- via turtle.detect() first -- if no block ahead and dig returns false
-- the slot is empty.
local function leftIsPeripheral()
    return peripheral.wrap("left") ~= nil
end

local function pickaxeEquipped()
    if leftIsPeripheral() then return false end   -- scanner is on left
    -- Slot is a tool (or empty). CC:T exposes turtle.getEquippedLeft() in 1.109+
    -- Fall back gracefully if that API is absent.
    if turtle.getEquippedLeft then
        local info = turtle.getEquippedLeft()
        if info == nil then return false end       -- empty
        return tostring(info.name or ""):find("pickaxe") ~= nil
    end
    -- Older CC:T: assume a non-peripheral left slot is the pickaxe.
    -- We verify by attempting dig on something we know is there (the wall
    -- ahead during actual mining). Accept the ambiguity at boot and let
    -- the first `forward()` expose a bad state.
    return true
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

    -- moveTo is defined later; we call it after all helpers are defined.
    -- This function is only ever called from the boot sequence or brain loop,
    -- after moveTo is in scope, so forward-reference is fine in Lua.
    if not moveTo({ x = base.x, y = base.y + 1, z = base.z }) then
        log("PICK", "Could not reach BASE_CHEST. Parking until rebooted.")
        while true do sleep(5) end
    end

    local fetched = false
    for attempt = 1, 54 do
        for s = 1, 15 do
            if turtle.getItemCount(s) == 0 then
                turtle.select(s)
                if turtle.suckDown(1) then
                    local d = turtle.getItemDetail(s)
                    if d and tostring(d.name):find("pickaxe") then
                        turtle.select(s)
                        turtle.equipLeft()
                        if pickaxeEquipped() then
                            log("PICK", "Pickaxe equipped from BASE_CHEST.")
                            fetched = true
                            break
                        end
                    end
                    turtle.dropDown()
                else
                    break
                end
            end
        end
        if fetched then break end
    end

    if not fetched then
        log("PICK", "No pickaxe in BASE_CHEST. Add one. Retrying every 10s...")
        while not fetched do
            sleep(10)
            for s = 1, 15 do
                if turtle.getItemCount(s) == 0 then
                    turtle.select(s)
                    if turtle.suckDown(1) then
                        local d = turtle.getItemDetail(s)
                        if d and tostring(d.name):find("pickaxe") then
                            turtle.select(s)
                            turtle.equipLeft()
                            if pickaxeEquipped() then
                                log("PICK", "Pickaxe found. Resuming.")
                                fetched = true
                                break
                            end
                        end
                        turtle.dropDown()
                    end
                end
            end
        end
    end

    if resumePos then
        moveTo(resumePos)
        face(my_dir)
    end
end

-- ============================================================
-- MOVEMENT
-- ============================================================
local function turnRight() turtle.turnRight() facing = (facing + 1) % 4 end
local function turnLeft()  turtle.turnLeft()  facing = (facing + 3) % 4 end

local function face(target)
    while facing ~= target do
        if (target - facing) % 4 == 1 then turnRight() else turnLeft() end
    end
end

function forward()
    if isLavaAhead() then
        log("MOVE", "Lava ahead. Skipping block.")
        return false
    end
    if not turtle.forward() then
        if not turtle.detect() then return false end   -- truly empty air, something else wrong
        local tries = 0
        while turtle.detect() and tries < 64 do
            if not turtle.dig() then
                turtle.attack()
            end
            tries = tries + 1
            sleep(0.15)
        end
        if not turtle.forward() then return false end
    end
    pos.x = pos.x + DIRV[facing].dx
    pos.z = pos.z + DIRV[facing].dz
    return true
end

local function up()
    if isLavaUp() then return false end
    if not turtle.up() then
        turtle.digUp() turtle.attackUp()
        if not turtle.up() then return false end
    end
    pos.y = pos.y + 1
    return true
end

local function down()
    if isLavaDown() then return false end
    if not turtle.down() then
        turtle.digDown() turtle.attackDown()
        if not turtle.down() then return false end
    end
    pos.y = pos.y - 1
    return true
end

local function moveX(tx)
    while pos.x ~= tx do face(pos.x < tx and 1 or 3) if not forward() then return false end end
    return true
end
local function moveZ(tz)
    while pos.z ~= tz do face(pos.z < tz and 2 or 0) if not forward() then return false end end
    return true
end
local function moveY(ty)
    while pos.y ~= ty do
        if pos.y < ty then if not up()   then return false end
        else               if not down() then return false end end
    end
    return true
end

function moveTo(t)
    if moveY(t.y) and moveX(t.x) and moveZ(t.z) then return true end
    if moveX(t.x) and moveZ(t.z) and moveY(t.y) then return true end
    return pos.x == t.x and pos.y == t.y and pos.z == t.z
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
-- STEP 1: PICKAXE CHECK  (before any movement)
-- ============================================================
local function checkPickaxeAtBoot()
    if pickaxeEquipped() then
        log("INIT", "Pickaxe: equipped on left side. OK")
        return
    end
    -- Scanner might already be on left; try swapping to recover pick from slot 16
    if turtle.getItemCount(SCANNER_SLOT) > 0 then
        log("INIT", "Pickaxe not detected. Attempting hot-swap recovery...")
        turtle.select(SCANNER_SLOT)
        turtle.equipLeft()   -- whatever is in slot 16 goes left; old left goes to slot 16
        if pickaxeEquipped() then
            log("INIT", "Pickaxe recovered via slot 16 swap. OK")
            return
        end
    end
    log("INIT", "No pickaxe equipped and none found in slot 16.")
    log("INIT", "Will attempt to fetch one from BASE_CHEST after GPS fix.")
    -- We cannot moveTo yet (no GPS). Flag for post-calibrate fetch.
end

-- ============================================================
-- STEP 2: FUEL WAKE-UP  (before calibrate, so no pos tracking needed)
-- ============================================================
local function wakeUp()
    log("WAKE", "Checking fuel... current = " .. tostring(turtle.getFuelLevel()))
    burnAboard(FUEL_TARGET)
    log("WAKE", "Burned aboard coal. Fuel = " .. tostring(turtle.getFuelLevel()))

    if fuelLevel() == 0 then
        log("WAKE", "EMPTY. Drop coal in any cargo slot to continue...")
        while fuelLevel() == 0 do
            burnAboard(FUEL_TARGET)
            sleep(2)
        end
        log("WAKE", "Got fuel. Fuel = " .. tostring(turtle.getFuelLevel()))
    end

    if fuelLevel() < FUEL_TARGET then
        log("WAKE", string.format("Below target (%d). Will forage for coal after GPS calibration.", FUEL_TARGET))
        -- Foraging is done AFTER calibrate() so pos tracking stays correct.
    else
        log("WAKE", "Fuel target reached. Ready.")
    end
end

-- Post-calibrate forage: we now know our heading so pos tracking is safe.
local function forageForCoal()
    if fuelLevel() >= FUEL_TARGET then return end
    log("FUEL", string.format("Foraging for coal (up to %d blocks)...", FORAGE_MAX))
    local steps = 0
    while fuelLevel() < FUEL_TARGET and steps < FORAGE_MAX do
        if not forward() then break end
        steps = steps + 1
        burnAboard(FUEL_TARGET)
        if steps % 4 == 0 then
            log("FUEL", string.format("Foraging... step %d fuel=%s", steps, tostring(turtle.getFuelLevel())))
        end
    end
    log("FUEL", string.format("Done foraging. %d blocks, fuel = %s", steps, tostring(turtle.getFuelLevel())))
end

-- ============================================================
-- STEP 3: CALIBRATE HEADING
-- ============================================================
local function calibrate()
    log("NAV", "GPS calibrating heading...")
    local p1 = gpsPos()
    if not p1 then error("[FATAL] No GPS fix. Build a GPS constellation first.", 0) end

    local moved = false
    for _ = 1, 12 do
        if turtle.forward() then moved = true break end
        if not turtle.dig() then turtle.attack() end
        sleep(0.2)
    end
    if not moved then
        error("[FATAL] Cannot calibrate: boxed in or no fuel after wake-up.", 0)
    end

    local p2 = gpsPos()
    if not p2 then error("[FATAL] Lost GPS during calibration step.", 0) end

    local dx, dz = p2.x - p1.x, p2.z - p1.z
    if     dx ==  1 then facing = 1
    elseif dx == -1 then facing = 3
    elseif dz ==  1 then facing = 2
    elseif dz == -1 then facing = 0
    else error("[FATAL] Calibration move was not a clean cardinal step.", 0) end

    pos = copy(p2)
    log("NAV", string.format("Heading calibrated: facing=%d pos=(%d,%d,%d)", facing, pos.x, pos.y, pos.z))
end

-- ============================================================
-- GEO SCAN: hot-swap pickaxe <-> scanner on the left slot
-- State machine approach: always know what is on the left first.
-- ============================================================
local function scanAround()
    if not has_scanner then return {} end

    local scannerOnLeft = leftIsPeripheral()

    if not scannerOnLeft then
        -- Normal state: pickaxe on left, scanner in slot 16
        if turtle.getItemCount(SCANNER_SLOT) == 0 then
            log("SCAN", "Scanner item missing from slot 16. Skipping scan.")
            return {}
        end
        turtle.select(SCANNER_SLOT)
        turtle.equipLeft()   -- scanner to left, pickaxe to slot 16
    end
    -- Scanner is now on left

    local results = {}
    local sc = peripheral.wrap("left")
    if sc and sc.scan then
        local ok, r = pcall(sc.scan, SCAN_RADIUS)
        if ok and type(r) == "table" then
            results = r
            log("SCAN", string.format("Scanned %d blocks.", #r))
        else
            log("SCAN", "Scan failed: " .. tostring(r))
        end
    end

    -- Swap back: pickaxe is in slot 16, put it left
    turtle.select(SCANNER_SLOT)
    turtle.equipLeft()   -- pickaxe to left, scanner to slot 16
    turtle.select(1)

    if not pickaxeEquipped() then
        log("WARN", "Hot-swap error: pickaxe not back on left. Will recover before next move.")
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
-- ORE REPORTING + SNAPSHOT
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
            solids[#solids + 1] = { x = b.x, y = b.y, z = b.z, name = n }
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
    if not dump then log("DUMP", "No dump chest set.") return end

    if not moveTo({ x = dump.x, y = dump.y + 1, z = dump.z }) then
        log("DUMP", "Could not reach DUMP_CHEST. Parking 10s.")
        sleep(10) return
    end

    for i = 1, 15 do
        turtle.select(i)
        if turtle.getItemCount(i) > 0 then turtle.dropDown() end
    end
    turtle.select(1)

    local leftover = false
    for i = 1, 15 do if turtle.getItemCount(i) > 0 then leftover = true break end end
    if leftover then
        log("DUMP", "DUMP_CHEST is FULL. Cargo remains. Parking 10s.")
        pcall(rednet.send, server_id, { type = "ALERT", hwid = hwid, msg = "CHEST_FULL", pos = pos }, PROTOCOL)
        sleep(10) return
    end

    refuelSelf()
    log("DUMP", "Emptied. Returning to work face.")
    if resumePos then moveTo(resumePos) face(my_dir) end
end

-- ============================================================
-- EMERGENCY FUEL FROM BASE
-- ============================================================
local function grabFuelFromBase()
    if not base then return end
    local resume = copy(pos)
    log("FUEL", "Critical. Crawling to BASE_CHEST for coal...")

    if not moveTo({ x = base.x, y = base.y + 1, z = base.z }) then
        log("FUEL", "Could not reach BASE_CHEST. Parking 10s.")
        sleep(10) return
    end

    for s = 1, 15 do
        if turtle.getItemCount(s) == 0 then
            turtle.select(s)
            if not turtle.suckDown(64) then break end
        end
    end
    burnAboard(FUEL_TARGET)
    -- Return non-fuel items
    for s = 1, 15 do
        turtle.select(s)
        if turtle.getItemCount(s) > 0 and not turtle.refuel(0) then
            turtle.dropDown()
        end
    end
    turtle.select(1)

    moveTo(resume)
    face(my_dir)
    log("FUEL", "Back from base. Fuel = " .. tostring(turtle.getFuelLevel()))
end

-- ============================================================
-- GOTO JOB
-- ============================================================
local function doJob(job)
    local resume = copy(pos)
    log("GOTO", string.format("Fetching %s at (%d,%d,%d)", job.ore or "ore", job.pos.x, job.pos.y, job.pos.z))

    if not pickaxeEquipped() then
        log("GOTO", "No pickaxe. Skipping job.")
        return
    end

    if moveTo(job.pos) then
        pcall(rednet.send, server_id, { type = "ORE_MINED", hwid = hwid, ore = job.ore, pos = job.pos }, PROTOCOL)
        log("GOTO", "Mined " .. (job.ore or "ore") .. ". Returning to work face.")
    else
        log("GOTO", "Could not reach target. Skipping.")
    end

    moveTo(resume)
    face(my_dir)
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
    log("AUTH", string.format("Broadcasting position (%d,%d,%d)...", pos.x, pos.y, pos.z))
    while not server_id do
        rednet.broadcast({ type = "AUTH_REQ", hwid = hwid, pos = pos }, PROTOCOL)
        local sender, msg = rednet.receive(PROTOCOL, 5)
        if sender and type(msg) == "table" and msg.type == "AUTH_ACK" and msg.hwid == hwid then
            server_id = sender
            my_dir    = msg.direction or 0
            dump      = msg.dump
            base      = msg.base
            facing    = my_dir
            face(my_dir)
            log("AUTH", string.format("Enlisted. Direction=%d Server=%d", my_dir, server_id))
            log("AUTH", "Awaiting CMD_START from Overseer.")
        else
            log("AUTH", "No reply from Overseer. Retrying...")
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
            if msg.type == "CMD_START" then
                started = true
                log("CMD", "Start received.")
            elseif msg.type == "CMD_STOP" then
                started = false
                log("CMD", "Stop received. Halting in place.")
            elseif msg.type == "CMD_RECALL" then
                home_requested = true
                log("CMD", "Recall received.")
            elseif msg.type == "CONFIG" then
                if msg.dump then dump = msg.dump end
                if msg.base then base = msg.base end
                log("CFG", "Chest coords updated by Overseer.")
            elseif msg.type == "GOTO" and msg.hwid == hwid and type(msg.pos) == "table" then
                log("GOTO", "Job queued: " .. (msg.ore or "ore"))
                table.insert(jobs, msg)
            end
        end
    end
end

local function heartbeatThread()
    while true do
        pcall(rednet.send, server_id, {
            type   = "HEARTBEAT",
            hwid   = hwid,
            fuel   = turtle.getFuelLevel(),
            pos    = pos,
            free   = freeSlots(),
            status = started and "MINING" or "STANDBY",
        }, PROTOCOL)
        sleep(HEARTBEAT_INT)
    end
end

local function brainThread()
    local tunnelled   = 0
    local was_started = false

    while true do
        -- Recall command: dump and park
        if home_requested then
            home_requested = false
            log("RECALL", "Returning home to park...")
            returnAndDump(nil)
            started = false
            log("RECALL", "Parked. Send 'start' to resume.")
        end

        -- Log start/stop transitions
        if started and not was_started then
            log("ACTIVE", "Mining commenced.")
            was_started = true
        elseif not started and was_started then
            log("HALT", "Halted. Awaiting 'start'.")
            was_started = false
        end

        if not started then
            sleep(0.5)
        else
            -- Priority 1: GOTO jobs
            while #jobs > 0 do doJob(table.remove(jobs, 1)) end

            -- Priority 2: Ensure pickaxe is equipped before moving
            if not pickaxeEquipped() then
                log("PICK", "Pickaxe missing mid-run. Fetching from base...")
                fetchPickaxeFromBase(copy(pos))
            end

            -- Priority 3: Fuel
            refuelSelf()
            if fuelLevel() > 0 and fuelLevel() < FUEL_CRITICAL then
                grabFuelFromBase()
            end

            -- Priority 4: Mine
            if fuelLevel() <= 0 then
                log("FUEL", "Zero fuel. Halting. Add coal manually.")
                sleep(10)
            elseif inventoryFull() then
                log("CARGO", "Holds full. Heading to dump.")
                returnAndDump(copy(pos))
                tunnelled = 0
            else
                face(my_dir)
                if forward() then
                    tunnelled = tunnelled + 1
                    if tunnelled % 8 == 0 then
                        log("MINE", string.format("tunnel=%d fuel=%s free=%d pos=(%d,%d,%d)",
                            tunnelled, tostring(turtle.getFuelLevel()), freeSlots(),
                            pos.x, pos.y, pos.z))
                    end
                else
                    log("MOVE", "Blocked (lava or bedrock). Stepping up/turning.")
                    if not up() then turnRight() end
                end

                -- Geo scan on schedule
                if tunnelled > 0 and tunnelled % SCAN_EVERY == 0 then
                    local snap = scanAround()
                    reportOres(snap)
                    sendSnapshot(snap)
                end

                -- End of tunnel run
                if tunnelled >= MAX_TUNNEL then
                    log("DONE", "Max tunnel length reached. Returning home.")
                    returnAndDump(nil)
                    started     = false
                    was_started = false
                    tunnelled   = 0
                    log("DONE", "Parked. Send 'start' to deploy again.")
                end
            end
        end

        sleep(0)
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
print("+----------------------------------+")
print("|   M-NET V3  |  MINER NODE        |")
print("+----------------------------------+")
log("INIT", "HWID: " .. hwid)

openModem()

-- Geo scanner check
has_scanner = turtle.getItemCount(SCANNER_SLOT) > 0
log("INIT", "Geo Scanner (slot 16): " .. (has_scanner and "READY" or "MISSING - scanning disabled"))

-- STEP 1: Pickaxe check (before any movement)
checkPickaxeAtBoot()

-- STEP 2: Burn aboard fuel
wakeUp()

-- STEP 3: Calibrate heading (one GPS-tracked step; pos tracking now safe)
calibrate()

-- STEP 3b: Forage for coal if still below target (heading now known)
forageForCoal()

-- STEP 4: Fetch pickaxe from base if boot check flagged it missing
if not pickaxeEquipped() then
    log("INIT", "Pickaxe still missing. Fetching from BASE_CHEST...")
    -- base is nil until handshake; we handshake first then fetch
end

-- STEP 5: Enlist with Overseer
handshake()

-- Now fetch pickaxe if we still need one (base coords arrived in handshake)
if not pickaxeEquipped() then
    fetchPickaxeFromBase(copy(pos))
end

log("BOOT", "All systems ready. Fuel=" .. tostring(turtle.getFuelLevel()) .. " Pos=("..pos.x..","..pos.y..","..pos.z..")")

parallel.waitForAll(brainThread, listenerThread, heartbeatThread)
