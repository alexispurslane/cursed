--- Spell store: per-buffer misspelling list, version-stamped against
--- `buf._words_gen` (the same mutation counter `completers.buffer_words`
--- uses). Mirrors the shape of `lsp.diagnostics_for_uri` so the
--- squiggle painter, picker, and completer all read from one source.
---
--- Entries are flat byte ranges in the buffer's native addressing:
---   { line, s_col, e_col, word, suggestions }
--- `line`/`s_col`/`e_col` are 0-based byte offsets, matching what
--- `OverlayManager:put_underline` and the mouse-click handler expect.
---
--- Keyed by buffer identity (the Buffer pointer token), not URI — spell
--- applies to unsaved scratch buffers too.

local M = {}

--- Tag the key we store stores under. The buffer's cdata pointer address
--- is stable for the buffer's lifetime and unique across open buffers.
local function key(buf)
	if buf == nil then
		return nil
	end
	local p = buf._ptr
	if p == nil then
		return nil
	end
	return tostring(p)
end

---@class SpellStore
---@field _stores table<string, {version: integer, items: table[]}> per-buffer stores
local store = { _stores = {} }
store.__index = store

---@return SpellStore
function M.new()
	return setmetatable({}, store)
end

--- Get the store entry for a buffer, or nil when no spell data exists.
---@param buf table
---@return {version: integer, items: table[]}|nil
function store:for_buf(buf)
	local k = key(buf)
	if k == nil then
		return nil
	end
	return self._stores[k]
end

--- Replace the misspelling list for `buf`, stamped against `gen`.
--- Clears the store if `items` is empty.
---@param buf table
---@param items table[] list of {line, s_col, e_col, word, suggestions}
---@param gen integer buf._words_gen at check time
function store:set(buf, items, gen)
	local k = key(buf)
	if k == nil then
		return
	end
	if items == nil or #items == 0 then
		self._stores[k] = nil
		return
	end
	self._stores[k] = { version = gen, items = items }
end

--- Add a single entry to the store (append), bumping nothing. Used by
--- the live client as it streams results. The final `set` on request
--- completion replaces the accumulated list atomically.
---@param buf table
---@param entry table {line, s_col, e_col, word, suggestions}
function store:add(buf, entry)
	local k = key(buf)
	if k == nil then
		return
	end
	local s = self._stores[k]
	if s == nil then
		s = { version = 0, items = {} }
		self._stores[k] = s
	end
	s.items[#s.items + 1] = entry
end

--- Drop the store for a buffer (on close / reinvalidate).
---@param buf table
function store:clear(buf)
	local k = key(buf)
	if k == nil then
		return
	end
	self._stores[k] = nil
end

--- Is `buf._words_gen` still consistent with the stored version?
--- A stale store means edits happened after the check; the squiggle
--- painter treats a stale store as empty (no squiggles) so we never
--- squiggle at displaced ranges.
---@param buf table
---@return boolean
function store:fresh(buf)
	local s = self:for_buf(buf)
	if s == nil then
		return true -- no store → vacuously fresh (nothing to paint)
	end
	return s.version == (buf._words_gen or 0)
end

--- Items iterator for painting. Returns a fresh-windowed slice.
---@param buf table
---@param top_li integer first visible 0-based line
---@param bottom_li integer last visible 0-based line
---@return table[] items subset whose line ∈ [top_li, bottom_li]
function store:visible(buf, top_li, bottom_li)
	local s = self:for_buf(buf)
	if s == nil then
		return {}
	end
	if not self:fresh(buf) then
		return {}
	end
	local out = {}
	for _, it in ipairs(s.items) do
		if it.line >= top_li and it.line <= bottom_li then
			out[#out + 1] = it
		end
	end
	return out
end

--- All items for a buffer (when fresh), else {}.
---@param buf table
---@return table[]
function store:items(buf)
	local s = self:for_buf(buf)
	if s == nil then
		return {}
	end
	if not self:fresh(buf) then
		return {}
	end
	return s.items
end

--- Find the next misspelling at-or-after (line, col).
--- Returns the entry, or nil when none.
---@param buf table
---@param line integer 0-based
---@param col integer 0-based byte offset
---@return table|nil
function store:find_next(buf, line, col)
	local items = self:items(buf)
	local best = nil
	for _, it in ipairs(items) do
		if it.line > line or (it.line == line and it.e_col > col) then
			if best == nil or (it.line < best.line) or (it.line == best.line and it.s_col < best.s_col) then
				best = it
			end
		end
	end
	return best
end

--- Find the misspelled entry covering (line, col) — the word under the
--- cursor. Returns nil when the cursor is not on a flagged word.
---
--- The check is inclusive at `e_col` so a cursor sitting "just past the
--- word's last byte" (e.g. after `step()` in flyspell_correct
--- positions at the entry's `e_col` for accept-replace semantics) is
--- still associated with the word the user is operating on.
---@param buf table
---@param line integer 0-based
---@param col integer 0-based byte offset
---@return table|nil
function store:word_at(buf, line, col)
	local items = self:items(buf)
	for _, it in ipairs(items) do
		if it.line == line and col >= it.s_col and col <= it.e_col then
			return it
		end
	end
	return nil
end

return M
