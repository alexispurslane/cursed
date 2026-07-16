--- Proc lane main-side facade.
---
--- The actual subprocess management (fork/exec/pipes/waiting) lives in
--- the proc lane (cursed.proc_lane). This module is the main-thread
--- handle to that lane: it mints monotonic procids, builds the wire
--- structs (ProcSpawnReq / ProcStdinReq / ProcKillReq), pushes them to
--- outbox_proc, and — crucially — wires the editor event bus so that
--- `process_in:<procid>` events become STDIN writes and inbox
--- MSG_PROC_OUTPUT/EXIT messages become `process_out:<procid>` events.
---
--- Lifecycle:
---   spawn(argv, opts) -> procid
---     - assigns a fresh procid
---     - registers editor.event_system:on("process_in:<procid>", fn)
---       whose fn(arg) forwards bytes to the lane (nil/false → EOF)
---       via send_stdin
---     - pushes MSG_PROC_SPAWN
---     - returns the procid
---     On spawn failure (lane can't fork/exec), main learns via the
---     inbox MSG_PROC_EXIT(FAILED) — spawn itself returns the procid.
---
---   send_stdin(procid, bytes)
---     - bytes is a string; nil/false → EOF (close child stdin)
---     - pushes MSG_PROC_STDIN (malloc'd copy; lane frees)
---
---   kill(procid, signal)
---     - pushes MSG_PROC_KILL (SIGTERM default); the authoritative
---       death notice (SIGNALED/EXITED) arrives when the child is reaped
---
---   on_proc_exit(procid)
---     - unregisters the `process_in:<procid>` listener (called by
---       main.lua's drain_proc_inbox on a TERMINAL EXIT)
---
--- For the inverse direction (lane → main), see drain_proc_inbox in
--- main.lua: it pops inbox_proc, frees malloc'd payloads, and emits
--- `process_out:<procid>` events with (kind, code) or (stream, bytes).

local ffi = require("ffi")
local log = require("cursed.log")
local json = require("cursed.json_ffi")
local constants = require("cursed.shared")
local drain_generic = require("cursed.lane_registry").drain_generic

local M = {}

-- SharedState (set once from main.lua via setup).
local function ss()
    return M._ss
end

-- Default signals.
local SIGTERM = 15

-- procid → registered `process_in:<procid>` handler (for :off on exit).
local _in_handlers = {} ---@type table<integer, function>

--- Build + push a ProcSpawnReq. Takes ownership of nothing on the Lua
--- side; the lane frees the malloc'd buf + spec bytes.
---@param procid integer
---@param spec_json string
local function push_spawn(procid, spec_json)
    local s = ss()
    if s == nil then
        return
    end
    local total = ffi.sizeof("struct ProcSpawnReq") + #spec_json
    local buf = ffi.C.calloc(1, total)
    if buf == nil then
        log.warn("proc", "spawn calloc failed", { procid = procid })
        return
    end
    local req = ffi.cast("struct ProcSpawnReq *", buf)
    req.procid = procid
    req.spec_len = #spec_json
    local base = ffi.cast("char *", buf) + ffi.sizeof("struct ProcSpawnReq")
    ffi.copy(base, spec_json, #spec_json)
    s:push(s._ptr.outboxes[constants.LANE_IDX_PROC], { type = constants.MSG_PROC_SPAWN, ptr = buf })
end

--- Build + push a ProcStdinReq. len==0 → EOF (ptr NULL). Ownership of
--- the malloc'd byte copy transfers to the lane.
---@param procid integer
---@param bytes string|nil|false  nil/false → close stdin (EOF)
local function push_stdin(procid, bytes)
    local s = ss()
    if s == nil then
        return
    end
    local buf = ffi.C.calloc(1, ffi.sizeof("struct ProcStdinReq"))
    if buf == nil then
        return
    end
    local req = ffi.cast("struct ProcStdinReq *", buf)
    req.procid = procid
    if bytes == nil or bytes == false then
        req.len = 0
        req.ptr = nil
    else
        local n = #bytes
        req.len = n
        if n > 0 then
            local copy = ffi.C.malloc(n)
            if copy ~= nil then
                ffi.copy(copy, bytes, n)
                req.ptr = ffi.cast("uint8_t *", copy)
            else
                req.len = 0
                req.ptr = nil
            end
        else
            req.ptr = nil
        end
    end
    s:push(s._ptr.outboxes[constants.LANE_IDX_PROC], { type = constants.MSG_PROC_STDIN, ptr = buf })
end

--- Build + push a ProcKillReq.
---@param procid integer
---@param signal integer
local function push_kill(procid, signal)
    local s = ss()
    if s == nil then
        return
    end
    local buf = ffi.C.calloc(1, ffi.sizeof("struct ProcKillReq"))
    if buf == nil then
        return
    end
    local req = ffi.cast("struct ProcKillReq *", buf)
    req.procid = procid
    req.signal = signal
    s:push(s._ptr.outboxes[constants.LANE_IDX_PROC], { type = constants.MSG_PROC_KILL, ptr = buf })
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

--- Wire the facade against the SharedState + editor (called once from
--- main.lua after the inbox wake is registered). The editor is needed
--- so spawn can register per-procid `process_in:<id>` listeners.
---@param shared_state SharedState
---@param es table
function M.setup(shared_state, es)
    M._ss = shared_state
    M._es = es
    M._pending = {}
    M._next_procid = 1
end

--- Spawn a subprocess. argv is the execvp argv (argv[1..] are args).
--- opts.env is a string→string table (merged into the child env);
--- opts.cwd is an optional working directory; opts.buffer_bytes caps
--- how much stdout/stderr the lane accumulates before flushing a
--- single chunk to main (default 8192; 0 = flush every read, i.e. no
--- buffering). Larger values protect main from chatty programs at the
--- cost of output latency.
---
--- Returns an AsyncToken whose `.id` field contains the assigned procid
--- (monotonic, available immediately). The token resolves on the
--- `process_start:<procid>` event: on success the payload is
--- `{ procid = procid }`; on failure it is `{ err = "spawn failed" }`.
--- Callers that don't need spawn confirmation can ignore the token and
--- use `token.id` for immediate procid access.
---@param argv string[]|table  argv[0] is the program
---@param opts table|nil  { env?: table<string,string>, cwd?: string, buffer_bytes?: integer }
---@return AsyncToken token  token.id is the procid
function M.spawn(argv, opts)
    opts = opts or {}
    local procid = M._next_procid
    M._next_procid = procid + 1
    M._pending[procid] = true

    -- Register the process_in:<procid> listener that forwards STDIN.
    -- bytes (string) → write; nil/false → EOF.
    local name = "process_in:" .. procid
    local fn = function(_editor, bytes)
        push_stdin(procid, bytes)
    end
    _in_handlers[procid] = fn
    if M._es then
        M._es:on(name, fn)
    end

    local spec = {
        argv = argv,
        env = opts.env,
        cwd = opts.cwd,
        buffer_bytes = opts.buffer_bytes,
    }
    local spec_json, err = json.encode(spec)
    if spec_json == nil then
        log.warn("proc", "spawn spec encode failed", { procid = procid, error = err })
        M._pending[procid] = nil
        local token = setmetatable({ id = procid, _resolved = true, _payload = { err = "spec encode failed" } }, {})
        return token
    end
    push_spawn(procid, spec_json)
    log.info("proc", "spawn requested", { procid = procid, argv0 = argv[1] })
    local async = require("cursed.async")
    local token = async.token(M._es, "process_start:" .. procid, function()
        M._pending[procid] = nil
    end)
    token.id = procid
    return token
end

--- Send bytes to a process's STDIN. nil/false closes stdin (EOF).
---@param procid integer
---@param bytes string|nil|false
function M.send_stdin(procid, bytes)
    push_stdin(procid, bytes)
end

--- Deliver a signal to a process (SIGTERM by default). Fire-and-forget;
--- the authoritative SIGNALED/EXITED arrives later when the pipes EOF
--- and the child is reaped.
---@param procid integer
---@param signal integer|nil  default 15 (SIGTERM)
function M.kill(procid, signal)
    push_kill(procid, signal or SIGTERM)
end

--- Unregister the `process_in:<procid>` listener. Called by
--- drain_proc_inbox on a TERMINAL exit (exited/signaled/failed) so the
--- bus stops accepting STDIN for a dead procid. Safe to call repeatedly.
---@param procid integer
function M.on_proc_exit(procid)
    local fn = _in_handlers[procid]
    if fn ~= nil and M._es then
        M._es:off("process_in:" .. procid, fn)
    end
    _in_handlers[procid] = nil
end

--- Clear a pending operation (called by main.lua on EXIT/TERM).
---@param procid integer
function M.clear(procid)
    M._pending[procid] = nil
end

--- Shutdown: best-effort SIGTERM of every live proc + listener detach.
--- Normally the lane handles process teardown on MSG_SHUTDOWN; this
--- only clears the main-side listener registry.
function M.shutdown()
    if M._es then
        for procid, fn in pairs(_in_handlers) do
            M._es:off("process_in:" .. procid, fn)
        end
    end
    _in_handlers = {}
end

--- Emit synthetic resolution events for every still-pending spawn when
--- the proc lane dies, so awaiting coroutines resume. Emits both
--- process_start (for spawn tokens) and process_out (for backwards
--- compat with lifecycle listeners).
function M.flush_pending()
    for procid in pairs(M._pending) do
        M._es:emit("process_start:" .. tostring(procid), { err = "lane restarted" })
        M._es:emit("process_out:" .. tostring(procid), "failed", 0)
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

--- Reinitialize after a lane restart. All child processes died with the
--- lane; clean up main-side listener state.
---@param shared_state SharedState
---@param _editor table
---@param es table
function M.reinitialize(shared_state, _editor, es)
    M._ss = shared_state
    M._es = es
    M.shutdown()
    -- _next_procid stays monotonic; don't reset it.
end

--- Terminal exit kind codes (mirror proc_lane.lua / shared_state.h).
local PROC_KIND_EXITED = 0
local PROC_KIND_SIGNALED = 1
local PROC_KIND_FAILED = 2

--- Map a kind code to the event tag.
---@param kind integer
---@return string
local function proc_kind_tag(kind)
	if kind == PROC_KIND_EXITED then
		return "exited"
	elseif kind == PROC_KIND_SIGNALED then
		return "signaled"
	elseif kind == PROC_KIND_FAILED then
		return "failed"
	end
	return "unknown"
end

--- Drain the proc lane inbox: pop all messages and emit the
--- corresponding events on the editor's event bus.
---@param editor table
function M.drain_inbox(editor)
	drain_generic(M._ss, M._ss._ptr.inboxes[constants.LANE_IDX_PROC], editor, {
		[constants.MSG_PROC_OUTPUT] = function(msg)
			if msg.ptr ~= nil then
				local out = ffi.cast("struct ProcOutput *", msg.ptr)
				local procid = tonumber(out.procid)
				local stream = tonumber(out.stream)
				local len = tonumber(out.len)
				local ptr = out.ptr
				---@cast procid integer
				---@cast stream integer
				---@cast len integer
				local bytes = ""
				if ptr ~= nil and len > 0 then
					bytes = ffi.string(ptr, len)
				end
				ffi.C.free(ptr)
				ffi.C.free(out)
				local stream_tag = (stream == 2) and "stderr" or "stdout"
				editor.event_system:emit("process_out:" .. procid, stream_tag, bytes)
			end
		end,
		[constants.MSG_PROC_EXIT] = function(msg)
			if msg.ptr ~= nil then
				local e = ffi.cast("struct ProcExit *", msg.ptr)
				local procid = tonumber(e.procid)
				local kind = tonumber(e.kind)
				local code = tonumber(e.code)
				---@cast procid integer
				---@cast kind integer
				---@cast code integer
				M.clear(procid)
				M.on_proc_exit(procid)
				editor.event_system:emit("process_out:" .. procid, proc_kind_tag(kind), code)
				ffi.C.free(msg.ptr)
			end
		end,
		[constants.MSG_PROC_SPAWNED] = function(msg)
			if msg.ptr ~= nil then
				local s = ffi.cast("struct ProcSpawned *", msg.ptr)
				local procid = tonumber(s.procid)
				local ok = tonumber(s.ok)
				---@cast procid integer
				---@cast ok integer
				ffi.C.free(msg.ptr)
				if ok ~= 0 then
					editor.event_system:emit("process_start:" .. procid, { procid = procid })
				else
					M.clear(procid)
					M.on_proc_exit(procid)
					editor.event_system:emit("process_start:" .. procid, { err = "spawn failed" })
					editor.event_system:emit("process_out:" .. procid, "failed", 0)
				end
			end
		end,
	})
end

require("cursed.lane_registry").register(constants.LANE_IDX_PROC, M)
return M
