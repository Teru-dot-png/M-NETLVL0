-- /onet/lib/log.lua  (SHARED — byte-identical on turtle + overseer)
-- Tagged logging. Every state transition / craft / build action calls this.
-- Kept tiny on purpose: it is the one dependency every other module pulls in.

local M = {}

-- Per-tag colour so the cockpit / shell scan reads at a glance.
local TAG_COLOR = {
    BOOT="cyan", NAV="lightBlue", MINE="lime", FUEL="orange", DUMP="yellow",
    NET="white", PUSH="magenta", SCAN="green", BUILD="brown", GENESIS="purple",
    ALERT="red", ROLE="cyan", OVERSEER="cyan",
}

-- log("NAV", "stuck at (12,64,-8)") -> "[NAV] stuck at (12,64,-8)"
function M.log(tag, msg)
    tag = tostring(tag or "?")
    local line = string.format("[%s] %s", tag, tostring(msg))
    -- term colours only exist on a real CC computer; guard for unit tests.
    if term and term.isColor and term.isColor() then
        local cname = TAG_COLOR[tag] or "white"
        local col   = colors and colors[cname] or nil
        if col then
            local prev = term.getTextColor()
            term.setTextColor(col)
            print(line)
            term.setTextColor(prev)
            return line
        end
    end
    print(line)
    return line
end

return M
