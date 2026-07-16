--- Built-in file manager app mode.
---
--- When the user opens a directory (CLI arg `cursed .` or `open-file` on
--- a directory), this mode launches instead of showing an error. It's a
--- non-file-backed Mode whose buffer text IS the directory listing,
--- whose cursor line IS the selected row.
---
--- Design: the header shows `_fm_dir .. _fm_query` — the resolved base
--- directory plus a fzy filter string. Typing appends to the query and
--- live-filters the items below. Hitting Enter on a directory navigates
--- into it. This unifies filtering, navigation, and completion into a
--- single mechanic.
---
--- Directory listings are async via editor:dirlist (IO lane). The view
--- shows "Loading…" while waiting; fzy filtering is purely local once
--- entries land. `is_directory` and `expand_path` remain synchronous
--- (hot path in header typing — these are fast stat calls).
---
--- Integration: `open_directory(editor, path)` creates the view and
--- activates the mode. Called from Editor:open_file / open_file_background
--- and main.lua CLI arg handling when a directory is detected.

local Mode = require("cursed.major_mode")
local View = require("cursed.view").View
local Buffer = require("cursed.buffer").Buffer
local find_file = require("cursed.find_file")
local fzy = require("cursed.fzy")
local async = require("cursed.async")

---@class FileManagerView : View
---@field _fm_dir string resolved base directory (no trailing slash, except root = "/")
---@field _fm_query string fzy filter text appended to the header (empty = no filter)
---@field _fm_entries table[] raw directory entries for _fm_dir
---@field _fm_matched table[] fzy-filtered and scored entries
---@field _fm_show_slash boolean whether to display a trailing "/" after _fm_dir (default true; cleared when user explicitly deletes it)
---@field _fm_loading boolean true while waiting for async dirlist

----------------------------------------------------------------------------------------------------
-- Header layout
----------------------------------------------------------------------------------------------------

local HEADER_PATH_LINE = 0
local HEADER_SEPARATOR_LINE = 1
local HEADER_LINES = 2

---@param width integer
---@return string
local function build_separator(width)
	return string.rep("─", width)
end

----------------------------------------------------------------------------------------------------
-- Async directory listing
----------------------------------------------------------------------------------------------------

--- Sort raw dirlist entries: directories first, then files, each group
--- sorted case-insensitively. Adds ".." parent entry when not at root.
--- Called inside the async callback so the IO lane isn't blocked.
---@param dir string absolute directory path
---@param raw table[] raw entries from editor:dirlist { name, is_dir }
---@return table[] entries { name, is_dir, is_parent?: true }
local function prepare_entries(dir, raw)
	local dirs = {}
	local files = {}
	for _, e in ipairs(raw) do
		if e.is_dir then
			dirs[#dirs + 1] = e
		else
			files[#files + 1] = e
		end
	end

	table.sort(dirs, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	table.sort(files, function(a, b)
		return a.name:lower() < b.name:lower()
	end)

	local entries = {}
	if dir ~= "/" then
		entries[#entries + 1] = { name = "..", is_dir = true, is_parent = true }
	end
	for _, d in ipairs(dirs) do
		entries[#entries + 1] = d
	end
	for _, f in ipairs(files) do
		entries[#entries + 1] = f
	end

	return entries
end

----------------------------------------------------------------------------------------------------
-- Buffer population
----------------------------------------------------------------------------------------------------

--- Rebuild the buffer from current state.
--- Header = `_fm_dir .. _fm_query`, items = `_fm_matched`.
---@param view FileManagerView
local function rebuild(view)
	local entries = view._fm_matched or {}
	local lines = {}
	for _, e in ipairs(entries) do
		if e.is_dir then
			lines[#lines + 1] = e.name .. "/"
		else
			lines[#lines + 1] = e.name
		end
	end

	local buf = view.buffer
	local term_w = 80
	if view.editor and view.editor.term then
		local tw = view.editor.term.width
		if type(tw) == "function" then
			term_w = view.editor.term:width()
		elseif type(tw) == "number" then
			term_w = tw
		end
	end
	local query = view._fm_query or ""
	local show_slash = view._fm_show_slash ~= false
	local header_text
	if #query > 0 then
		header_text = (view._fm_dir or "") .. "/" .. query
	elseif show_slash then
		header_text = (view._fm_dir or "") .. "/"
	else
		header_text = view._fm_dir or ""
	end

	buf:close_edit()
	buf:begin_edit()

	while buf:line_count() > 1 do
		buf:delete_char(0, 0, buf:line_len(0))
	end
	local content_len = buf:line_len(0) - 1
	if content_len > 0 then
		buf:delete_char(0, 0, content_len)
	end

	local all = { header_text, build_separator(term_w) }
	if view._fm_loading then
		all[#all + 1] = "Loading…"
	else
		for _, l in ipairs(lines) do
			all[#all + 1] = l
		end
	end
	if #all > 0 then
		buf:insert_char(0, 0, table.concat(all, "\n") .. "\n")
	end

	buf:end_edit()
	view:invalidate_wrap_cache()

	-- Clamp cursor (items area only; leave header cursor alone)
	local p = view:p()
	if p.line >= HEADER_LINES then
		local max_line = #lines + HEADER_LINES - 1
		if p.line > max_line then
			p.line = math.max(HEADER_LINES, max_line)
		end
		p.col = 0
		p.goal_col = 0
		p.visual_col = nil
		p.yank_line = nil
		p.yank_col = nil
	end
end

--- Request a directory listing from the IO lane and repopulate the view
--- when it arrives. Sets `_fm_loading = true` until the callback fires.
--- The view's `_fm_dir` must already be set to the desired directory.
--- Uses async.await — must be called from a coroutine (keybinding handler
--- or background task).
---@param view FileManagerView
local function fetch_dir(view)
	local editor = view.editor
	if not editor then
		return
	end
	view._fm_loading = true
	view._fm_entries = {}
	view._fm_matched = {}
	rebuild(view)

	local dir = view._fm_dir
	local payload = async.await(require("cursed.io_client").send_dirlist(dir))

	if payload.err then
		view._fm_loading = false
		view._fm_matched = {}
		return
	end
	if view._fm_dir ~= dir then
		-- Stale: the user navigated elsewhere before this reply landed.
		return
	end
	view._fm_loading = false
	view._fm_entries = prepare_entries(dir, payload.entries or {})
	view._fm_matched = view._fm_entries
	rebuild(view)

	-- Reposition cursor to first item (or header if empty).
	local p = view:p()
	if #view._fm_matched > 0 then
		p.line = HEADER_LINES
	else
		p.line = HEADER_LINES
	end
	p.col = 0
	p.goal_col = 0
end

--- Filter `entries` by fzy-scoring against `query`. Returns entries
--- that match, sorted by score descending (best match first).
--- When `query` is empty, returns all entries in their original order.
---@param entries table[]
---@param query string
---@return table[]
local function filter_entries(entries, query)
	if query == "" then
		return entries
	end
	local lneedle = fzy.lower_needle(query)
	local scored = {}
	for _, e in ipairs(entries) do
		local s = fzy.score(query, e.name, nil, lneedle)
		if s ~= nil then
			scored[#scored + 1] = { entry = e, score = s }
		end
	end
	table.sort(scored, function(a, b)
		return a.score > b.score
	end)
	local results = {}
	for _, se in ipairs(scored) do
		results[#results + 1] = se.entry
	end
	return results
end

----------------------------------------------------------------------------------------------------
-- Header path parsing
----------------------------------------------------------------------------------------------------

--- Split header text into a resolved base directory and a query suffix.
--- Walks `expand_path(text)` backwards to find the longest prefix that
--- is a valid directory. The query preserves the user's original
--- formatting (e.g. "~" instead of "/Users/...").
---@param text string raw header text
---@return string dir resolved base directory
---@return string query original text suffix after dir
local function split_header(text)
	local expanded = find_file.expand_path(text)
	local dir = expanded
	while dir ~= "" and not find_file.is_directory(dir) do
		dir = dir:match("^(.*)/[^/]*$")
		if not dir then
			dir = ""
			break
		end
	end
	if dir == "" then
		-- No valid directory in the path; fall back to cwd
		dir = "."
	end

	-- Calculate the query: everything in the original text after dir
	local query = ""
	if #text > #dir then
		query = text:sub(#dir + 1)
		-- Strip leading "/" (dir always displayed with a trailing "/")
		if query:sub(1, 1) == "/" then
			query = query:sub(2)
		end
	end

	-- Normalize: strip trailing slash (except root)
	if dir ~= "/" and dir:sub(-1) == "/" then
		dir = dir:sub(1, -2)
	end

	return dir, query
end

--- Read the header text, split into dir+query, update state, and
--- rebuild the display. Called after every edit to the header line.
--- Also auto-promotes the query when it uniquely prefixes a directory.
---@param view FileManagerView
local function resolve_header(view)
	local raw = view.buffer:line_text(HEADER_PATH_LINE)
	if raw == nil then
		return
	end
	---@cast raw string
	local text = raw:gsub("\n$", "")
	local new_dir, new_query = split_header(text)

	local dir_changed = new_dir ~= view._fm_dir
	view._fm_dir = new_dir
	view._fm_query = new_query

	-- If the user just typed a trailing "/" (query is empty but the
	-- raw text ends with "/"), re-enable the trailing slash display.
	if text:sub(-1) == "/" and new_query == "" then
		view._fm_show_slash = true
	end

	if dir_changed then
		view._fm_show_slash = true
		fetch_dir(view)
	else
		view._fm_matched = filter_entries(view._fm_entries, view._fm_query)
		rebuild(view)
	end

	-- Reposition cursor: if dir changed (e.g. ~ expanded), jump to end
	-- of the new header; otherwise stay where _printable_fn left it.
	local p = view:p()
	p.line = HEADER_PATH_LINE
	if dir_changed then
		local q = view._fm_query or ""
		p.col = #(view._fm_dir or "") + 1 + #q -- dir + "/" + query
		p.goal_col = p.col
	end
end

----------------------------------------------------------------------------------------------------
-- Navigation
----------------------------------------------------------------------------------------------------

--- Navigate to a directory, clearing the query. Async via fetch_dir.
---@param view FileManagerView
---@param dir string absolute directory path
local function navigate_to(view, dir)
	if dir ~= "/" and dir:sub(-1) == "/" then
		dir = dir:sub(1, -2)
	end

	view._fm_dir = dir
	view._fm_query = ""
	view._fm_show_slash = true
	fetch_dir(view)
end

--- Go to parent directory.
---@param view FileManagerView
local function go_up(view)
	local current = view._fm_dir or ""
	if current == "/" then
		return
	end
	local parent = current:match("^(.*)/[^/]+$")
	if not parent or parent == "" then
		parent = "/"
	end
	navigate_to(view, parent)
end

--- Open a file or navigate into a directory.
---@param view FileManagerView
---@param editor Editor
---@param entry table
local function activate_entry(view, editor, entry)
	if entry.is_parent then
		go_up(view)
	elseif entry.is_dir then
		local current = view._fm_dir or ""
		local target = current == "/" and ("/" .. entry.name) or (current .. "/" .. entry.name)
		navigate_to(view, target)
	else
		local current = view._fm_dir or ""
		local filepath = current == "/" and ("/" .. entry.name) or (current .. "/" .. entry.name)
		editor:close_view(view)
		editor:open_file(filepath)
	end
end

----------------------------------------------------------------------------------------------------
-- Cursor movement
----------------------------------------------------------------------------------------------------

---@param view FileManagerView
local function selected_entry(view)
	local matched = view._fm_matched or {}
	local idx = view:p().line - HEADER_LINES + 1
	return matched[idx]
end

---@param view FileManagerView
---@param editor Editor
local function fire_on_select(view, editor)
	local entry = selected_entry(view)
	if entry then
		activate_entry(view, editor, entry)
	end
end

--- Move cursor to the header line (normal, single-cell cursor at end).
---@param view FileManagerView
local function move_to_header(view)
	view:change_display_opts({ whole_line_cursor = false })
	local p = view:p()
	p.line = HEADER_PATH_LINE
	local q = view._fm_query or ""
	local show_slash = view._fm_show_slash ~= false
	p.col = #(view._fm_dir or "") + (show_slash and 1 or 0) + #q
	p.goal_col = p.col
end

--- Move cursor into the items area (whole-line cursor).
---@param view FileManagerView
local function move_to_items(view)
	view:change_display_opts({ whole_line_cursor = true })
	local p = view:p()
	if #view._fm_matched > 0 then
		p.line = HEADER_LINES
	else
		p.line = HEADER_LINES
	end
	p.col = 0
	p.goal_col = 0
end

----------------------------------------------------------------------------------------------------
-- Mode-scoped motion handlers (shared by arrow keys and Ctrl-n/Ctrl-p)
----------------------------------------------------------------------------------------------------

--- Handle downward motion (down arrow or Ctrl-n).
--- If on the header, moves to items and enables whole-line cursor.
---@param view FileManagerView
local function handle_down(view)
	local p = view:p()
	local matched = view._fm_matched or {}
	local max_line = #matched + HEADER_LINES - 1
	if p.line == HEADER_PATH_LINE then
		if #matched > 0 then
			move_to_items(view)
		end
	elseif p.line == HEADER_SEPARATOR_LINE then
		if #matched > 0 then
			move_to_items(view)
		end
	elseif p.line < max_line then
		p.line = p.line + 1
	end
	p.col = 0
	p.goal_col = 0
end

--- Handle upward motion (up arrow or Ctrl-p).
--- If on the first item or separator, moves to header and disables whole-line cursor.
---@param view FileManagerView
local function handle_up(view)
	local p = view:p()
	if p.line <= HEADER_PATH_LINE then
		return
	end
	if p.line == HEADER_SEPARATOR_LINE then
		move_to_header(view)
	elseif p.line == HEADER_LINES then
		move_to_header(view)
	else
		p.line = p.line - 1
	end
	p.col = 0
	p.goal_col = 0
end

----------------------------------------------------------------------------------------------------
-- File Manager Mode
----------------------------------------------------------------------------------------------------

local FileManager = Mode.new({
	name = "file-manager",
	no_gutter = true,
	wrap = false,
	multi_currency = false,
	on_enter = function(view, _editor)
		if not view._fm_dir then
			return
		end
		view._fm_query = view._fm_query or ""
		-- Start on the header with a normal (single-cell) cursor
		view:change_display_opts({ whole_line_cursor = false, no_completion = true })
		local p = view:p()
		p.line = HEADER_PATH_LINE
		p.col = #view._fm_dir + 1
		p.goal_col = p.col
		-- Fetch entries async; rebuild will show "Loading…" until the reply.
		fetch_dir(view)
	end,
	keymap = {
		["up"] = handle_up,
		["ctrl-p"] = handle_up,
		["down"] = handle_down,
		["ctrl-n"] = handle_down,
		["enter"] = function(view, editor)
			local line = view:p().line
			if line == HEADER_PATH_LINE then
				-- Try to resolve the header as a direct navigation, then
				-- move cursor to items
				resolve_header(view)
				move_to_items(view)
			elseif line >= HEADER_LINES then
				fire_on_select(view, editor)
			end
		end,
		["backspace"] = function(view, _editor)
			local line = view:p().line
			if line == HEADER_PATH_LINE then
				local p = view:p()
				-- Detect if we're deleting the trailing slash (right after _fm_dir)
				local show_slash = view._fm_show_slash ~= false
				local slash_pos = #(view._fm_dir or "") + (show_slash and 1 or 0)
				if p.col == slash_pos and #(view._fm_query or "") == 0 then
					view._fm_show_slash = false
				end
				if p.col > 0 then
					view:delete_char(-1)
				end
				resolve_header(view)
			elseif line >= HEADER_LINES then
				-- In items area: trim the query filter, or go to parent
				-- if query is already empty
				local q = view._fm_query or ""
				if #q > 0 then
					view._fm_query = q:sub(1, #q - 1)
					view._fm_matched = filter_entries(view._fm_entries, view._fm_query)
					rebuild(view)
				else
					go_up(view)
				end
			end
		end,
		["escape"] = function(view, editor)
			editor:close_view(view)
		end,
		["ctrl-g"] = function(view, editor)
			editor:close_view(view)
		end,
		["q"] = function(view, editor)
			editor:close_view(view)
		end,
		-- Tab: promote query to directory on header; open file if it's
		-- the only match; navigate to directories on items.
		["tab"] = function(view, editor)
			local line = view:p().line
			if line == HEADER_PATH_LINE then
				local q = view._fm_query or ""
				if #q == 0 then
					return
				end
				-- First: check for unique prefix match among directories
				local match = nil
				local lq = q:lower()
				for _, e in ipairs(view._fm_entries) do
					if e.is_dir and not e.is_parent then
						if e.name:lower():sub(1, #lq) == lq then
							if match ~= nil then
								match = nil
								break
							end
							match = e
						end
					end
				end
				-- Second: if no unique prefix dir, check if exactly one
				-- filtered result (fzy matches work too, incl. files)
				if match == nil then
					local filtered = view._fm_matched or {}
					if #filtered == 1 then
						match = filtered[1]
					end
				end
				if match ~= nil then
					if match.is_dir then
						view._fm_dir = view._fm_dir .. "/" .. match.name
						view._fm_query = ""
						fetch_dir(view)
						local p = view:p()
						p.line = HEADER_PATH_LINE
						p.col = #view._fm_dir + 1
						p.goal_col = p.col
					else
						-- Only match is a file: open it
						local filepath = view._fm_dir .. "/" .. match.name
						editor:close_view(view)
						editor:open_file(filepath)
					end
				end
			elseif line >= HEADER_LINES then
				local entry = selected_entry(view)
				if entry and entry.is_dir then
					activate_entry(view, editor, entry)
				end
			end
		end,
		["h"] = function(view, _editor)
			local line = view:p().line
			if line >= HEADER_LINES then
				go_up(view)
			end
		end,
		["left"] = function(view, _editor)
			go_up(view)
		end,
	},
	printable = function(view, editor, ch)
		local line = view:p().line
		if line == HEADER_PATH_LINE then
			-- Normal self-insert on the header, then live-resolve
			editor._printable_fn(view, editor, ch)
			resolve_header(view)
			return nil -- handled
		elseif line >= HEADER_LINES then
			-- Append to query and live-filter
			view._fm_query = (view._fm_query or "") .. ch
			view._fm_matched = filter_entries(view._fm_entries, view._fm_query)
			rebuild(view)
			return nil -- handled
		end
		return nil
	end,
})

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

--- Open a directory in the file manager view.
---@param editor Editor
---@param path string absolute directory path (already expanded)
local function open_directory(editor, path)
	if path ~= "/" and path:sub(-1) == "/" then
		path = path:sub(1, -2)
	end

	local buf = Buffer.new()
	local view = View.new(buf)
	---@cast view FileManagerView
	view.file_loaded = true
	view._fm_dir = path
	view._fm_query = ""
	view._fm_show_slash = true
	view._fm_loading = false
	view._fm_entries = {}
	view._fm_matched = {}

	editor:add_view(view)
	view:activate_major_mode(FileManager)

	-- on_enter kicks off the async fetch; rebuild will show "Loading…" until
	-- the dirlist reply arrives.
end

return {
	open_directory = open_directory,
	FileManager = FileManager,
}
