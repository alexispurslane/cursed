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
local crender = require("cursed.completion_render")
local log = require("cursed.log")
local profile = require("cursed.profile")

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
---@param fn Completer|nil source, or nil to clear
function CompletionMenu:set_completer(fn)
    self._completer = fn
end

----------------------------------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------------------------------

--- Close the popup and cancel any pending auto-open debounce.
function CompletionMenu:close()
    -- Remove transient key handler
    if self._transient_id then
        self._editor:remove_transient_handler(self._transient_id)
        self._transient_id = nil
    end
    if profile.enabled then
        log.info("completion_menu", "close", {
            active = self.active,
            items = #self._items,
            task = self._debounce_task ~= nil,
        })
    end
    self._editor:cancel_task(self._debounce_task)
    self._debounce_task = nil
    local was_active = self.active
    local accepted = self._accepted or false
    local text = nil
    if accepted and self._selected >= 1 and self._items[self._selected] ~= nil then
        text = completers.comp_text(self._items[self._selected])
    end
    self.active = false
    self._items = {}
    self._selected = 0
    self._scroll = 0
    self._loading = false
    self._accepted = false
    self._force_keep_open = 0
    -- Fire the on_close hook so iterate-pick loops (flyspell_correct,
    -- query-replace chaining) can chain accept→advance or stop on cancel.
    if was_active and self.on_close ~= nil then
        local cb = self.on_close
        self.on_close = nil
        cb(accepted, text)
    end
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
    -- After a trigger character (e.g. `.` / `:`) the word prefix left of
    -- the cursor is empty BY DEFINITION (the prior byte is the trigger,
    -- not a word char), yet this is exactly when the server returns
    -- context-sensitive MEMBERS — so the min-prefix gate must not close
    -- the popup there. The response retick calls _tick UNFORCED; without
    -- this bypass it would re-close a trigger-opened popup (whose prefix
    -- is "") before the just-arrived member items ever render.
    local on_trigger = false
    if not forced then
        local cm = self._completer
        local set = (cm ~= nil and type(cm.trigger_chars) == "function") and cm.trigger_chars()
            or nil
        if set ~= nil then
            local ch = char_before_cursor(view)
            if ch ~= nil and set[ch] then
                on_trigger = true
            end
        end
    end
    if not forced and not on_trigger and #ctx.prefix < self._min_prefix then
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
            -- Push transient key handler (LIFO) so the menu gets first crack
            if not self._transient_id then
                self._transient_id = self._editor:push_transient_handler(function(ed, token, _, _)
                    if self.active then
                        return self:handle_key(ed, token)
                    end
                    return false
                end)
            end
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
    -- Push transient key handler (LIFO) so the menu gets first crack
    if not self._transient_id then
        self._transient_id = self._editor:push_transient_handler(function(ed, token, _, _)
            if self.active then
                return self:handle_key(ed, token)
            end
            return false
        end)
    end
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
    -- Counter: suppress the NEXT N _on_post_command closes.
    -- Defaults to 1 (direct keybinding dispatch — one post_command
    -- from dispatch_key). Callers dispatched through M-x may need
    -- a higher count and can bump it after force_open returns (M-x's
    -- on_submit emits its own post_command_hook AND the wrapping
    -- dispatch_key emits another for the keybinding).
    self._force_keep_open = 1
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

    -- When the cursor is on a flagged misspelled word (spell store),
    -- extend the delete range to cover the ENTIRE word bounds, not just
    -- the typed prefix left of the cursor. Without this, selecting a
    -- correction leaves the suffix "eling" behind when the cursor was
    -- mid-word ("missp|eling" + Tab → "misspellingeling").
    local spell = require("cursed.spell")
    local store = spell.store(editor)
    if store ~= nil then
        local entry = store:word_at(buf, line, col)
        if entry ~= nil then
            if entry.s_col < start_col then
                start_col = entry.s_col
            end
            if entry.e_col > col then
                col = entry.e_col
            end
        end
    end

    self._accepted = true
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
    if profile.enabled then
        log.info("completion_menu", "handle_key", {
            token = token,
            active = self.active,
        })
    end
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
    elseif token == "tab" then
        self:accept()
    elseif token == "enter" or token == "return" then
        -- Enter always inserts a newline: close the menu and let the
        -- key fall through to normal dispatch (newline / electric-dedent
        -- handling) instead of accepting the selected candidate.
        self:close()
        return false
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
    -- force_open callers (flyspell_correct) set _force_keep_open to a
    -- counter (2) to suppress the first N post_command closes after
    -- forcing the menu open. M-x's on_submit emits post_command_hook
    -- for the dispatched command (flyspell_correct) AND the wrapping
    -- dispatch_key emits post_command_hook for the keybinding
    -- (enter_key) — we need to survive both before settling.
    if self._force_keep_open and self._force_keep_open > 0 then
        self._force_keep_open = self._force_keep_open - 1
        return
    end
    -- Fast no-op: menu already dismissed and this command cannot reopen
    -- it (only __printable typing or a keep-alive deletion can reopen via
    -- the trigger-char / debounce paths below). Pure motion (C-n/C-p/
    -- arrows/M-x/etc.) with the menu closed used to fall through to
    -- close() (a no-op here) + emit two per-keystroke log lines on every
    -- key — the churn the profiler flagged. Bail before any logging.
    if not self.active and cmd_name ~= "__printable" and not KEEP_ALIVE_COMMANDS[cmd_name] then
        return
    end
    if profile.enabled then
        log.info("completion_menu", "post_command", {
            cmd_name = cmd_name,
            view_loaded = view ~= nil and view.file_loaded or false,
            mb_active = editor.minibuffer and editor.minibuffer.active or false,
            menu_active = self.active,
        })
    end
    if editor.minibuffer and editor.minibuffer.active then
        self:close()
        return
    end
    if view == nil or not view.file_loaded or view.no_completion then
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
    -- NOTE: do NOT early-return on an empty prefix. After a trigger char
    -- (e.g. `.`) the word prefix left of the cursor is "" by definition,
    -- yet the server just returned context-sensitive MEMBERS and the box
    -- must paint below the cursor. _tick owns open/close gating; _render
    -- only paints whatever _tick decided to open. With an empty prefix
    -- `word_start_col == col`, so the box anchors at the cursor.
    if profile.enabled then
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
    end
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
        local tlen = crender.cell_len(crender.comp_text(self._items[self._scroll + i]))
        if tlen > max_text then
            max_text = tlen
        end
        local meta = crender.comp_meta(self._items[self._scroll + i])
        if meta then
            has_meta = true
            local mlen = crender.cell_len(meta)
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
    local meta_fg = ui("minibuffer_metadata")
    local dim_fg = ui("completion_dim")

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

    local list_w = interior
    if needs_sb then
        list_w = list_w - 1
    end

    crender.paint_candidate_list(
        fp,
        box_x + 1,
        box_y + 1,
        list_w,
        self._items,
        self._selected,
        self._scroll,
        mv,
        query,
        bg,
        {
            cursor_fg = ui("cursor_fg"),
            cursor_bg = ui("cursor_bg"),
            norm_fg = ui("minibuffer_prompt"),
            meta_fg = meta_fg,
            bright_fg = ui("minibuffer_text"),
            dim_fg = dim_fg,
            accent_fg = ui("minibuffer_prompt"),
            track_fg = ui("scrollbar_track"),
            thumb_fg = ui("scrollbar_thumb"),
        }
    )
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
