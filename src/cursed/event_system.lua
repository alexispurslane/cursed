--- Central event system — a publish/subscribe hub for cursed.
---
--- A traditional hook-list model: a table mapping `{ event_name: string
--- = [fns] }`. All handlers receive varargs. `emit(name, args...)`
--- looks up the list of registered functions for `name` and calls each
--- one as `fn(editor, args...)` in registration order. Errors inside a
--- handler are logged but do not abort the dispatch — every remaining
--- handler still runs.
---
--- Each handler runs in its own coroutine, so handlers can call
--- `async.await()` to suspend themselves waiting for other events or
--- lane replies without blocking the rest of the event dispatch.
---
--- Reentrancy: a handler that re-emits the same event name increments
--- a per-event depth counter. If depth exceeds MAX_REENTRANCY (10),
--- the re-emit is logged and dropped as a likely infinite loop.
---
--- The event system is reachable from the editor as
--- `editor.event_system`, so a handler running inside one event can
--- re-enter the hub and emit further events (`editor.event_system:emit(...)`)
--- if needed.

local log = require("cursed.log")

local MAX_REENTRANCY = 10

---@class EventSystem
---@field _editor table owning editor; passed as the first argument to every handler
---@field _handlers table<string, function[]> event_name → ordered handler list
---@field _depth table<string, integer> reentrancy depth counter per event name
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
        _depth = {},
    }, EventSystem)
end

--- Register a handler that only fires when the currently focused view
--- has a mode with the given name. Returns the wrapper so it can be
--- removed later via `off`.
---@param mode_name string mode name to scope to
---@param name string event name
---@param fn fun(view: View, editor: Editor, ...) handler (receives view as first arg instead of editor)
---@return function wrapper (pass to off to remove)
function EventSystem:on_mode(mode_name, name, fn)
    local wrapper = function(editor, ...)
        local view = editor:focused_view()
        local mode = view and view:top_mode()
        if mode and mode.name == mode_name then
            fn(view, editor, ...)
        end
    end
    return self:on(name, wrapper)
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

    -- Reentrancy guard: per-event depth counter. Handlers can re-emit
    -- the same event (e.g. post_command_hook within post_command_hook)
    -- up to MAX_REENTRANCY levels deep before we treat it as a loop.
    local depth = (self._depth[name] or 0) + 1
    if depth > MAX_REENTRANCY then
        log.error("event_system", "reentrant emit blocked", {
            event = name,
            depth = depth,
        })
        return
    end
    self._depth[name] = depth

    -- Capture varargs into a stable table so the inner coroutine
    -- functions can reference them. In Lua, `...` inside a non-vararg
    -- function is a syntax error, so we must pack/unpack explicitly.
    local nargs = select("#", ...)
    local args = { ... }

    local editor = self._editor
    for i = 1, #fns do
        -- Run each handler in its own coroutine so handlers can
        -- async.await() on other events or lane communication.
        local fn = fns[i]
        local co = coroutine.create(function()
            fn(editor, unpack(args, 1, nargs))
        end)
        local ok, err = coroutine.resume(co)
        if not ok then
            log.error("event_system", "handler error", {
                event = name,
                error = tostring(err),
            })
        end
        -- If the coroutine suspended (called async.await), it will
        -- be resumed later when the awaited event fires. We don't
        -- need to track it — the async token's one-shot handler
        -- holds a reference to the coroutine.
    end

    -- Decrement depth; clear key when back to zero.
    local new_depth = depth - 1
    if new_depth == 0 then
        self._depth[name] = nil
    else
        self._depth[name] = new_depth
    end
end

return EventSystem
