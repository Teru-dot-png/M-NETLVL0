-- /onet/turtle/inventory.lua
-- Inventory queries + slot protection + cargo dump.
-- SURVIVAL tier. §1.1 is NON-NEGOTIABLE here:
--   * Slot 1 = geo scanner, slot 2 = pickaxe. Both protected UNCONDITIONALLY.
--   * The slot-number check happens BEFORE any turtle.getItemDetail call,
--     because an NBT/Forge-tagged tool can make getItemDetail return nil and a
--     naive "is this a tool?" check would then dump the scanner. We fixed that
--     bug once; the slot check below is what keeps it fixed.
--   * Every dump/count loop runs slots 3..16 only (14 cargo slots).

local cfg      = require("config")
local state    = require("state")
local hardware = require("hardware")
local vec      = require("vec")
local log      = require("log").log

local M = {}

-- Returns true for any slot that must never be dropped.
function M.isTool(detail, slot)
    -- (1) Slot-number guard FIRST — before touching detail.
    if slot == cfg.SLOT_SCANNER then return true end   -- geo scanner
    if slot == cfg.SLOT_PICKAXE then return true end   -- diamond pickaxe
    -- (2) Defensive: scanner may have been bumped to another slot mid-swap.
    local HW = state.HW
    if HW.scanner_slot and slot == HW.scanner_slot and turtle.getItemCount(slot) > 0 then
        return true
    end
    -- (3) Only now consult detail (may be nil for tagged items).
    if not detail then
        return turtle.getItemCount(slot) > 0  -- fail-safe: never dump unknown
    end
    local n = tostring(detail.name or "")
    if hardware.isScannerName(n) then return true end
    return n:find("pickaxe") ~= nil
end

-- Cargo = slots 3..16.
function M.inventoryFull()
    for i = cfg.CARGO_FIRST, cfg.CARGO_LAST do
        if turtle.getItemCount(i) == 0 then return false end
    end
    return true
end

function M.freeSlots()
    local n = 0
    for i = cfg.CARGO_FIRST, cfg.CARGO_LAST do
        if turtle.getItemCount(i) == 0 then n = n + 1 end
    end
    return n
end

-- Drop all cargo (slots 3..16) in the given direction ("down"/"forward"/"up").
-- Tools are never dropped. Returns true if cargo fully cleared.
function M.dropCargo(dir)
    local drop = turtle.dropDown
    if dir == "forward" then drop = turtle.drop
    elseif dir == "up"  then drop = turtle.dropUp end

    for i = cfg.CARGO_FIRST, cfg.CARGO_LAST do
        if turtle.getItemCount(i) > 0 then
            local detail = turtle.getItemDetail(i)
            if M.isTool(detail, i) then
                log("DUMP", "Keeping protected slot " .. i)
            else
                turtle.select(i); drop()
            end
        end
    end
    turtle.select(cfg.CARGO_FIRST)

    for i = cfg.CARGO_FIRST, cfg.CARGO_LAST do
        if turtle.getItemCount(i) > 0 and not M.isTool(turtle.getItemDetail(i), i) then
            return false  -- leftover -> chest full
        end
    end
    return true
end

-- Suck items into cargo slots from a direction. Returns count of slots filled.
function M.suckInto(dir, max)
    local suck = turtle.suckDown
    if dir == "forward" then suck = turtle.suck
    elseif dir == "up"  then suck = turtle.suckUp end
    local filled = 0
    for i = cfg.CARGO_FIRST, cfg.CARGO_LAST do
        if max and filled >= max then break end
        if turtle.getItemCount(i) == 0 then
            turtle.select(i)
            if suck() then filled = filled + 1 else break end
        end
    end
    turtle.select(cfg.CARGO_FIRST)
    return filled
end

return M
