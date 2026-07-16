--- Lane module registry.
---
--- Each lane-facing client module registers itself here via
--- `require("cursed.lane_registry").register(LANE_IDX, M)`,
--- typically at the bottom of the module file. This lets main.lua
--- iterate over all registered modules to call setup/reinitialize
--- uniformly instead of hardcoding each module's lifecycle calls.
---
--- === Lane Client Module Interface ===
---
--- Every module that self-registers via `.register()` should conform to
--- this interface.  All methods are optional; a minimal client only
--- needs `drain_inbox`.  The registry's iterators (`each`, `setup_all`,
--- `drain_all`, `total_pending`) and main.lua's lane-death handler call
--- whichever methods exist on each module.
---
---   setup(ss, es)
---       Initialize the module at startup.  Receives the SharedState
---       ffi cdata and the event system.  Called exactly once from
---       `setup_all()` after all lane threads are spawned.
---
---   reinitialize(ss, editor, es)
---       Post-lane-crash recovery.  Restores references (typically the
---       SharedState pointer, which is re-mmap'd by the restarted lane
---       thread) and re-queues any state the lane needs to resume
---       operation (e.g. re-sending language identifiers for open
---       views, re-spawning subprocesses).  Called by main.lua's
---       lane_dead handler AFTER flush_pending and the C-level
---       restart_lane_thread.
---
---   drain_inbox(editor)
---       Drain the lane's ring buffer inbox, dispatching each message
---       to the appropriate handler.  Most modules implement this by
---       calling `drain_generic(ss, inbox, editor, handlers)` from this
---       very module.  Called by the editor's main loop on every
---       iteration (via `drain_all`) and also on specific lanes when
---       synchronously waiting (e.g. hl_client's drain for sync
---       highlighting).
---
---   flush_pending()
---       Emit synthetic errors (or otherwise clean up) for every
---       in-flight operation that was pending toward a now-dead lane.
---       Called ONCE by main.lua's lane_dead handler BEFORE
---       reinitialize, so the module can fail outstanding promises
---       before the lane restarts.
---
---   pending_count()
---       Return the number of outstanding operations this module is
---       tracking.  Used by headless test runs (main.lua's drain loop)
---       to know when the system has quiesced.

local M = {}
local _lanes = {}  -- [lane_idx] = module_table
local _by_lane = {} -- sorted list for deterministic iteration

function M.register(lane_idx, mod)
	_lanes[lane_idx] = mod
	table.insert(_by_lane, { lane_idx = lane_idx, mod = mod })
	table.sort(_by_lane, function(a, b)
		return a.lane_idx < b.lane_idx
	end)
end

function M.get(lane_idx)
	return _lanes[lane_idx]
end

--- Iterate registered modules in lane_idx order.
--- Returns an iterator suitable for `for lane_idx, mod in reg.each() do`.
function M.each()
	local i = 0
	return function()
		i = i + 1
		local entry = _by_lane[i]
		if entry then
			return entry.lane_idx, entry.mod
		end
	end
end

--- Call setup(ss, es) on every registered module.
function M.setup_all(ss, es)
	for _, mod in pairs(_lanes) do
		if mod.setup then
			mod.setup(ss, es)
		end
	end
end

--- Call flush_pending() for a specific lane.
function M.flush_pending(lane_idx)
	local mod = _lanes[lane_idx]
	if mod and mod.flush_pending then
		mod.flush_pending()
	end
end

--- Call reinitialize(ss, editor, es) for a specific lane.
function M.reinitialize(lane_idx, ss, editor, es)
	local mod = _lanes[lane_idx]
	if mod and mod.reinitialize then
		mod.reinitialize(ss, editor, es)
	end
end

--- Drain all messages from a ring buffer, dispatching each to the
--- matching handler in `handlers` (a msg.type → function table).
--- Handlers receive (msg, editor, ss) and are responsible for freeing
--- malloc'd payloads.
---@param ss SharedState
---@param inbox any  ring buffer (a RingBuf* ffi cdata)
---@param editor table
---@param handlers table<integer, fun(msg: table, editor: table, ss: table)>
function M.drain_generic(ss, inbox, editor, handlers)
	local msg = ss:pop(inbox)
	while msg ~= nil do
		editor.event_system:emit("ring_buffer_message", msg.type, msg)
		local handler = handlers[msg.type]
		if handler then
			handler(msg, editor, ss)
		end
		msg = ss:pop(inbox)
	end
end

--- Call drain_inbox(editor) on every registered module that has one.
function M.drain_all(editor)
	for _, mod in pairs(_lanes) do
		if mod.drain_inbox then
			mod.drain_inbox(editor)
		end
	end
end

--- Sum all registered pending_count() values.
function M.total_pending()
	local count = 0
	for _, mod in pairs(_lanes) do
		if mod.pending_count then
			count = count + mod.pending_count()
		end
	end
	return count
end

return M
