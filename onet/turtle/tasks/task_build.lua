-- /onet/turtle/tasks/task_build.lua
-- Builder place-structure sequence. Places a chest or furnace from cargo at the
-- target, optionally loads ore + fuel into a furnace to smelt. target =
-- { kind="chest"|"furnace", pos={x,y,z}, [smelt=true] }.
-- Skeleton-functional: the heavy zone-layout planning lives in role_builder.

local Task   = require("task")
local cfg    = require("config")
local state  = require("state")
local nav    = require("nav")
local movers = require("movers")
local blocks = require("blocks")
local log    = require("log").log

local M = {}

local function selectItem(pred)
    for s = cfg.CARGO_FIRST, cfg.CARGO_LAST do
        local d = turtle.getItemDetail(s)
        if d and pred(d.name) then turtle.select(s); return true end
    end
    return false
end

function M.new(target, opts)
    local t = Task.new("build", target, opts)

    function t:isValidTarget()
        return type(self.target) == "table" and type(self.target.pos) == "table"
    end

    function t:work()
        local kind = self.target.kind or "chest"
        local pos  = self.target.pos
        -- Stand next to the placement cell and face it.
        if not nav.moveTo({ x = pos.x, y = pos.y + 1, z = pos.z }) then
            log("BUILD", "Cannot reach build site.")
            self.failed = true; return false
        end

        local pred = (kind == "furnace")
            and function(n) return tostring(n):find("furnace") end
            or  function(n) return tostring(n):find("chest")   end
        if selectItem(pred) then
            turtle.placeDown()
            log("BUILD", "Placed " .. kind .. " at (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")")
        else
            log("BUILD", "No " .. kind .. " in cargo to place.")
        end

        -- Optional smelt: drop ore + fuel into the furnace below.
        if kind == "furnace" and self.target.smelt then
            if selectItem(function(n) return blocks.isOre(n) or tostring(n):find("cobblestone") end) then
                turtle.dropDown()  -- top input via face is approximate; role handles exact sides
            end
            if selectItem(blocks.isFuel) then turtle.dropDown() end
        end
        turtle.select(cfg.CARGO_FIRST)
        self.done = true
        return true
    end

    return t
end

return M
