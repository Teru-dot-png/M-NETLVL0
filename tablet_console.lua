--[[
    O-NET V1 | TABLET CONSOLE
    -------------------------------------------------------
    Pocket/tablet companion UI for fleet command.

    NOTE: Pocket computers accept only one peripheral upgrade.
    The wireless modem is mandatory, so geo scanner upload is
    not supported on the tablet. Use a miner turtle to scan.

    Features:
      - Self-adapting terminal UI (resizes with tablet screen)
      - Live fleet list with numeric selection (1..9, 0=10)
      - Commands to overseer:
          START / STOP / RECALL
          COME_TO_ME / GOTO / GETME / TUNNEL_FROM

    Controls:
      1..9 / 0  select robot index
      c         selected bot come to you (GPS required)
      g         selected bot goto x y z
      t         selected bot tunnel-from x y z dir(n/e/s/w)
      m         getme <ore> <count>
      a         start all
      o         stop all
      r         recall all
      s         force sync now
      q         quit
]]

local PROTOCOL = "ONET_V1"
local TABLET_ID = string.format("TB-%04X", os.getComputerID() % 0xFFFF)

local server_id = nil
local fleet = {}
local selected_index = 1
local last_sync_ms = 0
local last_msg = ""

local function nowMs()
    return os.epoch("utc")
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function splitWords(s)
    local t = {}
    for w in tostring(s or ""):gmatch("%S+") do
        t[#t + 1] = w
    end
    return t
end

local function parseCoords(parts, i)
    local x = tonumber(parts[i])
    local y = tonumber(parts[i + 1])
    local z = tonumber(parts[i + 2])
    if x and y and z then
        return {
            x = math.floor(x),
            y = math.floor(y),
            z = math.floor(z),
        }
    end
    return nil
end

local function parseDirToken(tok)
    local t = tostring(tok or ""):lower()
    if t == "0" or t == "n" or t == "north" then return 0 end
    if t == "1" or t == "e" or t == "east"  then return 1 end
    if t == "2" or t == "s" or t == "south" then return 2 end
    if t == "3" or t == "w" or t == "west"  then return 3 end
    return nil
end

local modem = peripheral.find("modem")
if not modem then
    error("No modem found. Attach wireless/ender modem.", 0)
end
rednet.open(peripheral.getName(modem))

local function getGpsPos(timeout)
    if not gps or type(gps.locate) ~= "function" then return nil end
    local x, y, z = gps.locate(timeout or 2)
    if x then
        return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
    end
    return nil
end

local function sendToOverseer(msg)
    if server_id then
        rednet.send(server_id, msg, PROTOCOL)
    else
        rednet.broadcast(msg, PROTOCOL)
    end
end

local function requestSync()
    sendToOverseer({
        type = "TABLET_SYNC_REQ",
        tablet = TABLET_ID,
        pos = getGpsPos(1),
    })
end

local function sendTabletCmd(action, payload)
    local msg = payload or {}
    msg.type = "TABLET_CMD"
    msg.from = TABLET_ID
    msg.action = action
    sendToOverseer(msg)
end

local function clampSelection()
    if #fleet <= 0 then
        selected_index = 1
        return
    end
    if selected_index < 1 then selected_index = 1 end
    if selected_index > #fleet then selected_index = #fleet end
end

local function selectedBot()
    clampSelection()
    return fleet[selected_index]
end

local function short(s, n)
    local text = tostring(s or "")
    if #text <= n then return text end
    if n <= 3 then return text:sub(1, n) end
    return text:sub(1, n - 3) .. "..."
end

local function prompt(label)
    local w, h = term.getSize()
    term.setCursorPos(1, h)
    term.clearLine()
    write(label)
    local line = read()
    term.setCursorPos(1, h)
    term.clearLine()
    return trim(line)
end

local function setMessage(s)
    last_msg = tostring(s or "")
end

local function drawUI()
    local w, h = term.getSize()
    term.setCursorPos(1, 1)
    term.clear()

    local conn = server_id and ("linked:" .. tostring(server_id)) or "searching"
    local age = (last_sync_ms > 0) and math.floor((nowMs() - last_sync_ms) / 1000) or -1

    print(short("O-NET Tablet " .. TABLET_ID .. "  " .. conn, w))
    print(short("Fleet:" .. #fleet .. "  Sync:" .. (age >= 0 and (age .. "s") or "-"), w))

    local sel = selectedBot()
    if sel then
        print(short(string.format("Selected %d: %s  %s", selected_index, sel.hwid or "?", sel.status or "?"), w))
    else
        print(short("Selected: none", w))
    end

    print(short("1..9/0 select | c come | g goto | t tunnel | m getme", w))
    print(short("a start | o stop | r recall | s sync | q quit", w))

    local header = "#  HWID       ST        AV   FUEL  POS"
    print(short(header, w))

    local rows_for_fleet = h - 8
    if rows_for_fleet < 1 then rows_for_fleet = 1 end

    local start_i = 1
    if selected_index > rows_for_fleet then
        start_i = selected_index - rows_for_fleet + 1
    end

    for row = 0, rows_for_fleet - 1 do
        local i = start_i + row
        local b = fleet[i]
        if not b then
            print("")
        else
            local mark = (i == selected_index) and ">" or " "
            local av = b.available and "Y" or "N"
            local p = b.pos or {}
            local line = string.format("%s%2d %-10s %-8s  %s  %-5s (%d,%d,%d)",
                mark, i,
                tostring(b.hwid or "?"),
                short(tostring(b.status or "?"), 8),
                av,
                short(tostring(b.fuel or "?"), 5),
                tonumber(p.x) or 0,
                tonumber(p.y) or 0,
                tonumber(p.z) or 0)
            print(short(line, w))
        end
    end

    term.setCursorPos(1, h)
    term.clearLine()
    write(short(last_msg, w))
end

local function handleTabletAck(msg)
    if msg.ok then
        setMessage("ACK " .. tostring(msg.action or "") .. (msg.hwid and (" -> " .. tostring(msg.hwid)) or ""))
    else
        setMessage("NACK " .. tostring(msg.action or "") .. ": " .. tostring(msg.err or "?"))
    end
end

local function receiverThread()
    while true do
        local sender, msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            if msg.type == "TABLET_SYNC" then
                server_id = sender
                if type(msg.fleet) == "table" then
                    fleet = msg.fleet
                else
                    fleet = {}
                end
                last_sync_ms = nowMs()
                clampSelection()
            elseif msg.type == "TABLET_ACK" then
                if sender == server_id or not server_id then
                    server_id = sender
                    handleTabletAck(msg)
                end
            end
            os.queueEvent("tablet_refresh")
        end
    end
end

local function syncThread()
    while true do
        requestSync()
        sleep(1.5)
    end
end

local function requireSelectedBot()
    local b = selectedBot()
    if not b then
        setMessage("No bot selected.")
        return nil
    end
    if not b.available then
        setMessage("Selected bot is not available right now.")
        return nil
    end
    return b
end

local function uiThread()
    requestSync()
    setMessage("Waiting for overseer sync...")
    drawUI()

    while true do
        local ev, p1 = os.pullEvent()

        if ev == "char" then
            local ch = tostring(p1)

            if ch:match("%d") then
                if ch == "0" then
                    selected_index = 10
                else
                    selected_index = tonumber(ch) or selected_index
                end
                clampSelection()
                local b = selectedBot()
                if b then
                    setMessage("Selected " .. tostring(b.hwid))
                end

            elseif ch == "c" then
                local b = requireSelectedBot()
                if b then
                    local me = getGpsPos(2)
                    if me then
                        sendTabletCmd("COME_TO_ME", { hwid = b.hwid, pos = me })
                        setMessage(string.format("COME_TO_ME -> %s (%d,%d,%d)", b.hwid, me.x, me.y, me.z))
                    else
                        setMessage("GPS lock required for COME_TO_ME.")
                    end
                end

            elseif ch == "g" then
                local b = requireSelectedBot()
                if b then
                    local line = prompt("goto x y z: ")
                    local parts = splitWords(line)
                    local pos = parseCoords(parts, 1)
                    if pos then
                        sendTabletCmd("GOTO", { hwid = b.hwid, pos = pos })
                        setMessage(string.format("GOTO -> %s (%d,%d,%d)", b.hwid, pos.x, pos.y, pos.z))
                    else
                        setMessage("Invalid coords. Use: x y z")
                    end
                end

            elseif ch == "t" then
                local b = requireSelectedBot()
                if b then
                    local line = prompt("tunnel-from x y z dir(n/e/s/w): ")
                    local parts = splitWords(line)
                    local pos = parseCoords(parts, 1)
                    local dir = parseDirToken(parts[4])
                    if pos and dir ~= nil then
                        sendTabletCmd("TUNNEL_FROM", { hwid = b.hwid, pos = pos, dir = dir })
                        setMessage(string.format("TUNNEL_FROM -> %s (%d,%d,%d) dir=%d", b.hwid, pos.x, pos.y, pos.z, dir))
                    else
                        setMessage("Invalid payload. Use: x y z dir")
                    end
                end

            elseif ch == "m" then
                local line = prompt("getme ore count: ")
                local parts = splitWords(line)
                local ore = parts[1]
                local count = tonumber(parts[2])
                if ore and count and count > 0 then
                    sendTabletCmd("GETME", { ore = ore, count = count })
                    setMessage(string.format("GETME %s x%d", ore, count))
                else
                    setMessage("Invalid getme. Use: ore count")
                end

            elseif ch == "a" then
                sendTabletCmd("START", {})
                setMessage("START broadcast.")

            elseif ch == "o" then
                sendTabletCmd("STOP", {})
                setMessage("STOP broadcast.")

            elseif ch == "r" then
                sendTabletCmd("RECALL", {})
                setMessage("RECALL broadcast.")

            elseif ch == "s" then
                requestSync()
                setMessage("Sync requested.")

            elseif ch == "q" then
                term.setCursorPos(1, 1)
                term.clear()
                print("Tablet console stopped.")
                return
            end

            os.queueEvent("tablet_refresh")
        elseif ev == "term_resize" or ev == "tablet_refresh" then
            -- redraw only
        end

        drawUI()
    end
end

parallel.waitForAny(receiverThread, syncThread, uiThread)
