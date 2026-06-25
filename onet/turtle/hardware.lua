-- /onet/turtle/hardware.lua
-- Hardware detection: find the modem side, the tool side, the scanner slot,
-- and whether this is a Crafty Turtle (GenesisRole). Pickaxe equip/fetch logic
-- lives in pickaxe.lua (§3 file split). CORE pairing with scanner.lua.

local cfg   = require("config")
local state = require("state")
local log   = require("log").log

local M = {}

function M.isScannerName(name)
    local n = tostring(name or "")
    return n == cfg.SCANNER_ITEM or n:find("geo_scanner", 1, true) ~= nil
end

function M.detectHardware()
    log("BOOT", "Scanning hardware...")
    local HW = state.HW

    -- Modem side
    for _, side in ipairs({ "left", "right" }) do
        if peripheral.isPresent(side) then
            local t = peripheral.getType(side)
            if t and (t:find("modem") or t == "ender_modem") then
                HW.modem_side = side; break
            end
        end
    end
    if not HW.modem_side then
        if peripheral.isPresent("left")  then HW.modem_side = "left"  end
        if peripheral.isPresent("right") then HW.modem_side = "right" end
    end
    HW.pick_side = (HW.modem_side == "left") and "right" or "left"
    log("BOOT", "Modem: " .. tostring(HW.modem_side) .. "  Tool: " .. tostring(HW.pick_side))

    -- Pickaxe already equipped on the tool side?
    if HW.pick_side then
        local getEq = HW.pick_side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
        if getEq then
            local info = getEq()
            if info and tostring(info.name or ""):find("pickaxe") then
                HW.has_pickaxe = true
                log("BOOT", "Pickaxe: equipped on " .. HW.pick_side .. ".")
            end
        elseif not peripheral.isPresent(HW.pick_side) then
            HW.has_pickaxe = true
        end
    end

    -- Crafty turtle? A crafting upgrade exposes turtle.craft.
    HW.is_crafty = type(turtle.craft) == "function"

    -- Scan all 16 slots for scanner / pickaxe items.
    for s = 1, 16 do
        local detail = turtle.getItemDetail(s)
        if detail then
            local name = tostring(detail.name or "")
            if M.isScannerName(name) then
                HW.scanner_slot = s
                HW.has_scanner  = true
                if s == cfg.SLOT_SCANNER then
                    log("BOOT", "Geo Scanner: slot 1 (reserved). OK")
                else
                    -- §1.1: scanner belongs in slot 1. Warn loudly; do not move
                    -- it programmatically here.
                    log("ALERT", "Scanner in slot " .. s .. " (should be slot 1)")
                end
            elseif name:find("pickaxe") then
                HW.has_pickaxe = true
            end
        end
    end

    if not HW.has_scanner then log("BOOT", "Geo Scanner: NOT FOUND. Scanning disabled.") end
    if not HW.modem_side  then log("ALERT", "No modem on either side.") end
    log("BOOT", "Hardware detection complete. crafty=" .. tostring(HW.is_crafty))
end

-- Re-locate the scanner slot (it can move when swapped onto the tool side).
function M.refreshScannerSlot()
    local HW = state.HW
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and M.isScannerName(d.name) then
            HW.scanner_slot = s
            HW.has_scanner  = true
            return s
        end
    end
    return nil
end

return M
