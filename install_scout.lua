--[[
    M-NET V2 | SCOUT INSTALLER
    ===========================
    Run this on a CC:T Turtle to download and install the Scout Node.

    Usage (from the Turtle shell):
        wget run https://raw.githubusercontent.com/Teru-dot-png/M-NETLVL0/refs/heads/main/install_scout.lua

    What it does:
        1. Downloads scout_node.lua from GitHub
        2. Saves it as /startup.lua  (auto-runs on every boot)
        3. Reboots the turtle to start the node immediately
]]

local BASE_URL   = "https://raw.githubusercontent.com/Teru-dot-png/M-NETLVL0/refs/heads/main/"
local INSTALL_AS = "startup.lua"

-- ── Helpers ──────────────────────────────────────────────────────────
local function printOk(msg)   term.setTextColor(colors.lime)   print("[OK]   " .. msg) end
local function printErr(msg)  term.setTextColor(colors.red)    print("[ERR]  " .. msg) end
local function printInfo(msg) term.setTextColor(colors.yellow) print("[..]   " .. msg) end
term.setTextColor(colors.white)

local function download(filename)
    local url = BASE_URL .. filename
    printInfo("Downloading " .. url)
    local res = http.get(url)
    if not res then
        printErr("HTTP request failed for: " .. url)
        return nil
    end
    local body = res.readAll()
    res.close()
    if not body or #body == 0 then
        printErr("Empty response for: " .. url)
        return nil
    end
    return body
end

local function writeFile(path, content)
    local f = fs.open(path, "w")
    if not f then
        printErr("Cannot open file for writing: " .. path)
        return false
    end
    f.write(content)
    f.close()
    return true
end

-- ── Main ─────────────────────────────────────────────────────────────
print("+----------------------------------+")
print("|  M-NET V2  |  SCOUT  INSTALLER  |")
print("+----------------------------------+")
print("")

if not http then
    printErr("HTTP API is disabled. Enable it in the server config (allow_http = true).")
    return
end

-- Warn if overwriting an existing startup
if fs.exists(INSTALL_AS) then
    printInfo("Existing " .. INSTALL_AS .. " will be overwritten.")
end

local content = download("scout_node.lua")
if not content then
    printErr("Installation aborted.")
    return
end

if not writeFile(INSTALL_AS, content) then
    printErr("Installation aborted.")
    return
end

printOk("scout_node.lua  ->  " .. INSTALL_AS)
print("")
printOk("Scout Node installed successfully!")
printInfo("Hardware checklist:")
printInfo("  [?]  Advanced Modem      attached (any side)")
printInfo("  [?]  Geo Scanner         in left  peripheral slot")
printInfo("  [?]  Entity Detector     in right peripheral slot")
printInfo("  [?]  Fuel loaded")
print("")
term.setTextColor(colors.white)
print("Rebooting in 3 seconds...")
os.sleep(3)
os.reboot()
