--- Word-count minor mode (built-in).
---
--- When active, displays live word/sentence/paragraph/section stats in the
--- modeline, updated after every edit via the off-thread task lane. Also
--- tracks progress toward word goals set via `set_word_goal` or
--- `set_word_goal_increment`.
---
--- Toggle on a per-buffer basis via:
---   M-x toggle_word_count_mode
---
--- Goal commands (usable independently of the mode):
---   M-x word_count             — one-shot count in the status message
---   M-x set_word_goal          — set a total word target
---   M-x set_word_goal_increment — set a "write N more" target

---@diagnostic disable: need-check-nil, undefined-field, lowercase-global, unused-local

local IH = require("cursed.input_hook")
---@diagnostic disable: inject-field

local wc = require("cursed.word_count")
local async = require("cursed.async")

--- The counting function, defined at module level so string.dump can
--- serialize it. Runs on the task lane; takes { lines = string[] } and
--- calls count_buffer via the required word_count module.
local function _count_fn(args)
	local wc_mod = require("cursed.word_count")
	local lines = args.lines
	return wc_mod.count_buffer(#lines, function(i)
		return lines[i + 1]
	end)
end

--- Dispatch a word-count task to the task lane, store results on the view.
--- Runs inside a background task coroutine (so async.await works).
--- Returns true to remove itself from the task queue.
---@param ctx table {view, editor, lines, lsp_ver, goals, gen}
local function dispatch(ctx)
	local view = ctx.view
	local editor = ctx.editor

	if not editor.task then
		-- No task lane (headless / minimal setup). Fall back to sync.
		local stats = wc.compute(view)
		view._wc_stats = stats
		view._wc_display = wc.format(stats, ctx.goals)
		return true
	end

	local token = editor.task.send_task(_count_fn, { lines = ctx.lines }, { requires = { "cursed.word_count" } })
	local result = async.await(token)

	-- Stale result: a newer recache happened while we were in flight.
	if ctx.gen ~= view._wc_gen then
		return true
	end

	if result and result.success and result.result then
		local stats = result.result
		-- Guard: buffer hasn't changed since we snapped lines.
		if view.buffer and view.buffer.lsp_version == ctx.lsp_ver then
			stats._lsp_version = view.buffer.lsp_version
			view._wc_stats = stats
			view._wc_display = wc.format(stats, ctx.goals)
		end
	end
	return true
end

--- Schedule a word-count dispatch (fire-and-forget background task).
--- Each call bumps the generation counter; any in-flight dispatches for
--- older generations will discard their results when they arrive.
---@param view View
---@param editor Editor
local function recache(view, editor)
	if not view or not view.buffer then
		return
	end
	local buf = view.buffer
	local lsp_ver = buf.lsp_version

	-- Bump generation so stale in-flight tasks are ignored.
	local gen = (view._wc_gen or 0) + 1
	view._wc_gen = gen

	-- Build goals table from view state.
	local goals
	if view._wc_goal_total or view._wc_goal_inc then
		goals = {}
		if view._wc_goal_total then
			goals.total = view._wc_goal_total
		end
		if view._wc_goal_inc and view._wc_start_words then
			goals.increment = view._wc_goal_inc
			goals.start_words = view._wc_start_words
		end
	end

	-- Snapshot: collect all line texts (fast — just mem + table alloc).
	local n = buf:line_count()
	local lines = {}
	for i = 0, n - 1 do
		lines[#lines + 1] = buf:line_text(i)
	end

	editor:push_background_task(function()
		return dispatch({
			view = view,
			editor = editor,
			lines = lines,
			lsp_ver = lsp_ver,
			goals = goals,
			gen = gen,
		})
	end)
end

-- Input hook: fires after every printable character.
local printable_hook = IH.hook(".*", "printable", function(view, _cursors)
	local editor = view and view.editor
	if editor then
		recache(view, editor)
	end
	return {}
end)

-- Post-command hook: fires after every command.
local function post_cmd_handler(editor, cmd_name, cmd_view)
	if not cmd_view or not cmd_view._wc_active then
		return
	end
	if cmd_name == "__printable" then
		return
	end
	local mod_cmds = {
		delete_backward = true,
		delete_forward = true,
		delete_word_backward = true,
		delete_word_forward = true,
		delete_whole_line = true,
		delete_line = true,
		delete_to_beginning_of_line = true,
		delete_to_end_of_line = true,
		kill_line = true,
		kill_visual_line = true,
		join_lines = true,
		split_line = true,
		insert_newline = true,
		indent_line = true,
		undo = true,
		redo = true,
		paste = true,
		paste_before = true,
		yank = true,
		transpose_chars = true,
		transpose_words = true,
		transpose_sentences = true,
	}
	if mod_cmds[cmd_name] then
		recache(cmd_view, editor)
	end
end

-- The modeline segment: reads the cached display string.
local seg_spec = {
	bg = "modeline_bg",
	fill = false,
	format = function(_editor, view)
		if not view then
			return ""
		end
		return "  " .. (view._wc_display or "")
	end,
}

local template = {
	name = "word-count",
	is_minor = true,

	--- On activation: kick off initial recache, register hooks/segment.
	---@param view View
	---@param editor Editor
	---@param instance ModeInstance
	on_enter = function(view, editor, instance)
		view._wc_active = true
		recache(view, editor)

		instance._wc_printable_hook = printable_hook
		instance._wc_post_handler = post_cmd_handler

		-- Insert modeline segment before the position segment.
		local found = false
		for _, s in ipairs(editor.modeline_segments) do
			if s == seg_spec then
				found = true
				break
			end
		end
		if not found then
			table.insert(editor.modeline_segments, seg_spec)
		end

		-- Register post-command handler.
		if not editor._wc_post_cmd_handler then
			editor._wc_post_cmd_handler = post_cmd_handler
			editor.event_system:on("post_command_hook", post_cmd_handler)
		end
	end,

	--- On deactivation: remove segment and handlers, clear cache.
	---@param view View
	---@param editor Editor
	---@param instance ModeInstance
	on_exit = function(view, editor, instance)
		-- Remove modeline segment.
		for i, s in ipairs(editor.modeline_segments) do
			if s == seg_spec then
				table.remove(editor.modeline_segments, i)
				break
			end
		end

		-- Remove post-command handler when no view references it.
		if editor._wc_post_cmd_handler then
			local mode_obj = instance._base ---@type Mode
			local still_active = false
			if editor._views then
				for _, v in ipairs(editor._views) do
					if v:has_major_mode(mode_obj) then
						still_active = true
						break
					end
				end
			end
			if not still_active then
				editor.event_system:off("post_command_hook", editor._wc_post_cmd_handler)
				editor._wc_post_cmd_handler = nil
			end
		end

		-- Clear view state.
		view._wc_active = nil
		view._wc_stats = nil
		view._wc_display = nil
	end,

	input_hooks = { printable_hook },
}

return template
