--- Visual-movement minor mode (built-in).
---
--- When active, ctrl-n/p/a/e operate on visual lines (display sub-rows
--- produced by soft word wrap) rather than logical buffer lines, and
--- ctrl-k kills to the end of the current visual sub-row.
---
--- This mode is never activated automatically — toggle it on a per-buffer
--- basis via:
---   M-x toggle_visual_movement
---
--- Keybinding overrides (when active):
---   ctrl-n → forward_visual_line
---   ctrl-p → backward_visual_line
---   ctrl-a → move_beginning_of_visual_line
---   ctrl-e → move_end_of_visual_line
---   ctrl-k → kill_visual_line

---@diagnostic disable: need-check-nil, undefined-field, lowercase-global, unused-local

local template = {
	name = "visual-movement",
	is_minor = true,

	keybindings = {
		["ctrl-n"] = "forward_visual_line",
		["ctrl-p"] = "backward_visual_line",
		["ctrl-a"] = "move_beginning_of_visual_line",
		["ctrl-e"] = "move_end_of_visual_line",
		["ctrl-k"] = "kill_visual_line",
	},

	--- Save the effective margin before set_major_modes nukes it,
	--- then restore it on the next tick so the vertical column
	--- indicator and other margin consumers see the right value.
	---@param view View
	---@param editor Editor
	---@param instance ModeInstance
	on_enter = function(view, editor, instance)
		local existing = view.margin or editor.margin
		if existing and existing > 0 then
			view._vm_margin = existing
			editor:schedule_after(0, function()
				view.margin = view._vm_margin
				view:invalidate_wrap_cache()
			end)
		end
	end,

	--- Restore the pre-activation margin when this mode exits.
	---@param view View
	---@param editor Editor
	---@param instance ModeInstance
	on_exit = function(_view, _editor, _instance)
		-- Margin restore is handled by set_major_modes recomputing
		-- from the remaining major-mode stack.
	end,
}

return template
