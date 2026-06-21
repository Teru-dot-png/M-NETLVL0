--[[
    M-NET V3 | OVERSEER  (Phase 1-5)
    ==================================
    Role : Fleet commander, warehouse monitor, and live map display.

    Hardware:
        Ender Modem      : any side (found via peripheral.find)
        Advanced Monitor : any side or array (the live cockpit display)
        Supply chest     : adjacent optional (for the warehouse readout)

    Phase 4  Lane assignment: spreads turtles across parallel tunnels
             spaced LANE_SPACING blocks apart. Tracks exhausted zones.
             Commands: zones, newrun <hwid>

    Phase 5  Map persistence: voxel database saved to mnet_map.dat,
             auto-loaded at boot and auto-saved every 60 seconds.
             Ore cluster detection: nearby reports merge into one GOTO
             dispatched to the nearest idle turtle.
             Live ore feed: bottom cockpit row cycles through last 8 finds.
             Commands: savemap, clearmap, feed

    Setup:
        Type  setdump x y z  to set the loot drop chest.
        Type  setbase x y z  to set the emergency coal + pickaxe chest.
        (Look at each chest, press F3, read "Targeted Block".)
        Coords save to disk and push live to the fleet.
        Type  help  for the full command list.
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
local PROTOCOL   = "MNET_V3"
local DUMP_CHEST = { x = 0, y = 64, z = 0 }   -- mined loot is emptied here
local BASE_CHEST = { x = 0, y = 64, z = 2 }   -- emergency coal + spare pickaxes

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
    -- Mark old zone exhausted, give a new lane on the same direction
    local old = zone_log[hwid]
    local dir = old and old.dir or 0
    old.exhausted = true
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

local function broadcastConfig()
    rednet.broadcast({ type = "CONFIG", dump = DUMP_CHEST, base = BASE_CHEST }, PROTOCOL)
end

-- ============================================================
-- STATE
-- ============================================================
-- fleet[hwid] = { net_id, last_pulse, pos, status, dir, fuel, free }
local fleet      = {}
local dir_index  = 0
local ore_log    = {}
local dispatched = {}

-- master_voxels[y][x][z] = blockName ; absolute world coords
local master_voxels = {}
local total_voxels  = 0

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
local map_dirty     = false   -- true when unsaved changes exist
local last_map_save = 0

local function saveMap()
    -- Flatten the 3D table into a list of {x,y,z,name} entries.
    -- textutils.serialize handles nested tables fine but is slow on huge maps;
    -- a flat list is both faster to write and to reload.
    local entries = {}
    for y, xt in pairs(master_voxels) do
        for x, zt in pairs(xt) do
            for z, name in pairs(zt) do
                entries[#entries+1] = {x=x,y=y,z=z,n=name}
            end
        end
    end
    local f = fs.open(MAP_FILE, "w")
    if f then
        f.write(textutils.serialize(entries))
        f.close()
        map_dirty = false
        last_map_save = os.epoch("utc")
    end
end

local function loadMap()
    if not fs.exists(MAP_FILE) then return end
    local f = fs.open(MAP_FILE, "r")
    if not f then return end
    local data = textutils.unserialize(f.readAll() or "")
    f.close()
    if type(data) ~= "table" then return end
    local count = 0
    for _, e in ipairs(data) do
        if type(e)=="table" and e.x and e.y and e.z and e.n then
            if not master_voxels[e.y] then master_voxels[e.y]={} end
            if not master_voxels[e.y][e.x] then master_voxels[e.y][e.x]={} end
            master_voxels[e.y][e.x][e.z] = e.n
            count = count + 1
        end
    end
    total_voxels = count
    print(string.format("[MAP]    Loaded %d voxels from disk.", count))
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
local function isAir(n) return n == nil or AIR_NAMES[n] == true end
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
    freeSlots = tonumber(freeSlots) or 15
    local used = 15 - math.max(0, math.min(15, freeSlots))
    local filled = math.floor(used / 15 * 5 + 0.5)
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
    return ORE_COLOUR[name] or colors.white
end

-- ── PANEL: HEADER (rows 1-3) ───────────────────────────────────────────

local function renderHeader(w)
    local uptime_s = math.floor((os.epoch("utc") - BOOT_TIME) / 1000)
    local uh = math.floor(uptime_s / 3600)
    local um = math.floor((uptime_s % 3600) / 60)
    local us = uptime_s % 60

    -- Row 1: title + clock
    local title = string.format(
        " M-NET V3  OVERSEER  ID:%-3d      %s  UP %02d:%02d:%02d ",
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
                    for d = 0, RAYCAST_DEPTH - 1 do
                        local vn = getVoxel(world_x, view_y - d, world_z)
                        if not isAir(vn) then
                            local bc, bfg = renderCell(vn, d)
                            ch, fg = bc, c2b(bfg)
                            break
                        end
                    end
                end
            elseif in_range then
                for d = 0, RAYCAST_DEPTH - 1 do
                    local vn = getVoxel(world_x, view_y - d, world_z)
                    if not isAir(vn) then
                        local tc, tfg = renderCell(vn, d)
                        ch, fg = tc, c2b(tfg)
                        break
                    end
                end
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
    legItem("#", colors.yellow,  "Stone")
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
    }

    rednet.send(net_id, {
        type        = "AUTH_ACK",
        hwid        = msg.hwid,
        direction   = dir,
        lane_offset = offset,
        dump        = DUMP_CHEST,
        base        = BASE_CHEST,
    }, PROTOCOL)

    print(string.format("[ENLIST] %s  ->  dir=%d lane=+%d", msg.hwid, dir, offset))
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

-- ============================================================
-- PHASE 5B: ORE CLUSTER DETECTION

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
    local x, y, z = math.floor(msg.pos.x or 0), math.floor(msg.pos.y or 0), math.floor(msg.pos.z or 0)

    -- Update running total
    ore_log[ore] = (ore_log[ore] or 0) + 1

    -- Push to live feed
    pushOreFeed(ore, msg.hwid, x, y, z)

    -- Phase 5B: cluster-aware dispatch
    if WANT_LIST[ore] then
        local cl = mergeOrCluster(ore, x, y, z)
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
                        ore  = ore,
                        pos  = { x=cl.cx, y=cl.cy, z=cl.cz },
                    }, PROTOCOL)
                    print(string.format("[ORDER]  %s -> GOTO %s cluster(%d,%d,%d) size=%d",
                        target_hwid, ore, cl.cx, cl.cy, cl.cz, cl.count))
                end
            end
        end
    end
end

local function handleGeoData(msg)
    local f = fleet[msg.hwid]
    if f then f.last_pulse = os.epoch("utc"); if msg.pos then f.pos = msg.pos end end
    local scan, p = msg.scan_data, msg.pos
    if type(scan) == "table" and type(p) == "table" then
        local ox, oy, oz = p.x or 0, p.y or 0, p.z or 0
        for _, b in ipairs(scan) do
            if type(b) == "table" and type(b.name) == "string" and not isAir(b.name) then
                setVoxel(floor(ox + (b.x or 0)), floor(oy + (b.y or 0)), floor(oz + (b.z or 0)), b.name)
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
            elseif msg.type == "ALERT"      then
                local al = tostring(msg.hwid) .. ": " .. tostring(msg.msg)
                print("[ALERT]  " .. al)
                pushAlert(al)
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
                fleet[hwid] = nil
            end
        end
    end
end

local function mapSaveThread()
    while true do
        sleep(60)
        if map_dirty then
            saveMap()
            print(string.format("[MAP]    Auto-saved %d voxels.", total_voxels))
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
local function printHelp()
    print("Commands:")
    print("  start | stop | recall   deploy / halt / call home")
    print("  status                  fleet + supplies")
    print("  setdump x y z           set loot dump chest")
    print("  setbase x y z           set emergency coal chest")
    print("  coords                  show chest coords")
    print("  want <ore> | unwant <ore> | wants")
    print("  zones                   show tunnel zone assignments")
    print("  newrun <hwid>           assign a fresh lane to a parked turtle")
    print("  map                     map stats and file info")
    print("  savemap                 force-save voxel map to disk now")
    print("  clearmap                wipe the voxel map")
    print("  feed                    show live ore feed (last 8 finds)")
    print("  help")
end

local function terminalThread()
    while true do
        local parts = splitWords(read())
        local cmd = parts[1]

        if cmd == "start" then
            rednet.broadcast({ type = "CMD_START" }, PROTOCOL); print("[CMD]    Fleet deployed.")
        elseif cmd == "stop" then
            rednet.broadcast({ type = "CMD_STOP" }, PROTOCOL); print("[CMD]    Halt-in-place sent.")
        elseif cmd == "recall" then
            rednet.broadcast({ type = "CMD_RECALL" }, PROTOCOL); print("[CMD]    Recall sent.")
        elseif cmd == "status" then
            print("---- FLEET ----")
            for hwid, f in pairs(fleet) do
                local p = f.pos or {}
                print(string.format("  %s dir%d %s fuel:%s free:%s (%d,%d,%d)",
                    hwid, f.dir or 0, f.status or "?", tostring(f.fuel), tostring(f.free),
                    p.x or 0, p.y or 0, p.z or 0))
            end
            print("---- SUPPLIES ----")
            for name, count in pairs(checkSupplies()) do print(string.format("  %-18s %d", name, count)) end
        elseif cmd == "setdump" then
            local c = parseCoords(parts[2], parts[3], parts[4])
            if c then DUMP_CHEST = c saveConfig() broadcastConfig()
                print(string.format("[CFG]    Dump chest set to (%d,%d,%d).", c.x, c.y, c.z))
            else print("Usage: setdump x y z") end
        elseif cmd == "setbase" then
            local c = parseCoords(parts[2], parts[3], parts[4])
            if c then BASE_CHEST = c saveConfig() broadcastConfig()
                print(string.format("[CFG]    Base chest set to (%d,%d,%d).", c.x, c.y, c.z))
            else print("Usage: setbase x y z") end
        elseif cmd == "coords" then
            print(string.format("  Dump: (%d,%d,%d)", DUMP_CHEST.x, DUMP_CHEST.y, DUMP_CHEST.z))
            print(string.format("  Base: (%d,%d,%d)", BASE_CHEST.x, BASE_CHEST.y, BASE_CHEST.z))
        elseif cmd == "want" then
            if parts[2] then WANT_LIST[parts[2]] = true saveConfig() print("[CFG]    Now fetching: " .. parts[2])
            else print("Usage: want <ore>") end
        elseif cmd == "unwant" then
            if parts[2] then WANT_LIST[parts[2]] = nil saveConfig() print("[CFG]    No longer fetching: " .. parts[2])
            else print("Usage: unwant <ore>") end
        elseif cmd == "wants" then
            write("  Fetching: ")
            local any = false
            for ore in pairs(WANT_LIST) do write(ore .. " ") any = true end
            print(any and "" or "(nothing)")
        elseif cmd == "zones" then
            print("---- ZONES ----")
            for hwid, z in pairs(zone_log) do
                print(string.format("  %-10s dir=%d lane=+%d %s",
                    hwid, z.dir, z.offset,
                    z.exhausted and "[EXHAUSTED]" or "[ACTIVE]"))
            end

        elseif cmd == "newrun" then
            local target = parts[2]
            if target and fleet[target] then
                local f = fleet[target]
                local dir, offset = reassignLane(target)
                f.dir         = dir
                f.lane_offset = offset
                rednet.send(f.net_id, {
                    type        = "CONFIG",
                    direction   = dir,
                    lane_offset = offset,
                    dump        = DUMP_CHEST,
                    base        = BASE_CHEST,
                }, PROTOCOL)
                print(string.format("[CMD]    %s reassigned -> dir=%d lane=+%d", target, dir, offset))
            elseif target then
                print("Unknown turtle: "..target)
            else
                print("Usage: newrun <hwid>")
            end
            print(string.format("  Voxels stored : %d", total_voxels))
            print(string.format("  View centre   : (%d,%d)  layer Y=%d", view_cx, view_cz, view_y))
        elseif cmd == "map" then
            print(string.format("  Voxels stored : %d", total_voxels))
            print(string.format("  View centre   : (%d,%d)  layer Y=%d", view_cx, view_cz, view_y))
            print(string.format("  Map file      : %s", fs.exists(MAP_FILE) and MAP_FILE or "not saved yet"))
        elseif cmd == "savemap" then
            saveMap()
            print(string.format("[MAP]    Saved %d voxels to disk.", total_voxels))
        elseif cmd == "clearmap" then
            master_voxels = {}; total_voxels = 0; map_dirty = false
            if fs.exists(MAP_FILE) then fs.delete(MAP_FILE) end
            print("[MAP]    Voxel database cleared.")
        elseif cmd == "feed" then
            if #ORE_FEED == 0 then print("  No ore found yet.")
            else
                print("---- ORE FEED ----")
                for i = #ORE_FEED, 1, -1 do
                    local e = ORE_FEED[i]
                    print(string.format("  %s %-8s %-16s (%d,%d,%d)",
                        e.time, e.hwid, e.ore, e.x, e.y, e.z))
                end
            end
            printHelp()
        elseif cmd and cmd ~= "" then
            print("Unknown command: " .. cmd .. "   (type help)")
        end
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
loadConfig()
loadMap()   -- Phase 5A: restore voxel map from previous sessions

print("+------------------------------------------+")
print("|   M-NET V3  --  OVERSEER  (Phase 1-5)    |")
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

parallel.waitForAll(listenerThread, prunerThread, displayThread, terminalThread, mapSaveThread)
