-- /onet/overseer/terminal.lua
-- Operator command console. Mirrors the V1 command set, plus V2 additions
-- (setzone, setpop, role). Every fleet-wide command broadcasts or targets a
-- single hwid.

local cfg      = require("config")
local state    = require("state")
local fleet    = require("fleet")
local zones    = require("zones")
local orders   = require("orders")
local population= require("population")
local persist  = require("persist")
local voxelmap = require("voxelmap")
local blocks   = require("blocks")

local M = {}

local function words(line)
    local out = {}
    for w in tostring(line or ""):gmatch("%S+") do out[#out + 1] = w end
    return out
end
local function coords(w, i) return tonumber(w[i]), tonumber(w[i + 1]), tonumber(w[i + 2]) end

local function sendAll(mtype, hwid_filter)
    for hwid, f in pairs(state.fleet) do
        if not hwid_filter or hwid_filter == hwid then
            rednet.send(f.net_id, { type = mtype, hwid = hwid }, cfg.PROTOCOL)
        end
    end
end

local function help()
    print([[
Commands:
  start|stop|recall [hwid]   fleet run control
  status                     fleet roster
  setdump x y z              set dump chest
  setbase x y z              set base chest
  setpark x1 y1 z1 x2 y2 z2  define park zone
  setzone ZONE x y z         set a storage zone chest
  zones                      list zones + fill
  want|unwant <ore>          edit want list
  wants                      list want list
  getme <ore> <n>            collect n of an ore
  orders                     active getme orders
  cancelorder <ore>          cancel an order
  setpop <n>                 set target fleet size
  role <hwid> <ROLE>         reassign a turtle's role
  map [y] | savemap | clearmap | feed | help]]
    )
end

function M.terminalThread()
    while true do
        io.write("> ")
        local line = io.read()
        if not line then break end
        local w = words(line)
        local cmd = (w[1] or ""):lower()

        if cmd == "start" or cmd == "stop" or cmd == "recall" then
            local mtype = ({ start = "CMD_START", stop = "CMD_STOP", recall = "CMD_RECALL" })[cmd]
            sendAll(mtype, w[2])
            print("  " .. cmd .. " sent.")

        elseif cmd == "status" then
            print(string.format("  Fleet %d (live %d) / target %d", fleet.count(), fleet.liveCount(), state.target_fleet))
            for _, s in ipairs(fleet.snapshot()) do
                print(string.format("    %-11s %-9s %-7s (%d,%d,%d)", s.hwid, s.role or "?", s.status,
                    s.pos.x, s.pos.y, s.pos.z))
            end

        elseif cmd == "setdump" then
            local x, y, z = coords(w, 2)
            if x then state.DUMP_CHEST = { x = x, y = y, z = z }; persist.saveConfig(); persist.broadcastConfig()
                print("  dump set.") else print("  Usage: setdump x y z") end

        elseif cmd == "setbase" then
            local x, y, z = coords(w, 2)
            if x then state.BASE_CHEST = { x = x, y = y, z = z }; persist.saveConfig(); persist.broadcastConfig()
                print("  base set.") else print("  Usage: setbase x y z") end

        elseif cmd == "setpark" then
            local x1, y1, z1 = coords(w, 2)
            local x2, y2, z2 = coords(w, 5)
            if x1 and x2 then
                state.PARK_ZONE = { x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2 }
                persist.saveConfig(); print("  park zone set.")
            else print("  Usage: setpark x1 y1 z1 x2 y2 z2") end

        elseif cmd == "setzone" then
            local zone = (w[2] or ""):upper()
            local x, y, z = coords(w, 3)
            if x then local ok, err = zones.setChest(zone, { x = x, y = y, z = z })
                if ok then persist.saveConfig() else print("  " .. tostring(err)) end
            else print("  Usage: setzone ZONE x y z") end

        elseif cmd == "zones" then
            for z, info in pairs(zones.fillSnapshot()) do
                print(string.format("  %-12s %s  total=%d", z, info.chest and "set" or "----", info.total))
            end

        elseif cmd == "want" then
            local ore = w[2] and blocks.normalizeOreName(w[2])
            if ore then state.WANT_LIST[ore] = true; persist.saveConfig(); persist.broadcastConfig(); print("  +" .. ore)
            else print("  Usage: want <ore>") end

        elseif cmd == "unwant" then
            local ore = w[2] and blocks.normalizeOreName(w[2])
            if ore then state.WANT_LIST[ore] = nil; persist.saveConfig(); persist.broadcastConfig(); print("  -" .. ore)
            else print("  Usage: unwant <ore>") end

        elseif cmd == "wants" then
            local any = false
            for ore in pairs(state.WANT_LIST) do print("  " .. ore); any = true end
            if not any then print("  (empty)") end

        elseif cmd == "getme" then
            local ok, err = orders.startGetme(w[2], w[3])
            if not ok then print("  " .. tostring(err)) end

        elseif cmd == "orders" then
            local any = false
            for ore, o in pairs(state.active_orders) do
                print(string.format("  %s: %d/%d (dump %d)", ore, o.got, o.target, orders.countInDump(ore))); any = true
            end
            if not any then print("  none") end

        elseif cmd == "cancelorder" then
            local ore = w[2] and blocks.normalizeOreName(w[2])
            if ore and state.active_orders[ore] then state.active_orders[ore] = nil; print("  cancelled " .. ore)
            else print("  no such order") end

        elseif cmd == "setpop" then
            local ok, err = population.setTarget(w[2])
            if ok then population.tick() else print("  " .. tostring(err)) end

        elseif cmd == "role" then
            local hwid, role = w[2], (w[3] or ""):upper()
            local rolename = cfg.ROLES[role]
            local f = hwid and state.fleet[hwid]
            if f and rolename then
                f.role = rolename
                rednet.send(f.net_id, { type = "ROLE_ASSIGN", hwid = hwid, role = rolename }, cfg.PROTOCOL)
                print("  " .. hwid .. " -> " .. rolename)
            else print("  Usage: role <hwid> <MINER|HAULER|SCOUT|REFUEL|BUILDER|GENESIS>") end

        elseif cmd == "map" then
            local y = tonumber(w[2]) or state.view_y
            for z = state.view_cz - 16, state.view_cz + 16, 2 do
                local row = {}
                for x = state.view_cx - 24, state.view_cx + 24 do
                    local v = voxelmap.getVoxel(x, y, z)
                    row[#row + 1] = (not v and " ") or (voxelmap.isAir(v) and ".") or (voxelmap.isOre(v) and "O") or "#"
                end
                print(table.concat(row))
            end

        elseif cmd == "savemap" then persist.saveMap(); print("  saved.")
        elseif cmd == "clearmap" then state.master_voxels = {}; state.total_voxels = 0; print("  cleared.")
        elseif cmd == "feed" then
            for _, e in ipairs(state.ORE_FEED) do
                print(string.format("  [%s] %s %s (%d,%d,%d)", e.time, e.hwid, e.ore, e.x, e.y, e.z))
            end
        elseif cmd == "help" or cmd == "?" then help()
        elseif cmd ~= "" then print("  unknown; 'help'") end
    end
end

return M
