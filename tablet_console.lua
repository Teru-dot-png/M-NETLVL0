--[[
    O-NET V1 | TABLET GLASS COCKPIT
    ---------------------------------------------
    Pocket-first UI for wireless tablet command.

    - One-upgrade pocket mode (wireless modem only)
    - Compact, width-aware rendering for small screens
    - Periodic GPS self-location refresh
    - Fleet selection + command dispatch
]]

local PROTOCOL = "ONET_V1"
local TABLET_ID = string.format("TB-%04X", os.getComputerID() % 0xFFFF)

local SYNC_INTERVAL_SEC = 1.5
local GPS_REFRESH_SEC = 4

local server_id = nil
local fleet = {}
local selected_index = 1
local last_sync_ms = 0
local last_msg = ""

local self_pos = nil
local last_gps_ms = 0
local gps_ok = false

local modem = peripheral.find("modem")
if not modem then
    error("No modem found. Attach wireless/ender modem.", 0)
end
rednet.open(peripheral.getName(modem))

local function nowMs()
    return os.epoch("utc")
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function splitWords(s)
    local t = {}
    for w in tostring(s or ""):gmatch("%S+") do t[#t + 1] = w end
    return t
end

local function parseCoords(parts, i)
    local x = tonumber(parts[i])
    local y = tonumber(parts[i + 1])
    local z = tonumber(parts[i + 2])
    if x and y and z then
        return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
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

local function fit(s, w)
    local text = tostring(s or "")
    if #text > w then return text:sub(1, w) end
    return text .. string.rep(" ", w - #text)
end

local function shortId(hwid, maxLen)
    local s = tostring(hwid or "?")
    if #s <= maxLen then return s end
    return s:sub(1, maxLen)
end

local function setMessage(s)
    last_msg = tostring(s or "")
end

local function getGpsPos(timeout)
    if not gps or type(gps.locate) ~= "function" then return nil end
    local x, y, z = gps.locate(timeout or 2)
    if x then
        return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
    end
    return nil
end

local function refreshSelfGps(timeout)
    local p = getGpsPos(timeout or 1.5)
    if p then
        self_pos = p
        last_gps_ms = nowMs()
        gps_ok = true
    else
        gps_ok = false
    end
    os.queueEvent("tablet_refresh")
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
        pos = self_pos,
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

local function prompt(label)
    local w, h = term.getSize()
    term.setCursorPos(1, h)
    term.clearLine()
    write(fit(label, w))
    local line = read()
    term.setCursorPos(1, h)
    term.clearLine()
    return trim(line)
end

local function promptRequired(label)
    while true do
        local v = prompt(label)
        if v == "" then
            setMessage("Cancelled")
            return nil
        end
        return v
    end
end

local function promptInt(label)
    local v = promptRequired(label)
    if not v then return nil end
    local n = tonumber(v)
    if not n then
        setMessage("Expected number")
        return nil
    end
    return math.floor(n)
end

local function drawBand(y, text, fg, bg, w)
    term.setCursorPos(1, y)
    term.blit(fit(text, w), string.rep(fg, w), string.rep(bg, w))
end

local function statusCode(st)
    local s = tostring(st or "?"):upper()
    if s == "MINING" then return "MIN" end
    if s == "STANDBY" then return "STB" end
    if s == "PARKED" then return "PRK" end
    if s == "RTB_DUMP" then return "RDP" end
    if s == "RTB_FUEL" then return "RFL" end
    if s == "FETCH_PICK" then return "FPK" end
    if s == "GOTO" then return "GTO" end
    return s:sub(1, 3)
end

local function cmdHint(w)
    local phase = math.floor(nowMs() / 2200) % 3
    if phase == 0 then
        return fit("1-9/0 sel | c come | g goto", w)
    elseif phase == 1 then
        return fit("t tunnel | m getme | a/o/r all", w)
    end
    return fit("s sync | l gps | q quit", w)
end

local function drawUI()
    local w, h = term.getSize()
    local cockpitBlue = "b"
    local glassBg = "7"
    local infoBg = "8"
    local textLight = "f"
    local textDark = "0"
    local accent = "3"

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.clear()

    local syncAge = (last_sync_ms > 0) and math.floor((nowMs() - last_sync_ms) / 1000) or -1
    local linkTxt = server_id and ("OVR:" .. tostring(server_id)) or "OVR:--"
    local top = string.format("ONET %s %s S:%s", TABLET_ID, linkTxt, (syncAge >= 0 and (syncAge .. "s") or "-"))
    drawBand(1, top, textLight, cockpitBlue, w)

    local gpsLine
    if gps_ok and self_pos then
        local gAge = math.floor((nowMs() - last_gps_ms) / 1000)
        gpsLine = string.format("GPS FIX %d,%d,%d  %ds", self_pos.x, self_pos.y, self_pos.z, gAge)
    else
        gpsLine = "GPS NO FIX"
    end
    drawBand(2, gpsLine, textDark, accent, w)

    local b = selectedBot()
    local selLine = "SEL: NONE"
    if b then
        local p = b.pos or { x = 0, y = 0, z = 0 }
        local av = b.available and "Y" or "N"
        selLine = string.format("SEL%d %s %s AV%s F%s", selected_index, shortId(b.hwid, 8), statusCode(b.status), av, tostring(b.fuel or "?"))
        if w >= 24 then
            selLine = string.format("SEL%d %s %s AV%s F%s @%d,%d,%d",
                selected_index, shortId(b.hwid, 8), statusCode(b.status), av,
                tostring(b.fuel or "?"), p.x or 0, p.y or 0, p.z or 0)
        end
    end
    drawBand(3, selLine, textLight, infoBg, w)

    drawBand(4, cmdHint(w), textLight, glassBg, w)

    term.setCursorPos(1, 5)
    term.blit(string.rep("-", w), string.rep("8", w), string.rep("0", w))

    local listTop = 6
    local listBottom = h - 1
    if listBottom < listTop then listBottom = listTop end
    local rows = listBottom - listTop + 1

    local start_i = 1
    if selected_index > rows then
        start_i = selected_index - rows + 1
    end

    for r = 0, rows - 1 do
        local y = listTop + r
        local i = start_i + r
        local bot = fleet[i]
        if bot then
            local p = bot.pos or { x = 0, y = 0, z = 0 }
            local mark = (i == selected_index) and ">" or " "
            local av = bot.available and "Y" or "N"
            local line
            if w <= 22 then
                line = string.format("%s%1d %s %s %s", mark, i % 10, shortId(bot.hwid, 6), statusCode(bot.status), av)
            elseif w <= 28 then
                line = string.format("%s%2d %-8s %s %s %d,%d", mark, i, shortId(bot.hwid, 8), statusCode(bot.status), av, p.x or 0, p.z or 0)
            else
                line = string.format("%s%2d %-10s %-3s %s F%-4s @%d,%d,%d",
                    mark, i, shortId(bot.hwid, 10), statusCode(bot.status), av,
                    tostring(bot.fuel or "?"), p.x or 0, p.y or 0, p.z or 0)
            end
            local fg = (i == selected_index) and string.rep("f", w) or string.rep("7", w)
            local bg = (i == selected_index) and string.rep("4", w) or string.rep("0", w)
            term.setCursorPos(1, y)
            term.blit(fit(line, w), fg, bg)
        else
            term.setCursorPos(1, y)
            term.blit(string.rep(" ", w), string.rep("0", w), string.rep("0", w))
        end
    end

    term.setCursorPos(1, h)
    term.blit(fit(last_msg, w), string.rep("f", w), string.rep("8", w))
end

local function handleTabletAck(msg)
    if msg.ok then
        setMessage("ACK " .. tostring(msg.action or "") .. (msg.hwid and ("->" .. tostring(msg.hwid)) or ""))
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
        sleep(SYNC_INTERVAL_SEC)
    end
end

local function gpsThread()
    while true do
        refreshSelfGps(1.5)
        sleep(GPS_REFRESH_SEC)
    end
end

local function requireSelectedBot()
    local b = selectedBot()
    if not b then
        setMessage("No bot selected")
        return nil
    end
    if not b.available then
        setMessage("Selected bot busy")
        return nil
    end
    return b
end

local function uiThread()
    refreshSelfGps(2)
    requestSync()
    setMessage("Cockpit online")
    drawUI()

    while true do
        local ev, p1 = os.pullEvent()
        if ev == "char" then
            local ch = tostring(p1)

            if ch:match("%d") then
                if ch == "0" then selected_index = 10 else selected_index = tonumber(ch) or selected_index end
                clampSelection()
                local b = selectedBot()
                if b then setMessage("Selected " .. tostring(b.hwid)) end

            elseif ch == "c" then
                local b = requireSelectedBot()
                if b then
                    if self_pos then
                        sendTabletCmd("COME_TO_ME", { hwid = b.hwid, pos = self_pos })
                        setMessage(string.format("COME %s -> %d,%d,%d", b.hwid, self_pos.x, self_pos.y, self_pos.z))
                    else
                        setMessage("GPS lock required")
                    end
                end

            elseif ch == "g" then
                local b = requireSelectedBot()
                if b then
                    local x = promptInt("goto x: ")
                    if x ~= nil then
                        local y = promptInt("goto y: ")
                        if y ~= nil then
                            local z = promptInt("goto z: ")
                            if z ~= nil then
                                local pos = { x = x, y = y, z = z }
                                sendTabletCmd("GOTO", { hwid = b.hwid, pos = pos })
                                setMessage(string.format("GOTO %s -> %d,%d,%d", b.hwid, pos.x, pos.y, pos.z))
                            end
                        end
                    end
                end

            elseif ch == "t" then
                local b = requireSelectedBot()
                if b then
                    local x = promptInt("tun x: ")
                    if x ~= nil then
                        local y = promptInt("tun y: ")
                        if y ~= nil then
                            local z = promptInt("tun z: ")
                            if z ~= nil then
                                local d = promptRequired("dir n/e/s/w: ")
                                if d then
                                    local dir = parseDirToken(d)
                                    if dir ~= nil then
                                        local pos = { x = x, y = y, z = z }
                                        sendTabletCmd("TUNNEL_FROM", { hwid = b.hwid, pos = pos, dir = dir })
                                        setMessage(string.format("TUN %s -> %d,%d,%d d%d", b.hwid, pos.x, pos.y, pos.z, dir))
                                    else
                                        setMessage("Bad dir")
                                    end
                                end
                            end
                        end
                    end
                end

            elseif ch == "m" then
                local ore = promptRequired("ore name: ")
                if ore then
                    local count = promptInt("ore count: ")
                    if count and count > 0 then
                        sendTabletCmd("GETME", { ore = ore, count = count })
                        setMessage(string.format("GETME %s x%d", ore, count))
                    elseif count then
                        setMessage("Count must be > 0")
                    end
                end

            elseif ch == "a" then
                sendTabletCmd("START", {})
                setMessage("START broadcast")

            elseif ch == "o" then
                sendTabletCmd("STOP", {})
                setMessage("STOP broadcast")

            elseif ch == "r" then
                sendTabletCmd("RECALL", {})
                setMessage("RECALL broadcast")

            elseif ch == "s" then
                requestSync()
                setMessage("Sync requested")

            elseif ch == "l" then
                refreshSelfGps(2)
                if self_pos then
                    setMessage(string.format("GPS %d,%d,%d", self_pos.x, self_pos.y, self_pos.z))
                else
                    setMessage("GPS no fix")
                end

            elseif ch == "q" then
                term.setCursorPos(1, 1)
                term.clear()
                print("Tablet cockpit stopped.")
                return
            end

            os.queueEvent("tablet_refresh")
        elseif ev == "term_resize" or ev == "tablet_refresh" then
            -- redraw only
        end

        drawUI()
    end
end

parallel.waitForAny(receiverThread, syncThread, gpsThread, uiThread)
