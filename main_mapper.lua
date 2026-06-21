--[[
    O-NET V1 | OVERSEER
    =======================================================
    Successor to M-NET V3. Coordinates the mining fleet,
    maintains the voxel map, and brokers the O-NET V1
    push protocol between turtles.

    Role : Fleet commander, warehouse monitor, and live map display.

    Hardware:
        Ender Modem      : any side (found via peripheral.find)
        Advanced Monitor : any side or array (the live cockpit display)
        Supply chest     : adjacent optional (for the warehouse readout)

    O-NET V1 additions:
        - Push protocol broker: on PUSH_REQ from a stuck turtle, the
          overseer identifies which turtle is at the blocked tile, compares
          priorities via MOVE_PRIORITY_MAP, and sends a direct YIELD command
          to the lower-urgency turtle. Mirrors Overmind's pushCreep() logic.
        - MOVE_PRIORITY_MAP mirrors MOVE_PRIORITY in miner_node.lua.
          GOTO=1 (never yields), ..., PARKED=9 (always yields).

    Map behaviour:
        - Air blocks clear voxels when received (tunnel tracking live).
        - setVoxel and shouldStore skip all stone-class blocks entirely.
        - total_voxels is decremented when air clears a stored voxel.
        - cargoBar uses 14 slots (2-15; slot 1 reserved for scanner).

    Parking:
        - setpark x1 y1 z1 x2 y2 z2 defines a rectangle.
        - getParkSlot(index) fills it row-by-row along the X axis.
        - Each turtle gets a unique slot in AUTH_ACK and on setpark.
        - broadcastConfig() does NOT send park (would corrupt turtle
          park_pos — turtles expect {x,y,z}, not the zone definition).

    getme command:
        - Scans map for known ore positions, dispatches GOTOs to nearest
          idle turtles, tracks completion via ORE_MINED + dump chest count.
        - No-map warning prints once only (warned_empty flag per order).
        - Completing orders auto-close when target count reached.

    Setup:
        setdump x y z                set loot drop chest
        setbase x y z                set emergency coal + pickaxe chest
        setpark x1 y1 z1 x2 y2 z2   parking rectangle
        Type  help  for the full command list.
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
local PROTOCOL   = "ONET_V1"   -- upgraded from MNET_V3
local DUMP_CHEST = { x = 0, y = 64, z = 0 }
local BASE_CHEST = { x = 0, y = 64, z = 2 }

-- Parking zone: axis-aligned rectangle defined by two corners.
-- Turtles assigned a slot inside this zone when they park.
-- nil = no zone set, turtles park in place.
local PARK_ZONE  = nil   -- { x1,y1,z1, x2,y2,z2 } or nil

local WANT_LIST = {                            -- ores worth a detour
    diamond = true, ancient_debris = true, emerald = true,
    gold = true, redstone = true, lapis = true,
}

local DIRECTIONS   = { 0, 1, 2, 3 }    -- N, E, S, W assigned round-robin
local LANE_SPACING = 4                   -- blocks between parallel tunnels
local HB_TIMEOUT   = 12000
local DISP_REFRESH = 0.5

-- Zone tracking: zones[hwid] = { dir, lane_offset, exhausted }
-- When a turtle reports DONE or PARKED after a full run,
-- its zone is marked exhausted so it gets fresh coords next time.
local zone_log      = {}     -- zone_log[hwid] = { dir, offset, exhausted }
local lane_counters = {      -- how many lanes assigned per direction
    [0]=0,[1]=0,[2]=0,[3]=0
}
local fleet
local park_claim_by_hwid = {}
local park_claim_by_key  = {}

local function parkPosKey(p)
    return math.floor(p.x)..":"..math.floor(p.y)..":"..math.floor(p.z)
end

local function clearParkClaim(hwid)
    local old = park_claim_by_hwid[hwid]
    if old and old.key then park_claim_by_key[old.key] = nil end
    park_claim_by_hwid[hwid] = nil
end

local function clearAllParkClaims()
    park_claim_by_hwid = {}
    park_claim_by_key = {}
end

local function isOccupiedByOtherFleet(pos, requester)
    for hwid, f in pairs(fleet) do
        if hwid ~= requester and f.pos then
            local fp = f.pos
            if math.floor(fp.x or 0) == math.floor(pos.x)
            and math.floor(fp.y or 0) == math.floor(pos.y)
            and math.floor(fp.z or 0) == math.floor(pos.z) then
                return true
            end
        end
    end
    return false
end

local function assignUnclaimedParkSlot(hwid, ref)
    if not PARK_ZONE then return nil end
    local x1 = math.min(PARK_ZONE.x1, PARK_ZONE.x2)
    local x2 = math.max(PARK_ZONE.x1, PARK_ZONE.x2)
    local y  = math.min(PARK_ZONE.y1, PARK_ZONE.y2)
    local z1 = math.min(PARK_ZONE.z1, PARK_ZONE.z2)
    local z2 = math.max(PARK_ZONE.z1, PARK_ZONE.z2)

    clearParkClaim(hwid)

    local best, best_d = nil, math.huge
    local rx = math.floor((ref and ref.x) or x1)
    local ry = math.floor((ref and ref.y) or y)
    local rz = math.floor((ref and ref.z) or z1)

    for z = z1, z2 do
        for x = x1, x2 do
            local p = { x=x, y=y, z=z }
            local k = parkPosKey(p)
            local owner = park_claim_by_key[k]
            if owner and not fleet[owner] then
                park_claim_by_key[k] = nil
                owner = nil
            end
            if (not owner or owner == hwid) and not isOccupiedByOtherFleet(p, hwid) then
                local d = math.abs(x-rx) + math.abs(y-ry) + math.abs(z-rz)
                if d < best_d then
                    best_d = d
                    best = p
                end
            end
        end
    end

    if best then
        local k = parkPosKey(best)
        park_claim_by_key[k] = hwid
        park_claim_by_hwid[hwid] = { key = k, pos = best }
    end
    return best
end

-- Returns the park position for a given fleet slot index (0-based).
-- Fills the rectangle row by row along the longest horizontal axis.
local function getParkSlot(slot_index)
    if not PARK_ZONE then return nil end
    local x1 = math.min(PARK_ZONE.x1, PARK_ZONE.x2)
    local x2 = math.max(PARK_ZONE.x1, PARK_ZONE.x2)
    local y  = math.min(PARK_ZONE.y1, PARK_ZONE.y2)
    local z1 = math.min(PARK_ZONE.z1, PARK_ZONE.z2)
    local z2 = math.max(PARK_ZONE.z1, PARK_ZONE.z2)
    local cols = x2 - x1 + 1
    local rows = z2 - z1 + 1
    local total = cols * rows
    local idx   = slot_index % total
    local col   = idx % cols
    local row   = math.floor(idx / cols)
    return { x = x1 + col, y = y, z = z1 + row }
end

local function assignLane(hwid)
    -- Prefer a direction that has fewer turtles to spread the fleet out
    local best_dir, best_count = 0, math.huge
    for _,d in ipairs(DIRECTIONS) do
        if lane_counters[d] < best_count then
            best_count = lane_counters[d]
            best_dir   = d
        end
    end
    local offset = lane_counters[best_dir] * LANE_SPACING
    lane_counters[best_dir] = lane_counters[best_dir] + 1
    zone_log[hwid] = { dir=best_dir, offset=offset, exhausted=false }
    return best_dir, offset
end

local function reassignLane(hwid)
    local old = zone_log[hwid]
    if old then old.exhausted = true end
    local dir = old and old.dir or 0
    local offset = lane_counters[dir] * LANE_SPACING
    lane_counters[dir] = lane_counters[dir] + 1
    zone_log[hwid] = { dir=dir, offset=offset, exhausted=false }
    return dir, offset
end

-- Map display
local MAP_RADIUS    = 24    -- max block radius drawn around the view centre
local RAYCAST_DEPTH = 3     -- layers searched below the view layer
local ZONE_A_ROWS   = 8     -- monitor rows reserved for the roster header

local floor = math.floor

-- ============================================================
-- CONFIG PERSISTENCE
-- ============================================================
local CONFIG_FILE = "mnet_overseer.cfg"

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    if f then
        f.write(textutils.serialize({
            dump = DUMP_CHEST, base = BASE_CHEST,
            want = WANT_LIST,  park = PARK_ZONE,
        }))
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
        if data.park then PARK_ZONE  = data.park end
    end
end

local function broadcastConfig()
    -- Note: park is NOT broadcast here because each turtle has a different
    -- slot position. Park slots are sent individually via AUTH_ACK and
    -- the setpark command loop. Sending PARK_ZONE here would corrupt
    -- turtle park_pos (they expect {x,y,z} not {x1,y1,z1,x2,y2,z2}).
    rednet.broadcast({
        type = "CONFIG", dump = DUMP_CHEST, base = BASE_CHEST, want = WANT_LIST,
    }, PROTOCOL)
end

-- ============================================================
-- STATE
-- ============================================================
-- fleet[hwid] = { net_id, last_pulse, pos, status, dir, fuel, free }
fleet      = {}
local dir_index  = 0
local fleet_slot = 0    -- increments per turtle enlisted, used for park slot assignment
local ore_log    = {}
local dispatched = {}

-- O-NET V1: priority map used by the push broker (Overmind: MovePriorities).
-- Mirrors MOVE_PRIORITY table in miner_node.lua.
-- Lower number = higher urgency = never gets YIELD'd by the broker.
-- The broker sends YIELD to the turtle at the blocked tile only when
-- that turtle's priority number is >= the pusher's priority number.
local MOVE_PRIORITY_MAP = {
    GOTO       = 1,   -- never yielded: targeted ore retrieval
    RTB_FUEL   = 2,   -- nearly never yielded: emergency fuel
    RTB_DUMP   = 3,   -- cargo run
    FETCH_PICK = 4,   -- pickaxe fetch
    MINING     = 5,   -- normal tunnelling
    STANDBY    = 8,   -- idle
    PARKED     = 9,   -- always yielded: lowest urgency
}

-- master_voxels[y][x][z] = blockName ; absolute world coords
local master_voxels = {}
local total_voxels  = 0
local AIR_MARKER    = "__air__"  -- known, scanned air cell (dug tunnel)

-- Volatile solid sightings used only for negative-space inference.
-- This is RAM-only and intentionally never persisted to disk.
local volatile_solids = {}
local VOL_SOLID_TTL_MS = 180000

local view_cx, view_cz, view_y = 0, 0, 64

-- Phase 5B: ore clusters
local CLUSTER_RADIUS = 4
local clusters       = {}

-- Phase 5C: live ore feed (declared here so renderFooter can see it)
local ORE_FEED     = {}
local ORE_FEED_MAX = 8

-- ============================================================
-- PHASE 5A: MAP PERSISTENCE
-- The voxel database survives overseer reboots. The map
-- accumulates across multiple mining sessions automatically.
-- Auto-saves every 60 seconds and on any clean shutdown.
-- ============================================================
local MAP_FILE      = "mnet_map.dat"
local map_dirty     = false
local last_map_save = 0
local map_persist_enabled = true
local map_persist_reason  = nil

local function disableMapPersistence(reason)
    if map_persist_enabled then
        map_persist_enabled = false
        map_persist_reason = tostring(reason or "unknown error")
        print("[MAP]    Persistence disabled; running RAM-only.")
        print("[MAP]    Reason: " .. map_persist_reason)
    end
end

-- Map file format: one voxel per line, tab-separated:
--   x\ty\tz\tname
-- This is ~4x more compact than textutils.serialize and streams
-- line by line so CC's disk limit is never hit in one write call.
-- Stone-class blocks are skipped entirely since they are the default
-- assumption and take up ~90% of the data for zero nav benefit.

-- What is worth persisting to disk:
--   AIR    = yes, these mark dug tunnels the navigator needs to find
--   ORES   = yes, these are dispatch targets
--   HAZARDS (lava/water) = yes, the navigator avoids these
--   CHESTS/COMPUTERS = yes, protected blocks the nav must route around
--   STONE and all common rock = NO, navigator assumes solid by default
--   so storing it wastes space for zero benefit
local function shouldStore(name)
    if not name or name == "" then return false end
    if name == AIR_MARKER        then return true  end  -- tracked tunnel air
    if name:find("air")          then return true  end  -- tunnel corridor
    if name:find("_ore")         then return true  end  -- ore targets
    if name:find("lava")         then return true  end  -- hazard
    if name:find("water")        then return true  end  -- hazard
    if name:find("chest")        then return true  end  -- protected
    if name:find("computer")     then return true  end  -- protected
    if name:find("turtle")       then return true  end  -- protected
    -- Everything else (stone, deepslate, granite, dirt, gravel...)
    -- is assumed solid by the navigator already. Skip it.
    return false
end

local function isGeoScanNoise(name)
    local n = tostring(name or ""):lower()
    -- Geo scanner can report dynamic turtle entities (e.g. "...turtle_advanced (alt)").
    -- Treat these as transient/air so they never harden into map solids.
    return n:find("turtle", 1, true) ~= nil
end

local function saveMap()
    if not map_persist_enabled then return false end

    local ok_open, f = pcall(fs.open, MAP_FILE, "w")
    if not ok_open or not f then
        disableMapPersistence(ok_open and "could not open map file for writing" or f)
        return false
    end

    local count = 0
    for y, xt in pairs(master_voxels) do
        for x, zt in pairs(xt) do
            for z, name in pairs(zt) do
                if shouldStore(name) then
                    local ok_write, err_write = pcall(function()
                        f.writeLine(x.."\t"..y.."\t"..z.."\t"..name)
                    end)
                    if not ok_write then
                        pcall(function() f.close() end)
                        disableMapPersistence(err_write)
                        return false
                    end
                    count = count + 1
                end
            end
        end
    end

    local ok_close, err_close = pcall(function() f.close() end)
    if not ok_close then
        disableMapPersistence(err_close)
        return false
    end

    map_dirty     = false
    last_map_save = os.epoch("utc")
    print(string.format("[MAP]    Saved %d entries (of %d voxels) to disk.", count, total_voxels))
    return true
end

local function loadMap()
    if not fs.exists(MAP_FILE) then return end
    local f = fs.open(MAP_FILE, "r")
    if not f then return end
    local count = 0
    local line  = f.readLine()
    while line do
        local x, y, z, name = line:match("^(-?%d+)\t(-?%d+)\t(-?%d+)\t(.+)$")
        if x then
            x = tonumber(x); y = tonumber(y); z = tonumber(z)
            if not master_voxels[y]    then master_voxels[y]    = {} end
            if not master_voxels[y][x] then master_voxels[y][x] = {} end
            master_voxels[y][x][z] = name
            count = count + 1
        end
        line = f.readLine()
    end
    f.close()
    total_voxels = total_voxels + count
    print(string.format("[MAP]    Loaded %d entries from disk.", count))
end

-- ============================================================
-- PERIPHERALS
-- ============================================================
local modem = peripheral.find("modem")
if not modem then error("[FATAL] No modem found. Attach an Ender Modem and reboot.", 0) end
rednet.open(peripheral.getName(modem))

local mon   = peripheral.find("monitor")
local vault = peripheral.find("inventory")

if mon then
    mon.setTextScale(0.5)
    mon.setBackgroundColor(colors.black)
    mon.clear()
    mon.setCursorBlink(false)
end

-- ============================================================
-- BLIT + COLOUR HELPERS
-- ============================================================
local C2B = {
    [colors.white]="0",[colors.orange]="1",[colors.magenta]="2",[colors.lightBlue]="3",
    [colors.yellow]="4",[colors.lime]="5",[colors.pink]="6",[colors.gray]="7",
    [colors.lightGray]="8",[colors.cyan]="9",[colors.purple]="a",[colors.blue]="b",
    [colors.brown]="c",[colors.green]="d",[colors.red]="e",[colors.black]="f",
}
local function c2b(col) return C2B[col] or "f" end

local FADE = {
    [colors.yellow]    = { colors.orange,    colors.gray  },
    [colors.white]     = { colors.lightGray, colors.gray  },
    [colors.cyan]      = { colors.lightBlue, colors.gray  },
    [colors.lime]      = { colors.green,     colors.gray  },
    [colors.lightBlue] = { colors.blue,      colors.black },
    [colors.green]     = { colors.gray,      colors.black },
    [colors.orange]    = { colors.brown,     colors.black },
}
local function fadeColor(base, depth)
    if depth == 0 then return base end
    local e = FADE[base]
    if not e then return depth == 1 and colors.lightGray or colors.black end
    return e[depth] or colors.black
end

-- ============================================================
-- VOXEL DATABASE
-- ============================================================
local function setVoxel(x, y, z, name)
    -- Never store stone-class blocks in RAM. The navigator already treats
    -- unknown as solid, so storing stone is wasted memory and disk space.
    -- Only ores, air, hazards, and protected blocks are worth tracking.
    if not shouldStore(name) then return end
    if not master_voxels[y] then master_voxels[y] = {} end
    if not master_voxels[y][x] then master_voxels[y][x] = {} end
    if not master_voxels[y][x][z] then total_voxels = total_voxels + 1 end
    master_voxels[y][x][z] = name
    map_dirty = true
end
local function getVoxel(x, y, z)
    local ly = master_voxels[y]; if not ly then return nil end
    local lx = ly[x];           if not lx then return nil end
    return lx[z]
end

-- ============================================================
-- BLOCK CLASSIFICATION + RENDER
-- ============================================================
local AIR_NAMES = {
    ["minecraft:air"]=true, ["air"]=true, ["minecraft:cave_air"]=true,
    ["minecraft:void_air"]=true, [""]=true,
}
local function isAir(n) return n == nil or n == AIR_MARKER or AIR_NAMES[n] == true end
local function isOre(n) return n ~= nil and n:find("_ore", 1, true) ~= nil end

local WALL_GLYPH = { [0]="#", [1]="+", [2]="-" }

local function oreGlyph(name, depth)
    local ore = name:match(":(.-)_ore") or name:match("(.-)_ore") or "x"
    ore = ore:match("deepslate_(.+)") or ore:match("nether_(.+)") or ore
    local ch = ore:sub(1, 1)
    return depth < 2 and ch:upper() or ch:lower()
end

local function renderCell(name, depth)
    depth = math.min(depth, 2)
    if isAir(name) then return " ", colors.black end
    if isOre(name) then return oreGlyph(name, depth), fadeColor(colors.cyan, depth) end
    return WALL_GLYPH[depth] or "-", fadeColor(colors.yellow, depth)
end

-- ============================================================
-- UTILITIES
-- ============================================================
local function fleetCount()
    local n = 0; for _ in pairs(fleet) do n = n + 1 end; return n
end

local function pad(s, len)
    s = tostring(s)
    if #s >= len then return s:sub(1, len) end
    return s .. string.rep(" ", len - #s)
end

local function nextDirection()
    dir_index = (dir_index % #DIRECTIONS) + 1
    return DIRECTIONS[dir_index]
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

-- Track the map centre + working layer to the live fleet centroid.
local function updateViewCenter()
    local n, sx, sz, sy = 0, 0, 0, 0
    for _, f in pairs(fleet) do
        if f.pos then
            sx = sx + floor(f.pos.x or 0)
            sz = sz + floor(f.pos.z or 0)
            sy = sy + floor(f.pos.y or 64)
            n  = n + 1
        end
    end
    if n > 0 then
        view_cx = floor(sx / n)
        view_cz = floor(sz / n)
        view_y  = floor(sy / n)
    end
end

-- ============================================================
-- COCKPIT DISPLAY
-- ============================================================
-- Layout (at 0.5 text scale on a 3x2 monitor array = ~164x46 cells)
--
--  Row 1        : HEADER BAR  (full width, cyan on black)
--  Row 2        : subheader   (voxels, ore haul, uptime, map centre)
--  Row 3        : column labels
--  Row 4..N-2   : THREE PANELS side by side, separated by | chars
--     LEFT  ~28 cols  : fleet roster with fuel bars + cargo bars
--     CENTRE remainder: scanned voxel map
--     RIGHT ~22 cols  : ore haul tally + supply chest
--  Row N-1      : LEGEND BAR
--  Row N        : ALERT TICKER (scrolling, last 1 line)
--
-- All drawing is done via mon.blit() for efficiency.
-- ============================================================

local BOOT_TIME  = os.epoch("utc")
local alert_log  = {}       -- ring buffer of recent alerts, shown in ticker
local MAX_ALERTS = 8

local function pushAlert(msg)
    table.insert(alert_log, os.date("%H:%M ") .. msg)
    if #alert_log > MAX_ALERTS then table.remove(alert_log, 1) end
end

-- ── Blit helpers ───────────────────────────────────────────────────────

local function blitLine(row, text, fgStr, bgStr)
    mon.setCursorPos(1, row)
    mon.blit(text, fgStr, bgStr)
end

-- Write a padded, uniformly-coloured row
local function solidRow(row, text, fg, bg, w)
    local s = pad(text, w)
    mon.setCursorPos(1, row)
    mon.blit(s, string.rep(c2b(fg), w), string.rep(c2b(bg), w))
end

-- Write a string at an exact column with given fg/bg (no padding)
local function put(row, col, text, fg, bg)
    mon.setCursorPos(col, row)
    local n = #text
    mon.blit(text, string.rep(c2b(fg), n), string.rep(c2b(bg), n))
end

-- ── Layout constants ────────────────────────────────────────────────────

local LEFT_W  = 29   -- columns for the fleet panel (including border char)
local RIGHT_W = 23   -- columns for the ore/supply panel (including border)
-- Centre map panel = w - LEFT_W - RIGHT_W

local HDR_ROWS   = 3   -- rows 1-3: header
local FOOTER_ROWS = 2  -- last 2 rows: legend + ticker

-- ── Fuel / cargo bar renderer ──────────────────────────────────────────
-- Produces a 6-char visual bar:  [||||  ]  in varying colours

local function fuelBar(fuel, maxFuel)
    maxFuel = maxFuel or 20000
    if fuel == "unlimited" or fuel == math.huge then return "[UNLIM]" end
    fuel = tonumber(fuel) or 0
    local filled = math.floor((fuel / maxFuel) * 5 + 0.5)
    filled = math.max(0, math.min(5, filled))
    return "[" .. string.rep("|", filled) .. string.rep(" ", 5 - filled) .. "]"
end

local function cargoBar(freeSlots)
    -- Slots 2-15 = 14 cargo slots (slot 1 reserved for scanner)
    freeSlots = tonumber(freeSlots) or 14
    local used = 14 - math.max(0, math.min(14, freeSlots))
    local filled = math.floor(used / 14 * 5 + 0.5)
    return "[" .. string.rep("#", filled) .. string.rep(".", 5 - filled) .. "]"
end

local function fuelColor(fuel)
    if fuel == "unlimited" then return colors.cyan end
    fuel = tonumber(fuel) or 0
    if fuel > 1000 then return colors.lime end
    if fuel > 300  then return colors.yellow end
    return colors.red
end

local function statusColor(status)
    status = tostring(status or ""):upper()
    if status == "MINING"     then return colors.lime      end
    if status == "STANDBY"    then return colors.yellow    end
    if status == "PARKED"     then return colors.gray      end
    if status == "GOTO"       then return colors.cyan      end
    if status == "RTB_DUMP"   then return colors.orange    end
    if status == "RTB_FUEL"   then return colors.red       end
    if status == "FETCH_PICK" then return colors.magenta   end
    return colors.lightGray
end

-- Dir number → compass glyph
local DIR_GLYPH = { [0]="N", [1]="E", [2]="S", [3]="W" }

-- Ore name → display colour
local ORE_COLOUR = {
    diamond       = colors.cyan,
    emerald       = colors.lime,
    gold          = colors.yellow,
    iron          = colors.lightGray,
    coal          = colors.gray,
    redstone      = colors.red,
    lapis         = colors.blue,
    copper        = colors.orange,
    ancient_debris= colors.purple,
}
local function oreColor(name)
    -- name arrives as short form e.g. "deepslate_diamond" or "diamond_ore"
    -- strip any _ore suffix and deepslate_/nether_ prefix to get base ore
    local base = name:match("deepslate_(.-)_ore$")
              or name:match("nether_(.-)_ore$")
              or name:match("(.-)_ore$")
              or name
    return ORE_COLOUR[base] or colors.white
end

local function normalizeOreName(name)
    local n = tostring(name or "")
    n = n:match("deepslate_(.-)_ore$")
     or n:match("nether_(.-)_ore$")
     or n:match("(.-)_ore$")
     or n
    return n
end

-- ── PANEL: HEADER (rows 1-3) ───────────────────────────────────────────

local function renderHeader(w)
    local uptime_s = math.floor((os.epoch("utc") - BOOT_TIME) / 1000)
    local uh = math.floor(uptime_s / 3600)
    local um = math.floor((uptime_s % 3600) / 60)
    local us = uptime_s % 60

    -- Row 1: title + clock
    local title = string.format(
        " O-NET X  OVERSEER  ID:%-3d      %s  UP %02d:%02d:%02d ",
        os.getComputerID(), os.date("%H:%M:%S"), uh, um, us)
    solidRow(1, title, colors.black, colors.cyan, w)

    -- Row 2: fleet stats + map info
    local mining = 0
    local ACTIVE_STATES = { MINING=true, GOTO=true, RTB_DUMP=true, RTB_FUEL=true, FETCH_PICK=true }
    for _, f in pairs(fleet) do if ACTIVE_STATES[tostring(f.status):upper()] then mining=mining+1 end end
    local ore_total = 0
    for _, v in pairs(ore_log) do ore_total = ore_total + v end

    local sub = string.format(
        " ONLINE:%-2d  MINING:%-2d  VOXELS:%-8d  ORES:%-6d  VIEW(%d,%d) Y:%-4d",
        fleetCount(), mining, total_voxels, ore_total, view_cx, view_cz, view_y)
    solidRow(2, sub, colors.yellow, colors.black, w)

    -- Row 3: panel column labels separated by borders
    local lbl_t, lbl_f, lbl_b = {}, {}, {}
    local function pushStr(s, fg, bg)
        for i = 1, #s do
            lbl_t[#lbl_t+1] = s:sub(i,i)
            lbl_f[#lbl_f+1] = c2b(fg)
            lbl_b[#lbl_b+1] = c2b(bg)
        end
    end
    -- Left panel label
    pushStr(pad(" FLEET", LEFT_W - 1), colors.lightGray, colors.black)
    pushStr("|", colors.gray, colors.black)
    -- Centre label
    local map_w = w - LEFT_W - RIGHT_W
    pushStr(pad(" MAP", map_w - 1), colors.lightGray, colors.black)
    pushStr("|", colors.gray, colors.black)
    -- Right panel label
    pushStr(pad(" ORES & SUPPLIES", RIGHT_W), colors.lightGray, colors.black)

    mon.setCursorPos(1, 3)
    mon.blit(table.concat(lbl_t), table.concat(lbl_f), table.concat(lbl_b))
end

-- ── PANEL LEFT: Fleet roster ───────────────────────────────────────────

local function renderFleet(first_row, last_row)
    local BLK = c2b(colors.black)
    local GRY = c2b(colors.gray)
    local row = first_row
    local inner = LEFT_W - 1   -- usable cols before the | border

    for hwid, f in pairs(fleet) do
        if row > last_row then break end

        local p      = f.pos or {}
        local status = tostring(f.status or "?"):upper()
        local dir_g  = DIR_GLYPH[f.dir or 0] or "?"
        local fb     = fuelBar(f.fuel)
        local cb     = cargoBar(f.free)
        local fc     = c2b(fuelColor(f.fuel))
        local sc     = c2b(statusColor(status))

        -- Line A: HWID  dir  STATUS
        local lineA = string.format("%-9s %s %-6s", hwid, dir_g, status:sub(1,6))
        lineA = pad(lineA, inner)

        local t_a, f_a, b_a = {}, {}, {}
        for i = 1, #lineA do
            t_a[i] = lineA:sub(i,i)
            b_a[i] = BLK
            -- colour HWID cyan, rest status colour
            f_a[i] = i <= 9 and c2b(colors.cyan) or sc
        end
        t_a[#t_a+1] = "|"; f_a[#f_a+1] = GRY; b_a[#b_a+1] = BLK

        mon.setCursorPos(1, row)
        mon.blit(table.concat(t_a), table.concat(f_a), table.concat(b_a))
        row = row + 1
        if row > last_row then break end

        -- Line B: fuel bar  cargo bar  pos
        local lineB = string.format("%s%s (%d,%d)", fb, cb, math.floor(p.x or 0), math.floor(p.z or 0))
        lineB = pad(lineB, inner)

        local t_b, f_b, b_b = {}, {}, {}
        for i = 1, #lineB do
            t_b[i] = lineB:sub(i,i)
            b_b[i] = BLK
            if i <= 7 then f_b[i] = fc               -- fuel bar
            elseif i <= 14 then f_b[i] = c2b(colors.orange)  -- cargo bar
            else f_b[i] = c2b(colors.lightGray) end
        end
        t_b[#t_b+1] = "|"; f_b[#f_b+1] = GRY; b_b[#b_b+1] = BLK

        mon.setCursorPos(1, row)
        mon.blit(table.concat(t_b), table.concat(f_b), table.concat(b_b))
        row = row + 1

        -- separator between robots
        if row <= last_row then
            local sep = pad(string.rep("-", inner - 1), inner)
            mon.setCursorPos(1, row)
            mon.blit(sep .. "|", string.rep(GRY, inner) .. GRY, string.rep(BLK, inner + 1))
            row = row + 1
        end
    end

    -- Empty rows
    while row <= last_row do
        mon.setCursorPos(1, row)
        mon.blit(pad("", inner) .. "|",
            string.rep(c2b(colors.black), inner) .. GRY,
            string.rep(BLK, inner + 1))
        row = row + 1
    end
end

-- ── PANEL RIGHT: Ore tally + supplies ──────────────────────────────────

local function renderRight(first_row, last_row, map_end_col)
    local BLK  = c2b(colors.black)
    local inner = RIGHT_W - 1

    local row = first_row

    -- Ore tally header
    local hdr = pad(" >> ORE HAUL", inner)
    mon.setCursorPos(map_end_col, row)
    mon.blit("|" .. hdr, c2b(colors.gray) .. string.rep(c2b(colors.yellow), inner),
             string.rep(BLK, 1 + inner))
    row = row + 1

    -- Sort ores by count descending
    local sorted = {}
    for name, count in pairs(ore_log) do
        sorted[#sorted+1] = { name = name, count = count }
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)

    for _, entry in ipairs(sorted) do
        if row > last_row - 3 then break end  -- reserve rows for supplies
        local bar_filled = math.min(5, math.floor(entry.count / 10))
        local bar = string.rep("|", bar_filled) .. string.rep(".", 5 - bar_filled)
        local line = string.format("[%s] %-10s %d", bar, entry.name:sub(1,10), entry.count)
        line = pad(line, inner)
        local col = oreColor(entry.name)

        mon.setCursorPos(map_end_col, row)
        mon.blit("|" .. line, c2b(colors.gray) .. string.rep(c2b(col), inner),
                 string.rep(BLK, 1 + inner))
        row = row + 1
    end

    -- Supply divider
    if row <= last_row - 2 then
        local div = pad(" >> SUPPLIES", inner)
        mon.setCursorPos(map_end_col, row)
        mon.blit("|" .. div, c2b(colors.gray) .. string.rep(c2b(colors.yellow), inner),
                 string.rep(BLK, 1 + inner))
        row = row + 1
    end

    -- Supply chest contents
    local supplies = checkSupplies()
    for name, count in pairs(supplies) do
        if row > last_row then break end
        local line = pad(string.format(" %-11s %d", name:sub(1,11), count), inner)
        mon.setCursorPos(map_end_col, row)
        mon.blit("|" .. line, c2b(colors.gray) .. string.rep(c2b(colors.lightGray), inner),
                 string.rep(BLK, 1 + inner))
        row = row + 1
    end

    -- Empty rows
    while row <= last_row do
        mon.setCursorPos(map_end_col, row)
        mon.blit("|" .. pad("", inner), c2b(colors.gray) .. string.rep(BLK, inner),
                 string.rep(BLK, 1 + inner))
        row = row + 1
    end
end

-- ── PANEL CENTRE: Voxel map ────────────────────────────────────────────

local function renderMap(first_row, last_row, map_col_start, map_col_end)
    local map_w   = map_col_end - map_col_start + 1
    local map_h   = last_row - first_row + 1
    local cx_col  = map_col_start + math.floor(map_w / 2)
    local cx_row  = first_row    + math.floor(map_h / 2)
    local blink   = (os.epoch("utc") % 800) < 400
    local BLK     = c2b(colors.black)

    local blips = {}
    for _, f in pairs(fleet) do
        if f.pos then
            blips[floor(f.pos.x or 0) * 1000003 + floor(f.pos.z or 0)] = { hwid = f, status = f.status }
        end
    end
    local dumpKey = floor(DUMP_CHEST.x) * 1000003 + floor(DUMP_CHEST.z)
    local baseKey = floor(BASE_CHEST.x) * 1000003 + floor(BASE_CHEST.z)
    local park_x1, park_x2, park_z1, park_z2 = nil, nil, nil, nil
    if PARK_ZONE then
        park_x1 = math.min(PARK_ZONE.x1, PARK_ZONE.x2)
        park_x2 = math.max(PARK_ZONE.x1, PARK_ZONE.x2)
        park_z1 = math.min(PARK_ZONE.z1, PARK_ZONE.z2)
        park_z2 = math.max(PARK_ZONE.z1, PARK_ZONE.z2)
    end

    for srow = first_row, last_row do
        local rz      = srow - cx_row
        local world_z = view_cz + rz
        local t_buf, f_buf = {}, {}

        for scol = map_col_start, map_col_end do
            local rx      = scol - cx_col
            local world_x = view_cx + rx
            local ch, fg  = " ", BLK
            local ck      = world_x * 1000003 + world_z
            local in_range = math.abs(rx) <= MAP_RADIUS and math.abs(rz) <= MAP_RADIUS
            local in_park = park_x1
                and world_x >= park_x1 and world_x <= park_x2
                and world_z >= park_z1 and world_z <= park_z2

            if ck == dumpKey then
                ch, fg = "D", c2b(colors.orange)
            elseif ck == baseKey then
                ch, fg = "B", c2b(colors.cyan)
            elseif blips[ck] then
                if blink then
                    local st = tostring((blips[ck].status or "?")):upper()
                    ch = (st == "MINING") and "@" or (st == "DUMP" and "D" or "?")
                    fg = c2b(statusColor(st))
                elseif in_range then
                    local saw_known_air = false
                    for d = 0, RAYCAST_DEPTH - 1 do
                        local vn = getVoxel(world_x, view_y - d, world_z)
                        if vn == AIR_MARKER then
                            saw_known_air = true
                            -- Tunnel air at this column should win over deeper rock.
                            break
                        elseif not isAir(vn) then
                            local bc, bfg = renderCell(vn, d)
                            ch, fg = bc, c2b(bfg)
                            break
                        end
                    end
                    if ch == " " then
                        if saw_known_air then
                            ch, fg = "*", c2b(colors.gray)
                        else
                            ch, fg = " ", BLK
                        end
                    end
                end
            elseif in_range then
                local saw_known_air = false
                for d = 0, RAYCAST_DEPTH - 1 do
                    local vn = getVoxel(world_x, view_y - d, world_z)
                    if vn == AIR_MARKER then
                        saw_known_air = true
                        -- Tunnel air at this column should win over deeper rock.
                        break
                    elseif not isAir(vn) then
                        local tc, tfg = renderCell(vn, d)
                        ch, fg = tc, c2b(tfg)
                        break
                    end
                end
                if ch == " " then
                    if saw_known_air then
                        ch, fg = "*", c2b(colors.gray)
                    else
                        ch, fg = " ", BLK
                    end
                end
            end

            -- Draw park zone marker only when no higher-priority symbol is present.
            if in_park and ch == " " then
                ch, fg = "%", c2b(colors.lightGray)
            end

            t_buf[#t_buf+1] = ch
            f_buf[#f_buf+1] = fg
        end

        mon.setCursorPos(map_col_start, srow)
        mon.blit(table.concat(t_buf), table.concat(f_buf), string.rep(BLK, map_w))
    end
end

-- ── PANEL: LEGEND + LIVE ORE FEED (bottom rows) ──────────────────────

local function renderFooter(h, w)
    local BLK = c2b(colors.black)

    -- Legend row (second to last)
    local leg_t, leg_f, leg_b = {}, {}, {}
    local function legItem(ch, fg, label)
        local s = ch .. "=" .. label .. "  "
        for i = 1, #s do
            leg_t[#leg_t+1] = s:sub(i,i)
            leg_b[#leg_b+1] = BLK
            leg_f[#leg_f+1] = (i == 1) and c2b(fg) or c2b(colors.gray)
        end
    end
    legItem("@", colors.magenta, "Robot")
    legItem("D", colors.orange,  "Dump")
    legItem("B", colors.cyan,    "Base")
    legItem("%", colors.lightGray, "Park Zone")
    legItem("#", colors.yellow,  "Known Solid")
    legItem("*", colors.gray,    "Inferred Air")
    legItem("d", colors.cyan,    "Ore")
    while #leg_t < w do leg_t[#leg_t+1]=" "; leg_f[#leg_f+1]=BLK; leg_b[#leg_b+1]=BLK end
    mon.setCursorPos(1, h - 1)
    mon.blit(table.concat(leg_t,"",1,w), table.concat(leg_f,"",1,w), table.concat(leg_b,"",1,w))

    -- Bottom row: Phase 5C live ore feed (most recent find)
    local feed_msg = "  No ore found yet."
    if #ORE_FEED > 0 then
        local latest = ORE_FEED[#ORE_FEED]
        feed_msg = string.format(" %s %s %s (%d,%d,%d)",
            latest.time, latest.hwid, latest.ore, latest.x, latest.y, latest.z)
        -- Cycle through all feed entries every 3 seconds
        local idx = math.floor(os.epoch("utc")/3000) % #ORE_FEED + 1
        local e = ORE_FEED[idx]
        feed_msg = string.format(" %s %s %s (%d,%d,%d)",
            e.time, e.hwid, e.ore, e.x, e.y, e.z)
    end
    solidRow(h, pad(feed_msg, w), colors.cyan, colors.black, w)
end

-- ── Master render ──────────────────────────────────────────────────────

local function renderDisplay()
    if not mon then return end
    local w, h = mon.getSize()

    -- Panel column boundaries
    local map_col_start = LEFT_W + 1
    local map_col_end   = w - RIGHT_W
    local first_content = HDR_ROWS + 1
    local last_content  = h - FOOTER_ROWS

    renderHeader(w)
    renderFleet(first_content, last_content)
    renderMap(first_content, last_content, map_col_start, map_col_end)
    renderRight(first_content, last_content, map_col_end)
    renderFooter(h, w)
end

-- ============================================================
-- NETWORK HANDLERS
-- ============================================================
local function handleAuth(net_id, msg)
    if type(msg.hwid) ~= "string" then return end
    local existing = fleet[msg.hwid]

    local dir, offset
    if existing and zone_log[msg.hwid] and not zone_log[msg.hwid].exhausted then
        -- Re-enlisting turtle keeps its existing lane
        dir    = zone_log[msg.hwid].dir
        offset = zone_log[msg.hwid].offset
    else
        dir, offset = assignLane(msg.hwid)
    end

    fleet[msg.hwid] = {
        net_id      = net_id,
        last_pulse  = os.epoch("utc"),
        pos         = msg.pos or { x=0, y=0, z=0 },
        status      = "STANDBY",
        dir         = dir,
        lane_offset = offset,
        fuel        = "?",
        free        = "?",
        park_slot   = fleet_slot,
    }
    fleet_slot = fleet_slot + 1

    local park_pos = getParkSlot(fleet[msg.hwid].park_slot)

    rednet.send(net_id, {
        type        = "AUTH_ACK",
        hwid        = msg.hwid,
        direction   = dir,
        lane_offset = offset,
        dump        = DUMP_CHEST,
        base        = BASE_CHEST,
        want        = WANT_LIST,
        park        = park_pos,
    }, PROTOCOL)

    print(string.format("[ENLIST] %s  ->  dir=%d lane=+%d park=%s",
        msg.hwid, dir, offset,
        park_pos and string.format("(%d,%d,%d)", park_pos.x, park_pos.y, park_pos.z)
                 or "none"))
end

local function handleHeartbeat(msg)
    local f = fleet[msg.hwid]; if not f then return end
    f.last_pulse = os.epoch("utc")
    if msg.status then f.status = msg.status end
    if msg.fuel   then f.fuel   = msg.fuel   end
    if msg.pos    then f.pos    = msg.pos    end
    if msg.free   then f.free   = msg.free   end

    -- When a turtle parks after exhausting its tunnel, mark zone done
    if msg.status == "PARKED" and zone_log[msg.hwid] then
        if not zone_log[msg.hwid].exhausted then
            zone_log[msg.hwid].exhausted = true
            print(string.format("[ZONE]   %s tunnel complete. Type 'newrun %s' to assign fresh lane.",
                msg.hwid, msg.hwid))
        end
    end
end

local function handleParkReq(net_id, msg)
    if type(msg.hwid) ~= "string" then return end
    local slot = assignUnclaimedParkSlot(msg.hwid, msg.pos)
    rednet.send(net_id, {
        type = "PARK_ASSIGN",
        hwid = msg.hwid,
        nonce = msg.nonce,
        strict = true,
        park = slot,
    }, PROTOCOL)
    if slot then
        print(string.format("[PARK]   %s -> strict slot (%d,%d,%d)", msg.hwid, slot.x, slot.y, slot.z))
    else
        print(string.format("[PARK]   %s requested strict park but no slot available.", msg.hwid))
    end
end

local function handleParkRelease(msg)
    if type(msg.hwid) ~= "string" then return end
    clearParkClaim(msg.hwid)
end

-- ============================================================
-- ACTIVE ORDERS  (getme command)
-- active_orders[ore_name] = {
--     target  = number,   -- how many the user asked for
--     got     = number,   -- confirmed mined so far this order
--     jobs    = {},       -- set of coord keys currently dispatched
-- }
-- ============================================================
local active_orders = {}

-- Tile reservations for collision prevention.
-- reservations["x:y:z"] = { hwid = "MN-0001", expires = epoch_ms }
local reservations = {}

local function reserveKey(p)
    local x = math.floor(tonumber(p.x) or 0)
    local y = math.floor(tonumber(p.y) or 0)
    local z = math.floor(tonumber(p.z) or 0)
    return x .. ":" .. y .. ":" .. z
end

local function cleanupReservations(now)
    now = now or os.epoch("utc")
    for k, r in pairs(reservations) do
        if type(r) ~= "table" or (tonumber(r.expires) or 0) <= now then
            reservations[k] = nil
        end
    end
end

local function clearReservationsFor(hwid)
    for k, r in pairs(reservations) do
        if type(r) == "table" and r.hwid == hwid then
            reservations[k] = nil
        end
    end
end

local function isOccupiedByOther(want, requester_hwid)
    local tx = math.floor(tonumber(want.x) or 0)
    local ty = math.floor(tonumber(want.y) or 0)
    local tz = math.floor(tonumber(want.z) or 0)
    for hwid, f in pairs(fleet) do
        if hwid ~= requester_hwid and f.pos then
            local p = f.pos
            if math.floor(tonumber(p.x) or 0) == tx
            and math.floor(tonumber(p.y) or 0) == ty
            and math.floor(tonumber(p.z) or 0) == tz then
                return hwid
            end
        end
    end
    return nil
end

local function handleReserveReq(net_id, msg)
    if type(msg.hwid) ~= "string" or type(msg.want) ~= "table" then return end
    cleanupReservations()

    local now = os.epoch("utc")
    local k = reserveKey(msg.want)
    local ttl = math.floor(tonumber(msg.ttl_ms) or 1200)
    ttl = math.max(250, math.min(4000, ttl))

    local occupied_by = isOccupiedByOther(msg.want, msg.hwid)
    local existing = reservations[k]
    local granted = false
    local owner = nil

    if occupied_by then
        granted = false
        owner = occupied_by
    elseif existing and existing.hwid ~= msg.hwid and (tonumber(existing.expires) or 0) > now then
        granted = false
        owner = existing.hwid
    else
        reservations[k] = { hwid = msg.hwid, expires = now + ttl }
        granted = true
        owner = msg.hwid
    end

    rednet.send(net_id, {
        type    = "RESERVE_ACK",
        hwid    = msg.hwid,
        nonce   = msg.nonce,
        granted = granted,
        owner   = owner,
        want    = msg.want,
    }, PROTOCOL)
end

local function handleReserveRel(msg)
    if type(msg.hwid) ~= "string" or type(msg.want) ~= "table" then return end
    cleanupReservations()
    local k = reserveKey(msg.want)
    local r = reservations[k]
    if r and r.hwid == msg.hwid then
        reservations[k] = nil
    end
end

local function countInDump(ore_name)
    -- Count matching items already in the dump chest.
    -- The ore name may arrive as "diamond" (shortname) or
    -- "minecraft:diamond" (full). Match both.
    if not vault then return 0 end
    local ok, list = pcall(vault.list, vault)
    if not ok or type(list) ~= "table" then return 0 end
    local total = 0
    for _, item in pairs(list) do
        local n = tostring(item.name or "")
        if n:find(ore_name, 1, true) or n == ore_name then
            total = total + item.count
        end
    end
    return total
end

-- Scan master_voxels for all blocks whose name contains ore_name.
-- Returns a list of { x, y, z, name } sorted nearest-first to refpos.
local function findOreInMap(ore_name, refpos)
    local found = {}
    for y, xt in pairs(master_voxels) do
        for x, zt in pairs(xt) do
            for z, name in pairs(zt) do
                if type(name) == "string" and name:find(ore_name, 1, true) then
                    found[#found+1] = { x=x, y=y, z=z, name=name }
                end
            end
        end
    end
    -- Sort by Manhattan distance from refpos
    if refpos then
        table.sort(found, function(a, b)
            local da = math.abs(a.x-refpos.x)+math.abs(a.y-refpos.y)+math.abs(a.z-refpos.z)
            local db = math.abs(b.x-refpos.x)+math.abs(b.y-refpos.y)+math.abs(b.z-refpos.z)
            return da < db
        end)
    end
    return found
end

local function mergeOrCluster(ore_name, x, y, z)
    -- Find an existing cluster of the same ore type within CLUSTER_RADIUS
    for _, cl in ipairs(clusters) do
        if cl.ore == ore_name then
            local dist = math.abs(x-cl.cx)+math.abs(y-cl.cy)+math.abs(z-cl.cz)
            if dist <= CLUSTER_RADIUS then
                -- Update centroid (running average)
                cl.count = cl.count + 1
                cl.cx = math.floor((cl.cx*(cl.count-1) + x) / cl.count + 0.5)
                cl.cy = math.floor((cl.cy*(cl.count-1) + y) / cl.count + 0.5)
                cl.cz = math.floor((cl.cz*(cl.count-1) + z) / cl.count + 0.5)
                return cl
            end
        end
    end
    -- New cluster
    local cl = { ore=ore_name, cx=x, cy=y, cz=z, count=1, dispatched=false }
    clusters[#clusters+1] = cl
    return cl
end

-- Find the nearest idle turtle (MINING or STANDBY) to a coordinate
local function nearestIdleTurtle(x, y, z, exclude_hwid)
    local best_hwid, best_dist = nil, math.huge
    for hwid, f in pairs(fleet) do
        if hwid ~= exclude_hwid and f.pos then
            local st = tostring(f.status):upper()
            if st == "MINING" or st == "STANDBY" or st == "PARKED" then
                local d = math.abs(f.pos.x-x)+math.abs(f.pos.y-y)+math.abs(f.pos.z-z)
                if d < best_dist then best_dist=d; best_hwid=hwid end
            end
        end
    end
    return best_hwid
end

-- ============================================================
-- PHASE 5C: LIVE ORE FEED
-- ============================================================
local function pushOreFeed(ore, hwid, x, y, z)
    table.insert(ORE_FEED, {
        time = os.date("%H:%M"),
        ore  = ore,
        hwid = hwid,
        x=x, y=y, z=z,
    })
    if #ORE_FEED > ORE_FEED_MAX then table.remove(ORE_FEED, 1) end
end

local function handleOreReport(msg)
    if type(msg.ore) ~= "string" or type(msg.pos) ~= "table" then return end
    local ore = msg.ore
    local ore_key = normalizeOreName(ore)
    local x, y, z = math.floor(msg.pos.x or 0), math.floor(msg.pos.y or 0), math.floor(msg.pos.z or 0)

    -- Update running total
    ore_log[ore_key] = (ore_log[ore_key] or 0) + 1

    -- Push to live feed
    pushOreFeed(ore_key, msg.hwid, x, y, z)

    -- Phase 5B: cluster-aware dispatch
    if WANT_LIST[ore_key] then
        local cl = mergeOrCluster(ore_key, x, y, z)
        if not cl.dispatched then
            cl.dispatched = true
            -- Dispatch the nearest idle turtle (not necessarily the reporter)
            local target_hwid = nearestIdleTurtle(cl.cx, cl.cy, cl.cz, nil)
            if target_hwid then
                local f = fleet[target_hwid]
                if f then
                    rednet.send(f.net_id, {
                        type = "GOTO",
                        hwid = target_hwid,
                        ore  = ore_key,
                        pos  = { x=cl.cx, y=cl.cy, z=cl.cz },
                    }, PROTOCOL)
                    print(string.format("[ORDER]  %s -> GOTO %s cluster(%d,%d,%d) size=%d",
                        target_hwid, ore_key, cl.cx, cl.cy, cl.cz, cl.count))
                end
            end
        end
    end
end

local function handleGeoData(msg)
    -- Ingest scan data into the voxel map.
    -- Air blocks are explicitly tracked as AIR_MARKER so the map can render
    -- tunnels distinctly from unknown/solid areas.
    local f = fleet[msg.hwid]
    if f then f.last_pulse = os.epoch("utc"); if msg.pos then f.pos = msg.pos end end
    local scan, p = msg.scan_data, msg.pos
    if type(scan) == "table" and type(p) == "table" then
        local ox, oy, oz = floor(p.x or 0), floor(p.y or 0), floor(p.z or 0)
        local now = os.epoch("utc")
        local seen = {}

        -- Prune stale volatile sightings to cap RAM growth.
        for k, v in pairs(volatile_solids) do
            if type(v) ~= "table" or (now - (tonumber(v.ts) or 0)) > VOL_SOLID_TTL_MS then
                volatile_solids[k] = nil
            end
        end

        for _, b in ipairs(scan) do
            if type(b) == "table" and type(b.name) == "string" then
                local ax = floor(ox + (b.x or 0))
                local ay = floor(oy + (b.y or 0))
                local az = floor(oz + (b.z or 0))
                local k = ax..":"..ay..":"..az
                if isGeoScanNoise(b.name) then
                    setVoxel(ax, ay, az, AIR_MARKER)
                    volatile_solids[k] = nil
                elseif isAir(b.name) then
                    setVoxel(ax, ay, az, AIR_MARKER)
                    volatile_solids[k] = nil
                else
                    seen[k] = true
                    if shouldStore(b.name) then
                        setVoxel(ax, ay, az, b.name)
                    else
                        -- Rock-like solids are tracked only in RAM.
                        volatile_solids[k] = { x=ax, y=ay, z=az, ts=now }
                    end
                end
            end
        end

        -- Geo scanner typically reports non-air blocks only.
        -- If a volatile in-range solid is no longer reported, treat that
        -- negative space as inferred air and persist only the air marker.
        local radius = floor(tonumber(msg.scan_radius) or 0)
        if radius > 0 then
            local r2 = radius * radius
            for k, v in pairs(volatile_solids) do
                local dx = v.x - ox
                local dy = v.y - oy
                local dz = v.z - oz
                if (dx*dx + dy*dy + dz*dz) <= r2 then
                    if not seen[k] then
                        setVoxel(v.x, v.y, v.z, AIR_MARKER)
                        volatile_solids[k] = nil
                    else
                        v.ts = now
                    end
                end
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
            elseif msg.type == "GEO_DATA"   then handleGeoData(msg)
            elseif msg.type == "ORE_MINED"  then
                local ore = tostring(msg.ore or "")
                local k   = (msg.pos and (msg.pos.x..":"..msg.pos.y..":"..msg.pos.z)) or ""
                -- Update active orders
                for order_ore, order in pairs(active_orders) do
                    if ore:find(order_ore, 1, true) or order_ore:find(ore, 1, true) then
                        if order.jobs[k] then
                            order.jobs[k] = nil
                            order.got = order.got + 1
                            print(string.format("[ORDER]  getme %s: %d/%d confirmed.",
                                order_ore, order.got, order.target))
                        end
                    end
                end
                -- Reset cluster dispatched flag near this position so the
                -- same area can be re-dispatched if more ore appears later
                if msg.pos then
                    local px = math.floor(msg.pos.x or 0)
                    local py = math.floor(msg.pos.y or 0)
                    local pz = math.floor(msg.pos.z or 0)
                    for _, cl in ipairs(clusters) do
                        if cl.ore == ore then
                            local d = math.abs(px-cl.cx)+math.abs(py-cl.cy)+math.abs(pz-cl.cz)
                            if d <= CLUSTER_RADIUS then
                                cl.dispatched = false
                            end
                        end
                    end
                end
            elseif msg.type == "ALERT"      then
                local al = tostring(msg.hwid) .. ": " .. tostring(msg.msg)
                print("[ALERT]  " .. al)
                pushAlert(al)

            elseif msg.type == "PARK_REQ" then
                handleParkReq(net_id, msg)

            elseif msg.type == "PARK_RELEASE" then
                handleParkRelease(msg)

            elseif msg.type == "RESERVE_REQ" then
                handleReserveReq(net_id, msg)

            elseif msg.type == "RESERVE_REL" then
                handleReserveRel(msg)

            -- O-NET V1: Push protocol broker.
            -- A turtle broadcasts PUSH_REQ when stuck. We find who is at
            -- the blocked position, compare priorities, and send a YIELD
            -- directly to the lower-priority turtle if needed.
            elseif msg.type == "PUSH_REQ" then
                local want = msg.want
                if want and type(want) == "table" then
                    local pusher_pri = tonumber(msg.priority) or 10
                    for target_hwid, f in pairs(fleet) do
                        if target_hwid ~= msg.hwid and f.pos then
                            local fp = f.pos
                            if math.floor(fp.x)==want.x
                            and math.floor(fp.y)==want.y
                            and math.floor(fp.z)==want.z then
                                -- Found the blocker. Check priority.
                                local blocker_state = tostring(f.status or "STANDBY"):upper()
                                local blocker_pri = MOVE_PRIORITY_MAP[blocker_state] or 10
                                if blocker_pri >= pusher_pri then
                                    rednet.send(f.net_id, {
                                        type = "YIELD",
                                        hwid = target_hwid,
                                    }, PROTOCOL)
                                    print(string.format(
                                        "[PUSH]   %s(pri=%d) pushing %s(pri=%d) off (%d,%d,%d)",
                                        msg.hwid, pusher_pri,
                                        target_hwid, blocker_pri,
                                        want.x, want.y, want.z))
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- ORDER THREAD  (drives getme commands)
-- Runs a background loop. Every 3 seconds for each active order:
--   1. Count items already in the dump chest.
--   2. Scan the voxel map for known ore locations.
--   3. Sort nearest-first and dispatch GOTO to idle turtles.
--   4. Mark order complete when target is reached.
-- ============================================================
local function orderThread()
    while true do
        sleep(3)

        for ore_name, order in pairs(active_orders) do

            local in_chest  = countInDump(ore_name)
            local effective = math.max(order.got, in_chest)

            if effective >= order.target then
                print(string.format(
                    "[ORDER]  getme %s COMPLETE: %d/%d in dump chest.",
                    ore_name, in_chest, order.target))
                active_orders[ore_name] = nil
            else
                local remaining = order.target - effective
                local pending   = 0
                for _ in pairs(order.jobs) do pending = pending + 1 end
                local slots_open = remaining - pending

                if slots_open > 0 then
                    local refpos    = { x=view_cx, y=view_y, z=view_cz }
                    local locations = findOreInMap(ore_name, refpos)
                    local dispatched_this_tick = 0

                    for _, loc in ipairs(locations) do
                        if dispatched_this_tick >= slots_open then break end
                        local lk = loc.x..":"..loc.y..":"..loc.z
                        if not order.jobs[lk] then
                            local target_hwid = nearestIdleTurtle(loc.x, loc.y, loc.z, nil)
                            if target_hwid then
                                local f = fleet[target_hwid]
                                if f then
                                    rednet.send(f.net_id, {
                                        type = "GOTO",
                                        hwid = target_hwid,
                                        ore  = ore_name,
                                        pos  = { x=loc.x, y=loc.y, z=loc.z },
                                    }, PROTOCOL)
                                    order.jobs[lk] = true
                                    dispatched_this_tick = dispatched_this_tick + 1
                                    print(string.format(
                                        "[ORDER]  getme %s: sent %s -> (%d,%d,%d) [~%d/%d]",
                                        ore_name, target_hwid,
                                        loc.x, loc.y, loc.z,
                                        effective + dispatched_this_tick, order.target))
                                end
                            end
                        end
                    end

                    -- Only warn about no map data once per order, not every tick
                    if dispatched_this_tick == 0 and pending == 0
                    and not order.warned_empty then
                        order.warned_empty = true
                        print(string.format(
                            "[ORDER]  getme %s: no known locations on map yet. Waiting for fleet scans.",
                            ore_name))
                    end

                    -- Clear the warning once ore appears on the map
                    if dispatched_this_tick > 0 then
                        order.warned_empty = false
                    end
                end
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
                pushAlert(hwid .. " LOST SIGNAL")
                clearReservationsFor(hwid)
                clearParkClaim(hwid)
                fleet[hwid] = nil
            end
        end
    end
end

local function mapSaveThread()
    while true do
        sleep(60)
        if map_persist_enabled and map_dirty then
            local ok = saveMap()
            if ok then
            print(string.format("[MAP]    Auto-saved %d voxels.", total_voxels))
            end
        end
    end
end

local function displayThread()
    if not mon then return end
    while true do
        updateViewCenter()
        renderDisplay()
        sleep(DISP_REFRESH)
    end
end

-- ---- terminal ----
local function splitWords(s)
    local t = {}; for w in s:gmatch("%S+") do t[#t + 1] = w end; return t
end
local function parseCoords(a, b, c)
    local x, y, z = tonumber(a), tonumber(b), tonumber(c)
    if x and y and z then return { x = x, y = y, z = z } end
    return nil
end
local function terminalThread()
    while true do
        local parts = splitWords(read())
        local cmd = parts[1]

        if cmd == "start" then
            rednet.broadcast({ type = "CMD_START" }, PROTOCOL)
            clearAllParkClaims()
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
                print(string.format("  %-10s dir=%d %-10s fuel=%-6s free=%-2s (%d,%d,%d)",
                    hwid, f.dir or 0, f.status or "?",
                    tostring(f.fuel), tostring(f.free),
                    p.x or 0, p.y or 0, p.z or 0))
            end
            print("---- SUPPLIES ----")
            for name, count in pairs(checkSupplies()) do
                print(string.format("  %-20s %d", name, count))
            end

        elseif cmd == "setdump" then
            local c = parseCoords(parts[2], parts[3], parts[4])
            if c then
                DUMP_CHEST = c; saveConfig(); broadcastConfig()
                print(string.format("[CFG]    Dump chest -> (%d,%d,%d).", c.x, c.y, c.z))
            else print("Usage: setdump x y z") end

        elseif cmd == "setbase" then
            local c = parseCoords(parts[2], parts[3], parts[4])
            if c then
                BASE_CHEST = c; saveConfig(); broadcastConfig()
                print(string.format("[CFG]    Base chest -> (%d,%d,%d).", c.x, c.y, c.z))
            else print("Usage: setbase x y z") end

        elseif cmd == "coords" then
            print(string.format("  Dump: (%d,%d,%d)", DUMP_CHEST.x, DUMP_CHEST.y, DUMP_CHEST.z))
            print(string.format("  Base: (%d,%d,%d)", BASE_CHEST.x, BASE_CHEST.y, BASE_CHEST.z))
            if PARK_ZONE then
                print(string.format("  Park: (%d,%d,%d) -> (%d,%d,%d)  %d slots",
                    PARK_ZONE.x1, PARK_ZONE.y1, PARK_ZONE.z1,
                    PARK_ZONE.x2, PARK_ZONE.y2, PARK_ZONE.z2,
                    (math.abs(PARK_ZONE.x2-PARK_ZONE.x1)+1)*(math.abs(PARK_ZONE.z2-PARK_ZONE.z1)+1)))
            else
                print("  Park: not set (turtles park in place)")
            end

        elseif cmd == "want" then
            if parts[2] then
                WANT_LIST[parts[2]] = true; saveConfig()
                print("[CFG]    Now fetching: " .. parts[2])
            else print("Usage: want <ore_name>  e.g. want diamond") end

        elseif cmd == "unwant" then
            if parts[2] then
                WANT_LIST[parts[2]] = nil; saveConfig()
                print("[CFG]    Stopped fetching: " .. parts[2])
            else print("Usage: unwant <ore_name>") end

        elseif cmd == "wants" then
            write("  Fetching: ")
            local any = false
            for ore in pairs(WANT_LIST) do write(ore .. "  "); any = true end
            print(any and "" or "(nothing)")

        elseif cmd == "zones" then
            if not next(zone_log) then print("  No zones assigned yet."); else
                print("---- ZONES ----")
                for hwid, z in pairs(zone_log) do
                    print(string.format("  %-10s dir=%d lane=+%d %s",
                        hwid, z.dir, z.offset,
                        z.exhausted and "[EXHAUSTED]" or "[ACTIVE]"))
                end
            end

        elseif cmd == "newrun" then
            local target = parts[2]
            if target and fleet[target] then
                local f = fleet[target]
                local dir, offset = reassignLane(target)
                f.dir = dir; f.lane_offset = offset
                rednet.send(f.net_id, {
                    type="CONFIG", direction=dir, lane_offset=offset,
                    dump=DUMP_CHEST, base=BASE_CHEST, want=WANT_LIST,
                }, PROTOCOL)
                print(string.format("[CMD]    %s -> dir=%d lane=+%d", target, dir, offset))
            elseif target then
                print("Unknown turtle: " .. target)
            else
                print("Usage: newrun <hwid>   e.g. newrun MN-0014")
            end

        elseif cmd == "map" then
            print(string.format("  Voxels  : %d", total_voxels))
            print(string.format("  Centre  : (%d,%d)  Y=%d", view_cx, view_cz, view_y))
            print(string.format("  File    : %s", fs.exists(MAP_FILE) and MAP_FILE or "not saved yet"))
            print(string.format("  Dirty   : %s", map_dirty and "yes (unsaved changes)" or "no"))
            print(string.format("  Persist : %s", map_persist_enabled and "enabled" or ("disabled ("..tostring(map_persist_reason or "error")..")")))

        elseif cmd == "savemap" then
            if not map_persist_enabled then
                print("[MAP]    Persistence disabled; running RAM-only.")
            else
                local ok = saveMap()
                if ok then
                    print(string.format("[MAP]    Saved %d voxels to disk.", total_voxels))
                end
            end

        elseif cmd == "clearmap" then
            master_voxels = {}; total_voxels = 0; map_dirty = false
            if fs.exists(MAP_FILE) then fs.delete(MAP_FILE) end
            print("[MAP]    Voxel database cleared.")

        elseif cmd == "feed" then
            if #ORE_FEED == 0 then
                print("  No ore found yet.")
            else
                print("---- ORE FEED (newest first) ----")
                for i = #ORE_FEED, 1, -1 do
                    local e = ORE_FEED[i]
                    print(string.format("  %s  %-10s  %-20s  (%d,%d,%d)",
                        e.time, e.hwid, e.ore, e.x, e.y, e.z))
                end
            end

        elseif cmd == "getme" then
            -- Usage: getme <ore> <count>
            -- Scans the map for known ore locations, dispatches GOTOs to
            -- the nearest idle turtles, and keeps dispatching until the
            -- target count arrives in the dump chest.
            local ore_name = parts[2]
            local target   = tonumber(parts[3])
            if not ore_name or not target or target <= 0 then
                print("Usage: getme <ore> <count>   e.g. getme diamond 128")
            else
                -- Cancel any previous order for this ore
                if active_orders[ore_name] then
                    print(string.format("[ORDER]  Replacing existing getme %s order.", ore_name))
                end
                active_orders[ore_name] = {
                    target = target,
                    got    = 0,
                    jobs   = {},
                }
                local in_chest = countInDump(ore_name)
                local on_map   = #findOreInMap(ore_name, nil)
                print(string.format(
                    "[ORDER]  getme %s x%d started. In chest: %d. Known on map: %d locations.",
                    ore_name, target, in_chest, on_map))
                if in_chest >= target then
                    print(string.format("[ORDER]  Already have %d in dump chest. Order complete.", in_chest))
                    active_orders[ore_name] = nil
                elseif on_map == 0 then
                    print("[ORDER]  No known locations on map yet. Fleet will report finds as it mines.")
                end
            end

        elseif cmd == "orders" then
            if not next(active_orders) then
                print("  No active orders.")
            else
                print("---- ACTIVE ORDERS ----")
                for ore_name, order in pairs(active_orders) do
                    local in_chest = countInDump(ore_name)
                    local pending  = 0
                    for _ in pairs(order.jobs) do pending = pending + 1 end
                    print(string.format("  getme %-14s %d/%d  in_chest=%d  jobs_out=%d",
                        ore_name, order.got, order.target, in_chest, pending))
                end
            end

        elseif cmd == "cancelorder" then
            local ore_name = parts[2]
            if ore_name and active_orders[ore_name] then
                active_orders[ore_name] = nil
                print("[ORDER]  Cancelled getme " .. ore_name)
            elseif ore_name then
                print("No active order for: " .. ore_name)
            else
                print("Usage: cancelorder <ore>")
            end

        elseif cmd == "setpark" then
            local x1,y1,z1 = tonumber(parts[2]),tonumber(parts[3]),tonumber(parts[4])
            local x2,y2,z2 = tonumber(parts[5]),tonumber(parts[6]),tonumber(parts[7])
            if x1 and y1 and z1 and x2 and y2 and z2 then
                PARK_ZONE = {x1=x1,y1=y1,z1=z1, x2=x2,y2=y2,z2=z2}
                clearAllParkClaims()
                saveConfig(); broadcastConfig()
                local cols = math.abs(x2-x1)+1
                local rows = math.abs(z2-z1)+1
                print(string.format("[CFG]    Park zone set: (%d,%d,%d)->(%d,%d,%d)  %d slots (%dx%d).",
                    x1,y1,z1, x2,y2,z2, cols*rows, cols, rows))
                -- Re-send each turtle its park slot
                local slot = 0
                for hwid, f in pairs(fleet) do
                    f.park_slot = slot
                    local park_pos = getParkSlot(slot)
                    rednet.send(f.net_id, {
                        type="CONFIG", dump=DUMP_CHEST,
                        base=BASE_CHEST, want=WANT_LIST, park=park_pos,
                    }, PROTOCOL)
                    print(string.format("  -> %s park slot (%d,%d,%d)",
                        hwid, park_pos.x, park_pos.y, park_pos.z))
                    slot = slot + 1
                end
            else
                print("Usage: setpark x1 y1 z1 x2 y2 z2")
                print("  Mark two opposite corners of the parking rectangle.")
                print("  e.g. setpark 130 0 -320  145 0 -320")
            end

        -- !! HELP IS INLINE HERE ON PURPOSE so it cannot be accidentally
        -- !! lost when adding new commands. Do not move it to a function.
        elseif cmd == "help" then
            print("Commands:")
            print("  start | stop | recall      deploy / halt / call home")
            print("  status                     fleet + supplies")
            print("  setdump x y z              set loot dump chest")
            print("  setbase x y z              set emergency coal chest")
            print("  setpark x1 y1 z1 x2 y2 z2 define parking rectangle")
            print("  coords                     show chest + park coords")
            print("  want <ore>                 add to auto-fetch list")
            print("  unwant <ore>               remove from auto-fetch list")
            print("  wants                      show auto-fetch list")
            print("  getme <ore> <count>        e.g. getme diamond 128")
            print("  orders                     show active getme orders")
            print("  cancelorder <ore>          cancel a getme order")
            print("  zones                      show tunnel lane assignments")
            print("  newrun <hwid>              give parked turtle a fresh lane")
            print("  map                        voxel map stats")
            print("  savemap                    force-save map to disk")
            print("  clearmap                   wipe the voxel map")
            print("  feed                       last 8 ore finds")
            print("  help                       this list")

        elseif cmd and cmd ~= "" then
            print("Unknown command: " .. cmd)
            print("Type  help  for the full list.")
        end
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
loadConfig()
loadMap()   -- Phase 5A: restore voxel map from previous sessions

print("+------------------------------------------+")
print("|   O-NET V1  --  OVERSEER  (Phase 1-5)    |")
print("+------------------------------------------+")
print("  Computer ID : " .. os.getComputerID())
print("  Dump chest  : (" .. DUMP_CHEST.x .. ", " .. DUMP_CHEST.y .. ", " .. DUMP_CHEST.z .. ")")
print("  Base chest  : (" .. BASE_CHEST.x .. ", " .. BASE_CHEST.y .. ", " .. BASE_CHEST.z .. ")")
print("  Monitor     : " .. (mon and "linked" or "NONE (map disabled)"))
print("  Warehouse   : " .. (vault and "linked" or "no chest found"))
print("  Map voxels  : " .. total_voxels .. " (from disk)")
print("")
print("  Type  help  for the command list.")
print("  Waiting for miners to enlist...")
print("")

parallel.waitForAll(listenerThread, prunerThread, displayThread, terminalThread, mapSaveThread, orderThread)
