--- Central event system — a publish/subscribe hub for cursed.
---
--- A traditional hook-list model: a table mapping `{ event_name: string
--- = [fns] }`. All handlers receive varargs. `emit(name, args...)`
--- looks up the list of registered functions for `name` and calls each
--- one as `fn(editor, args...)` in registration order. Errors inside a
--- handler are logged but do not abort the dispatch — every remaining
--- handler still runs.
---
--- The event system is reachable from the editor as
--- `editor.event_system`, so a handler running inside one event can
--- re-enter the hub and emit further events (`editor.event_system:emit(...)`)
--- if needed.
---
--- Recursion is the caller's responsibility: handlers that emit the
--- same event they're handling will recurse. The system itself imposes
--- no reentrancy guard, so trivial infinite loops are possible; trace
--- your emit chains if you suspect one.

local log = require("cursed.log")

---@class EventSystem
---@field _editor table owning editor; passed as the first argument to every handler
---@field _handlers table<string, function[]> event_name → ordered handler list
local EventSystem = {}
EventSystem.__index = EventSystem

--- Create a new EventSystem bound to an editor.
--- The editor is forwarded as the first argument to every handler so
--- handlers don't have to thread it through their own call sites.
---@param editor Editor
---@return EventSystem
function EventSystem.new(editor)
    return setmetatable({
        _editor = editor,
        _handlers = {},
    }, EventSystem)
end

--- Register a handler for an event.
--- Handlers are called as `fn(editor, ...)` in registration order.
---@param name string event name
---@param fn function handler
function EventSystem:on(name, fn)
    local fns = self._handlers[name]
    if fns == nil then
        fns = {}
        self._handlers[name] = fns
    end
    fns[#fns + 1] = fn
    return fn
end

--- Remove a previously-registered handler. No-op if the handler isn't
--- registered for the event.
---@param name string event name
---@param fn function handler to remove
function EventSystem:off(name, fn)
    local fns = self._handlers[name]
    if fns == nil then
        return
    end
    for i = 1, #fns do
        if fns[i] == fn then
            table.remove(fns, i)
            return
        end
    end
end

--- Emit an event. Every registered handler is called in registration
--- order as `fn(editor, ...)`. Errors in a handler are logged and do
--- not abort the dispatch — every remaining handler still runs.
---@param name string event name
---@param ... any payload forwarded to each handler after the editor
function EventSystem:emit(name, ...)
    local fns = self._handlers[name]
    if fns == nil then
        return
    end
    local editor = self._editor
    for i = 1, #fns do
        local ok, err = pcall(fns[i], editor, ...)
        if not ok then
            log.error("event_system", "handler error", {
                event = name,
                error = tostring(err),
            })
        end
    end
end

return EventSystem
