--- Spell driver: debounced re-check coordinator.
---
--- Listens to buffer edits (via a post_command_hook on the gen counter,
--- mirroring how `completers.buffer_words` invalidates its cache) +
--- buffer_open + viewport scroll. On a quiet window, masks the visible
--- region, sends each masked line to the spell client, and swaps the
--- fresh results into the store version-stamped against `buf._words_gen`.
---
--- The squiggle painter (`on_render_spell_squiggles` in
--- editor_listeners) reads the store every frame, so once results land
--- the squiggles appear on the next render — no explicit repaint hook
--- needed.

local store_mod = require("cursed.spell.spell_store")
local mask_mod = require("cursed.spell.mask")
local client_mod = require("cursed.spell.client")

local M = {}

---@class SpellDriver
---@field _editor table owning editor
---@field _store SpellStore
---@field _client SpellClient
---@field _pending table<integer, table>bufkey → {timer scheduled check}
---@field _tracked table<integer, integer> bufkey → last-seen _words_gen
local SpellDriver = {}
SpellDriver.__index = SpellDriver

---@param editor table
---@return SpellDriver
function M.new(editor)
    local s = store_mod.new()
    local c = client_mod.new(editor, s)
    return setmetatable({
        _editor = editor,
        _store = s,
        _client = c,
        _pending = {},
        _tracked = {},
    }, SpellDriver)
end

--- Expose the store for the squiggle painter + completer.
---@return SpellStore
function SpellDriver:store()
    return self._store
end

--- Expose the client (for add_to_dict commands etc).
---@return SpellClient
function SpellDriver:client()
    return self._client
end

--- Debounce window in microseconds. Short enough to feel live while
--- typing, long enough to let a burst of keystrokes coalesce.
M.DEBOUNCE_US = 350 * 1000

--- Schedule a check for `buf` after the debounce window. Replaces any
--- pending check for the same buffer.
---@param buf table
function SpellDriver:_schedule(buf)
    local k = tostring(buf._ptr)
    ---@diagnostic disable-next-line: need-check-nil
    local prev = self._pending[k]
    if prev ~= nil and prev.task ~= nil then
        self._editor:cancel_task(prev.task)
    end
    local this = self
    local function fire()
        local p = this._pending[k]
        if p == nil then
            return -- superseded or cleared
        end
        this._pending[k] = nil
        this:_check(buf)
    end
    local task = self._editor:schedule_after(M.DEBOUNCE_US, fire)
    self._pending[k] = { task = task, buf = buf }
end

--- Compute the visible line window for `view`.
---@param view table
---@return integer top_li 0-based
---@return integer bottom_li 0-based
local function visible_window(view, editor)
    local top_li = view.scroll_li or 0
    local max_y = editor.term:height() - editor:footer_rows() - 1
    local bottom_li = view:viewport_line_at_row(max_y) or top_li
    -- Clamp to line count.
    local n = view:line_count()
    if bottom_li >= n then
        bottom_li = n - 1
    end
    if top_li < 0 then
        top_li = 0
    end
    return top_li, bottom_li
end

--- Run a check cycle on `buf`: mask the visible window and send each
--- line to the client.
---@param buf table
function SpellDriver:_check(buf)
    local view = self._editor:current_view()
    if view == nil or view.buffer ~= buf then
        -- Spell-check the current view's buffer only when focus is on it
        -- (the proc-pipe model is per-buffer; other buffers' procs
        -- persist but we re-check on focus return).
        return
    end
    if not view.file_loaded then
        return
    end
    local top_li, bottom_li = visible_window(view, self._editor)
    local scope, ranges = mask_mod.build_ranges(view, top_li, bottom_li)
    if scope == nil then
        return -- mode opted out of spellcheck entirely
    end
    local gen = buf._words_gen or 0
    self._client:begin_batch(buf, gen)
    for li = top_li, bottom_li do
        local text = buf:line_text(li)
        -- Strip trailing newline if present (line_text includes it).
        if #text > 0 and text:byte(#text) == 10 then
            text = text:sub(1, #text - 1)
        end
        ---@diagnostic disable-next-line: unused-local
        local masked, col0, _col1 = mask_mod.mask_line(view, li, text, scope, ranges)
        if masked ~= nil and #masked > 0 then
            self._client:check_line(buf, li, masked, col0, gen)
        end
    end
    self._client:end_batch()
    self._tracked[tostring(buf._ptr)] = gen
end

--- Hook: called after edits. Bumps the debounce if the buffer's gen
--- changed since we last checked.
---@param buf table
function SpellDriver:on_edit(buf)
    if buf == nil then
        return
    end
    local k = tostring(buf._ptr)
    local gen = buf._words_gen or 0
    if self._tracked[k] == gen then
        return -- no net change since last check
    end
    self:_schedule(buf)
end

--- Hook: a buffer was opened (or focused). Schedule an initial check.
---@param buf table
function SpellDriver:on_buffer_open(buf)
    if buf == nil then
        return
    end
    self:_schedule(buf)
end

--- Hook: viewport scrolled. Re-check in case new lines are visible
--- (cheap because begin_batch clears; the proc pipe is reusable).
---@param view table
function SpellDriver:on_scroll(view)
    if view == nil or view.buffer == nil then
        return
    end
    self:_schedule(view.buffer)
end

return M
