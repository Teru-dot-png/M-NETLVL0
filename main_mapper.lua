--[[
    M-NET V3 | OVERSEER  (fleet commander + warehouse + live map)
    =============================================================
    Role : Hands out tunnel directions, tracks the fleet, fetches wanted
           ores, sweeps an adjacent supply chest, and renders a live monitor
           with an online-robot roster and a top-down scanned voxel map.

    HARDWARE:
        Ender Modem      : any side (comms with the fleet)
        Advanced Monitor : any side or array (the live display)
        Supply chest     : adjacent (optional, for the supply readout)

    SCREENS:
        The MONITOR shows the roster + map and refreshes on its own.
        The COMPUTER terminal is where you type commands and read the log.

    SETUP:
        Type  setdump x y z  and  setbase x y z  to point the turtles at your
        chests (look at each, press F3, read "Targeted Block"). These save to
        disk and push live to the fleet. Type  help  for everything else.
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

local DIRECTIONS   = { 0, 1, 2, 3 }   -- N, E, S, W assigned round-robin
local HB_TIMEOUT   = 12000            -- ms before a miner is declared lost
local DISP_REFRESH = 0.5              -- seconds between monitor redraws

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

local view_cx, view_cz, view_y = 0, 0, 64   -- map centre, auto-tracked

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
    if status == "MINING"  then return colors.lime end
    if status == "STANDBY" then return colors.yellow end
    if status == "GOTO"    then return colors.cyan end
    if status == "DUMP"    then return colors.orange end
    if status == "RECALL"  then return colors.magenta end
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
    for _, f in pairs(fleet) do if tostring(f.status):upper() == "MINING" then mining = mining + 1 end end
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

-- ── PANEL: LEGEND + ALERT TICKER (bottom 2 rows) ──────────────────────

local function renderFooter(h, w)
    local BLK = c2b(colors.black)

    -- Legend row
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
    -- pad to width
    while #leg_t < w do leg_t[#leg_t+1]=" " leg_f[#leg_f+1]=BLK leg_b[#leg_b+1]=BLK end

    mon.setCursorPos(1, h - 1)
    mon.blit(table.concat(leg_t, "", 1, w),
             table.concat(leg_f, "", 1, w),
             table.concat(leg_b, "", 1, w))

    -- Alert ticker: cycle through recent alerts
    local tick_idx = math.floor(os.epoch("utc") / 3000) % math.max(1, #alert_log) + 1
    local alert_msg = alert_log[tick_idx] or "  All systems nominal."
    solidRow(h, pad(" " .. alert_msg, w), colors.red, colors.black, w)
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
    local dir = existing and existing.dir or nextDirection()
    fleet[msg.hwid] = {
        net_id = net_id, last_pulse = os.epoch("utc"),
        pos = msg.pos or { x = 0, y = 0, z = 0 },
        status = "STANDBY", dir = dir, fuel = "?", free = "?",
    }
    rednet.send(net_id, {
        type = "AUTH_ACK", hwid = msg.hwid, direction = dir,
        dump = DUMP_CHEST, base = BASE_CHEST,
    }, PROTOCOL)
    print(string.format("[ENLIST] %s  ->  direction %d", msg.hwid, dir))
end

local function handleHeartbeat(msg)
    local f = fleet[msg.hwid]; if not f then return end
    f.last_pulse = os.epoch("utc")
    if msg.status then f.status = msg.status end
    if msg.fuel   then f.fuel   = msg.fuel   end
    if msg.pos    then f.pos    = msg.pos    end
    if msg.free   then f.free   = msg.free   end
end

local function handleOreReport(msg)
    if type(msg.ore) ~= "string" or type(msg.pos) ~= "table" then return end
    ore_log[msg.ore] = (ore_log[msg.ore] or 0) + 1
    if WANT_LIST[msg.ore] then
        local k = msg.pos.x .. ":" .. msg.pos.y .. ":" .. msg.pos.z
        if not dispatched[k] then
            dispatched[k] = true
            local f = fleet[msg.hwid]
            if f then
                rednet.send(f.net_id, { type = "GOTO", hwid = msg.hwid, ore = msg.ore, pos = msg.pos }, PROTOCOL)
                print(string.format("[ORDER]  %s -> GOTO %s (%d,%d,%d)",
                    msg.hwid, msg.ore, msg.pos.x, msg.pos.y, msg.pos.z))
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
    print("  map                     show map stats")
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
        elseif cmd == "map" then
            print(string.format("  Voxels stored : %d", total_voxels))
            print(string.format("  View centre   : (%d,%d)  layer Y=%d", view_cx, view_cz, view_y))
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
loadConfig()

print("+------------------------------------------+")
print("|   M-NET V3  --  OVERSEER (FLEET COMMAND)  |")
print("+------------------------------------------+")
print("  Computer ID : " .. os.getComputerID())
print("  Dump chest  : (" .. DUMP_CHEST.x .. ", " .. DUMP_CHEST.y .. ", " .. DUMP_CHEST.z .. ")")
print("  Base chest  : (" .. BASE_CHEST.x .. ", " .. BASE_CHEST.y .. ", " .. BASE_CHEST.z .. ")")
print("  Monitor     : " .. (mon and "linked" or "NONE (map disabled)"))
print("  Warehouse   : " .. (vault and "linked" or "no chest found"))
print("")
print("  Type  help  for the command list.")
print("  Waiting for miners to enlist...")
print("")

parallel.waitForAll(listenerThread, prunerThread, displayThread, terminalThread)
