--[[
    M-NET V2 | MAIN MAPPER INSTALLER
    ==================================
    Run this on a CC:T Advanced Computer to download and install the Main Mapper.

    Usage (from the Computer shell):
        wget run https://raw.githubusercontent.com/Teru-dot-png/M-NETLVL0/refs/heads/main/install_mapper.lua

    What it does:
        1. Downloads main_mapper.lua from GitHub
        2. Saves it as /startup.lua  (auto-runs on every boot)
        3. Reboots the computer to start the mapper immediately
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
print("|  M-NET V2  |  MAPPER  INSTALLER |")
print("+----------------------------------+")
print("")

if not http then
    printErr("HTTP API is disabled. Enable it in the server config (allow_http = true).")
    return
end

if fs.exists(INSTALL_AS) then
    printInfo("Existing " .. INSTALL_AS .. " will be overwritten.")
end

local content = download("main_mapper.lua")
if not content then
    printErr("Installation aborted.")
    return
end

if not writeFile(INSTALL_AS, content) then
    printErr("Installation aborted.")
    return
end

printOk("main_mapper.lua  ->  " .. INSTALL_AS)
print("")
printOk("Main Mapper installed successfully!")
printInfo("Hardware checklist:")
printInfo("  [?]  Advanced Computer   (required — not a standard computer)")
printInfo("  [?]  Advanced Modem      on the BACK  side")
printInfo("  [?]  Advanced Monitor    on the TOP   side")
print("")
term.setTextColor(colors.white)
print("Rebooting in 3 seconds...")
os.sleep(3)
os.reboot()
