--[[
    M-NET V2 | RELAY NODE  (auto-deploy / startup.lua version)
    ============================================================
    This script is designed to be written to a floppy disk by a
    Scout Node and auto-run by a freshly placed relay computer.

    Auto-deploy procedure performed by scout_node.lua:
      1. Scout detects consecutive transmission failures
         (fail_count >= CFG.RELAY_FAIL_THRESHOLD).
      2. Scout turns around and places a computer from
         inventory slot CFG.RELAY_SLOT.
      3. The placed computer must either:
           a) Have this file pre-installed as its startup.lua, OR
           b) Have a floppy disk with this file placed in an
              adjacent disk drive before booting.
      4. Scout boots the relay via peripheral.wrap("front").turnOn().

    To pre-load relay computers (recommended workflow):
      1. Boot a fresh CC:T computer.
      2. Run:  edit startup.lua
      3. Paste this entire file, save, and quit.
      4. Craft the computer into a regular item and give it to
         your Scout Turtle in inventory slot 16.
      The Scout will place and boot one each time signal degrades.

    Alternatively, write this file to a floppy disk:
      - Name the floppy file "startup"  (no extension needed).
      - CC:Tweaked will run disk/startup automatically when the
        relay computer boots with that disk in an adjacent drive.
]]

-- ============================================================
-- INITIALISATION
-- ============================================================
if not peripheral.find("modem", rednet.open) then
    -- Retry once after a short delay in case the modem is still loading
    os.sleep(1)
    if not peripheral.find("modem", rednet.open) then
        error("[RELAY FATAL] No wireless modem found. Cannot operate.")
    end
end

print("[M-NET RELAY ONLINE]")
print(string.format("[RELAY] Computer ID : %d", os.getComputerID()))
print("[RELAY] Listening for MNET_V2 packets...\n")

-- ============================================================
-- RELAY LOOP
-- ============================================================
while true do
    local sender_id, message, protocol = rednet.receive("MNET_V2")

    if message ~= nil then
        rednet.broadcast(message, "MNET_V2")
    end
end
