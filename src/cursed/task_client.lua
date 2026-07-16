--- Task lane main-side facade.
---
--- Sends bytecode functions to the task lane for off-thread evaluation.
--- Returns an AsyncToken that resolves with the JSON-decoded result
--- when the task completes.
---
--- Usage (from a coroutine, e.g. keybinding handler):
---   local result = async.await(task_client.send_task(function(args)
---     return { words = count(args.text) }
---   end, { text = buffer_text }))
---   -- result is { success = true, result = { words = 42 } }
---   -- or { success = false, error = "..." }

local ffi = require("ffi")
local log = require("cursed.log")
local json = require("cursed.json_ffi")
local constants = require("cursed.shared")
local async = require("cursed.async")

local M = {}

---@return SharedState|nil
local function ss()
	return M._ss
end

--- Returns true once setup() has been called (task lane is available).
function M.is_setup()
	return M._ss ~= nil
end

--- Wire the facade against SharedState + EventSystem.
---@param shared_state SharedState
---@param es table
function M.setup(shared_state, es)
	M._ss = shared_state
	M._es = es
	M._pending = {}
	M._next_task_id = 1
end

--- Send a bytecode function + args to the task lane.
--- Returns an AsyncToken that resolves with:
---   { success = true, result = <return value> }
---   { success = false, error = "<error message>" }
---
--- The function must be self-contained (no upvalues — string.dump
--- strips them). Pass all state explicitly in `args`.
--- Args are a flat JSON-encodable table (strings, numbers, booleans,
--- nil, and arrays/tables of those). No pointers or userdata.
---
--- opts.requires is a list of module names (e.g. `{"cursed.word_count"}`)
--- that are `require`'d in the task lane's lua_State before the bytecode
--- runs. Use this when the function references project modules that
--- wouldn't otherwise be in scope.
---
---@param fn function
---@param args? table
---@param opts? { requires?: string[] }
---@return AsyncToken
function M.send_task(fn, args, opts)
	local s = ss()
	if s == nil then
		return async.resolved({ success = false, error = "not setup" })
	end

	local task_id = M._next_task_id
	M._next_task_id = task_id + 1
	M._pending[task_id] = true

	local bc = string.dump(fn, true)
	local requires = (opts and opts.requires) or {}
	local args_json, jerr = json.encode({ requires = requires, args = args or {} })
	if args_json == nil then
		return async.resolved({ success = false, error = "args encode failed: " .. tostring(jerr) })
	end

	---@cast task_id integer
	local total = ffi.sizeof("struct TaskSubmit") + #bc + #args_json
	local buf = ffi.C.calloc(1, total)
	if buf == nil then
		return async.resolved({ success = false, error = "calloc failed" })
	end
	local req = ffi.cast("struct TaskSubmit *", buf)
	req.task_id = task_id
	req.bytecode_len = #bc
	req.args_len = #args_json
	local base = ffi.cast("char *", buf) + ffi.sizeof("struct TaskSubmit")
	ffi.copy(base, bc, #bc)
	ffi.copy(base + #bc, args_json, #args_json)

	s:push(s._ptr.outboxes[constants.LANE_IDX_TASK], { type = constants.MSG_TASK_SUBMIT, ptr = buf })

	log.info("task", "submitted", { task_id = task_id, bc_len = #bc, args_len = #args_json })

	return async.token(M._es, "task_result:" .. tostring(task_id))
end

--- Remove a task from the pending set (called by main.lua on result).
---@param task_id integer
function M.clear(task_id)
	M._pending[task_id] = nil
end

--- Emit synthetic error events for all still-pending tasks after
--- a task lane restart, so awaiting coroutines resume.
function M.flush_pending()
	for task_id in pairs(M._pending) do
		M._es:emit("task_result:" .. tostring(task_id), { success = false, error = "task lane restarted" })
	end
	M._pending = {}
end

---@return integer
function M.pending_count()
	local n = 0
	for _ in pairs(M._pending) do
		n = n + 1
	end
	return n
end

--- Reinitialize after a lane restart. The task lane is stateless
--- (fire-and-forget bytecode). Just restore the shared state reference.
---@param shared_state SharedState
---@param _editor table
---@param _es table
function M.reinitialize(shared_state, _editor, _es)
	M._ss = shared_state
	M._es = _es
	-- next_task_id stays monotonic; don't reset.
end

require("cursed.lane_registry").register(constants.LANE_IDX_TASK, M)
return M
