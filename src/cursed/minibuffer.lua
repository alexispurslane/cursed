--- Minibuffer: a multi-line input area at the bottom of the screen.
---
--- Provides a View+Buffer for text input with a prompt and submit/cancel
--- callbacks. Activated via Editor:read_from_minibuffer(), deactivated
--- on Enter (submit) or C-g (cancel). C-j inserts a literal newline,
--- allowing multiline input — the minibuffer expands to show all lines.
---
--- History is keyed by prompt string: each prompt gets its own ring.
--- M-p / M-n cycle through previous inputs.
---
--- Completion mode: when `completion` is true in opts, the completer
--- function is called on every change. Results are shown vertically
--- below the minibuffer (max 5 visible). Up/Down scroll, Tab expands,
--- Enter chooses and submits. Default completer: prefix match on history.
---
--- Auto-accept mode: when `auto_accept` is true, the minibuffer will
--- automatically submit when the current input exactly matches one of
--- the completion options, without requiring Enter. Useful for selecting
--- from a known list (e.g. buffer switch, kill buffer).

local View = require("cursed.view").View
local Buffer = require("cursed.buffer").Buffer

local COMP_MAX_VISIBLE = 5

----------------------------------------------------------------------------------------------------
-- Completion item helpers (backward compatible)
----------------------------------------------------------------------------------------------------

--- A completion item is either a bare `string` (legacy) or a table
--- `{ text = string, metadata = string? }` (new). These helpers normalize
--- access so completers may return either shape.

--- Extract the display text from a completion item.
---@param item string|{text: string, metadata: string?}
---@return string
local function comp_text(item)
    if type(item) == "table" then
        return item.text or ""
    end
    return item
end

--- Extract the metadata string from a completion item (nil if absent).
---@param item string|{text: string, metadata: string?}
---@return string|nil
local function comp_meta(item)
    if type(item) == "table" then
        return item.metadata
    end
    return nil
end

---@class Minibuffer
---@field view View the permanent input view
---@field active boolean whether the minibuffer is currently shown
---@field prompt string displayed before input
---@field on_submit function|nil called with input text on submit
---@field on_cancel function|nil called on cancel
---@field on_change function|nil called with input text when it changes
---@field _prev_text string previous input text (for change detection)
---@field _histories table<string, string[]> prompt-keyed history rings
---@field _hist_index integer|nil current position in history (0=newest, up=older)
---@field _hist_draft string|nil saved in-progress text when navigating away
---@field completion boolean whether completion mode is active
---@field completer function|nil called with text, returns completion items (string or {text,metadata})
---@field _completions table current completion items (string or {text,metadata})
---@field _comp_index integer 1-based index of selected completion (0 = none)
---@field _comp_scroll integer scroll offset into completion list
---@field auto_accept boolean when true, auto-submit on exact match with a completion
---@field _auto_accepting boolean true while auto-accept is firing (prevents re-entrant submit)
---@field _just_closed integer? count of stale Enter/Tab events to suppress after auto-accept
local Minibuffer = {}
Minibuffer.__index = Minibuffer

----------------------------------------------------------------------------------------------------
-- Internal: input buffer construction
----------------------------------------------------------------------------------------------------

--- Create a fresh input buffer initialized with one empty line.
--- Matches the empty-file convention used by Buffer.from_mmap.
---@return Buffer
local function make_input_buffer()
    local buf = Buffer.new()
    local nl_off = buf:append_add("\n")
    buf:grow_lines(1)
    buf:init_line(0, 1, nl_off, 1)
    buf._ptr.count = 1
    return buf
end

----------------------------------------------------------------------------------------------------
-- Internal: set the buffer text and place cursor at end
----------------------------------------------------------------------------------------------------

--- Replace the minibuffer input with the given string (may contain newlines).
--- Delete-then-insert runs as one undo group (caller-managed grouping
--- now that Buffer primitives are grouping-naive).
---@param text string
function Minibuffer:_set_text(text)
    local view = self.view
    self:_atomic(function()
        local buf = view.buffer
        while buf:line_count() > 1 do
            buf:delete_char(0, 0, buf:line_len(0))
        end
        local content_len = buf:line_len(0) - 1
        if content_len > 0 then
            buf:delete_char(0, 0, content_len)
        end
        if #text > 0 then
            local rl, rc = buf:insert_char(0, 0, text)
            view:p().line = rl
            view:p().col = rc
            view:_set_goal_col(rc)
        else
            view:p().line = 0
            view:p().col = 0
            view:_set_goal_col(0)
        end
    end)
end

----------------------------------------------------------------------------------------------------
-- Internal: default completer (prefix match on history)
----------------------------------------------------------------------------------------------------

local function history_completer(mb, text)
    if #text == 0 then
        return {}
    end
    local ring = mb._histories[mb.prompt]
    if not ring then
        return {}
    end
    local results = {}
    for i = #ring, 1, -1 do
        if ring[i]:sub(1, #text) == text then
            results[#results + 1] = ring[i]
        end
    end
    return results
end

----------------------------------------------------------------------------------------------------
-- Atomic edit group helper
----------------------------------------------------------------------------------------------------

--- Run `fn` as one undo group on the minibuffer's buffer.
--- The minibuffer's programmatic resets/pre-fills (activate, _set_text)
--- are multi-step delete+insert that should coalesce into a single
--- undo step — Buffer primitives no longer manage grouping themselves.
---@param fn fun()
function Minibuffer:_atomic(fn)
    local buf = self.view.buffer
    buf:close_edit()
    buf:begin_edit()
    fn()
    buf:end_edit()
end

----------------------------------------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------------------------------------

--- Create a new Minibuffer with a permanent View+Buffer.
---@return Minibuffer
function Minibuffer.new()
    local buf = make_input_buffer()
    local view = View.new(buf)
    view.file_loaded = true

    return setmetatable({
        view = view,
        active = false,
        prompt = "",
        on_submit = nil,
        on_cancel = nil,
        on_change = nil,
        _prev_text = "",
        _histories = {},
        _hist_index = nil,
        _hist_draft = nil,
        completion = false,
        completer = nil,
        _completions = {},
        _comp_index = 0,
        _comp_scroll = 0,
        auto_accept = false,
        _auto_accepting = false,
    }, Minibuffer)
end

----------------------------------------------------------------------------------------------------
-- Text access
---------------------------------------------------------------------------------------------------

--- Get the current input text (all lines joined, trailing newline stripped).
---@return string
function Minibuffer:view_text()
    local buf = self.view.buffer
    local parts = {}
    for i = 0, buf:line_count() - 1 do
        parts[#parts + 1] = buf:line_text(i)
    end
    local text = table.concat(parts)
    -- Strip single trailing newline (the empty-line sentinel)
    if #text > 0 and text:byte(#text) == 10 then
        text = text:sub(1, #text - 1)
    end
    return text
end

--- Number of rows the minibuffer input requires (one per line).
---@return integer
function Minibuffer:input_rows()
    return self.view.buffer:line_count()
end

--- Fire on_change with the current text + selected completion index.
--- Called after text edits AND after completion navigation
--- (comp_up/comp_down) so live-preview callbacks can react to the
--- highlighted completion as well as typed input. `comp_index` is
--- 0 when no completion is selected, otherwise 1-based into
--- `self._completions`.
---@param text string  the current minibuffer text
function Minibuffer:_fire_on_change(text)
    if self.on_change then
        self.on_change(text, self._comp_index)
    end
end

--- If the minibuffer is active, fire on_change and completer when text has changed.
--- Called from the main loop after each key event.
--- When auto_accept is enabled and the input exactly matches a completion,
--- the minibuffer auto-submits immediately.
function Minibuffer:notify_change()
    if not self.active then
        return
    end
    local text = self:view_text()
    if text ~= self._prev_text then
        self._prev_text = text
        if self.completion and self.completer then
            self._completions = self.completer(text)
            self._comp_index = #self._completions > 0 and 1 or 0
            self._comp_scroll = 0

            -- Auto-accept: if input exactly matches one completion, submit immediately
            if
                self.auto_accept
                and not self._auto_accepting
                and #self._completions == 1
                and comp_text(self._completions[1]) == text
            then
                self._auto_accepting = true
                self:history_push(text)
                -- Capture callback before deactivate clears it.
                -- Deactivate FIRST so on_submit can start a new session
                -- (e.g. query-replace chaining) without this deactivate killing it.
                local callback = self.on_submit
                self:deactivate()
                -- Flag that minibuffer just closed, so stale Enter/Tab
                -- events don't dispatch to the main view.
                -- Count: 2 because both Tab and Enter may arrive after
                -- auto_accept.
                self._just_closed = 2
                if callback then
                    callback(text)
                end
                return
            end
        end
        -- Fire on_change AFTER completions are refreshed so the callback
        -- sees the up-to-date comp_index / completion list (live-preview
        -- callbacks resolve the highlighted completion from this).
        self:_fire_on_change(text)
    end
end

----------------------------------------------------------------------------------------------------
-- History
----------------------------------------------------------------------------------------------------

--- Get the history ring for the current prompt.
---@return string[]
function Minibuffer:_history_ring()
    local ring = self._histories[self.prompt]
    if not ring then
        ring = {}
        self._histories[self.prompt] = ring
    end
    return ring
end

--- Push a value onto the history ring for the current prompt.
--- Deduplicates: if the value already exists at the top, skip.
---@param value string
function Minibuffer:history_push(value)
    if #value == 0 then
        return
    end
    local ring = self:_history_ring()
    if #ring > 0 and ring[#ring] == value then
        return
    end
    ring[#ring + 1] = value
end

--- Go up one entry in history (toward older entries).
function Minibuffer:history_up()
    local ring = self:_history_ring()
    if #ring == 0 then
        return
    end
    if self._hist_index == nil then
        self._hist_draft = self:view_text()
        self._hist_index = 0
    end
    if self._hist_index >= #ring then
        return
    end
    self._hist_index = self._hist_index + 1
    self:_set_text(ring[#ring - self._hist_index + 1])
end

--- Go down one entry in history (toward newer entries).
function Minibuffer:history_down()
    if self._hist_index == nil then
        return
    end
    self._hist_index = self._hist_index - 1
    if self._hist_index <= 0 then
        self._hist_index = nil
        self:_set_text(self._hist_draft or "")
        self._hist_draft = nil
    else
        local ring = self:_history_ring()
        self:_set_text(ring[#ring - self._hist_index + 1])
    end
end

----------------------------------------------------------------------------------------------------
-- Completion navigation
----------------------------------------------------------------------------------------------------

--- Number of visible completion rows for the current completion list.
---@return integer
function Minibuffer:comp_visible_rows()
    if not self.completion then
        return 0
    end
    return math.min(#self._completions, COMP_MAX_VISIBLE)
end

--- Ensure the current completion selection is within the visible
--- window, adjusting `_comp_scroll` if needed. Handles both directions:
--- scrolled past the top OR past the bottom (which is what happens on
--- wrap-around, where the old per-direction checks missed the scrolled
--- case).
function Minibuffer:_comp_ensure_visible()
    local idx = self._comp_index
    if idx < 1 then
        return
    end
    -- Visible window is (scroll+1 .. scroll+COMP_MAX_VISIBLE), 1-based.
    if idx <= self._comp_scroll then
        self._comp_scroll = idx - 1
    elseif idx > self._comp_scroll + COMP_MAX_VISIBLE then
        self._comp_scroll = idx - COMP_MAX_VISIBLE
    end
end

--- Move the completion selection up one.
function Minibuffer:comp_up()
    if not self.completion or #self._completions == 0 then
        return
    end
    if self._comp_index <= 1 then
        self._comp_index = #self._completions
    else
        self._comp_index = self._comp_index - 1
    end
    self:_comp_ensure_visible()
    -- Fire on_change so live-preview callbacks react to the newly
    -- highlighted completion (text is unchanged, but comp_index moved).
    self:_fire_on_change(self:view_text())
end

--- Move the completion selection down one.
function Minibuffer:comp_down()
    if not self.completion or #self._completions == 0 then
        return
    end
    if self._comp_index >= #self._completions then
        self._comp_index = 1
    else
        self._comp_index = self._comp_index + 1
    end
    self:_comp_ensure_visible()
    -- Fire on_change so live-preview callbacks react to the newly
    -- highlighted completion (text is unchanged, but comp_index moved).
    self:_fire_on_change(self:view_text())
end

--- Expand the selected completion into the minibuffer (Tab).
--- Returns true if a completion was expanded.
---@return boolean
function Minibuffer:comp_expand()
    if not self.completion or self._comp_index < 1 then
        return false
    end
    local item = self._completions[self._comp_index]
    if not item then
        return false
    end
    self:_set_text(comp_text(item))
    return true
end

--- Expand the selected completion and submit (Enter on completion).
--- Returns true if a completion was chosen.
---@return boolean
function Minibuffer:comp_submit()
    if not self.completion or self._comp_index < 1 then
        return false
    end
    local item = self._completions[self._comp_index]
    if not item then
        return false
    end
    self:_set_text(comp_text(item))
    return true
end

----------------------------------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------------------------------

--- Activate the minibuffer with the given options.
--- Resets the buffer content and overwrites callbacks.
---@param opts { prompt: string?, on_submit: function?, on_cancel: function?, on_change: function?, initial: string?, completion: boolean?, completer: function?, value: any?, auto_accept: boolean? }
function Minibuffer:activate(opts)
    local view = self.view

    -- Reset buffer: delete all content back to a single empty line,
    -- then pre-fill — all as one undo group (caller-managed grouping
    -- now that Buffer primitives are grouping-naive).
    self:_atomic(function()
        local buf = view.buffer
        while buf:line_count() > 1 do
            buf:delete_char(0, 0, buf:line_len(0))
        end
        local content_len = buf:line_len(0) - 1
        if content_len > 0 then
            buf:delete_char(0, 0, content_len)
        end
        view:p().line = 0
        view:p().col = 0
        view:_set_goal_col(0)
        view:p().anchor_line = nil
        view:p().anchor_col = nil

        if opts.initial and #opts.initial > 0 then
            local rl, rc = buf:insert_char(0, 0, opts.initial)
            view:p().line = rl
            view:p().col = rc
            view:_set_goal_col(rc)
        end
    end)

    self.active = true
    self.prompt = opts.prompt or ""
    self.on_submit = opts.on_submit
    self.on_cancel = opts.on_cancel
    self.on_change = opts.on_change
    self._prev_text = self:view_text()
    self._hist_index = nil
    self._hist_draft = nil

    -- Fire on_change if initial text was provided
    if opts.initial and #opts.initial > 0 and self.on_change then
        self.on_change(opts.initial)
    end

    -- Completion
    self.completion = opts.completion or false
    if self.completion then
        self.completer = opts.completer
            or function(text)
                return history_completer(self, text)
            end
        self._completions = self.completer(self:view_text())
        self._comp_index = #self._completions > 0 and 1 or 0
        self._comp_scroll = 0
    else
        self.completer = nil
        self._completions = {}
        self._comp_index = 0
        self._comp_scroll = 0
    end
    self.auto_accept = opts.auto_accept or false
    self._auto_accepting = false
end

--- Deactivate the minibuffer, clearing callbacks.
--- Buffer+View are kept for next invocation.
function Minibuffer:deactivate()
    self.active = false
    self.prompt = ""
    self.on_submit = nil
    self.on_cancel = nil
    self.on_change = nil
    self._prev_text = ""
    self._hist_index = nil
    self._hist_draft = nil
    self.completion = false
    self.completer = nil
    self._completions = {}
    self._comp_index = 0
    self._comp_scroll = 0
    self.auto_accept = false
    self._auto_accepting = false
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    Minibuffer = Minibuffer,
    comp_text = comp_text,
    comp_meta = comp_meta,
}
