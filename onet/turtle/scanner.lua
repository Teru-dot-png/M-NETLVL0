-- /onet/turtle/scanner.lua
-- Geo scanner hot-swap + ore reporting. CORE (pairs with hardware.lua).
-- The hot-swap trick: one tool side, one scanner slot. We equip the scanner,
-- scan, then equip the pickaxe back. The `scanning_now` lock (set in state) is
-- ESSENTIAL — without it the inventory/pickaxe check can race the swap and the
-- protection logic dumps the scanner. Do not remove the lock (§1.1, §11).

local cfg      = require("config")
local state    = require("state")
local cache    = require("cache")
local hardware = require("hardware")
local pickaxe  = require("pickaxe")
local vec      = require("vec")
local blocks   = require("blocks")
local log      = require("log").log

local M = {}

function M.scanAround()
    local HW = state.HW
    if not HW.has_scanner or not HW.scanner_slot then return {} end
    if not HW.pick_side then return {} end

    local scannerOnSide = peripheral.isPresent(HW.pick_side)
    if not scannerOnSide then
        if turtle.getItemCount(HW.scanner_slot) == 0 then
            hardware.refreshScannerSlot()
            if turtle.getItemCount(HW.scanner_slot) == 0 then
                log("SCAN", "Scanner missing from slot " .. HW.scanner_slot .. ". Skipping.")
                return {}
            end
        end
        state.scanning_now = true            -- LOCK: protect against pickaxe race
        turtle.select(HW.scanner_slot)
        if HW.pick_side == "left" then turtle.equipLeft() else turtle.equipRight() end
    end

    local results = {}
    local sc = peripheral.wrap(HW.pick_side)
    if sc and sc.scan then
        local ok, r = pcall(sc.scan, cfg.SCAN_RADIUS)
        if ok and type(r) == "table" then
            results = r
            cache.feedCache(results, state.pos)
            log("SCAN", string.format("Scanned %d blocks. Cache: %d.", #results, state.cache_size))
        else
            log("SCAN", "Scan error: " .. tostring(r))
        end
    end

    -- Swap scanner back out; pickaxe returns to the tool side.
    turtle.select(HW.scanner_slot)
    if HW.pick_side == "left" then turtle.equipLeft() else turtle.equipRight() end
    turtle.select(cfg.SLOT_SCANNER)
    state.scanning_now = false               -- UNLOCK

    hardware.refreshScannerSlot()
    if not pickaxe.pickaxeEquipped() then
        if pickaxe.ensurePickaxeOnSide() then
            log("SCAN", "Recovered pickaxe after scan swap.")
        else
            log("ALERT", "Pickaxe not restored after scan swap.")
        end
    end
    return results
end

-- Report newly-seen ores to the overseer (dedup by world key, this run).
function M.reportOres(scan)
    if not scan then return end
    for _, b in ipairs(scan) do
        local name = b.name or ""
        if name:find("_ore") then
            local abs = {
                x = state.pos.x + (b.x or 0),
                y = state.pos.y + (b.y or 0),
                z = state.pos.z + (b.z or 0),
            }
            local k = vec.key(abs)
            if not state.reported[k] then
                state.reported[k] = true
                local short = blocks.normalizeOreName(name)
                log("SCAN", string.format("%s at (%d,%d,%d)", short, abs.x, abs.y, abs.z))
                pcall(rednet.send, state.server_id, {
                    type = "ORE_REPORT",
                    hwid = state.hwid,
                    ore  = short,
                    pos  = abs,
                }, cfg.PROTOCOL)
            end
        end
    end
end

-- Full solid-block snapshot to the overseer voxel map.
function M.sendSnapshot(scan)
    if not scan or not state.server_id then return end
    local solids = {}
    for _, b in ipairs(scan) do
        local n = b.name or ""
        if n ~= "" and not n:find("air") and not cache.isScanNoise(n) then
            solids[#solids + 1] = { x = b.x, y = b.y, z = b.z, name = n }
        end
    end
    pcall(rednet.send, state.server_id, {
        type        = "GEO_DATA",
        hwid        = state.hwid,
        pos         = vec.copy(state.pos),
        scan_data   = solids,
        scan_radius = cfg.SCAN_RADIUS,
    }, cfg.PROTOCOL)
end

-- Does the scan contain anything on the operator WANT_LIST?
function M.scanForWanted(scan)
    for _, b in ipairs(scan or {}) do
        local name = tostring(b.name or "")
        if name:find("_ore", 1, true) then
            local k = blocks.normalizeOreName(name)
            if state.WANT_LIST[k] then return k end
        end
    end
    return nil
end

return M
