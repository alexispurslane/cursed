--- Coroutine-based async/await for event-bus-driven IO.
---
--- Usage:
---   local payload = async.await(editor:dirlist_async("/tmp"))
---   if payload.err then error(payload.err) end
---   for _, e in ipairs(payload.entries) do ... end
---
--- The token convention: any table with `_es` (EventSystem) and `_ev`
--- (event name string) is awaitable. Editor _async methods return these.
--- `await` yields the current coroutine and registers a one-shot event
--- handler; when the event fires, the coroutine is resumed with the
--- event payload as its return value.
---
--- Only call `await` from inside a coroutine (i.e., a keybinding handler
--- or background task wrapped by the dispatch layer). Calling from the
--- main thread is a fatal error.

---@class AsyncToken
---@field _es EventSystem
---@field _ev string
---@field _on_complete fun()?
---@field _resolved boolean?
---@field _payload table?

--- Yield the current coroutine until `token._ev` fires on `token._es`,
--- then return the event payload.
---
--- The one-shot handler auto-unsubscribes on first delivery. If the
--- event never fires, the coroutine stays suspended forever (no timeout
--- — this is cooperative; the main loop will eventually shut down and
--- orphaned coroutines are GC'd).
---
local async = {}

-- Counter for unique timer event names.
local _timer_id = 0

--- Suspend the current coroutine for `us` microseconds.
--- Uses Editor:schedule_after to create a deadline task that emits
--- a one-shot event, then async.awaits that event.
---
--- Must be called from inside a coroutine (keybinding handler,
--- background task, or headless -e chunk).
---
---@param editor Editor
---@param us integer microseconds to sleep
function async.sleep(editor, us)
    local co = coroutine.running()
    if co == nil then
        error("async.sleep called outside a coroutine", 2)
    end
    _timer_id = _timer_id + 1
    local token = async.token(editor.event_system, "timer:" .. _timer_id)
    editor:schedule_after(us, function()
        editor.event_system:emit(token._ev, true)
        return true -- remove task from queue
    end)
    async.await(token)
end

---@param token AsyncToken
---@return table payload event payload (keys vary by op: {entries}, {mmap,size}, {err}, {})
function async.await(token)
    -- Resolved tokens: the result is already known (e.g. minibuffer
    -- kmacro replay or value short-circuit). Return immediately.
    if token._resolved then
        if token._on_complete then
            token._on_complete()
        end
        return token._payload
    end

    local co = coroutine.running()
    if co == nil then
        error("async.await called outside a coroutine", 2)
    end

    local es = token._es
    local ev = token._ev

    local handler
    handler = es:on(ev, function(_, ...)
        es:off(ev, handler)
        -- Fire the on_complete hook (e.g. decrement _pending_ops_count)
        -- BEFORE resuming the coroutine, so the editor state is correct
        -- when the caller's code runs.
        if token._on_complete then
            token._on_complete()
        end
        coroutine.resume(co, ...)
    end)

    return coroutine.yield()
end

--- Build a pre-resolved token that async.await returns immediately.
--- Used when the result is already known (kmacro replay, value
--- short-circuit) and no event round-trip is needed.
---@param payload table
---@param on_complete? fun()
---@return AsyncToken
function async.resolved(payload, on_complete)
    return { _resolved = true, _payload = payload, _on_complete = on_complete }
end

--- Build a token from an EventSystem, event name, and optional
--- completion callback (e.g., editor._pending_ops_count decrement).
---@param es EventSystem
---@param ev string
---@param on_complete? fun()
---@return AsyncToken
function async.token(es, ev, on_complete)
    return { _es = es, _ev = ev, _on_complete = on_complete }
end

return async
