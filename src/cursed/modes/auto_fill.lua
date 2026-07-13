--- Auto-fill major mode (built-in).
---
--- When active, automatically breaks lines at word boundaries when the
--- cursor passes `fill-column` (uses `view.margin` or 72 as the fill
--- width). Only triggers on printable character insertion.
---
--- This mode does NOT match any file pattern by default — it is never
--- activated automatically. Toggle it on a per-buffer basis via:
---   M-x toggle_auto_fill
---
--- The implementation listens on `post_command_hook` after `__printable`
--- commands and, if the cursor's display column exceeds `fill_width`,
--- finds the last space on the current line before `fill_width` and
--- replaces it with a newline. This mirrors Emacs's auto-fill-mode behavior.

---@diagnostic disable: need-check-nil, undefined-field, lowercase-global, unused-local

--- Get the effective fill width for auto-fill.
--- Uses _auto_fill_margin (our dedicated field that survives
--- set_major_modes overwrites), falling back to view.margin.
---@param view View
---@return integer
local function fill_width(view)
	return view._auto_fill_margin or view.margin or 72
end

local function do_auto_fill(view)
	local fw = fill_width(view)
	if fw <= 0 then
		return
	end
	local c = view:p()
	if not c then
		return
	end
	-- Check if cursor is past fill_width (using display column).
	local cursor_display_col = view:byte_to_col(c.line, c.col)
	if cursor_display_col <= fw then
		return
	end

	-- Get the line's grapheme skeleton to find the last space before fill_width.
	local bs, widths, prefix = view:_graph(c.line)
	local ng = #widths
	if ng == 0 then
		return
	end

	-- Walk graphemes; record the last space/tab that ends at or before fw.
	local break_gi = nil
	for i = 1, ng do
		local gi_end = prefix[i] + widths[i]
		if gi_end > fw then
			break
		end
		local line_text = view.buffer:line_text(c.line)
		local b = line_text:byte(bs[i])
		if b == 0x20 or b == 0x09 then
			break_gi = i
		end
	end
	if not break_gi then
		return -- No suitable word boundary to break at.
	end

	local buf = view.buffer
	local space_col = bs[break_gi] - 1 -- 0-based byte offset

	-- Single undo group: delete the space, insert newline.
	view:batch_edit(true, function(cur)
		local sl, sc = cur.line, space_col
		buf:delete_char(sl, sc, 1)
		buf:insert_char(sl, sc, "\n")
		-- Cursor was at (sl, cur.col) (byte offset) before the edit.
		-- After deleting 1 byte at (sl, sc) before the cursor:
		--   cursor shifts left by 1 → (sl, cur.col - 1).
		-- After splitting at sc: content from sc onward moves to
		--   line+1, so the cursor is now (sl + 1, (cur.col - 1) - sc).
		local result_line = sl + 1
		local result_col = cur.col - 1 - sc
		return sl, sc, result_line, result_col, "insert"
	end)
	view:_set_goal_col(view:p().col)
end

--- Store the template reference so the handler can check has_major_mode.
local template

---@return MajorModeSpec
template = {
	name = "auto-fill",
	-- Disable visual wrap: auto-fill handles line breaking by inserting
	-- actual newlines. Visual wrap would fight against that.
	wrap = false,

	--- Per-view initialization on mode enter.
	--- Prompts for fill margin when none is configured (neither the
	--- auto-fill mode spec, nor the editor config). Also registers
	--- the post_command_hook listener (first time only across all views).
	---
	--- on_enter fires BEFORE set_major_modes, so view.margin still has
	--- its old value here. We predict the post-setup margin: if neither
	--- our mode spec, editor.margin, nor view.margin provides one, we
	--- prompt. The on_submit callback runs asynchronously AFTER
	--- set_major_modes, so setting view.margin from the prompt sticks.
	on_enter = function(view, editor, instance)
		local mode_obj = instance._base ---@type MajorMode

		-- Capture the effective fill margin BEFORE set_major_modes
		-- runs and overwrites view.margin to nil. We use a dedicated
		-- field _auto_fill_margin that nothing else touches.
		local existing = view.margin or editor.margin or 72
		view._auto_fill_margin = existing

		-- Prompt for margin if none is configured anywhere.
		local has_any_margin = (mode_obj.margin ~= nil and mode_obj.margin > 0)
			or (editor.margin ~= nil and editor.margin > 0)
			or (view.margin ~= nil and view.margin > 0)

		if has_any_margin then
			-- set_major_modes (called after on_enter returns) will
			-- nuke view.margin because the auto-fill mode spec has
			-- no margin field and editor.margin is nil. Schedule a
			-- zero-delay restoration so the vertical column indicator
			-- and any other margin consumers see the right value.
			editor:schedule_after(0, function()
				view.margin = view._auto_fill_margin
				view:invalidate_wrap_cache()
			end)
		else
			local df = io.open("/tmp/af_debug.txt", "a")
			if df then
				df:write("on_enter: no margin, calling read_from_minibuffer\n")
				df:close()
			end
			editor:read_from_minibuffer({
				prompt = "Fill margin: ",
				initial = tostring(existing),
				on_submit = function(input)
					local s = input:gsub("^%s+", ""):gsub("%s+$", "")
					if s == "" or s == "0" or s == "nil" then
						view._auto_fill_margin = 72
						view:invalidate_wrap_cache()
						editor.status_message = "auto-fill: no margin, using 72"
						return
					end
					local n = tonumber(s)
					if not n or n < 1 then
						editor.status_message = "auto-fill: invalid margin, using 72"
						view._auto_fill_margin = 72
						view:invalidate_wrap_cache()
						return
					end
					view._auto_fill_margin = math.floor(n)
					view:invalidate_wrap_cache()
					editor.status_message = "auto-fill: margin set to " .. view._auto_fill_margin
				end,
				on_cancel = function()
					view._auto_fill_margin = existing
					view:invalidate_wrap_cache()
					editor.status_message = "auto-fill: using default margin 72"
				end,
			})
		end

		-- Register the post_command_hook listener (first view only).
		if editor._auto_fill_handler then
			return
		end
		editor._auto_fill_handler = function(_ed, cmd_name, cmd_view)
			if not cmd_view then
				return
			end
			if cmd_name ~= "__printable" then
				return
			end
			if editor:focused_view() ~= cmd_view then
				return
			end
			local df = io.open("/tmp/af_debug.txt", "a")
			if df then
				df:write("handler called, hmm check start\n")
				df:close()
			end
			if not cmd_view:has_major_mode(mode_obj) then
				return
			end
			do_auto_fill(cmd_view)
		end
		editor.event_system:on("post_command_hook", editor._auto_fill_handler)
	end,

	--- Remove the handler when the last view exits auto-fill mode.
	on_exit = function(_view, editor, instance)
		local mode_obj = instance._base ---@type MajorMode
		local still_active = false
		if editor._views then
			for _, v in ipairs(editor._views) do
				if v:has_major_mode(mode_obj) then
					still_active = true
					break
				end
			end
		end
		if not still_active and editor._auto_fill_handler then
			editor.event_system:off("post_command_hook", editor._auto_fill_handler)
			editor._auto_fill_handler = nil
		end
	end,
}

return template
