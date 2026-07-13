--- Main entry point for the cursed editor.
---
--- Initializes terminal, creates an Editor, loads the file from CLI arg,
--- and runs the main event loop.

local ffi = require("ffi")
local bit = require("bit")
local tb = require("cursed.tb")
local shared = require("cursed.shared")
local kq_ffi = require("cursed.kqueue_ffi")
local Kqueue = require("cursed.kqueue").Kqueue
local pffi = require("cursed.posix_ffi")
local c = pffi.C
local keybind = require("cursed.keybind")
local WhichKey = require("cursed.whichkey")
local commands = require("cursed.commands")
local Editor = require("cursed.editor")
local View = require("cursed.view").View
local Buffer = require("cursed.buffer").Buffer
local ColorScheme = require("cursed.colorscheme")
local find_file = require("cursed.find_file")
local log = require("cursed.log")
local profile = require("cursed.profile")
local lsp = require("cursed.lsp_client")

----------------------------------------------------------------------------------------------------
-- Keybind building (config-aware)
----------------------------------------------------------------------------------------------------

local Config = require("cursed.config")

--- Prime the editor's base keybindings from the defaults table.
--- Separates the __printable handler and stores the base bindings,
--- then rebuilds the base trie. Called BEFORE Config.load() so that
--- init.lua (and any `editor:global_set_key` it issues) operates on a
--- fully-initialized editor and is applied for real rather than
--- clobbered by a later trie build. The returned `config.keybindings`
--- table is applied on top via `editor:global_set_key` after load.
---@param editor Editor the editor to prime
local function prime_default_keybindings(editor)
	local defaults = require("cursed.default_keybindings")
	local bindings = {}
	local printable_fn ---@type function?
	for chord, func in pairs(defaults) do
		if chord == "__printable" then
			---@cast func function
			printable_fn = func
		else
			bindings[chord] = func
		end
	end
	editor._base_keybindings = bindings
	editor._printable_fn = printable_fn
	editor:rebuild_base_trie()
	editor._active_trie = editor._base_trie
	editor._chord_for_command = keybind.build_chord_for_command(bindings)
end

----------------------------------------------------------------------------------------------------
-- Generic inbox drain
----------------------------------------------------------------------------------------------------

--- Pop messages from `inbox`, emit `ring_buffer_message` for each,
--- and route by `msg.type` through `handlers[msg.type](msg, editor,
--- ss)`. Returns when the inbox is empty.
local function drain_generic(ss, inbox, editor, handlers)
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

----------------------------------------------------------------------------------------------------
-- Inbox drain
----------------------------------------------------------------------------------------------------

local function drain_inbox(editor, ss)
	drain_generic(ss, ss._ptr.inbox_io, editor, {
		[shared.MSG_FILE_LOADED_V2] = function(msg)
			-- Read the FileLoadReply struct: req_id, file_size, mmap_ptr.
			-- Main frees the struct after extracting and emits to the
			-- event bus; callers subscribe one-shot "file_op:<req_id>"
			-- handlers that self-unsubscribe on first delivery.
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

			editor.event_system:emit("file_op:" .. req_id, {
				mmap = mmap_ptr,
				size = file_size,
			})
		end,
		[shared.MSG_FILE_ERROR] = function(msg)
			-- File-op errors carry a req_id in arg and dispatch through
			-- the event bus ("file_op:<req_id>" with { err = ... }).
			-- Legacy load errors (req_id=0) fall through to the old path.
			local req_id = tonumber(msg.arg)
			local err_str = msg.ptr ~= nil and ffi.string(msg.ptr) or "<no message>"
			if msg.ptr ~= nil then
				ffi.C.free(msg.ptr)
			end
			if req_id and req_id ~= 0 then
				editor.event_system:emit("file_op:" .. req_id, { err = err_str })
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
		[shared.MSG_FILE_DIRLIST_RESP] = function(msg)
			local req_id = tonumber(msg.arg) or 0
			---@cast req_id integer
			if msg.ptr == nil then
				editor.event_system:emit("file_op:" .. req_id, { err = "null pointer in dirlist reply" })
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
			editor.event_system:emit("file_op:" .. req_id, { entries = entries })
		end,
		[shared.MSG_FILE_SAVED] = function(msg)
			local saved_filepath = ffi.string(msg.ptr or "")
			ffi.C.free(msg.ptr)
			editor.status_message = "Wrote " .. saved_filepath
		end,
		[shared.MSG_FILE_INSERTED] = function(msg)
			-- arg is req_id (echoed by the IO lane from MSG_INSERT_FILE).
			-- Emit to event bus so the one-shot handler self-cleans.
			local req_id = tonumber(msg.arg) or 0
			---@cast req_id integer
			if req_id ~= 0 then
				editor.event_system:emit("file_op:" .. req_id, {})
			end
			-- Re-calculate line geometry for the current view's buffer
			-- after a do_insert_file request completes.
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

----------------------------------------------------------------------------------------------------
-- Highlight inbox drain — install span replies from the highlight lane
----------------------------------------------------------------------------------------------------

local function drain_hl_inbox(editor, ss)
	drain_generic(ss, ss._ptr.inbox_hl, editor, {
		[shared.MSG_HL_SPANS] = function(msg)
			if msg.ptr ~= nil then
				local hdr = ffi.cast("struct HlSpansHdr *", msg.ptr)
				local gen = tonumber(hdr.gen)
				local bucket_start = tonumber(hdr.bucket_start)
				local bucket_end = tonumber(hdr.bucket_end)
				local count = tonumber(hdr.count)
				local name_count = tonumber(hdr.name_count)
				local raw_ptr = ffi.cast("char *", msg.ptr)
				local spans_ptr = ffi.cast("struct HlSpan *", raw_ptr + ffi.sizeof("struct HlSpansHdr"))
				local names_ptr = ffi.cast(
					"struct HlName *",
					raw_ptr + ffi.sizeof("struct HlSpansHdr") + count * ffi.sizeof("struct HlSpan")
				)
				-- Route to the view that owns the in-flight request.
				-- Ownership follows the return value: on `true`, the
				-- view took ownership (retained in cache via ffi.gc, or
				-- freed itself on a stale/skip-install path) and we must
				-- NOT free. On `false` (no view claimed it), free here.
				local claimed = false
				for _, v in ipairs(editor.views) do
					if v._hl_install_spans then
						if
							v:_hl_install_spans(
								gen,
								bucket_start,
								bucket_end,
								count,
								msg.ptr,
								spans_ptr,
								name_count,
								names_ptr
							)
						then
							claimed = true
							break
						end
					end
				end
				if not claimed then
					ffi.C.free(hdr)
				end
			end
		end,
	})
end

local function drain_lsp_inbox(editor, ss)
	drain_generic(ss, ss._ptr.inbox_lsp, editor, {
		[shared.MSG_LSP_HANDSHAKE] = function(msg)
			local info = require("cursed.lsp_client").apply_handshake(msg.ptr)
			if info ~= nil then
				-- Per-client event so subscribers can scope to one server
				-- (mirrors lsp_response:<id> / lsp_notification:<method>).
				-- The payload carries prev_status so a smart listener can
				-- dedupe a repeated same-state re-emit.
				editor.event_system:emit(
					"lsp_status:" .. tostring(info.client_id),
					info.exe_name,
					info.status,
					info.prev_status
				)
			end
		end,
		[shared.MSG_LSP_RESPONSE] = function(msg)
			-- lsp_client decodes + frees; returns the id-routed tuple so
			-- main can re-emit on the event bus. Subscribers register
			-- one-shot listeners against `"lsp_response:" .. id`.
			local id, result, is_err, cid = require("cursed.lsp_client").apply_response(msg.ptr)
			if id ~= nil then
				editor.event_system:emit("lsp_response:" .. tostring(id), result, is_err, cid)
			end
		end,
		[shared.MSG_LSP_NOTIFICATION] = function(msg)
			local method, params, cid = require("cursed.lsp_client").apply_notification(msg.ptr)
			if method ~= nil and method ~= "" then
				editor.event_system:emit("lsp_notification:" .. method, params, cid)
			end
		end,
		[shared.MSG_LSP_SERVER_REQUEST] = function(msg)
			local method, params, rid, cid = require("cursed.lsp_client").apply_server_request(msg.ptr)
			if method ~= nil and method ~= "" then
				editor.event_system:emit("lsp_server_request:" .. method, params, rid, cid)
			end
		end,
	})
end

----------------------------------------------------------------------------------------------------
-- Proc inbox drain — relay subprocess output + lifecycle as
-- `process_out:<procid>` events on the editor event bus.
----------------------------------------------------------------------------------------------------

--- Terminal exit kinds (mirror proc_lane.lua / shared_state.h)
local PROC_KIND_EXITED = 0
local PROC_KIND_SIGNALED = 1
local PROC_KIND_FAILED = 2

--- Map a kind code to the event tag callers see as the second arg to
--- `process_out:<procid>` listeners.
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

local function drain_proc_inbox(editor, ss)
	local proc_client = require("cursed.proc_client")
	drain_generic(ss, ss._ptr.inbox_proc, editor, {
		[shared.MSG_PROC_OUTPUT] = function(msg)
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
		[shared.MSG_PROC_EXIT] = function(msg)
			if msg.ptr ~= nil then
				local e = ffi.cast("struct ProcExit *", msg.ptr)
				local procid = tonumber(e.procid)
				local kind = tonumber(e.kind)
				local code = tonumber(e.code)
				---@cast procid integer
				---@cast kind integer
				---@cast code integer
				editor.event_system:emit("process_out:" .. procid, proc_kind_tag(kind), code)
				ffi.C.free(msg.ptr)
			end
		end,
	})
end

----------------------------------------------------------------------------------------------------
-- Key processing (ported from old main.lua, adapted for View/Editor)
----------------------------------------------------------------------------------------------------

--- ESC/Alt disambiguation timeout in milliseconds.
local ESC_TIMEOUT_MS = 50

--- Wall-clock microseconds, for select() timeout math in the main loop.
local main_now_tv = ffi.new("struct timeval[1]")
local function now_us()
	pffi.C.gettimeofday(main_now_tv, nil)
	return tonumber(main_now_tv[0].tv_sec) * 1000000 + tonumber(main_now_tv[0].tv_usec)
end

--- Detect whether `ev` is a printable ASCII character.
---@param ev any
---@return boolean is_printable
---@return string|nil ch
local function _detect_printable(ev)
	if ev.key == 0 and tonumber(ev.ch) >= 32 and tonumber(ev.ch) < 127 then
		local ch_code = tonumber(ev.ch)
		---@cast ch_code integer
		return true, string.char(ch_code)
	end
	return false, nil
end

--- Phase 1: Run transient key handlers (LIFO — last pushed gets
--- first crack). Used by read-char, completion menu, query-replace,
--- and replace-regexp instead of hardcoded special cases.
---@param editor Editor
---@param token string|nil
---@param ch string|nil
---@param is_printable boolean
---@return boolean consumed
local function _intercept_special_keys(editor, token, ch, is_printable)
	local handlers = editor._transient_handlers
	-- Iterate in reverse (LIFO): most recently pushed handler wins.
	for i = #handlers, 1, -1 do
		local handler = handlers[i]
		if handler ~= nil and handler(editor, token, ch, is_printable) then
			return true
		end
	end
	return false
end

--- Phase 2: M-digit / M-- prefix argument accumulation.
--- Returns: "done" if consumed, "commit" if digit arg should commit
--- and fall through to trie, "cancel" if cancelled, nil to continue.
---@param editor Editor
---@param token string|nil
---@return string|nil signal
local function _handle_digit_arg(editor, token)
	if token then
		local digit = token:match("^alt%-(%d)$")
		if digit then
			---@type integer
			local d = (tonumber(digit)) --[[@as integer]]
			editor:accumulate_digit(d)
			return "done"
		end
		if token == "alt--" then
			editor:set_digit_negative()
			return "done"
		end
	end

	if editor._digit_active then
		if token == "ctrl-g" or token == "escape" then
			editor:cancel_digit_arg()
			return "cancel"
		end
		editor:commit_digit_arg()
		return "commit"
	end

	return nil
end

--- Phase 3: Unmodified printable character handling.
--- Handles self-insert into minibuffer (universal arg active) or
--- the buffer (via __printable). Returns: "done" if consumed,
--- "trie" if __printable declined (goto feed_trie).
---@param editor Editor
---@param view View|nil
---@param ch string|nil
---@param modified boolean
---@param in_chord boolean
---@param is_printable boolean
---@param printable_fn function|nil
---@return string|nil signal
local function _handle_printable(editor, view, ch, modified, in_chord, is_printable, printable_fn)
	if modified or in_chord or not is_printable then
		return nil
	end

	editor._last_was_kill = false

	-- Universal arg active: feed printable to minibuffer for self-insert
	if editor._universal_active then
		local mb_view = editor.minibuffer.view
		mb_view:delete_selection()
		---@cast ch string
		mb_view:insert_char(ch)
		return "done"
	end

	if printable_fn then
		local mode = view and view:top_mode()
		local pfn = (mode and mode.printable) or printable_fn
		local ok, claimed = pcall(pfn, view, editor, ch)
		if not ok then
			log.error("main", "printable error", { error = tostring(claimed) })
			return "done"
		end
		if claimed then
			return "trie"
		end
	end

	-- Self-insert was handled by __printable; emit post_command_hook
	-- so LSP didChange debounce sees the mutation.
	editor.event_system:emit("post_command_hook", "__printable", view)

	-- Record self-insert for kmacro (skip minibuffer inputs)
	if editor._recording and not (editor.minibuffer and editor.minibuffer.active) then
		editor._recorded_commands[#editor._recorded_commands + 1] =
			{ name = "__printable", ch = ch, universal_args = editor.universal_args }
	end

	return "done"
end

--- Phase 4: Universal argument state machine (C-u/C-g/Escape/Backspace).
--- Returns: "done" if consumed, "cancel" to reset and continue,
--- "commit" to finalize args and fall through to trie.
---@param editor Editor
---@param token string|nil
---@return string|nil signal
local function _handle_universal_arg(editor, token)
	if not editor._universal_active then
		return nil
	end

	if token == "ctrl-u" then
		editor:toggle_universal_arg()
		return "done"
	end
	if token == "ctrl-g" or token == "escape" then
		editor:cancel_universal_arg()
		return "cancel"
	end
	if token == "backspace" then
		local mb_view = editor.minibuffer.view
		if not mb_view:delete_selection() then
			if mb_view:p().col > 0 then
				mb_view:delete_char(-1)
			end
		end
		return "done"
	end

	-- Any other chord key terminates universal arg collection
	editor:get_universal_args()
	return "commit"
end

--- Phase 5: Trie dispatch (the ::feed_trie:: section).
--- Handles which-key paging, chord lookup, command dispatch,
--- and prefix accumulation.
---@param editor Editor
---@param view View|nil
---@param trie table
---@param key_state table
---@param key_node table
---@param token string|nil
---@param in_chord boolean
---@return table key_state
---@return table key_node
---@return string|nil quit
local function _dispatch_trie(editor, view, trie, key_state, key_node, token, in_chord)
	-- Which-key paging while a prefix is held
	if in_chord and token ~= nil and WhichKey.try_page(editor, token) then
		return key_state, key_node, nil
	end

	local child = key_node.children[token]
	if child == nil then
		key_state = {}
		key_node = trie
		editor.universal_args = nil
		if in_chord then
			editor.status_message = "undefined chord"
		end
	elseif child.action ~= nil then
		-- Full match: dispatch the command
		local act = child.action
		local cmd_name
		if type(act) == "string" then
			cmd_name = act
			act = commands[cmd_name]
			if not act then
				log.error("main", "unknown command", { name = cmd_name })
				editor.status_message = "unknown command: " .. cmd_name
				key_state = {}
				key_node = trie
			end
		end

		editor._kill_called = false

		if act then
			editor.event_system:emit("pre_command_hook", cmd_name, view)
			local mb_was_active_before = editor.minibuffer and editor.minibuffer.active
			local info = commands.get_cmd_info(act)
			local ok, result, is_async
			if info and info.isvararg and editor.universal_args then
				local gap = math.max(0, info.nparams - 2)
				---@type table
				local args = editor.universal_args
				local co
				if gap == 0 then
					co = coroutine.create(function()
						return act(view, editor, unpack(args))
					end)
				else
					local call_args = { view, editor }
					for _ = 1, gap do
						call_args[#call_args + 1] = nil
					end
					for i = 1, #args do
						---@cast args table
						call_args[#call_args + 1] = args[i]
					end
					co = coroutine.create(function()
						return act(unpack(call_args))
					end)
				end
				ok, result = coroutine.resume(co)
				is_async = coroutine.status(co) == "suspended"
			else
				local co = coroutine.create(function()
					return act(view, editor)
				end)
				ok, result = coroutine.resume(co)
				is_async = coroutine.status(co) == "suspended"
			end
			if is_async then
				-- Handler called async.await() — coroutine will resume
				-- when the event fires (inside drain_inbox). Treat as
				-- successful dispatch.
				ok, result = true, nil
			end
			if not ok then
				log.error("main", "keybinding error", { error = tostring(result) })
				editor.status_message = "error: " .. tostring(result)
			end
			editor._last_was_kill = editor._kill_called
			editor._kill_called = false
			if
				editor._recording
				and cmd_name
				and cmd_name ~= "start_kmacro"
				and cmd_name ~= "end_kmacro"
				and cmd_name ~= "run_kmacro"
				and not mb_was_active_before
			then
				editor._recorded_commands[#editor._recorded_commands + 1] =
					{ name = cmd_name, universal_args = editor.universal_args }
			end
			editor.event_system:emit("post_command_hook", cmd_name, view)
			key_state = {}
			key_node = trie
			if result == "quit" then
				return key_state, key_node, "quit"
			end
		end
	elseif next(child.children) ~= nil then
		-- Prefix match: accumulate
		key_state[#key_state + 1] = token
		key_node = child
	else
		-- Leaf with no action: reset
		key_state = {}
		key_node = trie
	end

	return key_state, key_node, nil
end

--- Process a key event token through the chord trie and editing logic.
---@param editor Editor
---@param view View|nil
---@param trie table root trie node
---@param key_state table accumulated key tokens
---@param key_node table current trie position
---@param token string key token from event_to_token
---@param ev any struct tb_event cdata
---@param printable_fn function|nil
---@return table key_state
---@return table key_node
---@return string|nil "quit" to exit
local function process_key(editor, view, trie, key_state, key_node, token, ev, printable_fn)
	local modified = keybind.is_modified(ev)
	local in_chord = #key_state > 0
	-- `_extend` is set true by a `*_select` command before it runs its
	-- motion, so the motion's transient-anchor drop is suppressed for
	-- that one gesture. Reset every keypress so it can't leak into a
	-- later plain motion (which must drop a shift-selection).
	editor._extend = false

	local is_printable, ch = _detect_printable(ev)

	-- Phase 1: Special key intercepts (read-char, completion, query-replace, replace-regexp)
	if _intercept_special_keys(editor, token, ch, is_printable) then
		return key_state, key_node, nil
	end

	-- Phase 2: M-digit / M-- prefix argument accumulation
	local sig = _handle_digit_arg(editor, token)
	if sig == "done" then
		return key_state, key_node, nil
	elseif sig == "cancel" then
		key_state = {}
		key_node = trie
		return key_state, key_node, nil
	elseif sig == "commit" then
		goto feed_trie
	end

	-- Phase 3: Unmodified printable character handling
	sig = _handle_printable(editor, view, ch, modified, in_chord, is_printable, printable_fn)
	if sig == "done" then
		return key_state, key_node, nil
	elseif sig == "trie" then
		goto feed_trie
	end

	-- Phase 4: Universal argument state machine
	sig = _handle_universal_arg(editor, token)
	if sig == "done" then
		return key_state, key_node, nil
	elseif sig == "cancel" then
		key_state = {}
		key_node = trie
		return key_state, key_node, nil
	elseif sig == "commit" then
		goto feed_trie
	end

	::feed_trie::
	return _dispatch_trie(editor, view, trie, key_state, key_node, token, in_chord)
end

----------------------------------------------------------------------------------------------------
-- Main
----------------------------------------------------------------------------------------------------

-- Catch SIGSEGV/SIGBUS so we can restore the terminal and log before dying
local SIGSEGV = 11
local SIGBUS = 7
ffi.C.signal(SIGSEGV, function(signum)
	log.error("main", "caught signal", { signal = tonumber(signum) })
	ffi.C.tb_shutdown()
	os.exit(128 + tonumber(signum))
end)
ffi.C.signal(SIGBUS, function(signum)
	log.error("main", "caught signal", { signal = tonumber(signum) })
	ffi.C.tb_shutdown()
	os.exit(128 + tonumber(signum))
end)

----------------------------------------------------------------------------------------------------
-- CLI option parsing (-e, -l, -h)
--
-- These run HEADLESS: no terminal, no editor, no event loop. They let
-- you drive cursed's library code (parsers, buffers, FFI) from a one-
-- liner, e.g. for tree-sitter node-name inspection:
--   build/cursed -e 'local ts=require"cursed.ts"; \
--     local p=ts.Parser.new(ts.lang.lua()); \
--     print(ts.node_string(p:parse_string("local x=1"):root()))'
-- `arg` becomes the filtered (file) list after extraction, so the TUI
-- path below only sees filenames when no -e/-l is present.
----------------------------------------------------------------------------------------------------
--- Print usage to stderr and return exit code 2 (arg error).
local function usage()
	io.stderr:write([[
usage: cursed [-e EXPR | -l MODULE]... [FILE...]
       cursed -h

  -e EXPR    evaluate a Lua chunk headlessly (may repeat; -l/-e compose)
  -l MODULE  require MODULE headlessly (may repeat; -l/-e compose)
  -h         show this help

When -e/-l are given, cursed runs them and exits (no TUI). Without
them, FILE... opens in the editor as usual.
]])
	return 2
end

--- Parse CLI args into { evals={}, requires={}, files={} }.
--- A flag's argument may be glued (-eEXPR) or separate (-e EXPR).
--- Returns nil + errmsg on a bad flag, or nil + "__usage__" for -h/--help.
---@return table|nil parsed
---@return string|nil errmsg
local function parse_cli_args()
	local out = { evals = {}, requires = {}, files = {} }
	if not arg then
		return out
	end
	local i = 1
	local n = #arg
	while i <= n do
		local a = arg[i]
		if a == "-h" or a == "--help" then
			return nil, "__usage__"
		elseif a == "-e" or a == "--eval" then
			if i == n then
				return nil, "option -e requires an argument"
			end
			out.evals[#out.evals + 1] = arg[i + 1]
			i = i + 2
		elseif a == "-l" or a == "--require" then
			if i == n then
				return nil, "option -l requires an argument"
			end
			out.requires[#out.requires + 1] = arg[i + 1]
			i = i + 2
		elseif type(a) == "string" and (a:match("^-e(.+)$") or a:match("^--eval=(.+)$")) then
			out.evals[#out.evals + 1] = a:match("^-e(.+)$") or a:match("^--eval=(.+)$")
			i = i + 1
		elseif type(a) == "string" and (a:match("^-l(.+)$") or a:match("^--require=(.+)$")) then
			out.requires[#out.requires + 1] = a:match("^-l(.+)$") or a:match("^--require=(.+)$")
			i = i + 1
		elseif type(a) == "string" and a:sub(1, 1) == "-" and a ~= "-" then
			return nil, ("unknown option: %s"):format(a)
		else
			out.files[#out.files + 1] = a
			i = i + 1
		end
	end
	return out
end

--- Run headless -e/-l requests in order, then exit. Returns an exit
--- code: 0 on success, 1 on a Lua error. The chunk's first returned
--- value, if a number, is used as the exit code (so `-e 'return 3'`
--- exits 3). Anything printed goes to stdout normally.
---@param parsed table { evals = string[], requires = string[] }
---@return integer
local function run_headless(parsed)
	for _, mod in ipairs(parsed.requires) do
		local ok, err = pcall(require, mod)
		if not ok then
			io.stderr:write(("cursed: -l %s failed: %s\n"):format(mod, tostring(err)))
			return 1
		end
	end
	for _, expr in ipairs(parsed.evals) do
		local fn, err = load(expr, "=eval")
		if not fn then
			io.stderr:write(("cursed: -e parse error: %s\n"):format(tostring(err)))
			return 1
		end
		-- Wrap in a coroutine so async.await() works from -e chunks.
		local co = coroutine.create(fn)
		local rok, rc_or_err = coroutine.resume(co)
		if coroutine.status(co) == "suspended" then
			-- Expression used async.await(); the coroutine will resume
			-- in the drain loop below.
			rok, rc_or_err = true, nil
		end
		if not rok then
			io.stderr:write(("cursed: -e error: %s\n"):format(tostring(rc_or_err)))
			return 1
		end
		if type(rc_or_err) == "number" then
			return math.floor(rc_or_err)
		end
	end
	return 0
end

--- Build a minimal live editor for headless -e/-l mode: the same
--- Editor/View/Buffer/commands/keybindings surface as the TUI path, but
--- no terminal takeover and no event loop. Exposes _G.editor / _G.view so
--- a `-e` chunk can drive the real APIs (cursor/buffer/command logic)
--- against a live editor without a TTY. Rendering-only term calls are
--- stubbed (height/width return sane dims; everything else is a no-op).
local function build_headless_editor()
	local stub_term = setmetatable({ height = 24, width = 80 }, {
		__index = function(_, _)
			return function() end
		end,
	})
	local editor = Editor.new(stub_term)
	_G.editor = editor
	_G.async = require("cursed.async")
	_G.Editor = require("cursed.editor")
	local ok, empty_buf = pcall(Buffer.new)
	if not ok then
		io.stderr:write(("cursed: headless buffer init failed: %s\n"):format(tostring(empty_buf)))
		return editor
	end
	local view = View.new(empty_buf)
	editor:add_view(view)
	_G.view = view
	prime_default_keybindings(editor)
	log.info("main", "headless editor ready", { views = #editor.views })
	return editor
end

local function main()
	-- Configure logging
	log.configure({ level = "info", output = "/tmp/cursed.log" })
	log.info("main", "starting")

	-- Parse -e/-l/-h. When headless requests are present, run them and
	-- exit without touching the terminal. The filtered file list is
	-- re-exposed as `arg` for the TUI path below so the existing arg
	-- loop keeps working unchanged.
	local parsed, perr = parse_cli_args()
	if parsed == nil then
		if perr == "__usage__" then
			local rc = usage()
			-- Same as the headless path: signal the lanes to stop so
			-- main.c's cleanup doesn't deadlock on pthread_join.
			pcall(function()
				local shared = require("cursed.shared")
				local ss = shared.SharedState.from_global()
				ss:stop()
			end)
			return rc
		end
		io.stderr:write(("cursed: %s\n"):format(perr))
		io.stderr:write("try 'cursed -h' for usage.\n")
		return 2
	end
	if #parsed.evals > 0 or #parsed.requires > 0 then
		-- Re-expose the file list as `arg` in case a headless chunk
		-- inspects it, then run and exit.
		if arg then
			for i = 1, #parsed.files do
				arg[i] = parsed.files[i]
			end
			for i = #parsed.files + 1, #arg do
				arg[i] = nil
			end
		end
		-- Build a minimal live editor (no TUI) so -e/-l chunks can drive
		-- the same Editor/View/Buffer/command APIs as the TUI path
		-- without taking over the terminal. Exposed as _G.editor / _G.view
		-- (a bare `editor` in the eval chunk resolves to _G.editor).
		local editor_headless = build_headless_editor()
		local rc = run_headless(parsed)
		-- Drain the inbox once after eval so that any async file-op
		-- replies (MSG_FILE_LOADED for read_into_buffer,
		-- MSG_FILE_ERROR for failing ops) are consumed before we shut
		-- down the lanes. Busy-wait up to 100µs worth of retries
		-- (the IO lane processes in microseconds, so a few iterations
		-- with a yield are enough).
		local ss_headless = require("cursed.shared").SharedState.from_global()
		for _ = 1, 100 do
			drain_inbox(editor_headless, ss_headless)
			drain_hl_inbox(editor_headless, ss_headless)
			drain_lsp_inbox(editor_headless, ss_headless)
			drain_proc_inbox(editor_headless, ss_headless)
			local count = editor_headless._pending_ops_count or 0
			if count == 0 then
				break
			end
		end
		-- Signal the worker lanes to stop. ss:stop() sets running=false
		-- AND pushes MSG_SHUTDOWN to each lane's outbox (ring_push
		-- triggers EVFILT_USER on the parked kevent, so each lane wakes,
		-- observes the shutdown, and returns). main.c's cleanup then
		-- pthread_join's a clean exit instead of deadlocking (the lanes
		-- are parked in kevent(); without the wake, join would block).
		pcall(function()
			ss_headless:stop()
		end)
		return rc
	end
	-- No headless flags: re-expose files as `arg` for the TUI path.
	if arg then
		for i = 1, #parsed.files do
			arg[i] = parsed.files[i]
		end
		for i = #parsed.files + 1, #arg do
			arg[i] = nil
		end
	end

	local term, err = tb.Term.new()
	if not term then
		log.error("main", "terminal init failed", { error = err or "unknown" })
		io.stderr:write(("cursed: failed to initialize terminal: %s\n"):format(err or "unknown error"))
		return 1
	end
	log.info("main", "terminal initialized")

	-- Truecolor / 256-color output mode + scheme loading.
	-- Probe the terminal's capability; fall back: 256 → normal (8-color).
	-- The active ColorScheme is captured in 0xRRGGBB (truecolor) or
	-- already-quantized 256-index form, matching the chosen mode.
	local output_mode = tb.output_normal
	local truecolor = false
	if term:has_truecolor() then
		output_mode = tb.output_truecolor
		truecolor = true
	else
		-- Fall back to 256-color for the best non-truecolor fidelity.
		output_mode = tb.output_256
		truecolor = false
	end
	term:set_output_mode(output_mode)
	log.info("main", "output mode set", {
		mode = output_mode,
		truecolor = truecolor,
	})

	-- Load the configured scheme file. The path resolves:
	--   1. config.colorscheme if it's an absolute path → that file
	--   2. config.colorscheme (a name) → <config_dir>/cursed/themes/<name>{.yaml,.toml}
	--   3. missing/unreadable → built-in gruvbox-dark-medium fallback
	-- We do the path resolution here AFTER Config.load() below; for
	-- now, stash the output-mode decision so the loader can quantize.
	-- (The actual scheme load happens post-config; see below.)

	-- Use INPUT_ESC so standalone Escape is delivered as key=27.
	term:set_input_mode(bit.bor(tb.input_esc, tb.input_mouse))

	local editor = Editor.new(term)
	-- Expose the editor as a process-global so user code (init.lua, M-:,
	-- user mode files) can reach it directly — e.g. register
	-- `editor.event_system` listeners. This is the Emacs-philosophy move:
	-- `~/.emacs` runs against the live Lisp image, not a sandbox; here
	-- init.lua runs against the live editor. See `cursed.config` for the
	-- unsandboxed loader.
	_G.editor = editor
	log.info("main", "editor created")

	local ok, empty_buf = pcall(Buffer.new)
	if not ok then
		log.error("main", "buffer creation failed", { error = tostring(empty_buf) })
		return 1
	end
	log.info("main", "buffer created")

	local view = View.new(empty_buf)
	editor:add_view(view)
	log.info("main", "initial view created")

	log.info("main", "loading config and keybindings")
	-- Prime default keybindings on the editor BEFORE Config.load() so
	-- init.lua (and any `editor:global_set_key` it issues) runs against
	-- a fully-initialized editor and is applied for real rather than
	-- clobbered by a later trie build.
	prime_default_keybindings(editor)
	local config = Config.load(editor)
	editor._config = config
	-- Apply init.lua's returned `keybindings` table on top via the same
	-- live path (`__printable` override handled there too).
	for chord, action in pairs(config.keybindings) do
		editor:global_set_key(chord, action)
	end
	-- Mirror prefix: clone the ctrl-x subtree under an alternative
	-- prefix (e.g. alt-q) for terminals that swallow bare C-x (Ghostty).
	if config.mirror_prefix then
		editor:mirror_prefix("ctrl-x", config.mirror_prefix)
		log.info("main", "mirrored ctrl-x prefix", { to = config.mirror_prefix })
	end
	-- Margin: global config applied to every view at load. The initial
	-- view is added before config loads, so backfill it here; views
	-- added later (find-file, etc.) inherit via Editor:add_view.
	editor.margin = config.margin
	for _, v in ipairs(editor.views) do
		v.margin = config.margin
	end
	log.info("main", "config and keybindings loaded")

	-- Resolve the colorscheme path now that config is loaded.
	-- The lookup logic lives in ColorScheme.resolve_path/list_names so
	-- the `load-theme` command shares the same search dirs at runtime.
	local xdg_cursed = ColorScheme.config_dir()
	-- Stash the user's concept→slot overrides on the module so every
	-- scheme load (startup AND live load-theme switches) honors them:
	-- e.g. concept_slots = { keyword = "base0D", modeline_bg = "base02" }
	ColorScheme.config_overrides = config.concept_slots
	local scheme_setting = config.colorscheme
	local scheme_path = ColorScheme.resolve_path(scheme_setting, xdg_cursed)
	local scheme = ColorScheme.load(scheme_path, truecolor)
	-- Expose the active scheme globally so the highlighter can resolve
	-- capture names. The highlighter reads `require("cursed.colorscheme").active`.
	ColorScheme.active = scheme
	log.info("main", "scheme loaded", {
		name = scheme.name,
		truecolor = scheme.truecolor,
		path = scheme_path or "(built-in)",
	})

	-- Register toggle commands for each major mode
	for mode_name, template in pairs(config.modes) do
		local cmd_name = mode_name .. "-mode"
		commands[cmd_name] = function(view, editor)
			if view:has_major_mode(template) then
				view:deactivate_major_mode(template)
				editor.status_message = mode_name .. "-mode deactivated"
			else
				view:activate_major_mode(template)
				editor.status_message = mode_name .. "-mode activated"
			end
		end
	end

	local ss = shared.SharedState.from_global()

	-- Register the inbox EVFILT_USER wakes BEFORE any MSG_FILE_LOAD is
	-- pushed. The IO lane replies in well under a millisecond and
	-- triggers EVFILT_USER on this kq; if the filter isn't registered
	-- yet, the trigger is dropped and select() won't wake until the
	-- 200ms watchdog — i.e. the "Loading..." flash. Registering early
	-- makes main(kq_fd) readable the instant the reply arrives, so
	-- select() returns immediately. (resizefd is added later, once
	-- termbox is up; it has no ordering dependency.)
	local main_kq = Kqueue.wrap(ss._ptr.main_kq_fd)
	main_kq:add_wake(assert(tonumber(ss._ptr.inbox_io.wake_ident)))
	main_kq:add_wake(assert(tonumber(ss._ptr.inbox_hl.wake_ident)))
	main_kq:add_wake(assert(tonumber(ss._ptr.inbox_lsp.wake_ident)))
	main_kq:add_wake(assert(tonumber(ss._ptr.inbox_proc.wake_ident)))

	-- Wire the LSP module's SharedState handle so it can enqueue
	-- SPAWN/SEND/KILL to the LSP lane (outbox_lsp). The lane owns all
	-- subprocess mgmt + JSON decode; main relays via this facade.
	require("cursed.lsp_client").set_shared_state(ss)

	-- Wire the proc lane's SharedState + editor handle so spawn/send_stdin/
	-- kill can push to outbox_proc and register per-procid `process_in`
	-- listeners on the bus. drain_proc_inbox (below) is the inverse path.
	local proc_client = require("cursed.proc_client")
	proc_client.setup(editor, ss)
	-- Expose on the editor so init.lua / user code can spawn processes
	-- against the live image: `editor.proc.spawn({...}, {cwd=...})`.
	editor.proc = proc_client

	-- Expose the editor's main kqueue + workspace root to the
	-- editor-level LSP manager (registered in cursed.editor_listeners):
	-- the centralized `mode_enter` listener spawns the language server
	-- declared by a mode's `lsp_servers` and registers its stdout on
	-- this kq. Read once at startup so all servers share one rootUri.
	editor.main_kq = main_kq
	do
		local cwd_buf = ffi.new("char[4096]")
		if ffi.C.getcwd(cwd_buf, 4096) ~= nil then
			editor.workspace_dir = ffi.string(cwd_buf)
		end
	end

	-- Expose the inbox_hl drain as an editor method so views can
	-- synchronously drain lane responses inline (the zero-flash
	-- sync-wait path in View:_hl_wait_response). The closure captures
	-- `editor` and `ss` from this scope.
	editor.drain_hl_inbox = function()
		drain_hl_inbox(editor, ss)
	end

	-- ------------------------------------------------------------------
	-- Central event system: default consumers.
	--
	-- Producer call sites (pre/post-command-hook, ring_buffer_message,
	-- mode_enter/mode_exit) live across main.lua and view.lua. All
	-- editor-lifetime DEFAULT consumers are registered in one place —
	-- `cursed.editor_listeners` — so there's a single home for the
	-- next listener and a single place to audit what observes the hub.
	-- Production extensions and major modes register their own
	-- listeners on `editor.event_system` independently (e.g. from
	-- `init.lua` against the global editor).
	-- ------------------------------------------------------------------
	require("cursed.editor_listeners").setup(editor)
	require("cursed.whichkey").setup(editor)
	require("cursed.mdview").setup(editor)

	-- Backfill textobject commands for views opened BEFORE
	-- editor_listeners.setup (the initial view + anything init.lua
	-- added): their `view_open` fired before the listener existed, so
	-- register their default textobjects here. Later views/mode-entry
	-- are covered by the live view_open / mode_enter listeners.
	local commands_mod = require("cursed.commands")
	for _, v in ipairs(editor.views) do
		commands_mod.register_textobject_commands(v)
	end

	-- Announce editor readiness. Fires AFTER init.lua (config.load, run
	-- above) and default listeners are registered, so both user and
	-- built-in `editor.event_system:on("editor_open", ...)` handlers
	-- observe it. NOTE: the initial empty view's view_open fires earlier
	-- (during Editor setup, before init.lua) and so is not observable by
	-- init.lua listeners — hook editor_open (or iterate editor.views
	-- there) for "on startup, walk every existing view" needs.
	editor.event_system:emit("editor_open")

	-- Request file load(s) from IO lane. Every file given on the
	-- command line is opened in its own View/Buffer; views are added
	-- in arg order and MSG_FILE_LOAD pushed in the same order so the
	-- FIFO MSG_FILE_LOADED handler in drain_inbox matches each reply
	-- to the right view (it picks the first `not file_loaded` view).
	-- The already-created initial `view` is reused for arg[1]; further
	-- args get fresh Buffer+View pairs.
	local first_file_view_index = nil
	local arg_count = 0
	if arg then
		for i = 1, #arg do
			if type(arg[i]) == "string" then
				arg_count = arg_count + 1
			end
		end
	end

	if arg_count == 0 then
		-- No file given on the command line: open a random temporary
		-- text file so the user edits a real on-disk file they can save.
		-- os.tmpname() returns a unique path without creating it; we
		-- create it empty via the IO lane's MSG_FILE_CREATE so the
		-- file actually exists before MSG_FILE_LOAD races the load.
		-- The IO lane processes both ops in order (CRE THEN LOAD), so
		-- the resulting MSG_FILE_LOADED will mmap an empty file.
		local tmp_path = os.tmpname() .. ".txt"
		editor:create_file(tmp_path)
		view.buffer:set_filepath(tmp_path)
		view._bench_open_t0 = require("cursed.bench").now_us()
		-- Push FILE_LOAD with a req_id so the load reply routes
		-- through the event bus. Re-uses the existing empty view
		-- rather than allocating a new one via open_file.
		local req_id = editor:_next_file_op_id()
		editor._pending_ops_count = (editor._pending_ops_count or 0) + 1
		local event_name = "file_op:" .. req_id
		local handler
		handler = editor.event_system:on(event_name, function(_, payload)
			editor.event_system:off(event_name, handler)
			editor._pending_ops_count = editor._pending_ops_count - 1
			if payload.err then
				editor.status_message = payload.err
				return
			end
			local mmap_ptr = payload.mmap
			local file_size = payload.size
			---@cast file_size integer
			local bench = require("cursed.bench")
			if mmap_ptr == nil then
				view.file_loaded = true
				if editor._config and tmp_path then
					view:activate_mode_for_filepath(tmp_path, editor._config)
				end
				editor.event_system:emit("file_loaded", view, view.buffer)
			else
				local psize = tonumber(ffi.C.sysconf(shared._SC_PAGESIZE)) or 4096
				local cap = file_size > 0 and bit.band(file_size + psize - 1, bit.bnot(psize - 1)) or psize
				local loaded_buf = Buffer.from_mmap(mmap_ptr, file_size, cap)
				view:set_buffer(loaded_buf, { loaded = true })
				loaded_buf:set_filepath(tmp_path)
				view.file_loaded = true
				if editor._config and tmp_path then
					view:activate_mode_for_filepath(tmp_path, editor._config)
				end
				editor.event_system:emit("file_loaded", view, loaded_buf)
				if view._bench_open_t0 then
					bench.span("main", "file_open TOTAL", view._bench_open_t0, { path = tmp_path })
					view._bench_open_t0 = nil
				end
			end
		end)
		ss:push(ss._ptr.outbox_io, {
			type = shared.MSG_FILE_LOAD,
			arg = req_id,
			ptr = tmp_path,
		})
		log.info("main", "no file; opened temp", { path = tmp_path })
	else
		local arg_seen = 0
		for i = 1, #arg do
			local filepath = arg[i]
			if type(filepath) == "string" then
				arg_seen = arg_seen + 1
				-- Reuse the initial view for the first file; create a
				-- new Buffer+View for each subsequent file.
				local cur_view
				if arg_seen == 1 then
					cur_view = view
					first_file_view_index = 1
				else
					local ok_nb, nb = pcall(Buffer.new)
					if not ok_nb then
						log.error("main", "buffer creation failed for cli arg", {
							arg = filepath,
							error = tostring(nb),
						})
						-- Skip this arg on failure; can't host a view.
						goto next_arg
					end
					cur_view = View.new(nb)
					editor:add_view(cur_view)
					first_file_view_index = first_file_view_index or 1
				end

				-- Expand ~ and $ENV so the IO lane opens the real path,
				-- and so missing-file creation targets the right location.
				local expanded = find_file.expand_path(filepath)

				if find_file.is_directory(expanded) then
					-- Open the directory in the file manager instead of the placeholder view.
					editor:close_view(cur_view)
					local fm = require("cursed.file_manager")
					fm.open_directory(editor, expanded)
					-- Fix up first_file_view_index since we removed a view
					if first_file_view_index and first_file_view_index > #editor.views then
						first_file_view_index = #editor.views
					end
					log.info("main", "cli path is a directory", { path = filepath })
				else
					-- If the file doesn't exist, create an empty one so
					-- the IO lane's io.open succeeding mirrors `touch`.
					-- On failure we fall through and let MSG_FILE_LOAD
					-- surface the error.
					local f = io.open(expanded, "rb")
					if f == nil then
						-- File doesn't exist yet — create it on the IO
						-- lane. The lane processes CREATE then LOAD in
						-- order, so MSG_FILE_LOADED will see the empty
						-- file. On create failure nothing else dies:
						-- the subsequent LOAD pushes MSG_FILE_ERROR
						-- and the view gets an error message.
						editor:create_file(expanded, function(ok, err)
							if ok then
								log.info("main", "created missing file", { path = expanded })
							else
								log.warn("main", "could not create missing file", {
									path = expanded,
									error = err,
								})
							end
						end)
					else
						f:close()
					end

					cur_view.buffer:set_filepath(expanded)
					cur_view._bench_open_t0 = require("cursed.bench").now_us()
					-- Req_id-correlated load so the lane's reply
					-- routes through the event bus.
					local req_id2 = editor:_next_file_op_id()
					editor._pending_ops_count = (editor._pending_ops_count or 0) + 1
					local event_name = "file_op:" .. req_id2
					local handler
					handler = editor.event_system:on(event_name, function(_, payload)
						editor.event_system:off(event_name, handler)
						editor._pending_ops_count = editor._pending_ops_count - 1
						if payload.err then
							editor.status_message = payload.err
							return
						end
						local mmap_ptr = payload.mmap
						local file_size = payload.size
						---@cast file_size integer
						local bench = require("cursed.bench")
						if mmap_ptr == nil then
							cur_view.file_loaded = true
							if editor._config and expanded then
								cur_view:activate_mode_for_filepath(expanded, editor._config)
							end
							editor.event_system:emit("file_loaded", cur_view, cur_view.buffer)
						else
							local psize = tonumber(ffi.C.sysconf(shared._SC_PAGESIZE)) or 4096
							local cap = file_size > 0 and bit.band(file_size + psize - 1, bit.bnot(psize - 1)) or psize
							local loaded_buf = Buffer.from_mmap(mmap_ptr, file_size, cap)
							cur_view:set_buffer(loaded_buf, { loaded = true })
							loaded_buf:set_filepath(expanded)
							cur_view.file_loaded = true
							if editor._config and expanded then
								cur_view:activate_mode_for_filepath(expanded, editor._config)
							end
							editor.event_system:emit("file_loaded", cur_view, loaded_buf)
							if cur_view._bench_open_t0 then
								bench.span("main", "file_open TOTAL", cur_view._bench_open_t0, { path = expanded })
								cur_view._bench_open_t0 = nil
							end
						end
					end)
					ss:push(ss._ptr.outbox_io, {
						type = shared.MSG_FILE_LOAD,
						arg = req_id2,
						ptr = expanded,
					})
					log.info("main", "pushing FILE_LOAD", { path = expanded })
				end

				::next_arg::
			end
		end

		-- add_view activates the newest view, so after opening several
		-- files the focus would rest on the last one. Reset to the
		-- first file's view to match user expectation (first arg active).
		if first_file_view_index then
			editor:set_active_view(first_file_view_index)
		end
	end

	-- File-load watchdog: if any view is still awaiting its initial
	-- load reply from the IO lane, schedule a 200ms timer. Exceeding it
	-- bails out of the program (the load is hung — e.g. on a stale NFS
	-- mount). Cancelled once all views report file_loaded. The no-file
	-- case now opens a temp file, so this arms and clears on the
	-- (instant) local load; directory args pre-mark their view loaded
	-- and so never arm it.
	local load_watchdog_task = nil
	for _, v in ipairs(editor.views) do
		if not v.file_loaded then
			load_watchdog_task = editor:schedule_after(200000, function()
				local any_pending = false
				for _, vv in ipairs(editor.views) do
					if not vv.file_loaded then
						any_pending = true
						break
					end
				end
				if not any_pending then
					return true
				end
				io.stderr:write("cursed: file load timed out after 200ms; aborting\n")
				log.error("main", "file load timeout")
				editor._exit_code = 2
				editor:request_quit()
				return true
			end)
			log.info("main", "file-load watchdog armed", { delay_us = 200000 })
			break
		end
	end

	-- Key chord state machine
	local key_state = {} -- accumulated key tokens for current chord
	local key_node = editor._active_trie -- current position in the trie

	--- Sync the which-key hint state from the authoritative chord state.
	--- Called after every process_key so the render_overlay listener
	--- redraws (or hides) the popup. The popup shows while a prefix has
	--- matched but the chord is unresolved.
	local function sync_whichkey()
		if #key_state > 0 and next(key_node.children) ~= nil then
			-- Reset the page index whenever the prefix node changes
			-- (i.e. the chord advanced or branched) so paging never
			-- points at a stale page.
			if editor._whichkey_node ~= key_node then
				editor._whichkey_page = 0
			end
			editor._whichkey_node = key_node
			local parts = {}
			for i = 1, #key_state do
				parts[#parts + 1] = keybind.format_token(key_state[i])
			end
			editor._whichkey_prefix = table.concat(parts, " ")
		else
			editor._whichkey_node = nil
			editor._whichkey_prefix = nil
			editor._whichkey_page = 0
		end
	end

	-- Set up the central kqueue for the main lane. This merges:
	--   - termbox resize fd     (EVFILT_READ — SIGWINCH)
	--   - inbox_io wake ident   (EVFILT_USER — IO lane signals us)
	--
	-- Note: macOS /dev/tty does not support kqueue EVFILT_READ, so we
	-- can't watch the tty fd on the kqueue. Instead, we select() on
	-- (ttyfd, kqueue_fd) — the kqueue fd becomes readable when it has
	-- events pending. This gives us a single blocking primitive that
	-- handles both tty input and kqueue-delivered events.
	--
	-- We use select() instead of poll() because macOS poll() has broken
	-- behavior on /dev/tty (spurious POLLNVAL / persistent POLLIN).
	local ttyfd, resizefd = term:get_fds()
	main_kq:add_fd(resizefd)

	local kq_fd = tonumber(ss._ptr.main_kq_fd)

	-- Self-pipe for waking select() from request_quit(). select() DOES
	-- reliably watch the kqueue fd, but request_quit() wants a wake
	-- primitive it can fire from arbitrary call sites (incl. async/signalled
	-- contexts where calling kevent() directly would be unsafe); a plain
	-- pipe write is async-signal-safe, so we route quit wakes through it.
	local wake_pipe = ffi.new("int[2]")
	pffi.C.pipe(wake_pipe)
	local wake_pipe_r = assert(tonumber(wake_pipe[0]), "pipe() failed")
	local wake_pipe_w = assert(tonumber(wake_pipe[1]), "pipe() failed")
	---@cast wake_pipe_r integer
	---@cast wake_pipe_w integer

	-- Wire up editor's wake-main callback so request_quit() can
	-- break out of select() without waiting for another keypress.
	editor._wake_main = function()
		local one = ffi.new("uint8_t[1]", 1)
		pffi.C.write(wake_pipe_w, one, 1)
	end

	log.info("main", "kqueue setup", {
		kq_fd = kq_fd,
		ttyfd = ttyfd,
		resizefd = resizefd,
		wake_pipe_r = wake_pipe_r,
		wake_pipe_w = wake_pipe_w,
	})

	-- select() on (ttyfd, kqueue_fd, wake_pipe_r)
	-- Pre-allocate fd_set buffer; we zero and re-fill each iteration.
	-- FD_SETSIZE on macOS is 1024 → 128 bytes is sufficient.
	local readfds = pffi.fd_set_new()
	---@diagnostic disable-next-line: param-type-mismatch
	local maxfd = math.max(ttyfd, math.max(kq_fd, wake_pipe_r)) + 1

	-- True while the left mouse button is held after a press, so motion
	-- events extend the selection instead of relocating the cursor.
	local mouse_drag = false

	-- Initial render (empty buffer; file load event will wake us via kq)
	editor:render()
	editor:schedule_blink() -- start the periodic blink timer
	log.info("main", "entering main loop")

	-- Main loop: select(ttyfd, kq_fd, wake_pipe_r), then dispatch
	while ss:running() do
		local loop_t0 = profile.now_us()
		-- Zero and rebuild fd_set each iteration (select mutates it)
		ffi.fill(readfds, 128, 0)
		pffi.fd_set_set(readfds, ttyfd)
		pffi.fd_set_set(readfds, kq_fd)
		pffi.fd_set_set(readfds, wake_pipe_r)

		-- select() timeout. Background tasks now carry their own
		-- deadlines; the editor returns the earliest one so we always
		-- wake in time for timers (blink, load watchdog)
		-- without bespoke deadline math here.
		local now = now_us()
		local deadline = editor:next_task_deadline()
		local tv
		if deadline == nil then
			tv = nil -- block indefinitely
		else
			local wait_us = deadline - now
			if wait_us < 0 then
				wait_us = 0
			end
			tv = ffi.new("struct timeval", 0, wait_us)
		end

		local select_t0 = profile.now_us()
		local select_rv = pffi.C.select(maxfd, readfds, nil, nil, tv)
		local select_wait_us = profile.now_us() - select_t0
		-- Distinguish "blocked in select" from "did work"; loop_iter is
		-- total wall time (select + work). loop_work (emitted at end of
		-- body) is everything after select() returned.
		profile.report("main", "select_wait", select_wait_us, {
			ready = (select_rv > 0) and 1 or 0,
		})
		local work_t0 = profile.now_us()

		-- Drain any pending kqueue events (non-blocking)
		local kq_t0 = profile.now_us()
		if select_rv > 0 and pffi.fd_set_isset(readfds, kq_fd) then
			local events, n = main_kq:wait(0)
			for i = 0, n - 1 do
				local ev = events[i]
				local f = tonumber(ev.filter)
				if f == kq_ffi.EVFILT_USER then
					-- inbox_io (ident 1) carries file load/save replies;
					-- inbox_hl (ident 2) carries highlight span replies;
					-- inbox_lsp (ident 3) carries LSP handshakes.
					if tonumber(ev.ident) == tonumber(ss._ptr.inbox_hl.wake_ident) then
						drain_hl_inbox(editor, ss)
					elseif tonumber(ev.ident) == tonumber(ss._ptr.inbox_lsp.wake_ident) then
						drain_lsp_inbox(editor, ss)
					elseif tonumber(ev.ident) == tonumber(ss._ptr.inbox_proc.wake_ident) then
						drain_proc_inbox(editor, ss)
					else
						drain_inbox(editor, ss)
					end
				elseif f == kq_ffi.EVFILT_READ then
					-- All child-stdout drains now happen on the LSP lane;
					-- main no longer watches any LSP fd. (tty + resize
					-- are handled via termbox + the resizefd below.)
				end
			end
		end
		profile.span("main", "kq_drain", kq_t0)

		-- Drain wake pipe (self-pipe trick for request_quit)
		local wake_t0 = profile.now_us()
		if select_rv > 0 and pffi.fd_set_isset(readfds, wake_pipe_r) then
			local drain_buf = ffi.new("uint8_t[32]")
			pffi.C.read(wake_pipe_r, drain_buf, 32)
		end
		profile.span("main", "wake_pipe_drain", wake_t0)

		-- Eager non-blocking inbox drain. select() reliably wakes on the
		-- main kq_fd when an EVFILT_USER trigger fires (the inbox wakes are
		-- registered before any MSG_FILE_LOAD is pushed, so no trigger is
		-- ever dropped). This unconditional drain is defense-in-depth: it
		-- shaves one loop-iteration of latency off a reply that lands in
		-- the brief window between select() returning (e.g. for tty input)
		-- and the kq event being consumed, and tolerates any future
		-- change to the wake registration ordering. ss:pop is a no-op on
		-- an empty ring, so this is cheap.
		local drain_t0 = profile.now_us()
		local d1 = profile.now_us()
		drain_inbox(editor, ss)
		profile.span("main", "drain_io", d1)
		local d2 = profile.now_us()
		drain_hl_inbox(editor, ss)
		profile.span("main", "drain_hl", d2)
		local d3 = profile.now_us()
		drain_lsp_inbox(editor, ss)
		profile.span("main", "drain_lsp", d3)
		local d4 = profile.now_us()
		drain_proc_inbox(editor, ss)
		profile.span("main", "drain_proc", d4)
		profile.span("main", "drain_all", drain_t0)

		-- File-load watchdog: re-check pending loads after the inbox
		-- drain above (a MSG_FILE_LOADED/MSG_FILE_ERROR may have just
		-- resolved a view). If everything is loaded now, cancel the
		-- watchdog task so it never fires spuriously post-startup.
		local watchdog_t0 = profile.now_us()
		if load_watchdog_task ~= nil then
			local any_pending = false
			for _, v in ipairs(editor.views) do
				if not v.file_loaded then
					any_pending = true
					break
				end
			end
			if not any_pending then
				editor:cancel_task(load_watchdog_task)
				load_watchdog_task = nil
				log.info("main", "file-load watchdog cleared (all views loaded)")
			end
		end
		profile.span("main", "file_load_watchdog", watchdog_t0)

		-- Process all buffered termbox events.
		-- termbox2 reads from the tty in one read() call and buffers
		-- events internally (global.in bytebuf). After select() returns
		-- for the first event, subsequent events may already be in
		-- termbox2's buffer but NOT on the tty fd — so select() would
		-- block. We drain all pending events here.
		--
		-- After the minibuffer closes (submit/cancel), continue
		-- draining events. The Enter/Tab that submitted the minibuffer
		-- was already consumed by the trie dispatch, so it won't
		-- leak into the main view.
		local mb_was_active = editor.minibuffer and editor.minibuffer.active
		local had_input = false
		local key_count = 0
		local keys_t0 = profile.now_us()
		repeat
			mb_was_active = editor.minibuffer and editor.minibuffer.active
			local ev = term:peek_event(0)
			if ev == nil then
				break
			end
			had_input = true
			key_count = key_count + 1
			local key_t0 = profile.now_us()

			local view_cur = editor:current_view()
			local focused_view = editor:focused_view()

			if ev.type == tb.event_key then
				local key = tonumber(ev.key)
				local mod = tonumber(ev.mod)
				local ch_val = tonumber(ev.ch)

				-- If the minibuffer just closed (auto_accept), stale
				-- Enter/Tab events from the terminal may still arrive
				-- in a later select() cycle. Consume them here before
				-- they reach process_key and dispatch as newline/indent.
				-- Flag _just_closed: count of stale events to suppress.
				-- After auto_accept, both Tab and Enter may arrive —
				-- we need to consume both.
				local stale_count = editor._mb_just_closed
					or (editor.minibuffer and editor.minibuffer._just_closed)
					or 0
				if stale_count > 0 and mod == 2 and (key == 13 or key == 9) then
					-- Decrement the counter
					if editor.minibuffer and editor.minibuffer._just_closed then
						editor.minibuffer._just_closed = editor.minibuffer._just_closed - 1
						if editor.minibuffer._just_closed <= 0 then
							editor.minibuffer._just_closed = nil
						end
					end
					if editor._mb_just_closed then
						editor._mb_just_closed = editor._mb_just_closed - 1
						if editor._mb_just_closed <= 0 then
							editor._mb_just_closed = nil
						end
					end
					goto continue_drain
				end
				-- Any other key clears the stale-event flags
				editor._mb_just_closed = nil
				if editor.minibuffer then
					editor.minibuffer._just_closed = nil
				end

				editor.status_message = nil -- clear transient status
				editor._eval_result = nil -- clear eval result

				-- If the active trie was rebuilt (mode change), reset chord state
				if editor._trie_changed then
					key_state = {}
					key_node = editor._active_trie
					editor._trie_changed = nil
				end

				-- ESC/Alt disambiguation
				if key == 27 and mod == 0 then
					local follow = term:peek_event(ESC_TIMEOUT_MS)
					if follow and follow.type == tb.event_key then
						-- Alt+key: add ALT mod and process
						follow.mod = bit.bor(tonumber(follow.mod), tb.mod_alt)
						local token = keybind.event_to_token(follow)
						if token ~= nil then
							local new_state, new_node, quit = process_key(
								editor,
								focused_view,
								editor._active_trie,
								key_state,
								key_node,
								token,
								follow,
								editor._printable_fn
							)
							key_state = new_state
							key_node = new_node
							sync_whichkey()
							if quit then
								editor:request_quit()
								break
							end
						end
					else
						-- Standalone Escape
						local new_state, new_node, quit = process_key(
							editor,
							focused_view,
							editor._active_trie,
							key_state,
							key_node,
							"escape",
							ev,
							editor._printable_fn
						)
						key_state = new_state
						key_node = new_node
						sync_whichkey()
						if quit then
							editor:request_quit()
							break
						end
					end
				else
					local token = keybind.event_to_token(ev)
					if token ~= nil then
						local new_state, new_node, quit = process_key(
							editor,
							focused_view,
							editor._active_trie,
							key_state,
							key_node,
							token,
							ev,
							editor._printable_fn
						)
						key_state = new_state
						key_node = new_node
						sync_whichkey()
						if quit then
							editor:request_quit()
							break
						end
					end
				end
			elseif ev.type == tb.event_mouse then
				if view_cur and view_cur.file_loaded then
					local key = tonumber(ev.key)
					local mx = tonumber(ev.x)
					local my = tonumber(ev.y)

					-- Map a mouse (mx,my) to a buffer (line,col) using the
					-- same centered geometry Editor:render paints, so clicks
					-- land under the rendered glyph regardless of margin.
					local function mouse_to_pos()
						local w = term:width()
						local _, text_x = view_cur:text_geometry(w)
						---@cast my integer
						local cli, sub_row = view_cur:viewport_line_at_row(my)
						local line = math.min(cli, view_cur:line_count() - 1)
						local col
						if mx >= text_x then
							local sub_col = mx - text_x
							local byte_off = view_cur:wrap_byte_offset(line, sub_row, sub_col)
							col = math.min(byte_off, view_cur:content_len(line))
						else
							-- Gutter or left of the centered block: col 0.
							col = 0
						end
						return line, col
					end

					if key == tb.key_mouse_left then
						local mod = tonumber(ev.mod) or 0
						local is_motion = bit.band(mod, tb.mod_motion) ~= 0
						local line, col = mouse_to_pos()
						---@cast line integer
						---@cast col integer
						if is_motion then
							-- Drag (button held + motion): extend the
							-- selection by moving the primary cursor; the
							-- mark set on press stays anchored at the drag
							-- start. Ignored when no press began a drag
							-- (e.g. motion while Alt was held), so motion
							-- events never spawn extra cursors.
							if mouse_drag then
								local c = view_cur:p()
								c.line = line
								c.col = col
								view_cur:_clamp_cursor(c)
								view_cur:_set_goal_col(c.col)
							end
						elseif mod and bit.band(mod, tb.mod_alt) ~= 0 then
							-- Alt-click press: add a cursor at the click
							-- point. (Alt-drag is not specially handled.)
							-- No-op in views whose mode disabled
							-- multi-currency (non-file app buffers).
							if view_cur:multi_currency_enabled() then
								view_cur:add_cursor(line, col)
								view_cur:_set_goal_col(view_cur:p().col)
							end
						else
							-- Press (start of a potential drag): place a
							-- single cursor and drop a mark at the same
							-- spot so an empty selection is ready. If the
							-- user doesn't drag, the release clears it so a
							-- plain click leaves no selection.
							view_cur:set_single_cursor(line, col)
							view_cur:set_mark()
							mouse_drag = true
							view_cur:_set_goal_col(view_cur:p().col)
						end
					elseif key == tb.key_mouse_release then
						-- End of a drag (or a plain click with no drag).
						-- A click that never moved leaves an empty
						-- selection (anchor == cursor); clear the mark so a
						-- plain click behaves as simple cursor placement.
						if mouse_drag then
							local c = view_cur:p()
							if c.anchor_line == c.line and c.anchor_col == c.col then
								view_cur:unset_mark()
							end
						end
						mouse_drag = false
					elseif key == tb.key_mouse_wheel_up then
						local text_rows = term:height() - editor:footer_rows()
						view_cur:scroll_viewport(-3, text_rows)
					elseif key == tb.key_mouse_wheel_down then
						local text_rows = term:height() - editor:footer_rows()
						view_cur:scroll_viewport(3, text_rows)
					end
				end
			end
			::continue_drain::
			profile.span("main", "process_key_one", key_t0, { had_input = had_input })
		until editor._quit_requested or #key_state == 0
		profile.span("main", "process_keys", keys_t0, { count = key_count })
		-- When in a chord (prefix matched), stop draining — we need
		-- select() to block for the next key. When quit was requested
		-- or the chord completed, we stop too.

		if editor._quit_requested then
			break
		end

		-- Always clear universal args after command dispatch.
		-- Commands that need them should read during execution;
		-- after this point they're consumed.
		editor.universal_args = nil

		-- Fire minibuffer on_change (e.g. isearch live update)
		local mb_t0 = profile.now_us()
		editor:minibuffer_notify_change()
		profile.span("main", "minibuffer_notify", mb_t0)

		-- Reset blink on input so the caret stays solid while typing.
		-- The blink toggle itself is a scheduled background task; run
		-- timers here after input processing so a deadline-only wake
		-- flips the phase before render.
		if had_input then
			local rb_t0 = profile.now_us()
			editor:reset_blink()
			profile.span("main", "reset_blink", rb_t0)
		end
		local tasks_t0 = profile.now_us()
		editor:tick_background_tasks()
		profile.span("main", "tick_background_tasks", tasks_t0)

		-- Update view and render only after processing input/wake
		local cur_view = editor:current_view()
		if cur_view then
			local scroll_t0 = profile.now_us()
			cur_view:scroll_to_cursor(term:height() - (editor:footer_rows() - 1))
			profile.span("main", "scroll_to_cursor", scroll_t0)
		end
		local render_t0 = profile.now_us()
		editor:render()
		profile.span("main", "render", render_t0)
		profile.span("main", "loop_work", work_t0)
		profile.span("main", "loop_iter", loop_t0)
	end

	editor.event_system:emit("editor_close")
	lsp.shutdown()
	require("cursed.proc_client").shutdown()
	term:shutdown()
	ss:stop()

	return editor._exit_code
end

-- main.lua is loaded via lua_pcall(L, 0, 1, ...) in main.c, so only the
-- FIRST return value here is observed. xpcall returns (ok, retval); on
-- success surface main()'s actual exit code (e.g. 2 on file-load
-- timeout). On an unhandled error, the handler restores the terminal
-- and exits 1 before xpcall can return, so `ok` is effectively always
-- true here — `ok and rc or 1` is just defensive.
local ok, rc = xpcall(main, function(err)
	log.error("main", "unhandled error", { error = tostring(err) })
	pcall(function()
		ffi.C.g_shared_state.running = false
	end)
	pcall(function()
		ffi.C.tb_shutdown()
	end)
	io.stderr:write(tostring(err) .. "\n")
	os.exit(1)
end)
return ok and rc or 1
