-- /onet/turtle/fuel.lua
-- Fuel checks, aboard burn, boot wake, and coal foraging.
-- SURVIVAL tier. Burns ONLY cargo slots 3..16 — slots 1+2 are the scanner and
-- pickaxe and must never be fed to the furnace (§1.1).

local cfg    = require("config")
local state  = require("state")
local movers = require("movers")
local log    = require("log").log

local M = {}

function M.fuelLevel()
    local f = turtle.getFuelLevel()
    return f == "unlimited" and math.huge or (tonumber(f) or 0)
end

-- Burn burnable cargo until target reached.
function M.burnAboard(target)
    for slot = cfg.CARGO_FIRST, cfg.CARGO_LAST do
        if M.fuelLevel() >= target then break end
        turtle.select(slot)
        if turtle.refuel(0) then turtle.refuel() end
    end
    turtle.select(cfg.CARGO_FIRST)
end

function M.refuelSelf()
    if M.fuelLevel() < cfg.FUEL_MIN then M.burnAboard(cfg.FUEL_TARGET) end
end

-- Boot fuel sequence: burn aboard, then wait up to 60s for hand-fed coal if dry.
function M.wakeUp()
    log("FUEL", "Fuel check. Current = " .. tostring(turtle.getFuelLevel()))
    M.burnAboard(cfg.FUEL_TARGET)
    if M.fuelLevel() == 0 then
        log("FUEL", "EMPTY. Drop coal in cargo slots 3-16...")
        local retries = 0
        while M.fuelLevel() == 0 and retries < 30 do
            M.burnAboard(cfg.FUEL_TARGET); sleep(2); retries = retries + 1
        end
        if M.fuelLevel() == 0 then
            log("FUEL", "No fuel after 60s. Continuing in passive mode.")
            return false
        end
    end
    if M.fuelLevel() < cfg.FUEL_TARGET then
        log("FUEL", "Below target. Will forage after calibration.")
    else
        log("FUEL", "Fuel target reached.")
    end
    return true
end

-- Mine forward picking up burnables until FUEL_TARGET met.
function M.forageForCoal()
    if M.fuelLevel() >= cfg.FUEL_TARGET then return end
    log("FUEL", "Foraging (up to " .. cfg.FORAGE_MAX .. " blocks)...")
    local steps = 0
    while M.fuelLevel() < cfg.FUEL_TARGET and steps < cfg.FORAGE_MAX do
        if not movers.forward() then break end
        steps = steps + 1
        M.burnAboard(cfg.FUEL_TARGET)
    end
    log("FUEL", "Foraged " .. steps .. " blocks. Fuel = " .. tostring(turtle.getFuelLevel()))
end

return M
