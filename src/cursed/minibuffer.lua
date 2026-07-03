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
local bit = require("bit")
local tb = require("cursed.tb")
local ColorScheme = require("cursed.colorscheme")
local completers = require("cursed.completers")

local COMP_MAX_VISIBLE = 5

----------------------------------------------------------------------------------------------------
-- UI color + cell-width / truncation / match-highlight helpers.
-- Compact local copies (mirroring completion_menu.lua) so this module
-- is self-contained and doesn't reach into the editor's privates.
----------------------------------------------------------------------------------------------------

--- Resolve a UI chrome color from the active colorscheme, falling back
--- to the terminal default during early startup (no scheme loaded yet).
---@param name string UI concept key in CONCEPT_SLOTS
---@return integer color
local function ui(name)
    local scheme = ColorScheme.active
    if scheme == nil then
        return tb.color_default
    end
    return scheme:color(name)
end

--- Display width of `s` in terminal cells: codepoint count. Assumes no
--- double-wide CJK (true for cursed's chrome).
---@param s string
---@return integer
local function cell_len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- Truncate `s` to at most `max` display cells, never splitting a
--- multibyte codepoint.
---@param s string
---@param max integer max cells
---@return string
local function truncate_cells(s, max)
    if max <= 0 then
        return ""
    end
    local cells = 0
    local byte_end = 0
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
        if cells + 1 > max then
            break
        end
        byte_end = i + len - 1
        cells = cells + 1
        i = i + len
    end
    return s:sub(1, byte_end)
end

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

--- Set of byte positions in `display` covered by the first occurrence
--- of each whitespace-separated term of `query`. Drives match-
--- highlighting in the list (matched chars pop, unmatched recede).
---@param display string visible (already-truncated) item text
---@param query string the prefix/word being completed
---@return table set of byte-index -> true (1-based, inclusive)
local function match_byte_set(display, query)
    local set = {}
    if not query or query == "" then
        return set
    end
    local lower = display:lower()
    for term in query:lower():gmatch("%S+") do
        local i, j = lower:find(term, 1, true)
        if i then
            for b = i, j do
                set[b] = true
            end
        end
    end
    return set
end

--- Print one completion-text row with matched substrings (per
--- `match_byte_set`) drawn in a distinct fg + style so the user can see
--- WHY each candidate matched. Splits into contiguous matched /
--- unmatched byte-runs and prints each with its own fg, advancing by
--- cell width so multi-byte chrome stays aligned. `mset` nil → single
--- unmatch-fg pass (no highlighting).
---@param fp function float-print sink (x, y, text, fg, bg)
---@param cx integer screen col
---@param cy integer screen row
---@param text string
---@param matched_fg integer
---@param unmatch_fg integer
---@param bg_p integer
---@param mset table|nil
---@param matched_style integer|nil additional style bits OR'd onto matched fg
local function print_highlighted(
    fp,
    cx,
    cy,
    text,
    matched_fg,
    unmatch_fg,
    bg_p,
    mset,
    matched_style
)
    local n = #text
    if n == 0 then
        return
    end
    local sx = cx
    local run_start = 1
    local cur = (mset ~= nil) and (mset[1] or false) or false
    for i = 2, n + 1 do
        local m = (mset ~= nil) and (mset[i] or false) or false
        if m ~= cur or i == n + 1 then
            local seg_end = i - 1
            if seg_end >= run_start then
                local sub = text:sub(run_start, seg_end)
                local fg = cur and matched_fg or unmatch_fg
                if cur and matched_style then
                    fg = bit.bor(fg, matched_style)
                end
                fp(sx, cy, sub, fg, bg_p)
                sx = sx + cell_len(sub)
            end
            run_start = i
            cur = m
        end
    end
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
        --- When true the minibuffer renders as a centered floating
        --- palette (command-palette style) instead of the inline
        --- bottom strip. Set by callers like M-x; ordinary reads
        --- (search, find-file, read-char) stay inline.
        palette = false,
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

--- Re-run the completer against the current text WITHOUT requiring a
--- text change, keeping the selection index when it is still valid.
--- Used by asynchronous completion sources (e.g. LSP workspace/document
--- symbol search) to swap fresh results into the list after a response
--- lands — the re-render next frame picks up `self._completions`. A
--- no-op when completion mode is off.
function Minibuffer:refresh_completions()
    if not self.active or not self.completion or not self.completer then
        return
    end
    self._completions = self.completer(self:view_text())
    -- Keep the existing selection if it still falls within bounds; this
    -- lets an async refresh (results narrowed/expanded/gone) preserve the
    -- user's highlighted row instead of snapping back to the top.
    if self._comp_index < 1 or self._comp_index > #self._completions then
        self._comp_index = #self._completions > 0 and 1 or 0
        self._comp_scroll = 0
    else
        self:_comp_ensure_visible()
    end
    self:_fire_on_change(self:view_text())
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
---@param opts { prompt: string?, on_submit: function?, on_cancel: function?, on_change: function?, initial: string?, completion: boolean?, completer: function?, value: any?, auto_accept: boolean?, palette: boolean? }
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
    self.palette = opts.palette or false
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
    self.palette = false
end

----------------------------------------------------------------------------------------------------
-- View: render
--
-- Painted from `Editor:render` just before the buffer paint loop
-- (an EARLY synchronous call). The returned count drives the buffer-
-- region narrowing (`max_y` / `modeline_y`): the inline bottom strip
-- reserves its input rows + visible completions below the modeline, so
-- the editor shrinks the viewport that many rows up to make room; the
-- floating palette (M-x) floats centered over the buffer and reserves
-- nothing. Composes via the overlay float sink so it stacks with the
-- modeline, in-buffer completion popup, and extension overlays.
----------------------------------------------------------------------------------------------------

--- Render the minibuffer chrome (inline bottom strip / floating palette)
--- and return how many screen rows the buffer region must reserve
--- below the modeline for this surface — the "move-up" count.
--- Inline strip reserves `input_rows + comp_visible_rows`; the floating
--- palette reserves 0. No-op (returns 0) when inactive.
---@param editor Editor owning editor (for term dims + `_blink_on`)
---@param w integer terminal width
---@param h integer terminal height
---@param fp function float-print sink (x, y, text, fg, bg)
---@return integer mb_tail rows reserved below the modeline this frame
function Minibuffer:_render(editor, w, h, fp)
    if not self.active then
        return 0
    end

    local bg_default = ui("default_bg")
    if self.palette then
        self:_render_palette(editor, w, h, fp, bg_default)
        return 0
    end

    local mb_tail = self:input_rows() + self:comp_visible_rows()
    self:_render_inline(editor, w, h, fp, bg_default, mb_tail)
    return mb_tail
end

--- Render the inline bottom strip: prompt + multiline input, an
--- underline-bar caret (gated on the editor's blink phase), and the
--- completion list below the input rows. Painted into rows
--- `[h - mb_tail, h - 1]` so it sits just below the modeline
--- (`h - mb_tail - 1`).
---@param editor Editor
---@param w integer terminal width
---@param h integer terminal height
---@param fp function float-print sink
---@param bg_default integer default_bg color
---@param mb_tail integer total rows this surface reserves (input + comp)
function Minibuffer:_render_inline(editor, w, h, fp, bg_default, mb_tail)
    local line_offset = h - mb_tail -- == modeline_y + 1
    local mb_view = self.view
    local mb_buf = mb_view.buffer
    local line_count = mb_buf:line_count()
    local prompt = self.prompt
    local prompt_w = cell_len(prompt)
    local prompt_fg = ui("minibuffer_prompt")
    local text_fg = ui("minibuffer_text")

    for li = 0, line_count - 1 do
        local line_text = mb_buf:line_text(li)
        -- Strip trailing newline for display.
        if #line_text > 0 and line_text:byte(#line_text) == 10 then
            line_text = line_text:sub(1, #line_text - 1)
        end
        local row = line_offset + li
        if li == 0 then
            -- First line: prompt + text
            fp(0, row, prompt, prompt_fg, bg_default)
            fp(prompt_w, row, line_text, text_fg, bg_default)
        else
            -- Subsequent lines: full width
            fp(0, row, line_text, text_fg, bg_default)
        end
    end

    -- Caret: hardware caret is hidden; drawn as a reverse-video cell
    -- (underline-bar style here so input contexts read distinctly from
    -- the main view's block caret) gated on the editor's blink phase.
    local mb_pos = mb_view:p()
    local cursor_row = line_offset + mb_pos.line
    local cursor_col = mb_pos.line == 0 and (prompt_w + mb_pos.col) or mb_pos.col
    if editor._blink_on and cursor_col < w then
        local lt = mb_buf:line_text(mb_pos.line)
        if #lt > 0 and lt:byte(#lt) == 10 then
            lt = lt:sub(1, #lt - 1)
        end
        local ch = lt:sub(mb_pos.col + 1, mb_pos.col + 1)
        if #ch == 0 then
            ch = " "
        end
        local bar_fg = bit.bor(ui("cursor_bg"), tb.underline)
        fp(cursor_col, cursor_row, ch, bar_fg, bg_default)
    end

    -- Completion list: full width, starting below the input rows.
    if self.completion and #self._completions > 0 then
        self:_paint_completions(0, line_offset + line_count, w, COMP_MAX_VISIBLE, bg_default, fp)
    end
end

--- Render the floating centered palette (M-x): a solid-bordered box
--- over the buffer with rounded corners, prompt + input on the second
--- row, and completions listed inside. Reserves no bottom rows.
---@param editor Editor
---@param w integer terminal width
---@param h integer terminal height
---@param fp function float-print sink
---@param bg_default integer default_bg color
function Minibuffer:_render_palette(editor, w, h, fp, bg_default)
    local mb_view = self.view
    local mb_buf = mb_view.buffer
    local prompt = self.prompt
    local prompt_w = cell_len(prompt)

    -- Box dimensions.
    local box_w = math.min(math.max(48, prompt_w + 24), w - 4)
    local box_x = math.floor((w - box_w) / 2)
    local n_comp = 0
    if self.completion and #self._completions > 0 then
        n_comp = math.min(#self._completions - (self._comp_scroll or 0), COMP_MAX_VISIBLE)
    end
    local box_h = 2 + 1 + n_comp + 1
    local box_y = math.floor((h - box_h) / 2)

    local border_fg = bit.bor(ui("minibuffer_prompt"), tb.bold)
    local prompt_fg = ui("minibuffer_prompt")
    local text_fg = ui("minibuffer_text")

    -- Clear the box interior with default_bg so it floats cleanly.
    for r = 0, box_h - 1 do
        fp(box_x, box_y + r, string.rep(" ", box_w), bg_default, bg_default)
    end

    -- Top border: ╭─...─╮
    fp(box_x, box_y, "╭" .. string.rep("─", box_w - 2) .. "╮", border_fg, bg_default)

    -- Input row: prompt + text.
    local input_y = box_y + 1
    fp(box_x + 1, input_y, prompt, prompt_fg, bg_default)
    do
        local lt = mb_buf:line_text(0)
        if #lt > 0 and lt:byte(#lt) == 10 then
            lt = lt:sub(1, #lt - 1)
        end
        local max_text = box_w - 2 - prompt_w
        fp(box_x + 1 + prompt_w, input_y, truncate_cells(lt, max_text), text_fg, bg_default)
    end

    -- Caret (underline bar, same as inline strip).
    if editor._blink_on then
        local lt = mb_buf:line_text(0)
        if #lt > 0 and lt:byte(#lt) == 10 then
            lt = lt:sub(1, #lt - 1)
        end
        local bcol = mb_view:p().col
        local cursor_col = box_x + 1 + prompt_w + bcol
        if cursor_col < box_x + box_w - 1 then
            local ch = lt:sub(bcol + 1, bcol + 1)
            if #ch == 0 then
                ch = " "
            end
            local bar_fg = bit.bor(ui("cursor_bg"), tb.underline)
            fp(cursor_col, input_y, ch, bar_fg, bg_default)
        end
    end

    -- Completions inside the box.
    if n_comp > 0 then
        self:_paint_completions(box_x + 1, input_y + 1, box_w - 2, COMP_MAX_VISIBLE, bg_default, fp)
    end

    -- Bottom border: ╰─...─╯
    fp(
        box_x,
        box_y + box_h - 1,
        "╰" .. string.rep("─", box_w - 2) .. "╯",
        border_fg,
        bg_default
    )
end

--- Unified completion-list renderer shared by the inline strip and the
--- floating palette. Paints up to `max_visible` items starting at (x, y)
--- over a `bg` background, draws a scrollbar on the far right when the
--- list overflows, and Helm/ido-style match-highlights each row.
---@param x integer screen col
---@param y integer screen row
---@param width integer list width (cells)
---@param max_visible integer max rows to paint
---@param bg integer surrounding bg color
---@param fp function float-print sink (x, y, text, fg, bg)
function Minibuffer:_paint_completions(x, y, width, max_visible, bg, fp)
    local completions = self._completions
    local total = #completions
    if total == 0 then
        return
    end
    local selected = self._comp_index or 0
    local scroll = self._comp_scroll or 0
    local n = math.min(total - scroll, max_visible)
    if n <= 0 then
        return
    end
    -- Reserve a scrollbar gutter on the far right only when the list
    -- actually overflows; otherwise the full width is usable.
    local needs_sb = total > max_visible
    local list_w = needs_sb and (width - 1) or width
    local cur_fg = ui("cursor_fg")
    local cur_bg = ui("cursor_bg")
    local norm_fg = ui("minibuffer_prompt")
    local meta_fg = ui("minibuffer_metadata")
    local bright_fg = ui("minibuffer_text")
    local dim_fg = meta_fg
    local accent_fg = norm_fg
    local query = self:view_text()

    -- Metadata column: longest displayed text + 2-space gap.
    local max_text = 0
    for i = 1, n do
        local tlen = cell_len(comp_text(completions[scroll + i]))
        if tlen > max_text then
            max_text = tlen
        end
    end
    local meta_col = max_text + 2
    local show_meta = meta_col + 4 <= list_w

    for i = 1, n do
        local ci = scroll + i
        local row = y + i - 1
        local item = completions[ci]
        local text = truncate_cells(comp_text(item), list_w)
        local meta = show_meta and comp_meta(item) or nil
        if ci == selected then
            -- Full-width reverse-video bar: fill the row with the
            -- selection bg first, then print text + meta on top.
            fp(x, row, string.rep(" ", list_w), cur_fg, cur_bg)
            local mset = match_byte_set(text, query)
            if next(mset) then
                print_highlighted(fp, x, row, text, accent_fg, cur_fg, cur_bg, mset, tb.bold)
            else
                fp(x, row, text, cur_fg, cur_bg)
            end
            if meta and meta_col + cell_len(meta) <= list_w then
                fp(x + meta_col, row, meta, cur_fg, cur_bg)
            end
        else
            local mset = match_byte_set(text, query)
            if next(mset) then
                print_highlighted(fp, x, row, text, bright_fg, dim_fg, bg, mset, tb.bold)
            else
                fp(x, row, text, norm_fg, bg)
            end
            if meta and meta_col + cell_len(meta) <= list_w then
                fp(x + meta_col, row, meta, meta_fg, bg)
            end
        end
    end

    -- Scrollbar: a 1-column gutter on the far right. Track = dim │,
    -- thumb = █ over the slice of the list currently in view.
    if needs_sb then
        local sb_col = x + width - 1
        local track_fg = ui("scrollbar_track")
        local thumb_fg = ui("scrollbar_thumb")
        local scrollable = math.max(1, total - n)
        local thumb_size = math.max(1, math.floor(n * n / total))
        local thumb_top = math.floor(scroll / scrollable * (n - thumb_size))
        if thumb_top < 0 then
            thumb_top = 0
        elseif thumb_top > n - thumb_size then
            thumb_top = n - thumb_size
        end
        for i = 0, n - 1 do
            local on_thumb = i >= thumb_top and i < thumb_top + thumb_size
            fp(sb_col, y + i, on_thumb and "█" or "│", on_thumb and thumb_fg or track_fg, bg)
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    Minibuffer = Minibuffer,
    comp_text = comp_text,
    comp_meta = comp_meta,
}
