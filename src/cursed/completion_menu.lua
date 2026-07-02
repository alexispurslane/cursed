--- In-buffer completion popup — a self-contained system parallel to
--- the minibuffer.
--
--- The minibuffer is a modal input surface at the bottom of the screen;
--- it owns its own model (minibuffer.lua), its own view (in Editor:render),
--- and its own controller (commands bound for its duration). This module
--- is the analogue for at-cursor completion popups: a floating list that
--- follows the cursor as you type, flips above the cursor near the
--- bottom of the viewport, and lets you accept a candidate by replacing
--- the word currently being completed.
---
--- Design (MVC split, like the rest of cursed):
---   • Model     — items[], selected, scroll, max_visible, plus the
---                 configured `completer` source. Stateless about WHERE
---                 to paint: position is recomputed each frame from the
---                 live cursor, so the popup never drifts.
---   • View      — `_render` runs on the `render_overlay` event and
---                 paints a bordered floating box via the overlay
---                 manager's `put_float` (the same sink the modeline /
---                 palette use). Cursor-tracked anchoring + flip-above.
---   • Controller— `handle_key` is the first-crack key intercept
---                 (called from the main loop before the trie when the
---                 menu is open) for nav / accept / cancel; the
---                 `post_command_hook` listener drives auto-popup-while-
---                 typing: after a self-insert it debounces, re-queries
---                 the source, and opens/refreshes / closes the menu.
---
--- The completion source is pluggable: `set_completer(fn)` where
--- `fn(ctx) -> items` and `ctx` carries `{ view, buf, line, col,
--- prefix, word_start_col }`. The default source (installed by the
--- editor) is `completers.buffer_words` — a buffer-dabbrev provider —
--- which dogfoods the whole loop end-to-end without requiring LSP. An
--- LSP completion provider can later plug in via the same interface.
---
--- Completion items use the same shape as the minibuffer's completions:
--- either a bare `string` or `{ text = string, metadata = string? }`,
--- shared via `completers.comp_text` / `comp_meta` so a source isn't
--- coupled to this module's internals.

local bit = require("bit")
local tb = require("cursed.tb")
local ColorScheme = require("cursed.colorscheme")
local completers = require("cursed.completers")
local log = require("cursed.log")

----------------------------------------------------------------------------------------------------
-- UI color helper (mirrors Editor's local `ui`; isolated so this module
-- is self-contained and doesn't reach into the editor's privates).
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

----------------------------------------------------------------------------------------------------
-- Cell-width / truncation + match-highlight helpers.
-- (Compact local copies; the editor keeps its own for the minibuffer.
-- Keeping them here makes the popup self-contained and avoids a require
-- cycle on the editor.)
----------------------------------------------------------------------------------------------------

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

----------------------------------------------------------------------------------------------------
-- Context: the word being completed at the cursor.
----------------------------------------------------------------------------------------------------

---@class CompCtx
---@field view View
---@field buf Buffer
---@field line integer 0-based cursor line
---@field col integer 0-based cursor byte col
---@field prefix string the trailing [%w_]* run left of the cursor
---@field word_start_col integer 0-based byte col where the prefix starts
---@field force boolean|nil true when the menu was triggered manually / via a trigger char (bypass the source's stale-cache shortcuts)

--- A completion source: a callable table (via __call) returning items,
--- plus optional hooks the menu queries without entering the main
--- closure. Plain-function sources (e.g. buffer_words) lack the hooks;
--- the menu's trigger-fast-path / keep-open-loading checks guard for nil.
---@class Completer
---@field __call fun(self, ctx: CompCtx): (string|{text:string,metadata:string?})[]
---@field trigger_chars? fun(): table<string,boolean>|nil server-declared single-byte triggers for the active client
---@field pending? fun(): boolean is a request currently in flight for the active client

--- Build a completion context from the current cursor: the word being
--- completed is the trailing run of word bytes (`[%w_]`) immediately
--- left of the cursor. `word_start_col` is where that run begins (0-based
--- byte col); `prefix` is the run itself. Anything else here is just
--- convenience for the source function.
---@param view View|nil
---@return CompCtx|nil ctx, nil when the view/buffer isn't loaded
local function build_ctx(view)
    if view == nil or not view.file_loaded then
        return nil
    end
    local buf = view.buffer
    local p = view:p()
    local line = p.line or 0
    local col = p.col or 0
    local line_text = buf:line_text(line)
    -- Strip a single trailing newline (line_text includes it).
    if #line_text > 0 and line_text:byte(#line_text) == 10 then
        line_text = line_text:sub(1, #line_text - 1)
    end
    local before = line_text:sub(1, col)
    local prefix = before:match("[%w_]*$") or ""
    return {
        view = view,
        buf = buf,
        line = line,
        col = col,
        prefix = prefix,
        word_start_col = col - #prefix,
    }
end

----------------------------------------------------------------------------------------------------
-- CompletionMenu
----------------------------------------------------------------------------------------------------

---@class CompletionMenu
---@field _editor Editor owning editor
---@field _completer Completer|nil source: callable table returning items + optional trigger_chars/pending hooks
---@field active boolean whether the popup is currently shown
---@field _items table current completion items (string | {text,metadata})
---@field _selected integer 1-based index of the highlighted item (0 = none)
---@field _scroll integer scroll offset into _items (0-based)
---@field max_visible integer max visible rows (config)
---@field _wrap boolean whether nav wraps at the ends (config)
---@field _min_prefix integer min prefix length to auto-open (config)
---@field _debounce_us integer auto-popup debounce window (config)
---@field _debounce_task table|nil scheduled debounce handle
---@field _loading boolean true while a source request is in flight and the popup holds a loading placeholder (set by _tick, reset by close/response)
---@field _handlers table|nil {render=fn, post_command=fn} for teardown
local CompletionMenu = {}
CompletionMenu.__index = CompletionMenu

--- Default config. Tunable via opts to new()/set_config().
local DEFAULTS = {
    max_visible = 10,
    wrap = true,
    min_prefix = 2,
    debounce_us = 120 * 1000, -- 120ms
}

--- Create a new completion menu bound to an editor.
--- `opts` overrides defaults (max_visible, wrap, min_prefix, debounce_us).
---@param editor Editor
---@param opts table? { max_visible?: integer, wrap?: boolean, min_prefix?: integer, debounce_us?: integer }
---@return CompletionMenu
local function new(editor, opts)
    opts = opts or {}
    local self = setmetatable({
        _editor = editor,
        _completer = nil,
        active = false,
        _items = {},
        _selected = 0,
        _scroll = 0,
        max_visible = opts.max_visible or DEFAULTS.max_visible,
        _wrap = opts.wrap ~= nil and opts.wrap or DEFAULTS.wrap,
        _min_prefix = opts.min_prefix or DEFAULTS.min_prefix,
        _debounce_us = opts.debounce_us or DEFAULTS.debounce_us,
        _debounce_task = nil,
        _loading = false,
        _handlers = nil,
    }, CompletionMenu)
    return self
end

----------------------------------------------------------------------------------------------------
-- Source configuration
----------------------------------------------------------------------------------------------------

--- Install the completion source: `fn(ctx) -> items`, where `items` is a
--- list of bare strings or `{ text, metadata }`. Replaces any prior
--- source. The editor installs `completers.buffer_words` by default.
---@param fn Completer source
function CompletionMenu:set_completer(fn)
    self._completer = fn
end

----------------------------------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------------------------------

--- Close the popup and cancel any pending auto-open debounce.
function CompletionMenu:close()
    log.info("completion_menu", "close", {
        active = self.active,
        items = #self._items,
        task = self._debounce_task ~= nil,
    })
    self._editor:cancel_task(self._debounce_task)
    self._debounce_task = nil
    self.active = false
    self._items = {}
    self._selected = 0
    self._scroll = 0
    self._loading = false
end

--- Single-byte char string immediately left of the cursor (the last
--- inserted char after a __printable), or nil. Used by the trigger-char
--- fast-path to decide whether to pop the menu immediately (bypassing the
--- debounce) when the active source declares that char as a trigger.
--- @param view View|nil
--- @return string|nil
local function char_before_cursor(view)
    if view == nil or not view.file_loaded then
        return nil
    end
    local buf = view.buffer
    local p = view:p()
    local col = p.col or 0
    if col <= 0 then
        return nil
    end
    local line_text = buf:line_text(p.line or 0) or ""
    if #line_text > 0 and line_text:byte(#line_text) == 10 then
        line_text = line_text:sub(1, #line_text - 1)
    end
    local b = line_text:byte(col) -- 1-based index → byte before 0-based cursor
    if b == nil then
        return nil
    end
    return string.char(b)
end

--- Open/refresh from the configured source against the current cursor.
--- Opens (selected = 1, scroll = 0) when not yet active; otherwise
--- refreshes in place. `force` (manual trigger / trigger-char fast-path)
--- skips the min-prefix gate AND keeps the popup open in a loading state
--- when the source has a request in flight but no cached items yet.
function CompletionMenu:_tick(force)
    local forced = force == true
    log.info("completion_menu", "tick_start", {
        active = self.active,
        selected = self._selected,
        scroll = self._scroll,
        force = forced,
    })
    local editor = self._editor
    if editor.minibuffer and editor.minibuffer.active then
        log.info("completion_menu", "tick_close_mb_active")
        self:close()
        return
    end
    local view = editor:current_view()
    local ctx = build_ctx(view)
    if ctx == nil then
        log.info("completion_menu", "tick_close_nil_ctx")
        self:close()
        return
    end
    if not forced and #ctx.prefix < self._min_prefix then
        log.info("completion_menu", "tick_close_short_prefix", {
            prefix = ctx.prefix,
            min = self._min_prefix,
        })
        self:close()
        return
    end
    local fn = self._completer
    if fn == nil then
        log.info("completion_menu", "tick_close_no_completer")
        self:close()
        return
    end
    ctx.force = forced
    local ok, items = pcall(function()
        return fn(ctx)
    end)
    if not ok then
        log.error("completion_menu", "completer error", { error = tostring(items) })
        self:close()
        return
    end
    items = items or {}
    log.info("completion_menu", "tick_result", {
        view = tostring(view),
        prefix = ctx.prefix,
        line = ctx.line,
        col = ctx.col,
        word_start_col = ctx.word_start_col,
        items = #items,
        active = self.active,
        selected = self._selected,
    })
    if #items == 0 then
        -- A source with a request in flight (e.g. the LSP source on its
        -- very first query for a position) returns empty until the
        -- response lands and reticks. Keep the popup open as a loading
        -- placeholder instead of snapping closed, so manual/trigger
        -- completions feel responsive. The retick on response replaces
        -- the placeholder with real items.
        local pending = type(fn.pending) == "function" and fn.pending()
        if pending then
            self._loading = true
            self._items = {}
            self._selected = 0
            self._scroll = 0
            self.active = true
            log.info("completion_menu", "tick_open_loading")
            return
        end
        self:close()
        return
    end
    local was_active = self.active and not self._loading
    self._items = items
    if not was_active then
        self._selected = 1
        self._scroll = 0
    else
        -- Keep selection if still valid; else reset to top.
        if self._selected > #items then
            self._selected = 1
        end
        self._scroll = 0
    end
    self:_ensure_visible()
    self.active = true
    self._loading = false
    log.info("completion_menu", "tick_open", {
        was_active = was_active,
        new_selected = self._selected,
        new_scroll = self._scroll,
        total = #self._items,
    })
end

--- Schedule a debounced refresh/open. Cancels any prior pending tick so
--- bursts of keystrokes coalesce into ONE source query.
function CompletionMenu:_schedule()
    local editor = self._editor
    if self._debounce_task then
        log.info("completion_menu", "schedule_cancel_existing")
        editor:cancel_task(self._debounce_task)
    end
    log.info("completion_menu", "schedule_new", { debounce_us = self._debounce_us })
    self._debounce_task = editor:schedule_after(self._debounce_us, function()
        log.info("completion_menu", "schedule_fire")
        self._debounce_task = nil
        self:_tick()
        return true -- one-shot: schedule_after re-queues falsy returns
    end)
end

--- Manual trigger (`M-/`): pop the menu NOW at the cursor, bypassing the
--- debounce AND the min-prefix gate, and force the source to re-query
--- (ctx.force) so it fires a request even when stale cache exists. Holds
--- a loading placeholder while the request is in flight.
function CompletionMenu:force_open()
    log.info("completion_menu", "force_open")
    self:_tick(true)
end

----------------------------------------------------------------------------------------------------
-- Navigation / selection (controller model)
----------------------------------------------------------------------------------------------------

--- Clamp + scroll-adjust the selection into the visible window.
function CompletionMenu:_ensure_visible()
    local idx = self._selected
    if idx < 1 then
        return
    end
    local mv = self.max_visible
    if idx <= self._scroll then
        self._scroll = idx - 1
    elseif idx > self._scroll + mv then
        self._scroll = idx - mv
    end
    if self._scroll < 0 then
        self._scroll = 0
    end
end

--- Move the selection up one (wraps when `_wrap`).
function CompletionMenu:up()
    if not self.active or #self._items == 0 then
        return
    end
    if self._selected <= 1 then
        if self._wrap then
            self._selected = #self._items
        end
    else
        self._selected = self._selected - 1
    end
    self:_ensure_visible()
end

--- Move the selection down one (wraps when `_wrap`).
function CompletionMenu:down()
    if not self.active or #self._items == 0 then
        return
    end
    if self._selected >= #self._items then
        if self._wrap then
            self._selected = 1
        end
    else
        self._selected = self._selected + 1
    end
    self:_ensure_visible()
end

--- Move the selection up by one visible page.
function CompletionMenu:page_up()
    if not self.active then
        return
    end
    self._selected = math.max(1, self._selected - self.max_visible)
    self:_ensure_visible()
end

--- Move the selection down by one visible page.
function CompletionMenu:page_down()
    if not self.active then
        return
    end
    self._selected = math.min(#self._items, self._selected + self.max_visible)
    self:_ensure_visible()
end

--- Jump to the first item.
function CompletionMenu:top()
    if not self.active then
        return
    end
    self._selected = 1
    self:_ensure_visible()
end

--- Jump to the last item.
function CompletionMenu:bottom()
    if not self.active then
        return
    end
    self._selected = #self._items
    self:_ensure_visible()
end

--- Accept the currently-selected item: replace the word being completed
--- (the trailing `[%w_]*` run left of the cursor) with the item's text,
--- as one undo group. No-op when no item is selected. Closes the menu
--- regardless (so a stale tick can't reopen from a pre-edit debounce).
---@return boolean accepted
function CompletionMenu:accept()
    log.info("completion_menu", "accept", {
        active = self.active,
        selected = self._selected,
    })
    if not self.active or self._selected < 1 then
        self:close()
        return false
    end
    local editor = self._editor
    local view = editor:current_view()
    local ctx = build_ctx(view)
    if ctx == nil then
        self:close()
        return false
    end
    local item = self._items[self._selected]
    local text = completers.comp_text(item)
    -- Re-compute the live word to replace from the cursor (not the
    -- possibly-stale query-time ctx): delete [word_start, cursor) and
    -- insert `text`, as one "replace" batch edit.
    local line, col, start_col = ctx.line, ctx.col, ctx.word_start_col
    view = ctx.view
    local buf = view.buffer
    self:close()
    view:batch_edit(false, function(c)
        local sl, sc = line, start_col
        local el, ec = line, col
        if ec > sc then
            buf:delete_char(sl, sc, ec - sc)
        end
        local rl, rc = sl, sc
        if #text > 0 then
            rl, rc = buf:insert_char(sl, sc, text)
        end
        return sl, sc, rl, rc, "replace", el, ec
    end)
    view:_set_goal_col(view:p().col)
    return true
end

----------------------------------------------------------------------------------------------------
-- Controller: key intercept (first-crack, before the trie)
----------------------------------------------------------------------------------------------------

--- Edits that should KEEP the menu alive (re-query / refresh) after the
--- post_command hook. A self-insert or a char/word deletion changes the
--- prefix being completed, so we debounce a refresh. Anything else
--- (motions, commands, mode switches) dismisses the menu.
local KEEP_ALIVE_COMMANDS = {
    __printable = true,
    backward_delete_char = true,
    delete_char = true,
    kill_word = true,
    kill_word_forward = true,
    delete_horizontal_space = true,
}

--- Tokens the menu owns while open. Anything not listed falls through to
--- normal dispatch (and, being a non-edit command, dismisses the menu
--- via the post_command hook).
local MENU_TOKENS = {
    ["up"] = true,
    ["down"] = true,
    ["ctrl-p"] = true,
    ["ctrl-n"] = true,
    ["page_up"] = true,
    ["page_down"] = true,
    ["tab"] = true,
    ["enter"] = true,
    ["return"] = true,
    ["escape"] = true,
    ["ctrl-g"] = true,
}

--- First-crack key handler. Called from the main loop before the trie
--- when the menu is open. Returns true if the key was consumed (nav /
--- accept / cancel); false to let it fall through to normal dispatch.
--- A fall-through non-edit key then dismisses the menu on the next
--- post_command hook.
---@param _editor Editor
---@param token string? keybind token
---@return boolean handled
function CompletionMenu:handle_key(_editor, token)
    log.info("completion_menu", "handle_key", {
        token = token,
        active = self.active,
    })
    if not self.active or token == nil then
        return false
    end
    if not MENU_TOKENS[token] then
        return false
    end
    log.info("completion_menu", "handle_key_consume", { token = token })
    if token == "up" or token == "ctrl-p" then
        self:up()
    elseif token == "down" or token == "ctrl-n" then
        self:down()
    elseif token == "page_up" then
        self:page_up()
    elseif token == "page_down" then
        self:page_down()
    elseif token == "tab" or token == "enter" or token == "return" then
        self:accept()
    else -- escape / ctrl-g
        self:close()
    end
    return true
end

--- post_command_hook handler. Drives auto-popup-while-typing: after an
--- edit command (self-insert or deletion) it debounces a refresh/open;
--- after any other command it dismisses the menu (the user left the
--- completion context). No-op while the minibuffer is active (the menu
--- never coexists with the minibuffer).
---@param editor Editor
---@param cmd_name string? command name (nil when dispatched to a fn)
---@param view View the active view at dispatch
function CompletionMenu:_on_post_command(editor, cmd_name, view)
    log.info("completion_menu", "post_command", {
        cmd_name = cmd_name,
        view_loaded = view ~= nil and view.file_loaded or false,
        mb_active = editor.minibuffer and editor.minibuffer.active or false,
        menu_active = self.active,
    })
    if editor.minibuffer and editor.minibuffer.active then
        self:close()
        return
    end
    if view == nil or not view.file_loaded then
        self:close()
        return
    end
    if
        cmd_name == "__printable"
        and self._completer ~= nil
        and type(self._completer.trigger_chars) == "function"
    then
        -- Trigger-character fast-path: if the char just inserted (the one
        -- immediately left of the cursor) is a server-declared trigger
        -- char, pop the menu NOW instead of debouncing — LSP servers
        -- return context-sensitive completions after e.g. `.`/`:`/`(` and
        -- the value of immediacy is lost behind a 120ms debounce.
        local ch = char_before_cursor(view)
        local set = self._completer.trigger_chars()
        if ch ~= nil and set ~= nil and set[ch] then
            log.info("completion_menu", "post_command_trigger_now", { char = ch })
            self:_tick(true)
            return
        end
    end
    if cmd_name ~= nil and KEEP_ALIVE_COMMANDS[cmd_name] then
        self:_schedule()
    else
        self:close()
    end
end

----------------------------------------------------------------------------------------------------
-- View: render (render_overlay listener)
----------------------------------------------------------------------------------------------------

--- Paint the popup for the current frame. Cursor-tracked: the box is
--- anchored at the screen cell of the START of the word being completed
--- (so it stays put as the cursor advances within the word), placed
--- below the cursor and flipped above when there isn't room. Uses
--- `put_float` so it composes with all other overlay chrome.
---@param editor Editor
function CompletionMenu:_render(editor)
    if not self.active or #self._items == 0 then
        return
    end
    local view = editor:current_view()
    local ctx = build_ctx(view)
    if ctx == nil then
        return
    end
    if #ctx.prefix < 1 then
        return
    end
    log.info("completion_menu", "render", {
        active = self.active,
        items = #self._items,
        selected = self._selected,
        scroll = self._scroll,
        prefix = ctx.prefix,
        line = ctx.line,
        col = ctx.col,
        word_start_col = ctx.word_start_col,
    })
    local ov = editor.overlays
    local term = editor.term
    local w = term:width()
    local h = term:height()
    local max_y = h - editor:footer_rows() - 1

    -- Anchor screen cell of the word being completed.
    local sx, sy = ov:file_to_screen(ctx.line, ctx.word_start_col)
    if sx == nil or sy == nil then
        return
    end

    local total = #self._items
    local mv = self.max_visible
    local n = math.min(total, mv)
    if n <= 0 then
        return
    end

    -- Width: longest item text + metadata (if any) + a scrollbar gutter
    -- when the list overflows + 2 border columns.
    local needs_sb = total > mv
    local query = ctx.prefix
    local max_text = 0
    local has_meta = false
    local max_meta = 0
    for i = 1, n do
        local tlen = cell_len(completers.comp_text(self._items[self._scroll + i]))
        if tlen > max_text then
            max_text = tlen
        end
        local meta = completers.comp_meta(self._items[self._scroll + i])
        if meta then
            has_meta = true
            local mlen = cell_len(meta)
            if mlen > max_meta then
                max_meta = mlen
            end
        end
    end
    local interior = max_text
    if has_meta then
        interior = interior + 2 + max_meta
    end
    if needs_sb then
        interior = interior + 1
    end
    local min_w = 16
    if interior < min_w then
        interior = min_w
    end
    local box_w = interior + 2
    if box_w > w - 2 then
        box_w = w - 2
        interior = box_w - 2
    end
    local box_h = n + 2

    -- x: anchor at word start, clamp to terminal width.
    local box_x = sx
    if box_x + box_w > w then
        box_x = math.max(0, w - box_w)
    end
    -- y: below the cursor row; flip above when it would overflow.
    local box_y
    if sy + 1 + box_h - 1 <= max_y then
        box_y = sy + 1
    else
        box_y = sy - box_h -- box occupies [sy-box_h, sy-1]
        if box_y < 0 then
            box_y = 0
        end
    end

    local bg = ui("popup_bg")
    local border_fg = bit.bor(ui("minibuffer_border"), tb.bold)
    local cur_fg = ui("cursor_fg")
    local cur_bg = ui("cursor_bg")
    local norm_fg = ui("minibuffer_prompt")
    local meta_fg = ui("minibuffer_metadata")
    local bright_fg = ui("minibuffer_text")
    local dim_fg = ui("completion_dim")
    local accent_fg = norm_fg

    local function fp(x, y, text, fg, b)
        ov:put_float(x, y, text, fg, b)
    end

    -- Clear the box interior with default_bg so it floats cleanly.
    for r = 0, box_h - 1 do
        fp(box_x, box_y + r, string.rep(" ", box_w), bg, bg)
    end

    -- Borders (rounded, like the command palette).
    fp(box_x, box_y, "╭" .. string.rep("─", box_w - 2) .. "╮", border_fg, bg)
    fp(box_x, box_y + box_h - 1, "╰" .. string.rep("─", box_w - 2) .. "╯", border_fg, bg)

    local list_x = box_x + 1
    local list_y = box_y + 1
    local list_w = interior
    if needs_sb then
        list_w = list_w - 1
    end

    -- Metadata column = longest text + 2-space gap (only when meta present).
    local meta_col = has_meta and (max_text + 2) or nil
    local show_meta = has_meta and (meta_col + 4 <= list_w)

    local selected = self._selected
    for i = 1, n do
        local ci = self._scroll + i
        local row = list_y + i - 1
        local item = self._items[ci]
        local text = truncate_cells(completers.comp_text(item), list_w)
        local meta = show_meta and completers.comp_meta(item) or nil
        if ci == selected then
            -- Full-width reverse-video selection bar.
            fp(list_x, row, string.rep(" ", list_w), cur_fg, cur_bg)
            local mset = match_byte_set(text, query)
            if next(mset) then
                print_highlighted(fp, list_x, row, text, accent_fg, cur_fg, cur_bg, mset, tb.bold)
            else
                fp(list_x, row, text, cur_fg, cur_bg)
            end
            if meta and meta_col + cell_len(meta) <= list_w then
                fp(list_x + meta_col, row, meta, cur_fg, cur_bg)
            end
        else
            local mset = match_byte_set(text, query)
            if next(mset) then
                print_highlighted(fp, list_x, row, text, bright_fg, dim_fg, bg, mset, tb.bold)
            else
                fp(list_x, row, text, norm_fg, bg)
            end
            if meta and meta_col + cell_len(meta) <= list_w then
                fp(list_x + meta_col, row, meta, meta_fg, bg)
            end
        end
    end

    -- Scrollbar: 1-col gutter on the far right of the interior.
    if needs_sb then
        local sb_col = list_x + interior - 1
        local track_fg = ui("scrollbar_track")
        local thumb_fg = ui("scrollbar_thumb")
        local scrollable = math.max(1, total - n)
        local thumb_size = math.max(1, math.floor(n * n / total))
        local thumb_top = math.floor(self._scroll / scrollable * (n - thumb_size))
        if thumb_top < 0 then
            thumb_top = 0
        elseif thumb_top > n - thumb_size then
            thumb_top = n - thumb_size
        end
        for i = 0, n - 1 do
            local on_thumb = i >= thumb_top and i < thumb_top + thumb_size
            fp(
                sb_col,
                list_y + i,
                on_thumb and "█" or "│",
                on_thumb and thumb_fg or track_fg,
                bg
            )
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Listener registration / teardown
----------------------------------------------------------------------------------------------------

--- Register the render + post_command listeners on the editor's event
--- system. Idempotent: safe to call once at startup (from Editor.new).
function CompletionMenu:setup()
    if self._handlers ~= nil then
        log.info("completion_menu", "setup_skip_already_configured")
        return
    end
    local es = self._editor.event_system
    log.info("completion_menu", "setup_register_listeners")
    local render_fn = function(_editor)
        self:_render(_editor)
    end
    local post_fn = function(editor, cmd_name, view)
        self:_on_post_command(editor, cmd_name, view)
    end
    es:on("render_overlay", render_fn)
    es:on("post_command_hook", post_fn)
    self._handlers = { render = render_fn, post_command = post_fn }
end

--- Remove the listeners. Largely for tests / reconfiguration; the
--- editor holds the singleton for its lifetime.
function CompletionMenu:teardown()
    if self._handlers == nil then
        return
    end
    local es = self._editor.event_system
    es:off("render_overlay", self._handlers.render)
    es:off("post_command_hook", self._handlers.post_command)
    self:close()
    self._handlers = nil
end

CompletionMenu.new = new
return CompletionMenu
