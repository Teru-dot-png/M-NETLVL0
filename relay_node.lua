--[[
    M-NET V2 | RELAY NODE  (manual-placement version)
    ====================================================
    Role     : Transparent packet repeater — extends wireless range
               by catching MNET_V2 packets and rebroadcasting them,
               enabling the daisy-chain back to the Main Mapper.
    Hardware : Any CC:T computer with a wireless modem.
    Protocol : MNET_V2

    Deployment: Place this computer anywhere coverage is needed.
                Run this script (or install it as startup.lua).
                No configuration required.

    NOTE: relay_startup.lua is the auto-injectable version of this
          script, intended to be written to a disk by a Scout Node
          and loaded by a freshly placed relay computer.
]]

-- ============================================================
-- INITIALISATION
-- ============================================================
if not peripheral.find("modem", rednet.open) then
    error("[FATAL] No wireless modem found. Attach one and reboot.")
end

print("+----------------------------------+")
print("|  M-NET V2  |  RELAY NODE ONLINE  |")
print("+----------------------------------+")
print(string.format("[INIT]  Computer ID : %d", os.getComputerID()))
print("[INIT]  Protocol    : MNET_V2")
print("[INIT]  Mode        : transparent packet repeater")
print("[RELAY] Listening for MNET_V2 traffic...\n")

-- ============================================================
-- RELAY LOOP
-- ============================================================
--[[
    Catch any MNET_V2 packet and immediately rebroadcast it.
    CC:Tweaked's rednet layer handles duplicate suppression and
    multi-hop routing automatically, so a simple rebroadcast is
    sufficient to extend the mesh.
]]
while true do
    local sender_id, message, protocol = rednet.receive("MNET_V2")

    if message ~= nil then
        rednet.broadcast(message, "MNET_V2")

        -- Minimal status output (avoids flooding the screen)
        if type(message) == "table" and message.type then
            print(string.format(
                "[RELAY] Forwarded %-10s  from ID %d",
                tostring(message.type), sender_id
            ))
        end
    end
end
