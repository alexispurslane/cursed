--- Highlight lane main-side facade.
---
--- Minimal client: the highlight lane's state is per-view cache (parse
--- trees, queries). On restart, we re-send MSG_HL_INITIALIZE_LANGUAGE
--- and re-query for all open views so highlighting recovers.

local constants = require("cursed.shared")
local M = {}

function M.setup(shared_state, _es)
	M._ss = shared_state
end

function M.reinitialize(shared_state, editor, _es)
	M._ss = shared_state
	-- Re-request highlighting for every open view that has a language.
	for _, view in ipairs(editor.views) do
		if view.file_loaded and view._hl_lang then
			if view.hl_reinitialize then
				view:hl_reinitialize()
			end
		end
	end
end

require("cursed.lane_registry").register(constants.LANE_IDX_HL, M)
return M
