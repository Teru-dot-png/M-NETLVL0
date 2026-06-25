-- /onet/turtle/tasks/task.lua
-- Base Task object (Overmind model). A Task is an atomic, composable unit of
-- work with an explicit termination condition (isWorking). Tasks chain via
-- .parent: when a task finishes it falls back to its parent, so a role can
-- express "dump, THEN resume mining" as task_mine with parent = task_dump.
--
-- Subclasses override:
--   :isValidTarget()  -> is the target still meaningful?
--   :work()           -> do ONE chunk of work; set self.done=true when finished;
--                        return true on progress/success, false on failure.

local Task = {}
Task.__index = Task

function Task.new(name, target, opts)
    local self = setmetatable({}, Task)
    self.name   = name or "task"
    self.target = target
    self.opts   = opts or {}
    self.parent = nil
    self.done   = false
    self.failed = false
    self.data   = {}
    return self
end

-- A target is valid by default. Override for coordinate/peripheral checks.
function Task:isValidTarget()
    return self.target ~= nil
end

-- The task should keep running while it is not done and its target is valid.
function Task:isWorking()
    return (not self.done) and (not self.failed) and self:isValidTarget()
end

-- One unit of work. Override. Base implementation just completes.
function Task:work()
    self.done = true
    return true
end

-- Drive the task one tick. Returns the task that should run next tick (self,
-- the parent, or nil when the whole chain is exhausted).
function Task:run()
    if self:isWorking() then
        local ok = self:work()
        if ok == false then self.failed = true end
        return self
    end
    return self.parent  -- fall back up the chain (nil = idle)
end

-- Chain another task to run after this one finishes.
function Task:fork(child)
    child.parent = self
    return child
end

return Task
