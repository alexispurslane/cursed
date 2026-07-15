--- Task Lane — off-thread bytecode evaluation.
---
--- Owns a single pthread + lua_State (spawned from
--- main.c::task_lane_thread). Receives string.dump'd Lua functions
--- with JSON-encoded args, executes them, and sends back JSON-encoded
--- results. Runs entirely off the main thread so CPU-heavy computation
--- (e.g. word count, linting) doesn't block UI.
---
--- Event source on its kqueue (task_kq_fd):
---   1. EVFILT_USER (ident 1) — main pushed a message to outbox_task
---      (TASK_SUBMIT / SHUTDOWN). Ring_push triggers it.
---
--- Main submits work through outbox_task and receives results via
--- inbox_task, re-emitting each as a `task_result:<task_id>` event
--- on the editor event bus.
---
--- This module is loaded as a top-level chunk (twin of proc_lane.lua /
--- io_lane.lua): its body is the lane's main loop, not a library.

local ffi = require("ffi")
local log = require("cursed.log")
local ss = require("cursed.shared").SharedState.from_global()
local constants = require("cursed.shared")
local json = require("cursed.json_ffi")
local Kqueue = require("cursed.kqueue").Kqueue
local kq_ffi = require("cursed.kqueue_ffi")

local task_kq = Kqueue.wrap(tonumber(ss._ptr.lane_kq_fds[constants.LANE_IDX_TASK]))
task_kq:add_wake(assert(tonumber(ss._ptr.outboxes[constants.LANE_IDX_TASK].wake_ident)))

log.configure({ level = "info", output = "/tmp/cursed.log" })
log.info("task_lane", "started")

----------------------------------------------------------------------------------------------------
-- Inbound reports (lane → main). Lane allocates; main frees after pop.
----------------------------------------------------------------------------------------------------

--- Push a JSON-encoded task result to the main lane's inbox.
--- Ownership of task_result + its result pointer transfers to main.
---@param task_id integer
---@param result_json string  JSON-encoded result object
---@param is_error boolean    true if the result represents an error
local function send_result(task_id, result_json, is_error)
	local out = ffi.cast("struct TaskResult *", ffi.C.calloc(1, ffi.sizeof("struct TaskResult")))
	out.task_id = task_id
	out.is_error = is_error and 1 or 0
	out.result_len = #result_json
	local copy = ffi.C.malloc(#result_json)
	if copy == nil then
		error("task_lane: out of memory allocating " .. #result_json .. " bytes for task result", 2)
	end
	ffi.copy(copy, result_json, #result_json)
	out.result = ffi.cast("uint8_t *", copy)
	ss:push(ss._ptr.inboxes[constants.LANE_IDX_TASK], { type = constants.MSG_TASK_RESULT, ptr = out })
end

----------------------------------------------------------------------------------------------------
-- outbox_task handlers (main → lane)
----------------------------------------------------------------------------------------------------

--- MSG_TASK_SUBMIT: load bytecode, decode args, execute, encode result.
--- The struct TaskSubmit is followed inline by bytecode_len bytes of
--- string.dump'd Lua then args_len bytes of JSON-encoded args. Lane
--- frees the struct after reading.
---@param msg Msg
local function handle_submit(msg)
	if msg.ptr == nil then
		return
	end
	local req = ffi.cast("struct TaskSubmit *", msg.ptr)
	local task_id = tonumber(req.task_id)
	local bc_len = tonumber(req.bytecode_len)
	local args_len = tonumber(req.args_len)
	---@cast task_id integer
	---@cast bc_len integer
	---@cast args_len integer

	local base = ffi.cast("const char *", req) + ffi.sizeof("struct TaskSubmit")
	local bc = ffi.string(base, bc_len)
	local args_json = ffi.string(base + bc_len, args_len)
	ffi.C.free(req)

	-- Decode payload: { requires = [...], args = {...} }
	local payload, derr = json.decode(args_json)
	if derr then
		log.warn("task_lane", "args decode failed", { task_id = task_id, error = derr })
		payload = {}
	end
	local requires = type(payload) == "table" and payload.requires or {}
	local args = type(payload) == "table" and payload.args or {}

	-- Pre-load required modules so the bytecode can reference them.
	for _, mod in ipairs(requires) do
		local ok, mod_err = pcall(require, mod)
		if not ok then
			send_result(
				task_id,
				json.encode({ success = false, error = "module '" .. mod .. "' not found: " .. tostring(mod_err) }),
				true
			)
			log.warn("task_lane", "require failed", { task_id = task_id, module = mod, error = tostring(mod_err) })
			return
		end
	end

	-- Run the bytecode
	local ok_fn, fn_or_err = pcall(loadstring, bc)
	if not ok_fn then
		send_result(
			task_id,
			json.encode({ success = false, error = "bytecode load failed: " .. tostring(fn_or_err) }),
			true
		)
		log.warn("task_lane", "bytecode load failed", { task_id = task_id, error = tostring(fn_or_err) })
		return
	end

	-- Execute the loaded function. Pass the args table as a single
	-- argument (the function signature is `function(args)`).
	local ok_ret, ret = xpcall(fn_or_err, debug.traceback, type(args) == "table" and args or {})
	if not ok_ret then
		local err_json, _ = json.encode({ success = false, error = tostring(ret) })
		send_result(task_id, err_json or '{"success":false,"error":"encode failed"}', true)
		log.warn("task_lane", "execution failed", { task_id = task_id, error = tostring(ret) })
		return
	end

	-- Encode the result as JSON.
	local result_json, jerr = json.encode({ success = true, result = ret })
	if result_json == nil then
		result_json = json.encode({ success = false, error = "result encode failed: " .. tostring(jerr) })
			or '{"success":false,"error":"encode failed"}'
	end
	send_result(task_id, result_json, result_json:find('"success":false') ~= nil)
	log.info("task_lane", "completed", { task_id = task_id })
end

----------------------------------------------------------------------------------------------------
-- Main loop: block on the lane kq; dispatch outbox_task messages.
----------------------------------------------------------------------------------------------------

while ss:running() do
    ss:heartbeat_set(constants.LANE_IDX_TASK)
	local events, n = task_kq:wait(1000)
	for i = 0, n - 1 do
		local ev = events[i]
		local f = tonumber(ev.filter)
		if f == kq_ffi.EVFILT_USER then
			-- outbox_task wake: drain all queued messages.
			local msg = ss:pop(ss._ptr.outboxes[constants.LANE_IDX_TASK])
			while msg ~= nil do
				xpcall(function()
					if msg.type == constants.MSG_TASK_SUBMIT then
						handle_submit(msg)
					elseif msg.type == constants.MSG_SHUTDOWN then
						log.info("task_lane", "shutdown received")
						return
					else
						log.warn("task_lane", "unknown message type", { type = msg.type })
					end
				end, function(e)
					log.error("task_lane", "unhandled error", {
						type = msg.type,
						error = tostring(e),
					})
				end)
				msg = ss:pop(ss._ptr.outboxes[constants.LANE_IDX_TASK])
			end
		end
	end
end
