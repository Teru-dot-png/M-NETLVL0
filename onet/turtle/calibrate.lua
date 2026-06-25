-- /onet/turtle/calibrate.lua
-- GPS heading derivation + disk-cached calibration. Split out of nav.lua (§3).
-- CORE: getting the heading wrong corrupts every coordinate the turtle reports.

local cfg    = require("config")
local state  = require("state")
local movers = require("movers")
local vec    = require("vec")
local log    = require("log").log

local M = {}

function M.saveCal()
    local f = fs.open(cfg.CAL_FILE, "w")
    if f then
        f.write(textutils.serialize({ pos = state.pos, facing = state.facing }))
        f.close()
    end
end

local function loadCal()
    if not fs.exists(cfg.CAL_FILE) then return nil end
    local f = fs.open(cfg.CAL_FILE, "r")
    if not f then return nil end
    local data = textutils.unserialize(f.readAll() or "")
    f.close()
    if type(data) == "table" and data.pos and type(data.facing) == "number" then return data end
    return nil
end

-- Resync position from GPS; on large drift, re-derive heading by stepping once.
function M.gpsSyncPos()
    local x, y, z = gps.locate(2)
    if not x then return end
    local pos = state.pos
    local drift = math.abs(x - pos.x) + math.abs(y - pos.y) + math.abs(z - pos.z)
    if drift == 0 then return end
    log("NAV", string.format("GPS drift %d. Correcting (%d,%d,%d)->(%d,%d,%d)",
        drift, pos.x, pos.y, pos.z, x, y, z))
    state.pos = { x = x, y = y, z = z }
    if drift > 3 then
        log("NAV", "Large drift. Re-deriving heading...")
        local moved = false
        for _ = 0, 3 do
            if turtle.forward() then moved = true; break end
            turtle.turnRight()
        end
        if moved then
            local x2, y2, z2 = gps.locate(2)
            if x2 then
                local ddx, ddz = x2 - x, z2 - z
                if     ddx ==  1 then state.facing = 1
                elseif ddx == -1 then state.facing = 3
                elseif ddz ==  1 then state.facing = 2
                elseif ddz == -1 then state.facing = 0 end
                state.pos = { x = x2, y = y2, z = z2 }
                M.saveCal()
            end
        end
    end
end

function M.calibrate()
    log("NAV", "Calibrating heading...")
    local function gpsPos()
        local x, y, z = gps.locate(2)
        if x then return { x = x, y = y, z = z } end
        return nil
    end

    local p1 = gpsPos()
    if not p1 then error("[FATAL] No GPS fix. Build a GPS constellation first.", 0) end

    local saved = loadCal()
    if saved then
        local dist = math.abs(p1.x - saved.pos.x) + math.abs(p1.y - saved.pos.y) + math.abs(p1.z - saved.pos.z)
        if dist <= 1 then
            state.pos    = vec.copy(p1)
            state.facing = saved.facing
            if turtle.forward() then
                local p2 = gpsPos()
                if p2 then
                    local ddx, ddz = p2.x - p1.x, p2.z - p1.z
                    local derived
                    if     ddx ==  1 then derived = 1
                    elseif ddx == -1 then derived = 3
                    elseif ddz ==  1 then derived = 2
                    elseif ddz == -1 then derived = 0 end
                    if derived ~= nil and derived ~= state.facing then
                        log("NAV", "Heading mismatch. Using GPS=" .. derived)
                        state.facing = derived
                    end
                    state.pos = vec.copy(p2)
                end
            end
            M.saveCal()
            log("NAV", string.format("Calibrated from save: facing=%d pos=(%d,%d,%d)",
                state.facing, state.pos.x, state.pos.y, state.pos.z))
            return
        else
            log("NAV", "Saved cal " .. dist .. " blocks off. Recalibrating fresh.")
        end
    end

    local moved = false
    for _ = 0, 3 do
        local ok = turtle.forward()
        if not ok then
            local has_block, data = turtle.inspect()
            if has_block and type(data) == "table" then
                local name = data.name or ""
                if movers.isDiggable(name) then
                    turtle.dig(); sleep(0.2); ok = turtle.forward()
                end
            end
        end
        if ok then moved = true; break end
        turtle.turnRight()
    end
    if not moved then error("[FATAL] All four directions blocked during calibration.", 0) end

    local p2 = gpsPos()
    if not p2 then error("[FATAL] Lost GPS during calibration move.", 0) end

    local dx, dz = p2.x - p1.x, p2.z - p1.z
    if     dx ==  1 then state.facing = 1
    elseif dx == -1 then state.facing = 3
    elseif dz ==  1 then state.facing = 2
    elseif dz == -1 then state.facing = 0
    else error(string.format("[FATAL] Bad GPS delta (%d,_,%d).", dx, dz), 0) end
    state.pos = vec.copy(p2)
    log("NAV", string.format("Calibrated fresh: facing=%d pos=(%d,%d,%d)",
        state.facing, state.pos.x, state.pos.y, state.pos.z))
    M.saveCal()
end

return M
