--[[
    M-NET V2 | MAIN MAPPER NODE  --  Full Revision
    ===============================================
    Hardware  :  Advanced Computer
                 Wireless Modem       -> Back  side
                 Advanced Monitor     -> Top   side   (array supported)

    Protocol  :  MNET_V2

    Packet types handled:
        AUTH_REQ   -> register drone, reply AUTH_ACK
        HEARTBEAT  -> refresh last_pulse timestamp
        GEO_DATA   -> ingest voxels into master_voxels, refresh pulse

    Display (Top monitor):
        Zone A  (top ZONE_A_ROWS)  -- title bar, stats, live drone roster
        Zone B  (remaining rows)   -- top-down raycasted voxel map
                                      with depth-fading colour palette,
                                      blip overlays, base origin marker

    Threads:  parallel.waitForAll(listenerThread, prunerThread, displayThread)
]]

-- ============================================================
-- CONFIGURATION
-- ============================================================
local PROTOCOL       = "MNET_V2"
local HB_TIMEOUT_MS  = 10000   -- ms before a node is declared MIA
local PRUNE_INTERVAL = 2       -- seconds between prune sweeps
local DISP_REFRESH   = 0.5     -- seconds between display redraws
local VIEW_Y         = 50      -- Y-layer used as the raycast origin
local MAP_RADIUS     = 20      -- max block radius around the view centre
local RAYCAST_DEPTH  = 3       -- layers to search below VIEW_Y  (0, 1, 2)
local ZONE_A_ROWS    = 9       -- monitor rows reserved for Zone A

-- ============================================================
-- PERIPHERAL SETUP
-- ============================================================
local mon = peripheral.wrap("top")
if not mon then
    error("[FATAL] No monitor found on Top side.  Attach one and reboot.", 0)
end

if not peripheral.wrap("back") then
    error("[FATAL] No modem found on Back side.  Attach one and reboot.", 0)
end

rednet.open("back")
mon.setTextScale(0.5)
mon.setBackgroundColor(colors.black)
mon.clear()
mon.setCursorBlink(false)

-- ============================================================
-- GLOBAL STATE
-- ============================================================
-- active_scouts[hwid] = { net_id, last_pulse, fuel, pos, facing, status }
local active_scouts = {}

-- master_voxels[y][x][z] = blockName  (absolute world coordinates)
local master_voxels = {}
local total_voxels  = 0      -- running count, incremented in setVoxel

-- XZ centre of the map viewport (auto-tracks swarm centroid)
local view_cx = 0
local view_cz = 0

-- ============================================================
-- BLIT HELPER
-- maps colors.X constant -> single hex char required by mon.blit()
-- ============================================================
local C2B = {
    [colors.white]     = "0",
    [colors.orange]    = "1",
    [colors.magenta]   = "2",
    [colors.lightBlue] = "3",
    [colors.yellow]    = "4",
    [colors.lime]      = "5",
    [colors.pink]      = "6",
    [colors.gray]      = "7",
    [colors.lightGray] = "8",
    [colors.cyan]      = "9",
    [colors.purple]    = "a",
    [colors.blue]      = "b",
    [colors.brown]     = "c",
    [colors.green]     = "d",
    [colors.red]       = "e",
    [colors.black]     = "f",
}
local function c2b(col) return C2B[col] or "f" end

-- ============================================================
-- DEPTH-FADING PALETTE
--   FADE[base_color] = { depth_1_color, depth_2_color }
-- ============================================================
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
    local entry = FADE[base]
    if not entry then
        return depth == 1 and colors.lightGray or colors.black
    end
    return entry[depth] or colors.black
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
-- BLOCK CLASSIFICATION & RENDERING
-- ============================================================
local AIR_NAMES = {
    ["minecraft:air"]      = true,
    ["air"]                = true,
    ["minecraft:cave_air"] = true,
    ["minecraft:void_air"] = true,
    [""]                   = true,
}

local function isAir(name)
    return name == nil or AIR_NAMES[name] == true
end

local function isOre(name)
    return name ~= nil and name:find("_ore", 1, true) ~= nil
end

-- Wall glyph changes with depth: "#" -> "+" -> "-"
local WALL_GLYPH = { [0] = "#", [1] = "+", [2] = "-" }

-- Extract the display character for an ore block.
-- depth 0,1: uppercase first letter of ore type
-- depth 2:   lowercase  (simulates distance / darkness)
local function oreGlyph(name, depth)
    -- "minecraft:diamond_ore"           -> ore type "diamond"
    -- "minecraft:deepslate_diamond_ore" -> "deepslate_diamond" -> "diamond"
    -- "minecraft:nether_quartz_ore"     -> "nether_quartz"     -> "quartz"
    local ore = name:match(":(.-)_ore") or name:match("(.-)_ore") or "x"
    ore = ore:match("deepslate_(.+)") or ore:match("nether_(.+)") or ore
    local ch = ore:sub(1, 1)
    return depth < 2 and ch:upper() or ch:lower()
end

-- Returns (char, fg_color) for a block at a given raycast depth
local function renderCell(name, depth)
    depth = math.min(depth, 2)
    if isAir(name) then return " ", colors.black end
    if isOre(name) then
        return oreGlyph(name, depth), fadeColor(colors.cyan, depth)
    end
    return WALL_GLYPH[depth] or "-", fadeColor(colors.yellow, depth)
end

-- ============================================================
-- UTILITY
-- ============================================================
local function scoutCount()
    local n = 0
    for _ in pairs(active_scouts) do n = n + 1 end
    return n
end

-- Update the map viewport centre to the centroid of all active scouts.
-- Falls back to (0, 0) if no scouts are connected.
local function updateViewCenter()
    local n, sx, sz = 0, 0, 0
    for _, d in pairs(active_scouts) do
        if d.pos then
            sx = sx + math.floor(d.pos.x or 0)
            sz = sz + math.floor(d.pos.z or 0)
            n  = n + 1
        end
    end
    if n > 0 then
        view_cx = math.floor(sx / n)
        view_cz = math.floor(sz / n)
    end
end

-- Pad or truncate string to exactly `len` characters
local function pad(s, len)
    s = tostring(s)
    if #s >= len then return s:sub(1, len) end
    return s .. string.rep(" ", len - #s)
end

-- ============================================================
-- DISPLAY -- ZONE A  (Header + Live Drone Roster)
-- ============================================================
local function renderZoneA(w)
    -- Write a full-width monitor row with uniform fg/bg colour
    local function blitRow(r, text, fg, bg)
        mon.setCursorPos(1, r)
        local t = pad(text, w)
        mon.blit(t, string.rep(c2b(fg), w), string.rep(c2b(bg), w))
    end

    -- Row 1 -- Title bar
    blitRow(1,
        string.format(" M-NET V2 | MAIN MAPPER | ID:%-4d | %s",
            os.getComputerID(), os.date("%H:%M:%S")),
        colors.white, colors.blue)

    -- Row 2 -- System statistics
    blitRow(2,
        string.format(" Scouts:%-3d  Voxels:%-10d  MapCentre:(%d, %d)",
            scoutCount(), total_voxels, view_cx, view_cz),
        colors.yellow, colors.black)

    -- Row 3 -- Column headers
    blitRow(3,
        string.format(" %-8s %-5s %-7s %-7s %-7s %-8s",
            "HWID", "FUEL", "X", "Y", "Z", "STATUS"),
        colors.gray, colors.black)

    -- Rows 4 to (ZONE_A_ROWS - 1) -- Live drone entries
    local row = 4
    for hwid, d in pairs(active_scouts) do
        if row >= ZONE_A_ROWS then break end
        local p = d.pos or {}
        blitRow(row,
            string.format(" %-8s %-5s %-7s %-7s %-7s %-8s",
                pad(hwid, 8),
                pad(tostring(d.fuel or "?"), 5),
                pad(tostring(math.floor(p.x or 0)), 7),
                pad(tostring(math.floor(p.y or 0)), 7),
                pad(tostring(math.floor(p.z or 0)), 7),
                pad(d.status or "ACTIVE", 8)),
            colors.lime, colors.black)
        row = row + 1
    end

    -- Clear unused drone rows
    for r = row, ZONE_A_ROWS - 1 do
        blitRow(r, "", colors.black, colors.black)
    end

    -- Row ZONE_A_ROWS -- zone separator
    blitRow(ZONE_A_ROWS, string.rep("=", w), colors.gray, colors.black)
end

-- ============================================================
-- DISPLAY -- ZONE B  (Raycasted Top-Down Voxel Map)
--
-- For each screen cell (col, row) in Zone B:
--   1. Compute (world_x, world_z) from the screen offset relative
--      to the viewport centre.
--   2. Raycast downward from VIEW_Y up to RAYCAST_DEPTH layers.
--   3. Apply the depth-fading palette to the first solid block found.
--   4. Overlay base-station origin (X) and scout blips (@).
--   5. Write each row as a single mon.blit() call for efficiency.
-- ============================================================
local function renderZoneB(w, h)
    local map_top = ZONE_A_ROWS + 1
    if map_top > h then return end   -- no room for Zone B

    local centre_row = map_top + math.floor((h - map_top) / 2)
    local centre_col = math.floor(w / 2) + 1

    -- Pulsing blip: on for the first 500 ms of each second
    local blink_on = (os.epoch("utc") % 1000) < 500

    -- Build integer-keyed lookup of active scout XZ positions.
    -- Prime multiplier (1000003) > MAP_RADIUS*2+1 guarantees no
    -- aliasing between any two cells within the rendered view.
    local scout_keys = {}
    for _, d in pairs(active_scouts) do
        if d.pos then
            scout_keys[math.floor(d.pos.x or 0) * 1000003
                     + math.floor(d.pos.z or 0)] = true
        end
    end

    local BLK        = c2b(colors.black)
    local origin_key = 0 * 1000003 + 0   -- world (0, 0)

    for screen_row = map_top, h do
        local rz      = screen_row - centre_row
        local world_z = view_cz + rz

        -- Per-row blit buffers (indices 1..w)
        local t_buf = {}
        local f_buf = {}

        for screen_col = 1, w do
            local rx      = screen_col - centre_col
            local world_x = view_cx + rx
            local in_view = math.abs(rx) <= MAP_RADIUS
                         and math.abs(rz) <= MAP_RADIUS

            local ch = " "
            local fg = BLK
            local ck = world_x * 1000003 + world_z

            -- Priority 1: base-station origin marker
            if ck == origin_key then
                ch = "X"
                fg = c2b(colors.green)

            -- Priority 2: active scout blip (pulsing magenta @)
            elseif scout_keys[ck] then
                if blink_on then
                    ch = "@"
                    fg = c2b(colors.magenta)
                else
                    -- Off-phase: render the terrain beneath the blip
                    if in_view then
                        for depth = 0, RAYCAST_DEPTH - 1 do
                            local vname = getVoxel(world_x, VIEW_Y - depth, world_z)
                            if not isAir(vname) then
                                local bc, bfg = renderCell(vname, depth)
                                ch = bc
                                fg = c2b(bfg)
                                break
                            end
                        end
                    end
                end

            -- Priority 3: terrain raycast (within MAP_RADIUS only)
            elseif in_view then
                for depth = 0, RAYCAST_DEPTH - 1 do
                    local vname = getVoxel(world_x, VIEW_Y - depth, world_z)
                    if not isAir(vname) then
                        local tc, tfg = renderCell(vname, depth)
                        ch = tc
                        fg = c2b(tfg)
                        break
                    end
                end
            end

            t_buf[screen_col] = ch
            f_buf[screen_col] = fg
        end

        -- Write the full row in a single blit call (no per-cell overhead)
        mon.setCursorPos(1, screen_row)
        mon.blit(
            table.concat(t_buf),
            table.concat(f_buf),
            string.rep(BLK, w)     -- background is uniformly black
        )
    end
end

-- Master render function called by displayThread each cycle
local function renderDisplay()
    local w, h = mon.getSize()
    renderZoneA(w)
    renderZoneB(w, h)
end

-- ============================================================
-- NETWORK HANDLERS
-- ============================================================
local function handleAuthReq(net_id, msg)
    local hwid = msg.hwid
    if type(hwid) ~= "string" or hwid == "" then return end

    local is_new = not active_scouts[hwid]
    active_scouts[hwid] = {
        net_id     = net_id,
        last_pulse = os.epoch("utc"),
        fuel       = msg.fuel   or 0,
        pos        = msg.pos    or { x = 0, y = VIEW_Y, z = 0 },
        facing     = msg.facing or 0,
        status     = "ACTIVE",
    }

    rednet.send(net_id, {
        type      = "AUTH_ACK",
        hwid      = hwid,
        server_id = os.getComputerID(),
    }, PROTOCOL)

    print(string.format("[%s]  %-10s  NetID: %d",
        is_new and "NEW NODE" or "RE-AUTH ", hwid, net_id))
end

local function handleHeartbeat(net_id, msg)
    local hwid = msg.hwid
    if type(hwid) ~= "string" then return end

    local s = active_scouts[hwid]
    if s then
        s.last_pulse = os.epoch("utc")
        if msg.status then s.status = msg.status end
        if msg.fuel   then s.fuel   = msg.fuel   end
    else
        -- Unknown node -- demand re-authentication before accepting data
        rednet.send(net_id, { type = "REAUTH_REQ", hwid = hwid }, PROTOCOL)
    end
end

local function handleGeoData(net_id, msg)
    local hwid = msg.hwid
    if type(hwid) ~= "string" then return end

    local s = active_scouts[hwid]
    if not s then
        -- Unauthenticated sender -- reject and force handshake
        rednet.send(net_id, { type = "REAUTH_REQ", hwid = hwid }, PROTOCOL)
        return
    end

    -- Refresh heartbeat and telemetry fields
    s.last_pulse = os.epoch("utc")
    if msg.pos    then s.pos    = msg.pos    end
    if msg.facing then s.facing = msg.facing end
    if msg.fuel   then s.fuel   = msg.fuel   end

    -- Ingest relative scan data into the absolute voxel store.
    -- Drone sends: scan_data = { {x, y, z, name}, ... }
    -- where x/y/z are offsets relative to the drone's reported pos.
    local scan = msg.scan_data
    local pos  = msg.pos
    if type(scan) == "table" and type(pos) == "table" then
        local ox = pos.x or 0
        local oy = pos.y or 0
        local oz = pos.z or 0
        for _, b in ipairs(scan) do
            if type(b) == "table"
            and type(b.name) == "string"
            and not isAir(b.name)
            then
                setVoxel(
                    math.floor(ox + (b.x or 0)),
                    math.floor(oy + (b.y or 0)),
                    math.floor(oz + (b.z or 0)),
                    b.name
                )
            end
        end
    end
end

-- ============================================================
-- THREAD 1 -- NETWORK LISTENER
-- ============================================================
local function listenerThread()
    while true do
        local net_id, msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            local t = msg.type
            if     t == "AUTH_REQ"  then handleAuthReq(net_id, msg)
            elseif t == "HEARTBEAT" then handleHeartbeat(net_id, msg)
            elseif t == "GEO_DATA"  then handleGeoData(net_id, msg)
            end
        end
    end
end

-- ============================================================
-- THREAD 2 -- HEARTBEAT PRUNER
-- ============================================================
local function prunerThread()
    while true do
        os.sleep(PRUNE_INTERVAL)

        local now  = os.epoch("utc")
        local dead = {}

        for hwid, d in pairs(active_scouts) do
            if (now - d.last_pulse) > HB_TIMEOUT_MS then
                table.insert(dead, hwid)
            end
        end

        for _, hwid in ipairs(dead) do
            local p = active_scouts[hwid].pos or {}
            print(string.format(
                "[LOST SIGNAL]  %-10s  last pos: (%s, %s, %s)",
                hwid,
                tostring(math.floor(p.x or 0)),
                tostring(math.floor(p.y or 0)),
                tostring(math.floor(p.z or 0))
            ))
            active_scouts[hwid] = nil
        end
    end
end

-- ============================================================
-- THREAD 3 -- DISPLAY
-- ============================================================
local function displayThread()
    while true do
        updateViewCenter()
        renderDisplay()
        os.sleep(DISP_REFRESH)
    end
end

-- ============================================================
-- ENTRY POINT
-- ============================================================
print("+------------------------------------------+")
print("|   M-NET V2  --  MAIN MAPPER NODE (FULL)  |")
print("+------------------------------------------+")
print(string.format("|  Computer ID : %-26d |", os.getComputerID()))
print(string.format("|  Protocol    : %-26s |", PROTOCOL))
print(string.format("|  HB Timeout  : %-25ds |", HB_TIMEOUT_MS / 1000))
print(string.format("|  View Y      : %-26d |", VIEW_Y))
print(string.format("|  Map Radius  : +/- %-22d |", MAP_RADIUS))
print("+------------------------------------------+")
print("")
print("[MAPPER]  All systems online.  Waiting for nodes...")
print("")

parallel.waitForAll(listenerThread, prunerThread, displayThread)

print("")
print("[MAPPER]  Shutdown complete.")
