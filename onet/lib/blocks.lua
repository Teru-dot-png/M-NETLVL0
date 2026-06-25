-- /onet/lib/blocks.lua  (SHARED — byte-identical on turtle + overseer)
-- Block classifiers. SURVIVAL tier: the NEVER_BREAK list is the only thing
-- stopping a turtle from chewing through the base computer, a chest, or a
-- Create contraption. Port the pattern lists VERBATIM — they encode a whole
-- session of "the fleet ate my base" debugging. Do not trim them to look tidy.
--
-- Also home to the storage-zone predicates (§6) so Hauler (sorting) and
-- Overseer (zone fill display) classify items identically.

local M = {}

-- ── Pattern tables (globals on purpose: §1.2 keeps them out of the local
--    pool, and they are immutable constants shared by every predicate) ──
DIGGABLE_PATTERNS = {
    "stone","granite","diorite","andesite","deepslate","tuff","calcite",
    "dripstone","basalt","blackstone","netherrack","end_stone","sandstone",
    "cobblestone","mossy_cobblestone","cobbled_deepslate",
    "gravel","dirt","sand","clay","mud","soul_sand","soul_soil",
    "_ore","raw_block",
}

NEVER_BREAK_PATTERNS = {
    "computer","turtle","monitor","speaker","printer","disk_drive","modem",
    "cable","wired_modem",
    "chest","barrel","hopper","dropper","dispenser","shulker","ender_chest",
    "create:","mechanical_","cogwheel","shaft","gearbox","bearing",
    "deployer","encased","schematic","contraption","fluid_tank",
    "valve","pump","funnel","chute","belt","vault","interface",
    "andesite_casing","brass_casing","copper_casing",
    "appeng:","refinedstorage:",
    "lava","water","fire","portal","bedrock","barrier",
    "command_block","structure_block","spawner","mob_spawner",
    "reinforced_deepslate","furnace",
}

local function matchAny(name, patterns)
    if type(name) ~= "string" then return false end
    name = name:lower()
    for _, p in ipairs(patterns) do
        if name:find(p, 1, true) then return true end
    end
    return false
end
M.matchAny = matchAny

-- NEVER_BREAK takes precedence: a block that matches both lists is protected.
function M.isProtectedBlock(name)
    return matchAny(name, NEVER_BREAK_PATTERNS)
end

function M.isDiggable(name)
    if M.isProtectedBlock(name) then return false end
    return matchAny(name, DIGGABLE_PATTERNS)
end

-- Passable = air or a non-solid we can move into.
local PASSABLE = {
    ["minecraft:air"]=true, ["air"]=true, ["minecraft:cave_air"]=true,
    ["minecraft:void_air"]=true, ["minecraft:water"]=true,
    [""]=true,
}
function M.isPassable(name)
    if name == nil then return true end
    return PASSABLE[name] == true
end

function M.isOre(name)
    return type(name) == "string" and name:find("_ore", 1, true) ~= nil
end

-- ── Fuel ──────────────────────────────────────────────────
local FUEL_PATTERNS = { "coal", "charcoal", "coal_block", "lava_bucket", "blaze_rod" }
function M.isFuel(name) return matchAny(name, FUEL_PATTERNS) end

-- ── Zone classification (§6) ──────────────────────────────
-- GENESIS_MAT is checked first because some of its items (ingots, ender items)
-- are processed forms we want routed to replication, not the generic ORES bin.
local GENESIS_PATTERNS = {
    "_ingot","ingot","redstone","ender_pearl","ender_eye","eye_of_ender",
    "computer","turtle","modem","diamond_pickaxe","glass_pane",
}
local ORE_PATTERNS = {
    "raw_iron","raw_gold","raw_copper","iron_ore","gold_ore","diamond",
    "emerald","redstone_ore","lapis","quartz","_ore","raw_block",
}
local BUILDING_PATTERNS = {
    "log","planks","cobblestone","_stone","stone","glass","sand","gravel",
    "dirt","stick","chest","furnace","cobbled_deepslate",
}

function M.isGenesisMat(name)  return matchAny(name, GENESIS_PATTERNS)  end
function M.isBuildingMat(name) return matchAny(name, BUILDING_PATTERNS) end

-- Route an item name to its storage zone. Order matters: fuel and genesis win
-- over the broad ore/building patterns.
function M.zoneFor(name)
    if M.isFuel(name)        then return "FUEL"         end
    if M.isGenesisMat(name)  then return "GENESIS_MAT"  end
    if M.isOre(name) or matchAny(name, ORE_PATTERNS) then return "ORES" end
    if M.isBuildingMat(name) then return "BUILDING_MAT" end
    return "ORES"  -- safe default: anything unknown goes to the ore bin
end

-- Strip namespace + deepslate/nether prefixes for display & tally keys.
function M.normalizeOreName(name)
    if type(name) ~= "string" then return "unknown" end
    local n = name:match(":(.+)") or name
    n = n:gsub("_ore$", "")
    n = n:gsub("^deepslate_", ""):gsub("^nether_", "")
    n = n:gsub("^raw_", "")
    return n
end

return M
