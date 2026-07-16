--- IO lane main-side facade.
---
--- Pure IO: no editor dependency. Each send_* function pushes a message
--- to the IO lane outbox and returns an AsyncToken (or nil for
--- fire-and-forget operations). Owns its own pending ops table for
--- lane-death recovery.
---
--- Lifecycle:
---   setup(ss, es)       — called once from main.lua
---   send_<op>(...)      — push a request, return AsyncToken / nil
---   flush_pending()     — emit synthetic errors on lane death
---   reinitialize(ss, es) — restore refs after lane restart

local ffi = require("ffi")
local async = require("cursed.async")
local constants = require("cursed.shared")
local drain_generic = require("cursed.lane_registry").drain_generic
local log = require("cursed.log")

local M = {
	_ss = nil,  -- SharedState (for outbox push)
	_es = nil,  -- EventSystem (for async.token)
	_pending = {}, -- { [req_id] = true }
	_next_id = 1,  -- monotonic request id
}
local PREFIX = "file"
local LANE = constants.LANE_IDX_IO

--- All ops that produce response events. Used by flush_pending and
--- the MSG_FILE_ERROR handler to unblock any pending operation.
local OPS = { "load", "insert", "delete", "create", "mkdir",
              "chmod", "rename", "dirlist", "write" }

--- Emit `payload` on every known `file_<op>:<id>` event name.
--- Only the one async.token that's actually waiting will catch it.
---@param id integer
---@param payload table
local function emit_all(id, payload)
	for _, op in ipairs(OPS) do
		M._es:emit(PREFIX .. "_" .. op .. ":" .. tostring(id), payload)
	end
end

--- Wire the facade against SharedState + EventSystem.
--- Call once from main.lua after both are available.
---@param ss SharedState
---@param es EventSystem
function M.setup(ss, es)
	M._ss = ss
	M._es = es
	M._pending = {}
	M._next_id = 1
end

-- Each send_<op> function follows the same pattern:
--   1. id = M._next_id; M._next_id = id + 1
--   2. M._pending[id] = true
--   3. Build/alloc wire data, push to outbox
--   4. Return async.token(es, "file_<op>:" .. id, cleanup)
--   Fire-and-forget ops return nil.

--- Load a file via MSG_FILE_LOAD.
--- Returns AsyncToken resolving to { mmap=ptr, size=int } or { err=str }.
---@param filepath string
---@return AsyncToken
function M.send_file_load(filepath)
	local id = M._next_id
	M._next_id = id + 1
	M._pending[id] = true
	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_FILE_LOAD,
		arg = id,
		ptr = filepath,
	})
	return async.token(M._es, PREFIX .. "_load:" .. id, function()
		M._pending[id] = nil
	end)
end

--- Insert a file's contents at cursor via MSG_INSERT_FILE.
--- The lane performs the insert off-main; response is a confirmation.
--- Returns AsyncToken resolving to {} or { err=str }.
---@param filepath string
---@return AsyncToken
function M.send_insert_file(filepath)
	local id = M._next_id
	M._next_id = id + 1
	M._pending[id] = true
	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_INSERT_FILE,
		arg = id,
		ptr = filepath,
	})
	return async.token(M._es, PREFIX .. "_insert:" .. id, function()
		M._pending[id] = nil
	end)
end

--- Delete a file via MSG_FILE_DELETE (unlink(2)).
--- Returns AsyncToken resolving to {} or { err=str }.
---@param filepath string
---@return AsyncToken
function M.send_file_delete(filepath)
	local id = M._next_id
	M._next_id = id + 1
	M._pending[id] = true
	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_FILE_DELETE,
		arg = id,
		ptr = filepath,
	})
	return async.token(M._es, PREFIX .. "_delete:" .. id, function()
		M._pending[id] = nil
	end)
end

--- Create a file via MSG_FILE_CREATE (O_CREAT|O_EXCL — fails if exists).
--- Returns AsyncToken resolving to {} or { err=str }.
---@param filepath string
---@return AsyncToken
function M.send_file_create(filepath)
	local id = M._next_id
	M._next_id = id + 1
	M._pending[id] = true
	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_FILE_CREATE,
		arg = id,
		ptr = filepath,
	})
	return async.token(M._es, PREFIX .. "_create:" .. id, function()
		M._pending[id] = nil
	end)
end

--- Make a single directory via MSG_FILE_MKDIR (mkdir(2), NOT -p).
--- Returns AsyncToken resolving to {} or { err=str }.
---@param dirpath string
---@return AsyncToken
function M.send_mkdir(dirpath)
	local id = M._next_id
	M._next_id = id + 1
	M._pending[id] = true
	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_FILE_MKDIR,
		arg = id,
		ptr = dirpath,
	})
	return async.token(M._es, PREFIX .. "_mkdir:" .. id, function()
		M._pending[id] = nil
	end)
end

--- chmod(2) via MSG_FILE_CHMOD.
--- Mode is packed in low 9 bits; req_id above. Lane splits them back.
--- Returns AsyncToken resolving to {} or { err=str }.
---@param filepath string
---@param mode integer 9-bit mode (e.g. tonumber("0755",8) → 493)
---@return AsyncToken
function M.send_chmod(filepath, mode)
	local id = M._next_id
	M._next_id = id + 1
	M._pending[id] = true
	local packed = bit.bor(bit.lshift(id, 9), bit.band(mode, 0x1FF))
	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_FILE_CHMOD,
		arg = packed,
		ptr = filepath,
	})
	return async.token(M._es, PREFIX .. "_chmod:" .. id, function()
		M._pending[id] = nil
	end)
end

--- rename(2) via MSG_FILE_RENAME.
--- Builds a heap FileMoveReq{src_len,dst_len} + inline src/dst bytes.
--- Lane frees the struct after consuming.
--- Returns AsyncToken resolving to {} or { err=str }.
---@param src string absolute source path
---@param dst string absolute destination path
---@return AsyncToken
function M.send_rename(src, dst)
	local id = M._next_id
	M._next_id = id + 1
	M._pending[id] = true

	local req_size = ffi.sizeof("struct FileMoveReq") + #src + #dst
	local req = ffi.C.malloc(req_size)
	if req == nil then
		M._pending[id] = nil
		return async.resolved({ err = "malloc failed" })
	end
	local hdr = ffi.cast("struct FileMoveReq *", req)
	hdr.src_len = #src
	hdr.dst_len = #dst
	local payload = ffi.cast("char *", req) + ffi.sizeof("struct FileMoveReq")
	ffi.copy(payload, src, #src)
	ffi.copy(payload + #src, dst, #dst)

	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_FILE_RENAME,
		arg = id,
		ptr = req,
	})
	return async.token(M._es, PREFIX .. "_rename:" .. id, function()
		M._pending[id] = nil
	end)
end

--- List directory entries via MSG_FILE_DIRLIST.
--- Returns AsyncToken resolving to { entries = { {name, is_dir}, ... } }
--- or { err=str }.
---@param dirpath string absolute directory path
---@return AsyncToken
function M.send_dirlist(dirpath)
	local id = M._next_id
	M._next_id = id + 1
	M._pending[id] = true
	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_FILE_DIRLIST,
		arg = id,
		ptr = dirpath,
	})
	return async.token(M._es, PREFIX .. "_dirlist:" .. id, function()
		M._pending[id] = nil
	end)
end

--- Write a heap byte buffer to a file via MSG_FILE_WRITE.
--- Copies data bytes + filepath inline into a heap FileWriteReq.
--- Lane frees the struct after writing.
--- Returns AsyncToken resolving to {} or { err=str }.
---@param data_ptr cdata uint8_t*  heap-owned byte buffer
---@param data_len integer number of bytes
---@param filepath string destination path
---@return AsyncToken
function M.send_file_write(data_ptr, data_len, filepath)
	local id = M._next_id
	M._next_id = id + 1
	M._pending[id] = true

	local req_size = ffi.sizeof("struct FileWriteReq") + data_len + #filepath
	local req = ffi.C.malloc(req_size)
	if req == nil then
		M._pending[id] = nil
		return async.resolved({ err = "malloc failed" })
	end
	local hdr = ffi.cast("struct FileWriteReq *", req)
	hdr.src_len = data_len
	hdr.filepath_len = #filepath
	local payload = ffi.cast("uint8_t *", req) + ffi.sizeof("struct FileWriteReq")
	ffi.copy(payload, ffi.cast("uint8_t *", data_ptr), data_len)
	ffi.copy(payload + data_len, filepath, #filepath)

	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_FILE_WRITE,
		arg = id,
		ptr = req,
	})
	return async.token(M._es, PREFIX .. "_write:" .. id, function()
		M._pending[id] = nil
	end)
end

--- Save a buffer to its filepath via MSG_FILE_SAVE (mmap variant).
--- Fire-and-forget: no response token. The lane saves and pushes
--- MSG_FILE_SAVED (a plain status string, no req_id).
---@param buf Buffer  must have a filepath set
function M.send_file_save(buf)
	local c = require("cursed.posix_ffi").C
	local fp = buf:filepath()
	if fp == nil then
		return
	end

	local data, len, cap = buf:serialize_to_mmap()

	local req = ffi.cast("struct SaveRequest *", c.calloc(1, ffi.sizeof("struct SaveRequest")))
	if req == nil then
		ffi.C.munmap(data, cap)
		return
	end
	req.data = data
	req.data_len = len
	req.data_cap = cap

	local fp_buf = ffi.cast("char *", c.calloc(#fp + 1, 1))
	if fp_buf == nil then
		ffi.C.munmap(data, cap)
		c.free(req)
		return
	end
	ffi.copy(fp_buf, fp)
	req.filepath = fp_buf

	M._ss:push(M._ss._ptr.outboxes[LANE], {
		type = constants.MSG_FILE_SAVE,
		ptr = req,
	})
end

--- Convert a send_file_load payload into a Buffer (or nil + err).
--- Shared by the open_file and read_into_buffer flows.
---@param payload table {mmap, size} or {err}
---@param filepath string
---@return Buffer|nil
---@return string|nil err
function M.payload_to_buffer(payload, filepath)
	local Buffer = require("cursed.buffer").Buffer
	if payload.err then
		return nil, payload.err
	end
	local mmap_ptr = payload.mmap
	local file_size = payload.size
	if mmap_ptr == nil then
		local placeholder = Buffer.new()
		placeholder:set_filepath(filepath)
		return placeholder, nil
	end
	local psize = tonumber(ffi.C.sysconf(constants._SC_PAGESIZE)) or 4096
	local cap = file_size > 0 and bit.band(file_size + psize - 1, bit.bnot(psize - 1)) or psize
	local buf = Buffer.from_mmap(mmap_ptr, file_size, cap)
	buf:set_filepath(filepath)
	return buf, nil
end

--- Reserve the next request id without creating a token.
--- Used by open_file / open_file_background which manage their own
--- event listeners and need an id for the push + listener pair.
--- The id is still tracked in _pending so flush_pending covers it.
---@return integer req_id
function M.reserve_id()
	local id = M._next_id
	M._next_id = id + 1
	return id
end

--- Mark a reserved id as in-flight (called by open_file family).
---@param id integer
function M.track_pending(id)
	M._pending[id] = true
end

--- Clear a reserved id from pending tracking.
---@param id integer
function M.clear_pending(id)
	M._pending[id] = nil
end

--- Emit synthetic error events for every in-flight operation.
--- Called by main.lua's lane_dead handler BEFORE reinitialize.
function M.flush_pending()
	for id in pairs(M._pending) do
		emit_all(id, { err = "IO lane restarted" })
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

--- Restore shared state + event system after lane restart.
--- _next_id stays monotonic (no reuse).
---@param ss SharedState
---@param es EventSystem
function M.reinitialize(ss, _editor, es)
	-- flush_pending should have been called before us by lane_dead handler.
	M._ss = ss
	M._es = es
end

--- Drain the IO lane inbox: pop all messages and dispatch file-op
--- replies to the editor event bus.
---@param editor table
function M.drain_inbox(editor)
	if M._ss == nil then
		return
	end
	drain_generic(M._ss, M._ss._ptr.inboxes[LANE], editor, {
		[constants.MSG_FILE_LOADED_V2] = function(msg)
			if msg.ptr == nil then
				return
			end
			local hdr = ffi.cast("struct FileLoadReply *", msg.ptr)
			local req_id = tonumber(hdr.req_id) or 0
			---@cast req_id integer
			local file_size = tonumber(hdr.file_size) or 0
			local mmap_ptr = hdr.mmap_ptr
			ffi.C.free(msg.ptr)
			log.info("main", "file loaded v2", { req_id = req_id, size = file_size })
			editor.event_system:emit("file_load:" .. req_id, {
				mmap = mmap_ptr,
				size = file_size,
			})
		end,
		[constants.MSG_FILE_ERROR] = function(msg)
			local req_id = tonumber(msg.arg)
			local err_str = msg.ptr ~= nil and ffi.string(msg.ptr) or "<no message>"
			if msg.ptr ~= nil then
				ffi.C.free(msg.ptr)
			end
			if req_id and req_id ~= 0 then
				emit_all(req_id, { err = err_str })
				return
			end
			-- Legacy load error without req_id.
			editor.status_message = err_str
			log.error("main", "file load error", { error = err_str })
			local failed_view = nil
			for _, v in ipairs(editor.views) do
				if not v.file_loaded then
					failed_view = v
					break
				end
			end
			if failed_view ~= nil then
				editor.event_system:emit("file_load_error", failed_view, err_str)
			end
		end,
		[constants.MSG_FILE_DIRLIST_RESP] = function(msg)
			local req_id = tonumber(msg.arg) or 0
			---@cast req_id integer
			if msg.ptr == nil then
				editor.event_system:emit("file_dirlist:" .. req_id, { err = "null pointer in dirlist reply" })
				return
			end
			local hdr = ffi.cast("struct FileDirListResp *", msg.ptr)
			local count = tonumber(hdr.count) or 0
			local entries = {}
			if count > 0 then
				local header_size = ffi.sizeof("struct FileDirListResp")
				local entry_size = ffi.sizeof("struct FileDirEntry")
				local cursor = (ffi.cast("uint8_t *", msg.ptr)) + header_size
				for _ = 1, count do
					local entry_ptr = ffi.cast("struct FileDirEntry *", cursor)
					local nlen = tonumber(entry_ptr.name_len) or 0
					local name = ffi.string((ffi.cast("char *", cursor)) + entry_size, nlen)
					entries[#entries + 1] = {
						name = name,
						is_dir = tonumber(entry_ptr.is_dir) == 1,
					}
					cursor = cursor + entry_size + nlen
				end
			end
			ffi.C.free(msg.ptr)
			editor.event_system:emit("file_dirlist:" .. req_id, { entries = entries })
		end,
		[constants.MSG_FILE_SAVED] = function(msg)
			local saved_filepath = ffi.string(msg.ptr or "")
			ffi.C.free(msg.ptr)
			editor.status_message = "Wrote " .. saved_filepath
		end,
		[constants.MSG_FILE_INSERTED] = function(msg)
			local req_id = tonumber(msg.arg) or 0
			---@cast req_id integer
			if req_id ~= 0 then
				editor.event_system:emit("file_insert:" .. req_id, {})
			end
			local cv = editor:current_view()
			if cv and cv.file_loaded then
				cv.buffer:build_lines()
				cv:invalidate_cached_text()
				cv.pending_cursors = {}
				cv:update_cached_text(cv.buffer, 0)
			end
		end,
	})
end

require("cursed.lane_registry").register(LANE, M)
return M
