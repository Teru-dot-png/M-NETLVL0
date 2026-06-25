-- /onet/turtle/pickaxe.lua
-- Pickaxe equip / fetch helpers. Split out of hardware.lua so the tool logic is
-- one file (§3). The diamond pickaxe lives in slot 2 when carried (§1.1).

local cfg      = require("config")
local state    = require("state")
local hardware = require("hardware")
local log      = require("log").log

local M = {}

function M.pickaxeEquipped()
    local HW = state.HW
    if not HW.pick_side then return false end
    if peripheral.isPresent(HW.pick_side) then return false end
    local getEq = HW.pick_side == "left" and turtle.getEquippedLeft or turtle.getEquippedRight
    if getEq then
        local info = getEq()
        if info == nil then return false end
        return tostring(info.name or ""):find("pickaxe") ~= nil
    end
    return true -- no peripheral on tool side -> pickaxe assumed
end

function M.equipOnPickaxeSide()
    if state.HW.pick_side == "left" then return turtle.equipLeft()
    else                                  return turtle.equipRight() end
end

function M.isEquippable(detail)
    if not detail then return false end
    return tostring(detail.name or ""):find("pickaxe") ~= nil
end

-- Pull a pickaxe item out of cargo and equip it. Cargo is slots 3..16; slot 2
-- is the canonical pickaxe slot, so try it first.
function M.ensurePickaxeOnSide()
    if M.pickaxeEquipped() then return true end
    for _, s in ipairs({ cfg.SLOT_PICKAXE }) do
        if M.isEquippable(turtle.getItemDetail(s)) then
            turtle.select(s); M.equipOnPickaxeSide()
            if M.pickaxeEquipped() then turtle.select(cfg.SLOT_PICKAXE); return true end
        end
    end
    for s = cfg.CARGO_FIRST, cfg.CARGO_LAST do
        if M.isEquippable(turtle.getItemDetail(s)) then
            turtle.select(s); M.equipOnPickaxeSide()
            if M.pickaxeEquipped() then turtle.select(cfg.SLOT_PICKAXE); return true end
        end
    end
    turtle.select(cfg.SLOT_PICKAXE)
    return false
end

function M.bootEquipPickaxe()
    if M.pickaxeEquipped() then log("BOOT", "Pickaxe already equipped. OK"); return true end
    local HW = state.HW
    -- If a peripheral (e.g. the scanner) is sitting on the tool side, move it
    -- into a free cargo slot first.
    if peripheral.isPresent(HW.pick_side) then
        for s = cfg.CARGO_FIRST, cfg.CARGO_LAST do
            if turtle.getItemCount(s) == 0 then
                turtle.select(s); M.equipOnPickaxeSide()
                local got = turtle.getItemDetail(s)
                if got and hardware.isScannerName(got.name) then HW.scanner_slot = s end
                break
            end
        end
    end
    -- Try slot 2, then cargo, for a usable pickaxe.
    for s = cfg.SLOT_PICKAXE, cfg.CARGO_LAST do
        local detail = turtle.getItemDetail(s)
        if detail and tostring(detail.name or ""):find("pickaxe") then
            if M.isEquippable(detail) then
                turtle.select(s); M.equipOnPickaxeSide()
                local swapped = turtle.getItemDetail(s)
                if swapped and hardware.isScannerName(swapped.name) then HW.scanner_slot = s end
                if M.pickaxeEquipped() then
                    log("BOOT", "Pickaxe equipped. OK"); turtle.select(cfg.SLOT_PICKAXE); return true
                end
            else
                log("BOOT", "Slot " .. s .. ": pickaxe damaged/enchanted. Skipping.")
            end
        end
    end
    log("BOOT", "No equippable pickaxe. Will fetch from BASE after enlisting.")
    return false
end

-- Travel to the base chest and pull a pickaxe (FETCH_PICK state). nav/movers are
-- required lazily INSIDE the function: requiring them at module load would form
-- the cycle nav -> scanner -> pickaxe -> nav. By the time this runs, every
-- module is already loaded, so the lazy require is safe and cheap (cached).
function M.fetchPickaxeFromBase(resume_pos)
    local nav    = require("nav")
    local movers = require("movers")
    local vec    = require("vec")

    if not state.base then
        log("BOOT", "No BASE chest set. Cannot fetch pickaxe.")
        return false
    end
    log("BOOT", "Heading to base chest for a pickaxe...")
    if not nav.moveTo({ x = state.base.x, y = state.base.y + 1, z = state.base.z }) then
        log("BOOT", "Cannot reach base chest.")
        return false
    end

    local function tryFetch()
        local chest = peripheral.wrap("bottom")
        local function pull(ts)
            local got = turtle.getItemDetail(ts)
            if got and M.isEquippable(got) then
                M.equipOnPickaxeSide()
                if M.pickaxeEquipped() then
                    log("BOOT", "Pickaxe equipped. OK")
                    turtle.select(cfg.SLOT_PICKAXE); return true
                end
            end
            turtle.dropDown()
            return false
        end
        if chest and chest.list then
            for _, item in pairs(chest.list()) do
                if tostring(item.name or ""):find("pickaxe") then
                    for ts = cfg.CARGO_FIRST, cfg.CARGO_LAST do
                        if turtle.getItemCount(ts) == 0 then
                            turtle.select(ts); turtle.suckDown(1)
                            if pull(ts) then return true end
                            break
                        end
                    end
                end
            end
        else
            for ts = cfg.CARGO_FIRST, cfg.CARGO_LAST do
                if turtle.getItemCount(ts) == 0 then
                    turtle.select(ts)
                    if not turtle.suckDown(1) then break end
                    if pull(ts) then return true end
                    break
                end
            end
        end
        return false
    end

    local fetched = tryFetch()
    local retries = 0
    while not fetched and retries < 12 do  -- up to 2 min waiting for a pickaxe
        sleep(10); retries = retries + 1; fetched = tryFetch()
    end

    if resume_pos then nav.moveTo(resume_pos); movers.face(state.my_dir) end
    return fetched
end

return M
