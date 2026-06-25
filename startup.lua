-- /startup.lua
-- O-NET V2 entry point. Detects whether this computer is a turtle or the
-- overseer and loads the matching boot module. This single file is what every
-- replicated turtle runs on power-on (Genesis copies the whole /onet tree +
-- this startup), so the dispatch must be trivial and dependency-free.

if turtle then
    shell.run("/onet/boot_turtle.lua")
else
    shell.run("/onet/boot_overseer.lua")
end
