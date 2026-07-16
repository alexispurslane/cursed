--- Highlight lane main-side facade.
---
--- Minimal client: the highlight lane's state is per-view cache (parse
--- trees, queries). On restart, we re-send MSG_HL_INITIALIZE_LANGUAGE
--- and re-query for all open views so highlighting recovers.

local ffi = require("ffi")
local constants = require("cursed.shared")
local drain_generic = require("cursed.lane_registry").drain_generic
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

--- Drain the highlight lane inbox: install span replies from the
--- highlight lane into the appropriate view.
---@param editor table
function M.drain_inbox(editor)
	if M._ss == nil then
		return
	end
	drain_generic(M._ss, M._ss._ptr.inboxes[constants.LANE_IDX_HL], editor, {
		[constants.MSG_HL_SPANS] = function(msg)
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

require("cursed.lane_registry").register(constants.LANE_IDX_HL, M)
return M
