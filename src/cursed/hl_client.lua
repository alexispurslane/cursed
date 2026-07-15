--- Highlight lane main-side facade.
---
--- Minimal client: the highlight lane's state is per-view cache (parse
--- trees, queries). On restart, we re-send MSG_HL_INITIALIZE_LANGUAGE
--- and re-query for all open views so highlighting recovers.

local M = {}

function M.setup(editor, shared_state)
	M._ss = shared_state
	M._editor = editor
end

function M.reinitialize(editor, ss)
	M._ss = ss
	M._editor = editor
	-- Re-request highlighting for every open view that has a language.
	for _, view in ipairs(editor.views) do
		if view.file_loaded and view._hl_lang then
			if view.hl_reinitialize then
				view:hl_reinitialize()
			end
		end
	end
end

return M
