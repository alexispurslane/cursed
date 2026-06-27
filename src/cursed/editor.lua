--- Editor: orchestration layer — rendering, keybinding dispatch, multi-view.
---
--- The Editor holds a list of Views, tracks the active view, and renders
--- it to the terminal. Keybinding functions receive (view, editor).

local tb = require("cursed.tb")
local ColorScheme = require("cursed.colorscheme")
local bit = require("bit")
local ffi = require("ffi")
local pffi = require("cursed.posix_ffi")
local c = pffi.C
local View = require("cursed.view").View
local Buffer = require("cursed.buffer").Buffer
local Minibuffer = require("cursed.minibuffer").Minibuffer
local EventSystem = require("cursed.event_system")
local shared = require("cursed.shared")
local find_file = require("cursed.find_file")
local kill_ring = require("cursed.kill_ring")
local completers = require("cursed.completers")
local keybind = require("cursed.keybind")
local OverlayManager = require("cursed.overlay")
local log = require("cursed.log")
local profile = require("cursed.profile")

--- Resolve a UI chrome color from the active colorscheme.
--- UI concepts (line_number, modeline_fg, cursor_bg, …) live in the
--- same CONCEPT_SLOTS table as syntax concepts, so `:color()` resolves
--- them (with no style bits, since they have no CONCEPT_STYLE entry).
--- Falls back to `tb.color_default` (terminal default) when no scheme
--- is active yet, so the editor still renders during early startup.
--- @param name string  UI concept key in CONCEPT_SLOTS
--- @return integer color
local function ui(name)
    local scheme = ColorScheme.active
    if scheme == nil then
        return tb.color_default
    end
    return scheme:color(name)
end

--- Blend a truecolor attr (`TB_TRUECOLOR` int 0xRRGGBB, possibly OR'd
--- with style bits) `factor` of the way toward the target color. Style
--- bits are preserved. Pure module-level helper; the focus backdrop
--- (inside render) uses it to dim fg AND bg toward default_bg. Unlike
--- SGR `dim` — which vanishes against a dark bg in many terminals —
--- blending keeps text legible while receding the buffer behind the
--- floating palette.
---@param color integer termbox attr (0xRRGGBB [+ style bits])
---@param target integer 0xRRGGBB (no style bits)
---@param factor integer 0..255; 0 = color unchanged, 255 = fully target
---@return integer
local function blend(color, target, factor)
    -- Strip style bits (everything ≥ 0x01000000) before blending.
    local style = bit.band(color, 0xFF000000)
    local c = bit.band(color, 0xFFFFFF)
    local tr = bit.rshift(target, 16)
    local tg = bit.band(bit.rshift(target, 8), 0xFF)
    local tb_ = bit.band(target, 0xFF)
    local r = bit.band(bit.rshift(c, 16), 0xFF)
    local g = bit.band(bit.rshift(c, 8), 0xFF)
    local b = bit.band(c, 0xFF)
    local inv = 255 - factor
    r = bit.rshift(r * inv + tr * factor, 8)
    g = bit.rshift(g * inv + tg * factor, 8)
    b = bit.rshift(b * inv + tb_ * factor, 8)
    return bit.bor(bit.bor(bit.bor(bit.lshift(r, 16), bit.lshift(g, 8)), b), style)
end

--- Matched-substring byte set for completion highlighting. Mirrors the
--- completers.lua matcher (space-separated terms, case-insensitive,
--- plain substring) and returns the set of byte positions in `display`
--- covered by the FIRST occurrence of each term. Drives the
--- match-highlighting paint in the completion list (Helm/ido-style).
---@param display string visible (already-truncated) completion text
---@param query string current minibuffer input
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
--- but termbox x/y are CELL columns — so any modeline math involving
--- unicode glyphs (◆ ▤ ⌖ ◣ ◢ …, all 1 cell but ≥2 bytes) must use this
--- instead or the column offsets drift and leave visible gaps. Counts
--- UTF-8 codepoints; assumes no double-wide CJK (true for our chrome).
---@param s string
---@return integer cells
local function cell_len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- Truncate `s` to at most `max` display cells, never splitting a
--- multibyte codepoint. ASCII `:sub` would slice a ◆/▤ mid-byte.
---@param s string
---@param max integer max cells
---@return string
local function truncate_cells(s, max)
    if cell_len(s) <= max then
        return s
    end
    local out, n = {}, 0
    for seq in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
        if n >= max then
            break
        end
        out[#out + 1] = seq
        n = n + 1
    end
    return table.concat(out)
end

----------------------------------------------------------------------------------------------------
-- Modeline segments (#5/#9 extensible modeline).
--
-- The modeline is decomposed into an ordered list of SEGMENTS a user can
-- override/extend via `editor.modeline_segments`. Each segment is:
--   {
--     bg   = <concept name string | base16 slot int 0x0N>,  -- segment bg color
--     format = function(editor, view) -> string,              -- text to show
--     fill  = boolean?,                                        -- absorb slack space
--     fg    = <concept name string | base16 slot int>?,        -- optional text color
--                                                                  override (else auto)
--   }
-- A segment whose format returns "" and isn't `fill` is skipped (no block,
-- no separators) — lets a section elide itself (e.g. no transient status).
--
-- SEPARATORS are fully automatic: ONE triangle per boundary between
-- survivor segments, direction alternating (◣ ◢ ◣ ◢ …) so adjacent
-- accent blocks fold into a zigzag (foo \ bar / baz \ end). Colors are
-- derived from the two adjacent segments' bg colors (no spec field):
--   • ◣ (lower-left filled, even boundary): fg = left.bg,  bg = right.bg
--   • ◢ (lower-right filled, odd boundary):  fg = right.bg, bg = left.bg
-- Both are lower triangles whose slant alternates, producing the fold.
--
-- TEXT color is auto-detected from the segment bg's luminance: a dark bg
-- gets base06 (bright), a light bg gets base00 (blackest) — pos-style
-- brightness on every accent. `fg` overrides auto-detection (escape hatch
-- for 256-color terminals where luminance from a palette index is wrong).
--
-- LAYOUT: available = w − Σ(text widths) − (N−1 separators). `available`
-- is split evenly among `fill` segments (remainder distributed
-- left→right). Non-fill segments render at exactly their text width (any
-- padding is baked into the format string). When text overflows the row,
-- fill segments get 0 extra and text clips off-screen.
----------------------------------------------------------------------------------------------------

--- Resolve a segment `bg`/`fg` spec to a termbox color int.
--- Accepts a colorscheme concept name string (resolved through the active
--- scheme's concept→slot map, so theme tweaks + user remaps apply) OR a
--- raw base16 slot int (0x00..0x0F). Returns the active scheme's color
--- for that slot (or default fg/bg when no scheme is active yet).
---@param spec string|integer concept name or base16 slot
---@param fallback integer color int when spec/resolution fails
---@return integer color
local function resolve_seg_color(spec, fallback)
    if spec == nil then
        return fallback
    end
    local scheme = ColorScheme.active
    if scheme == nil then
        return fallback
    end
    if type(spec) == "number" then
        return scheme:slot_color(spec)
    end
    ---@cast spec string
    return scheme:color(spec)
end

--- Relative luminance of a truecolor attr (0xRRGGBB, style bits ignored).
---@param color integer
---@return number 0..1
local function luminance(color)
    local c = bit.band(color, 0xFFFFFF)
    local r = bit.band(bit.rshift(c, 16), 0xFF) / 255
    local g = bit.band(bit.rshift(c, 8), 0xFF) / 255
    local b = bit.band(c, 0xFF) / 255
    return 0.299 * r + 0.587 * g + 0.114 * b
end

--- Auto-pick a segment's text color from its bg lightness.
--- Dark bg → base06 (bright); light bg → base00 (blackest). In 256-color
--- mode the resolved color is a palette index not RGB, so luminance is
--- unreliable — callers should set segment `fg` to pin it there.
---@param scheme ColorScheme
---@param bg_color integer resolved bg color int
---@return integer text color int
local function auto_text_color(scheme, bg_color)
    local text_slot
    if scheme.truecolor and luminance(bg_color) > 0.5 then
        text_slot = 0x00 -- base00: blackest on a light bg
    else
        text_slot = 0x06 -- base06: bright on a dark bg
    end
    return scheme:slot_color(text_slot)
end

--- The built-in modeline segment set: reproduces the historic segmented
--- modeline (◆ mode ◣ ▤ filepath ● … ◢ ⌖ pos) via the generic segment
--- path. `editor.modeline_segments` is seeded from this table in
--- Editor.new; init.lua / M-: can reassign, reorder, or append.
---@type table[]
local DEFAULT_MODELINE_SEGMENTS = {
    {
        bg = "modeline_mode_bg",
        fill = false,
        format = function(editor, view)
            local mode_name = "fundamental"
            if #view._major_modes > 0 then
                mode_name = view._major_modes[#view._major_modes].name or mode_name
            end
            return " ◆ " .. mode_name .. " "
        end,
    },
    {
        bg = "modeline_bg",
        fill = true,
        format = function(editor, view)
            local buf = view.buffer
            local dirty = buf:is_dirty()
            local modified = dirty and " ●" or ""
            local path = buf:filepath() or "[no file]"
            local rc = editor:read_char_status()
            return rc or editor.status_message or ("▤ " .. path .. modified)
        end,
    },
    {
        bg = "modeline_pos_bg",
        fill = false,
        format = function(editor, view)
            local line_count = view:line_count()
            local pct = math.floor(view:p().line / math.max(1, line_count - 1) * 100)
            return string.format(" ⌖ %d:%d  %d%% ", view:p().line + 1, view:p().col + 1, pct)
        end,
    },
}

----------------------------------------------------------------------------------------------------
-- Pretty printer for eval output
----------------------------------------------------------------------------------------------------

local function pprint(val, depth)
    depth = depth or 0
    if depth > 4 then
        return "..."
    end
    local t = type(val)
    if t == "nil" then
        return "nil"
    elseif t == "boolean" then
        return tostring(val)
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        if depth == 0 then
            -- Top-level: no quotes (user typed a string expression)
            return val
        end
        return string.format("%q", val)
    elseif t == "table" then
        local parts = {}
        for k, v in pairs(val) do
            local ks
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                ks = k
            else
                ks = "[" .. pprint(k, depth + 1) .. "]"
            end
            parts[#parts + 1] = ks .. " = " .. pprint(v, depth + 1)
        end
        if #parts == 0 then
            return "{}"
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    elseif t == "function" then
        return "<function>"
    elseif t == "cdata" then
        return tostring(val)
    else
        return "<" .. t .. ">"
    end
end

---@class Editor
---@field drain_hl_inbox fun()|nil inline inbox_hl drain (attached by main.lua) for the zero-flash sync-wait path
---@field views View[] list of open views
---@field active_view integer 1-based index into views
---@field term Term
---@field status_message string|nil
---@field minibuffer Minibuffer
---@field _isearch_origin_line integer|nil saved cursor line before isearch
---@field _isearch_origin_col integer|nil saved cursor col before isearch
---@field _isearch_direction integer 1=forward, -1=backward
---@field _isearch_regex boolean|nil true when active isearch is a regex search
---@field _eval_result string|nil pretty-printed eval result to show in minibuffer area
---@field _quit_requested boolean set by M-x to signal quit from async callback
---@field _wake_main function? callback to wake the main select() loop from async context
---@field _background_tasks (fun(): boolean?|{deadline: integer, fn: fun(): boolean?})[] main-thread task queue
---@field _universal_active boolean true when C-u argument collection is in progress
---@field _universal_count integer number of times C-u was pressed in current collection
---@field universal_args table|nil universal argument list for the next command dispatch
---@field _recording boolean true when kmacro recording is active
---@field _recorded_commands table[] stack of recorded {name, universal_args} commands
---@field _recorded_mb_inputs string[] minibuffer inputs captured during kmacro recording
---@field _kmacros table<string, { commands: table[], mb_inputs: string[] }> saved keyboard macros
---@field _mb_input_stack string[] minibuffer inputs popped during kmacro replay
---@field _mb_just_closed integer? count of stale Enter/Tab events to suppress after minibuffer closes
---@field _base_trie table the base keybind trie (no mode overlays)
---@field _base_keybindings table<string, string|function> flat chord→action map (base only)
---@field _active_trie table the current keybind trie (base + active mode overlay)
---@field _chord_for_command table<string, string>|nil reverse map command_name→formatted chord
---@field _trie_changed boolean? set when active_trie was rebuilt (main loop resets chord state)
---@field _digit_active boolean true when M-digit/M-- argument accumulation is in progress
---@field _digit_value integer accumulated digit value (starts at 0)
---@field _digit_negative boolean true when M-- was pressed (negate the arg)
---@field _last_was_kill boolean true when the most recent dispatched command was a kill (for consecutive-kill merging)
---@field _kill_called boolean true when push_kill was called during the current command dispatch
---@field _printable_fn function? the __printable handler
---@field _read_char_cb function|nil active callback for read-char (one-shot)
---@field _read_char_prompt string the prompt shown during read-char
---@field _config Config the loaded user configuration
---@field margin integer|nil max text render width; when set, the (gutter+text) column is centered in the window
---@field _blink_on boolean caret visible (drawn) this blink phase
---@field _blink_task table|nil handle of the scheduled blink toggle task
---@field event_system EventSystem central event hub (pre/post-command, mode_enter/exit, ring-buffer, ...)
---@field overlays OverlayManager screen-space overlay layer (file-anchored + floating)
---@field modeline_segments table[] ordered modeline segment specs (bg/format/fill/fg)
---@field _last_command string|nil name of the most recently dispatched command (Emacs `last-command`)
---@field _command_before_this string|nil the command before the most recent one (Emacs `command-before-this`)
---@field _last_complex_command { name: string, universal_args: table }|nil most recent command invoked with universal args (for repeat-complex-command)
---@field _exit_code integer exit code surfaced by async tasks
---@field _damage_start_row integer|nil 0 = full screen, nil = derive from cursor, >0 = repaint from this row down
---@field _last_min_cursor_row integer|nil smallest cursor/anchor screen row of the previous render
---@field _last_w integer|nil terminal width observed at last render
---@field _last_h integer|nil terminal height observed at last render
---@field _last_footer_rows integer|nil footer rows observed at last render
---@field _last_palette boolean|nil palette (M-x) active at last render
---@field _last_scroll_li integer|nil anchor line of current view at last render
---@field _last_scroll_sub_row integer|nil anchor sub-row of current view at last render
---@field _last_line_count integer|nil line count of current view at last render
local Editor = {}
Editor.__index = Editor

----------------------------------------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------------------------------------

--- Create a new Editor with an empty view list.
---@param term Term
---@return Editor
function Editor.new(term)
    local editor = setmetatable({
        views = {},
        active_view = 0,
        term = term,
        status_message = nil,
        minibuffer = Minibuffer.new(),
        _isearch_origin_line = nil,
        _isearch_origin_col = nil,
        _isearch_direction = 1,
        _isearch_regex = nil,
        _eval_result = nil,
        _quit_requested = false,
        _background_tasks = {},
        _exit_code = 0,
        _blink_task = nil,
        _hl_idle_last = nil,
        _wake_main = function() end,
        _universal_active = false,
        _universal_count = 0,
        universal_args = nil,
        _recording = false,
        _recorded_commands = {},
        _recorded_mb_inputs = {},
        _kmacros = {},
        _mb_input_stack = {},
        _base_trie = nil,
        _base_keybindings = {},
        _active_trie = nil,
        _chord_for_command = {},
        overlays = nil, -- OverlayManager singleton (set below)
        modeline_segments = nil, -- segment spec list (seeded from DEFAULT_MODELINE_SEGMENTS below)
        _digit_active = false,
        _digit_value = 0,
        _digit_negative = false,
        _last_was_kill = false,
        _kill_called = false,
        _printable_fn = nil,
        _read_char_cb = nil,
        _read_char_prompt = "",
        _config = nil,
        _blink_on = true, -- caret visible (drawn) this phase
        _last_command = nil, -- most recent dispatched command name
        _command_before_this = nil, -- command before the most recent
        _last_complex_command = nil, -- most recent command-with-args, for repeat-complex-command
        _damage_start_row = 0, -- full damage on first render
        _last_min_cursor_row = nil,
        _last_w = nil,
        _last_h = nil,
        _last_footer_rows = nil,
        _last_palette = nil,
        _last_scroll_li = nil,
        _last_scroll_sub_row = nil,
        _last_line_count = nil,
    }, Editor)
    editor.event_system = EventSystem.new(editor)
    editor.overlays = OverlayManager.new(editor)
    editor.modeline_segments = {}
    for _, seg in ipairs(DEFAULT_MODELINE_SEGMENTS) do
        editor.modeline_segments[#editor.modeline_segments + 1] = seg
    end
    return editor
end

--- Signal the main loop to exit. Sets the quit flag and wakes select()
--- via the kqueue so it doesn't block until the next keypress.
function Editor:request_quit()
    self._quit_requested = true
    self._wake_main()
end

----------------------------------------------------------------------------------------------------
-- Damage tracking / partial rerender (#4)
----------------------------------------------------------------------------------------------------

--- Request a full-screen repaint on the next render. Used by viewport
-- changes (scroll, resize, view switch, theme change) where partial
-- damage from the cursor down would leave stale content above.
function Editor:request_full_damage()
    self._damage_start_row = 0
end

--- Compute the screen row of a buffer position relative to the current
-- viewport. Helper for `_min_cursor_screen_row`; kept at module level
-- so it JIT-compiles instead of allocating a closure per render.
---@param view View
---@param line integer
---@param col integer
---@return integer row
local function cursor_screen_row(view, line, col)
    local sub_row, _ = view:wrap_sub_position(line, col)
    return view:viewport_row_for_line(line, sub_row)
end

--- Compute the topmost viewport row that may contain visual state
-- (cursor, selection anchor, or pending drop). Rendering from this row
-- downward covers cursor moves, selection changes, blink toggles, and
-- drop markers; the caller combines it with the previous frame's value
-- so the old cursor/selection cells are also erased.
---@return integer viewport row (0-based); 0 if derrived value is negative
function Editor:_min_cursor_screen_row()
    local mcsr_t0 = profile.now_us()
    local view = self:current_view()
    if view == nil then
        return 0
    end
    local min_row ---@type integer|nil
    for _, c in ipairs(view.cursors) do
        local row = cursor_screen_row(view, c.line, c.col)
        if min_row == nil or row < min_row then
            min_row = row
        end
        if c.anchor_line then
            row = cursor_screen_row(view, c.anchor_line, c.anchor_col)
            if row < min_row then
                min_row = row
            end
        end
    end
    for _, c in ipairs(view.pending_cursors) do
        local row = cursor_screen_row(view, c.line, c.col)
        if min_row == nil or row < min_row then
            min_row = row
        end
    end
    if min_row == nil then
        return 0
    end
    if min_row < 0 then
        return 0
    end
    profile.span("editor", "_min_cursor_screen_row", mcsr_t0)
    return min_row
end

----------------------------------------------------------------------------------------------------
-- Cursor blink
----------------------------------------------------------------------------------------------------

-- The real (hardware) terminal caret is always hidden; the caret is
-- drawn by render() as a reverse-video cell and toggled on/off here by
-- a timer advanced from the main select() loop. The phase is reset to
-- "on" (and the next-toggle deadline pushed forward) whenever input is
-- processed, so the caret stays solid while the user is actively typing
-- and only blinks after a half-period of idleness.
local BLINK_HALF_US = 530000

local now_tv = ffi.new("struct timeval[1]")
local function now_us()
    pffi.C.gettimeofday(now_tv, nil)
    return tonumber(now_tv[0].tv_sec) * 1000000 + tonumber(now_tv[0].tv_usec)
end

--- Schedule the next cursor-blink toggle. The task inverts `_blink_on`
-- and reschedules itself so the caret keeps blinking until input resets
-- it back to the "on" phase.
function Editor:schedule_blink()
    self._blink_task = self:schedule_after(BLINK_HALF_US, function()
        self._blink_on = not self._blink_on
        self:schedule_blink()
        return true
    end)
end

--- Reset the blink to the "on" phase and schedule the next toggle.
-- Called whenever input is processed so the caret stays solid while the
-- user is actively typing.
function Editor:reset_blink()
    self._blink_on = true
    if self._blink_task then
        self:cancel_task(self._blink_task)
    end
    self:schedule_blink()
end

--- Rebuild the active keybind trie by merging the active view's mode
--- keybindings on top of the base trie. Called when the mode changes.
function Editor:rebuild_active_trie()
    local view = self:focused_view()
    if view and #view._major_modes > 0 then
        -- Merge: start from a copy of base keybindings, then overlay each mode in order
        local merged = {}
        for k, v in pairs(self._base_keybindings) do
            merged[k] = v
        end
        for _, mode in ipairs(view._major_modes) do
            if next(mode.keybindings) then
                for k, v in pairs(mode.keybindings) do
                    merged[k] = v
                end
            end
        end
        self._active_trie = keybind.Trie.build(merged)
        -- Shortcuts shown in M-x reflect the active major mode's overrides.
        self._chord_for_command = keybind.build_chord_for_command(merged)
    else
        self._active_trie = self._base_trie
        -- Rebuild from base bindings so the map is fresh even with no modes.
        self._chord_for_command = keybind.build_chord_for_command(self._base_keybindings)
    end
    self._trie_changed = true
end

----------------------------------------------------------------------------------------------------
-- Keybinding convenience API (#5).
--
-- Emacs-style ergonomic wrappers over the trie-rebuild path. A keymap
-- is already just a Lua table (chord → command-name|function); these
-- methods make binding LIVE — they mutate the base/mode keybinding
-- tables and rebuild the tries immediately, so they work from M-:,
-- `editor.event_system` listeners, extension packages, AND init.lua
-- (the default keybindings are primed on the editor BEFORE init.lua
-- runs, so `editor:global_set_key` in init.lua is applied for real,
-- not clobbered by a later trie build).
----------------------------------------------------------------------------------------------------

--- Rebuild the base keybind trie (no mode overlays) from
--- `_base_keybindings`. Called after `global_set_key` mutates the base
--- bindings. (`rebuild_active_trie` rebuilds `_active_trie` from base +
--- active modes; in the no-mode branch it aliases `_base_trie`, so this
--- must stay fresh.)
function Editor:rebuild_base_trie()
    self._base_trie = keybind.Trie.build(self._base_keybindings)
end

--- Bind a key chord globally (Emacs `global-set-key`). `action` is either
--- a command name (string, resolved from the commands table at dispatch
--- time) or a `function(view, editor, ...)`. The chord is validated
--- eagerly so a typo surfaces now, not on first press. Rebuilds the
--- base + active tries immediately.
---@param chord string chord specifier ("ctrl-x ctrl-s", "alt-:", "f5", …)
---@param action string|function command name or function
function Editor:global_set_key(chord, action)
    if self._base_keybindings == nil then
        error(
            "editor:global_set_key: keybindings not yet initialized (call after startup prime)",
            2
        )
    end
    if chord == "__printable" then
        if type(action) == "function" then
            self._printable_fn = action
        end
        return
    end
    local tokens, err = keybind.parse_chord(chord)
    if not tokens then
        error(("editor:global_set_key: bad chord %q: %s"):format(chord, err or "?"), 2)
    end
    self._base_keybindings[chord] = action
    self:rebuild_base_trie()
    self:rebuild_active_trie()
end

--- Bind a key chord in a specific major mode (Emacs `define-key`).
--- `mode` is either a MajorMode object (e.g. `modes.lua`) or a mode name
--- string (resolved against `config.modes`). Mutates the mode template's
--- `keybindings` (instances delegate via `__index` so active views pick
--- it up), invalidates the mode's cached trie, and rebuilds the active
--- trie. No-op effect on views whose active mode stack doesn't include
--- `mode` until the mode is next activated.
---@param mode MajorMode|string the mode whose keymap to extend
---@param chord string chord specifier
---@param action string|function command name or function
function Editor:define_key(mode, chord, action)
    local mode_obj = mode
    if type(mode) == "string" then
        mode_obj = self._config and self._config.modes[mode]
        if mode_obj == nil then
            error(("editor:define_key: unknown mode %q"):format(mode), 2)
        end
    end
    local tokens, err = keybind.parse_chord(chord)
    if not tokens then
        error(("editor:define_key: bad chord %q: %s"):format(chord, err or "?"), 2)
    end
    mode_obj.keybindings = mode_obj.keybindings or {}
    mode_obj.keybindings[chord] = action
    mode_obj._trie = nil -- invalidate cached trie; rebuilt on next :trie()
    self:rebuild_active_trie()
end

--- Register a named command (Emacs `defun`-equivalent for the command
--- table). After registration the function is invocable via M-x by name
--- (spaces allowed, case-insensitive) and bindable by string in
--- `global_set_key` / `define_key`. Names normalize the same way
--- `commands.lookup` does (spaces → underscores, lowercased) so M-x
--- round-trips. The command also appears in M-x completion.
---@param name string command name (snake_case or with spaces)
---@param fn function(view, editor, ...) command implementation
function Editor:define_command(name, fn)
    local commands = require("cursed.commands")
    local key = name:gsub(" ", "_"):lower()
    commands[key] = fn
end

--- Schedule a plain function to run incrementally on the main thread.
--- The function is called once per main-loop iteration (round-robin
--- with other background tasks). If it returns true, it is removed
--- from the queue; false/nil means it will be called again next time.
---@param fn fun(): boolean?
function Editor:push_background_task(fn)
    self._background_tasks[#self._background_tasks + 1] = fn
end

--- Schedule a function to run once at or after `deadline_us` (monotonic
--- wall-clock microseconds). The function should return truthy when
--- done; false/nil re-queues it at the same deadline. Returns a task
--- handle that can be passed to `cancel_task`.
---@param deadline_us integer
---@param fn fun(): boolean?
---@return table handle
function Editor:schedule_at(deadline_us, fn)
    local task = { deadline = deadline_us, fn = fn }
    self._background_tasks[#self._background_tasks + 1] = task
    return task
end

--- Schedule a function to run once after `delay_us` microseconds.
---@param delay_us integer
---@param fn fun(): boolean?
---@return table handle
function Editor:schedule_after(delay_us, fn)
    return self:schedule_at(now_us() + delay_us, fn)
end

--- Remove a scheduled task from the queue by its handle.
---@param handle table
function Editor:cancel_task(handle)
    local tasks = self._background_tasks
    local j = 1
    for i = 1, #tasks do
        if tasks[i] ~= handle then
            tasks[j] = tasks[i]
            j = j + 1
        end
    end
    for i = j, #tasks do
        tasks[i] = nil
    end
end

--- Earliest deadline among pending tasks, or `now_us()` if any plain
--- task is queued. Used by the main select() loop to sleep only until
--- the next timer is due.
---@return integer|nil deadline_us
function Editor:next_task_deadline()
    local tasks = self._background_tasks
    if #tasks == 0 then
        return nil
    end
    local deadline ---@type integer|nil
    for _, e in ipairs(tasks) do
        if type(e) == "table" and e.deadline ~= nil then
            if deadline == nil or e.deadline < deadline then
                deadline = e.deadline
            end
        else
            -- Plain task: ready immediately.
            return now_us()
        end
    end
    return deadline
end

--- Execute one step of a single background task per call (round-robin).
--- Deadline tasks run only when their deadline has been reached; plain
--- tasks run every call. Re-queues unfinished tasks. Returns the
--- earliest remaining deadline so the caller can update its sleep time.
---@return integer|nil deadline_us
function Editor:tick_background_tasks()
    local tasks = self._background_tasks
    if #tasks == 0 then
        return nil
    end
    local entry = table.remove(tasks, 1)
    local now = now_us()
    local next_deadline ---@type integer|nil
    local done = false
    if type(entry) == "table" and entry.deadline ~= nil then
        if now >= entry.deadline then
            done = entry.fn()
        else
            next_deadline = entry.deadline
        end
    else
        done = entry()
    end
    if not done then
        tasks[#tasks + 1] = entry
    end
    for _, e in ipairs(tasks) do
        if type(e) == "table" and e.deadline ~= nil then
            if next_deadline == nil or e.deadline < next_deadline then
                next_deadline = e.deadline
            end
        else
            return now
        end
    end
    return next_deadline
end

----------------------------------------------------------------------------------------------------
-- View management
----------------------------------------------------------------------------------------------------

--- Helper: emit focus/blur lifecycle events around an active-view
--- change. Called by set_active_view once mutation is done.
--- Emits (in order): view_blur(old), buffer_blur(old.buffer),
--- view_focus(new), buffer_focus(new.buffer). Only fires when the
--- actual focused view object changes (index shifts to the same view
--- due to list removal are a no-op here).
---@param old_view View|nil
---@param new_view View|nil
function Editor:_emit_focus_change(old_view, new_view)
    if old_view == new_view then
        return
    end
    local es = self.event_system
    if old_view then
        es:emit("view_blur", old_view)
        if old_view.buffer then
            es:emit("buffer_blur", old_view.buffer, old_view)
        end
    end
    if new_view then
        es:emit("view_focus", new_view)
        if new_view.buffer then
            es:emit("buffer_focus", new_view.buffer, new_view)
        end
    end
end

--- Set the active view index and rebuild the keybind trie
--- if the new view has a different mode. Also fires view_blur /
--- buffer_blur (for the previously-active view) and view_focus /
--- buffer_focus (for the newly-active view) when the focused view
--- object actually changes.
---@param idx integer 1-based index into self.views
function Editor:set_active_view(idx)
    local old_view = self:current_view()
    self.active_view = idx
    self:rebuild_active_trie()
    self:_emit_focus_change(old_view, self:current_view())
    if old_view ~= self:current_view() then
        self:request_full_damage()
    end
end

--- Get the active view.
---@return View|nil
function Editor:current_view()
    if self.active_view >= 1 and self.active_view <= #self.views then
        return self.views[self.active_view]
    end
    return nil
end

--- Add a view to the editor and make it active.
--- Fires view_open (and, via set_active_view, view_focus/buffer_focus
--- for the new view plus view_blur/buffer_blur for the previous one).
---@param view View
function Editor:add_view(view)
    view.editor = self
    view.margin = self.margin
    table.insert(self.views, view)
    --    self.active_view = #self.views
    self:set_active_view(#self.views)
    self.event_system:emit("view_open", view)
end

--- Close a view and fix up the active_view index.
--- If the closed view was active, selects the nearest neighbor.
--- Fires (in order): view_blur + buffer_blur for the doomed view if it
--- was active, then buffer_close + view_close for the doomed view,
--- then (via set_active_view) view_focus + buffer_focus for the
--- neighbor that takes its place.
---@param view View
function Editor:close_view(view)
    local idx = 0
    for i, v in ipairs(self.views) do
        if v == view then
            idx = i
            break
        end
    end
    if idx == 0 then
        return
    end
    -- If the doomed view is currently focused, blur it (and its buffer)
    -- first so the close sequence reads blur→close→focus(neighbor).
    if self:current_view() == view then
        self:_emit_focus_change(view, nil)
    end
    local buf = view.buffer
    if buf then
        self.event_system:emit("buffer_close", buf, view)
    end
    self.event_system:emit("view_close", view)
    table.remove(self.views, idx)
    if #self.views == 0 then
        self:set_active_view(0)
    elseif self.active_view > #self.views then
        self:set_active_view(#self.views)
    elseif idx <= self.active_view then
        self:set_active_view(math.max(1, self.active_view - 1))
    end
end

----------------------------------------------------------------------------------------------------
-- Keybinding-driven operations (delegate to active view + buffer)
----------------------------------------------------------------------------------------------------

-- Note: editing ops (insert_char, delete_char, insert_newline,
-- delete_selection) live on View and are called directly.
-- Editor keeps only genuinely editor-level orchestration below.

--- Undo the last edit.
function Editor:undo()
    local view = self:focused_view()
    if not view then
        return
    end
    if not view:undo() then
        self.status_message = "no further undo information"
    end
end

--- Redo the last undone edit.
function Editor:redo()
    local view = self:focused_view()
    if not view then
        return
    end
    if not view:redo() then
        self.status_message = "no further redo information"
    end
end

--- Open a file in a new view.
--- Expands ~ and $ENV in the path, creates a new Buffer + View,
--- and requests the IO lane to load the file contents.
---@param filepath string raw path from the user (may contain ~, $ENV)
function Editor:open_file(filepath)
    local bench = require("cursed.bench")
    local t0 = bench.now_us()

    local expanded = find_file.expand_path(filepath)

    -- Refuse to open directories
    if find_file.is_directory(expanded) then
        self.status_message = "cannot open directory: " .. filepath
        return
    end

    local buf = Buffer.new()
    buf:set_filepath(expanded)
    local view = View.new(buf)
    view._bench_open_t0 = t0 -- start of the whole open pipeline (main lane)
    self:add_view(view)

    log.debug("editor", "open_file begin", { path = expanded })

    -- Request IO lane to load the file
    local ss = shared.SharedState.from_global()
    ss:push(ss._ptr.outbox_io, { type = shared.MSG_FILE_LOAD, ptr = expanded })
end

--- Insert a file's contents at the cursor (async via IO lane).
---@param filepath string raw path from the user (may contain ~, $ENV)
function Editor:insert_file(filepath)
    local expanded = find_file.expand_path(filepath)

    if find_file.is_directory(expanded) then
        self.status_message = "cannot insert directory: " .. filepath
        return
    end

    local ss = shared.SharedState.from_global()
    ss:push(ss._ptr.outbox_io, { type = shared.MSG_INSERT_FILE, ptr = expanded })
end

--- Save the current buffer to its filepath (async via IO lane).
function Editor:save()
    local view = self:current_view()
    if not view then
        return
    end
    local buf = view.buffer
    local fp = buf:filepath()
    if fp == nil then
        self.status_message = "no file"
        return
    end
    self:_async_save(buf)
end

--- Save the current buffer to a new filepath (async via IO lane).
---@param filepath string raw path from the user (may contain ~, $ENV)
function Editor:save_as(filepath)
    local view = self:current_view()
    if not view then
        return
    end
    local expanded = find_file.expand_path(filepath)
    view.buffer:set_filepath(expanded)
    self:_async_save(view.buffer)
end

--- Internal: serialize buffer to mmap and dispatch to IO lane.
---@param buf Buffer
function Editor:_async_save(buf)
    local fp = buf:filepath()
    if fp == nil then
        self.status_message = "no file"
        return
    end

    local data, len, cap = buf:serialize_to_mmap()

    -- Allocate SaveRequest on the heap
    local req = ffi.cast("struct SaveRequest *", c.calloc(1, ffi.sizeof("struct SaveRequest")))
    if req == nil then
        ffi.C.munmap(data, cap)
        self.status_message = "save failed"
        return
    end
    req.data = data
    req.data_len = len
    req.data_cap = cap

    -- Copy filepath into heap C string
    local fp_buf = ffi.cast("char *", c.calloc(#fp + 1, 1))
    if fp_buf == nil then
        ffi.C.munmap(data, cap)
        c.free(req)
        self.status_message = "save failed"
        return
    end
    ffi.copy(fp_buf, fp)
    req.filepath = fp_buf

    local ss = shared.SharedState.from_global()
    ss:push(ss._ptr.outbox_io, {
        type = shared.MSG_FILE_SAVE,
        ptr = req,
    })
end

--- Quit the editor.
---@return string
function Editor:quit()
    return "quit"
end

----------------------------------------------------------------------------------------------------
-- Minibuffer
----------------------------------------------------------------------------------------------------

--- Activate the minibuffer to read a line of input from the user.
--- If `opts.value` is non-nil, short-circuits: calls on_submit(value) directly
--- without showing the minibuffer.
---@param opts { prompt: string?, on_submit: function?, on_cancel: function?, on_change: function?, initial: string?, completion: boolean?, completer: function?, value: any?, auto_accept: boolean?, palette: boolean? }
function Editor:read_from_minibuffer(opts)
    -- When replaying a kmacro, pop from the input stack to auto-submit.
    -- This lets commands like find_file, isearch, etc. skip the
    -- interactive minibuffer during replay.
    if #self._mb_input_stack > 0 then
        local value = table.remove(self._mb_input_stack, 1)
        -- Simulate the user typing the answer, then pressing Enter.
        if opts.on_change then
            opts.on_change(value)
        end
        if opts.on_submit then
            opts.on_submit(value)
        end
        return
    end
    if opts.value ~= nil then
        if opts.on_submit then
            opts.on_submit(opts.value)
        end
        return
    end
    self.minibuffer:activate(opts)
end

--- Submit the minibuffer: invoke on_submit with the input text and deactivate.
function Editor:minibuffer_submit()
    if not self.minibuffer or not self.minibuffer.active then
        return
    end
    local input_text = self.minibuffer:view_text()
    self.minibuffer:history_push(input_text)
    -- If recording a kmacro, push this input onto the stack
    if self._recording then
        local stack = self._recorded_mb_inputs
        if stack then
            stack[#stack + 1] = input_text
        end
    end
    local callback = self.minibuffer.on_submit
    self.minibuffer:deactivate()
    -- Flag that minibuffer just closed, so stale Enter/Tab events
    -- in the same drain batch don't dispatch to the main view.
    self._mb_just_closed = 1
    if callback then
        callback(input_text)
    end
end

--- Cancel the minibuffer: invoke on_cancel and deactivate.
function Editor:minibuffer_cancel()
    if not self.minibuffer or not self.minibuffer.active then
        return
    end
    local callback = self.minibuffer.on_cancel
    self.minibuffer:deactivate()
    self._mb_just_closed = 1
    if callback then
        callback()
    end
end

--- Fire minibuffer on_change if text has changed. Called from the main loop.
function Editor:minibuffer_notify_change()
    if self.minibuffer then
        self.minibuffer:notify_change()
    end
end

----------------------------------------------------------------------------------------------------
-- Read-char (one-shot single-key input)
----------------------------------------------------------------------------------------------------

--- Start a one-shot read-char interaction. The next key event's
--- character (or `nil` if the user cancels with C-g/Escape) is passed
--- to `callback`. Used by quoted-insert (C-q), zap-to-char (M-z),
--- and zap-up-to-char (M-Z).
---
--- The prompt is shown in the status area (left of the modeline)
--- so the user knows what is being read; the main loop checks
--- `editor:_read_char_consume(token, ch)` after every key event,
--- which returns true if the event was consumed.
---@param prompt string short prompt (e.g. "Zap to char: ")
---@param callback fun(ch: string|nil) called with the char (or nil on cancel)
function Editor:read_char(prompt, callback)
    self._read_char_cb = callback
    self._read_char_prompt = prompt
end

--- Try to consume a key event for an active read-char interaction.
--- Returns true if the event was consumed (the caller must not
--- dispatch it further). On consume, clears the one-shot callback.
--- C-g / Escape cancel (callback called with nil, returns true).
--- Any printable byte feeds the callback with that character.
--- Non-printable keys (arrows, function keys, chords) are ignored
--- so the user can still e.g. move the cursor; they return false
--- and dispatch normally. The read-char interaction stays active.
---@param token string|nil key token from event_to_token
---@param ch string|nil printable character (1 byte) if the event is printable
---@return boolean consumed
function Editor:_read_char_consume(token, ch)
    if self._read_char_cb == nil then
        return false
    end
    if token == "ctrl-g" or token == "escape" then
        local cb = self._read_char_cb
        self._read_char_cb = nil
        self._read_char_prompt = ""
        if cb then
            cb(nil)
        end
        return true
    end
    if ch and #ch == 1 then
        -- Avoid Control characters (the is_printable filter in main
        -- already excludes them, but guard anyway).
        local byte = ch:byte(1)
        if byte >= 32 then
            local cb = self._read_char_cb
            self._read_char_cb = nil
            self._read_char_prompt = ""
            if cb then
                cb(ch)
            end
            return true
        end
    end
    return false
end

--- Active read-char prompt for modeline display, or nil.
---@return string|nil
function Editor:read_char_status()
    if self._read_char_cb ~= nil then
        return self._read_char_prompt
    end
    return nil
end

----------------------------------------------------------------------------------------------------
-- Universal argument (C-u)
----------------------------------------------------------------------------------------------------

--- Start universal argument collection.
--- Activates the minibuffer with a C-u prompt. Printable characters
--- are collected as the argument text; chord keys terminate and
--- dispatch the command with the universal args.
---@param count integer? initial C-u count (default 1)
function Editor:start_universal_arg(count)
    self._universal_active = true
    self._universal_count = count or 1
    self.minibuffer:activate({
        prompt = self:_universal_prompt(),
        on_cancel = function()
            self:cancel_universal_arg()
        end,
    })
end

--- Toggle the universal flag (called when C-u is pressed during collection).
function Editor:toggle_universal_arg()
    self._universal_count = self._universal_count + 1
    self.minibuffer.prompt = self:_universal_prompt()
end

--- Build the prompt string showing the current C-u state.
---@return string
function Editor:_universal_prompt()
    local cu_str = string.rep("C-u", self._universal_count)
    return cu_str .. " "
end

--- Cancel universal argument collection.
function Editor:cancel_universal_arg()
    self._universal_active = false
    self._universal_count = 0
    self.universal_args = nil
end

--- Compute and store the universal argument list from current state.
--- Called when a command key is pressed during universal arg collection.
--- The args are stored on editor.universal_args for the command to read.
function Editor:get_universal_args()
    local universal_arg = require("cursed.universal_arg")
    local input = self.minibuffer:view_text()
    local args = universal_arg.build_universal_args(self._universal_count, input)
    self._universal_active = false
    self._universal_count = 0
    self.minibuffer:deactivate()
    self.universal_args = args
end

----------------------------------------------------------------------------------------------------
-- M-digit / M-- prefix argument
----------------------------------------------------------------------------------------------------

--- Start or continue digit argument accumulation from an M-digit key.
--- M-3 M-0 → value becomes 30.
---@param digit integer 0-9
function Editor:accumulate_digit(digit)
    if not self._digit_active then
        self._digit_active = true
        self._digit_value = digit
        self._digit_negative = false
    else
        self._digit_value = self._digit_value * 10 + digit
    end
    self.status_message =
        string.format("Arg: %d", self._digit_negative and -self._digit_value or self._digit_value)
end

--- Set the negative flag for M--.
function Editor:set_digit_negative()
    if not self._digit_active then
        self._digit_active = true
        self._digit_value = 0
    end
    self._digit_negative = true
    if self._digit_value == 0 then
        self.status_message = "Arg: -"
    else
        self.status_message = string.format("Arg: -%d", self._digit_value)
    end
end

--- Commit the accumulated digit argument into universal_args.
--- Called when a command key is pressed during digit accumulation.
--- Builds { flag, value } where flag is false when negative.
--- The value is always positive; direction is encoded in the flag
--- (consistent with C-u's flag semantics).
function Editor:commit_digit_arg()
    local flag = not self._digit_negative
    local value = self._digit_value
    log.info(
        "editor",
        "commit_digit_arg",
        { flag = flag, value = value, negative = self._digit_negative }
    )
    if value == 0 and not self._digit_negative then
        -- M-0 alone: numeric arg 0
        self.universal_args = { true, 0 }
    elseif value == 0 and self._digit_negative then
        -- M-- alone: flag=false (like bare C-u)
        self.universal_args = { false }
    else
        -- M-N or M-- M-N: value is positive, direction in flag
        self.universal_args = { flag, value }
    end
    self._digit_active = false
    self._digit_value = 0
    self._digit_negative = false
end

--- Cancel digit argument accumulation.
function Editor:cancel_digit_arg()
    self._digit_active = false
    self._digit_value = 0
    self._digit_negative = false
end

----------------------------------------------------------------------------------------------------
-- Kill ring (consecutive-kill merging)
----------------------------------------------------------------------------------------------------

--- Push killed text onto the kill ring, merging with the previous
--- entry if the last command was also a kill.
--- This implements Emacs' consecutive-kill merging: C-k C-k produces
--- one kill ring entry (the two kills appended), not two separate entries.
---@param text string killed text to push or append
function Editor:push_kill(text)
    if #text == 0 then
        return
    end
    if (self._last_was_kill or self._kill_called) and #kill_ring.ring > 0 then
        -- Append to the top entry (consecutive kill or multiple kills in one command)
        kill_ring.ring[1] = kill_ring.ring[1] .. text
    else
        kill_ring:push(text)
        -- Sync new kill to system clipboard (consecutive kills skip this
        -- since they append to ring[1] here instead).
        require("cursed.clipboard").set_if_different(text)
    end
    self._kill_called = true
end

--- Store a pretty-printed eval result to display in the minibuffer area.
---@param value any
function Editor:show_eval_result(value)
    self._eval_result = pprint(value)
end

----------------------------------------------------------------------------------------------------
-- Incremental search (isearch)
----------------------------------------------------------------------------------------------------

--- Start an incremental search from the current cursor position.
---@param direction integer 1=forward, -1=backward
function Editor:start_isearch(direction, initial_query, opts)
    opts = opts or {}
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end

    -- Use selection text as initial query if none provided
    if not initial_query and main_view:p().anchor_line then
        local sl, sc, el, ec = main_view:selection_range()
        if sl then
            ---@cast sc integer
            ---@cast el integer
            ---@cast ec integer
            initial_query = main_view:text_between(sl, sc, el, ec)
        end
    end

    -- Save original point for C-g cancel
    self._isearch_origin_line = main_view:p().line
    self._isearch_origin_col = main_view:p().col
    self._isearch_direction = direction
    self._isearch_regex = opts.regex == true

    local prompt
    if opts.regex then
        prompt = direction > 0 and "Search regexp: " or "Search backward regexp: "
    else
        prompt = direction > 0 and "Search: " or "Search backward: "
    end

    -- When replaying a kmacro, use 'value' to auto-submit the query
    -- instead of opening an interactive minibuffer.
    local mb_opts = {
        prompt = prompt,
        completion = true,
        on_change = function(query)
            self:_isearch_update(query)
        end,
        on_submit = function(_query)
            -- Keep cursor at match, mark stays for C-x C-x jump-back
            self._isearch_origin_line = nil
            self._isearch_origin_col = nil
        end,
        on_cancel = function()
            -- Restore original point
            local mv = self:current_view()
            if mv and self._isearch_origin_line then
                mv:p().line = self._isearch_origin_line
                mv:p().col = self._isearch_origin_col
                mv:_set_goal_col(mv:p().col)
                mv:unset_mark()
            end
            self._isearch_origin_line = nil
            self._isearch_origin_col = nil
            self._isearch_regex = nil
        end,
    }

    mb_opts.initial = initial_query

    self:read_from_minibuffer(mb_opts)
end

--- Build a search iterator for the active isearch mode (plain or
--- regexp) in the given direction.
---@param buf Buffer
---@param query string
---@param start table start point {line, offset}
---@param direction integer 1=forward, -1=backward
---@return function|nil iter
---@return string|nil errmsg
function Editor:_isearch_iter(buf, query, start, direction)
    if self._isearch_regex then
        -- POSIX extended regex via TRE (case-sensitive), reusing the
        -- same search_regex / search_regex_backward path as
        -- replace_regexp for consistency.
        local icase = false
        if direction > 0 then
            return buf:search_regex(query, start, icase)
        else
            return buf:search_regex_backward(query, start, icase)
        end
    end
    if direction > 0 then
        return buf:search_forward(query, start, true)
    else
        return buf:search_backward(query, start, true)
    end
end

--- Jump to the next isearch match (C-s while in isearch).
function Editor:isearch_next()
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end
    local query = self.minibuffer:view_text()
    if #query == 0 then
        return
    end

    local buf = main_view.buffer
    -- Search forward from end of current match
    local start = { line = main_view:p().line, offset = main_view:p().col }
    local iter, err = self:_isearch_iter(buf, query, start, 1)
    if not iter then
        self.status_message = "invalid regexp: " .. tostring(err)
        return
    end
    local match = iter()
    if match then
        main_view:p().anchor_line = match.line
        main_view:p().anchor_col = match.offset
        main_view:p().line = match.end_line
        main_view:p().col = match.end_offset
        main_view:_set_goal_col(main_view:p().col)
        self.status_message = nil
    else
        self.status_message = "failing search"
    end

    self._isearch_direction = 1
    self.minibuffer.prompt = self._isearch_regex and "Search regexp: " or "Search: "
end

--- Jump to the previous isearch match (C-r while in isearch).
function Editor:isearch_prev()
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end
    local query = self.minibuffer:view_text()
    if #query == 0 then
        return
    end

    local buf = main_view.buffer
    -- Search backward from start of current match
    local start
    if main_view:p().anchor_line then
        start = { line = main_view:p().anchor_line, offset = main_view:p().anchor_col }
    else
        start = { line = main_view:p().line, offset = main_view:p().col }
    end
    local iter, err = self:_isearch_iter(buf, query, start, -1)
    if not iter then
        self.status_message = "invalid regexp: " .. tostring(err)
        return
    end
    local match = iter()
    if match then
        main_view:p().anchor_line = match.line
        main_view:p().anchor_col = match.offset
        main_view:p().line = match.end_line
        main_view:p().col = match.end_offset
        main_view:_set_goal_col(main_view:p().col)
        self.status_message = nil
    else
        self.status_message = "failing search"
    end

    self._isearch_direction = -1
    self.minibuffer.prompt = self._isearch_regex and "Search backward regexp: "
        or "Search backward: "
end

--- Internal: run isearch from the saved origin for the given query.
---@param query string
function Editor:_isearch_update(query)
    if #query == 0 then
        return
    end
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end
    local buf = main_view.buffer
    local start = { line = self._isearch_origin_line, offset = self._isearch_origin_col }
    local iter, err = self:_isearch_iter(buf, query, start, self._isearch_direction)
    if not iter then
        self.status_message = "invalid regexp: " .. tostring(err)
        return
    end
    local match = iter()
    if match then
        main_view:p().anchor_line = match.line
        main_view:p().anchor_col = match.offset
        main_view:p().line = match.end_line
        main_view:p().col = match.end_offset
        main_view:_set_goal_col(main_view:p().col)
        self.status_message = nil
    end
end

----------------------------------------------------------------------------------------------------
-- Query replace
----------------------------------------------------------------------------------------------------

--- Start an incremental query-replace session.
--- Step 1: minibuffer for search string (incremental highlight like isearch)
--- Step 2: minibuffer for replacement string
--- Step 3: auto-accept minibuffer with yes/no/all to walk matches
---@param initial_query string? optional pre-fill from selection
function Editor:start_query_replace(initial_query)
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end

    -- Use selection text as initial query if none provided
    if not initial_query and main_view:p().anchor_line then
        local sl, sc, el, ec = main_view:selection_range()
        if sl then
            ---@cast sc integer
            ---@cast el integer
            ---@cast ec integer
            initial_query = main_view:text_between(sl, sc, el, ec)
        end
    end

    -- Save point for C-g cancel
    local origin_line = main_view:p().line
    local origin_col = main_view:p().col

    self:read_from_minibuffer({
        prompt = "Query replace: ",
        initial = initial_query,
        on_change = function(query)
            if #query == 0 then
                return
            end
            local mv = self:current_view()
            if not mv then
                return
            end
            local buf = mv.buffer
            local start = { line = mv:p().line, offset = mv:p().col }
            local iter = buf:search_forward(query, start, true)
            local match = iter()
            if match then
                mv:p().anchor_line = match.line
                mv:p().anchor_col = match.offset
                mv:p().line = match.end_line
                mv:p().col = match.end_offset
                mv:_set_goal_col(mv:p().col)
            end
        end,
        on_submit = function(query)
            if #query == 0 then
                return
            end
            self:_query_replace_step2(query, origin_line, origin_col)
        end,
        on_cancel = function()
            local mv = self:current_view()
            if mv then
                mv:p().line = origin_line
                mv:p().col = origin_col
                mv:_set_goal_col(origin_col)
                mv:unset_mark()
            end
        end,
    })
end

--- Step 2 of query-replace: ask for the replacement string.
---@param query string the search string
---@param origin_line integer cursor line before the whole operation
---@param origin_col integer cursor col before the whole operation
function Editor:_query_replace_step2(query, origin_line, origin_col)
    self:read_from_minibuffer({
        prompt = "Query replace " .. query .. " with: ",
        on_submit = function(replacement)
            self:_query_replace_step3(query, replacement, origin_line, origin_col)
        end,
        on_cancel = function()
            local mv = self:current_view()
            if mv then
                mv:p().line = origin_line
                mv:p().col = origin_col
                mv:_set_goal_col(origin_col)
                mv:unset_mark()
            end
        end,
    })
end

--- Step 3 of query-replace: walk matches with yes/no/all auto-accept.
---@param query string
---@param replacement string
---@param origin_line integer
---@param origin_col integer
function Editor:_query_replace_step3(query, replacement, origin_line, origin_col)
    local main_view = self:current_view()
    if not main_view then
        return
    end

    -- Start search from the saved origin (before step 1 highlighting moved the cursor)
    main_view:p().line = origin_line
    main_view:p().col = origin_col
    main_view:unset_mark()

    -- Find the first match
    local buf = main_view.buffer
    local start = { line = origin_line, offset = origin_col }
    local iter = buf:search_forward(query, start, true)
    local match = iter()

    if not match then
        self.status_message = "no matches"
        -- Restore origin
        main_view:p().line = origin_line
        main_view:p().col = origin_col
        main_view:_set_goal_col(origin_col)
        return
    end

    -- Highlight the first match
    main_view:p().anchor_line = match.line
    main_view:p().anchor_col = match.offset
    main_view:p().line = match.end_line
    main_view:p().col = match.end_offset
    main_view:_set_goal_col(main_view:p().col)

    self:_query_replace_prompt(query, replacement)
end

--- Show the yes/no/all auto-accept prompt for the current match.
---@param query string
---@param replacement string
function Editor:_query_replace_prompt(query, replacement)
    self:read_from_minibuffer({
        prompt = "Replace? ",
        completion = true,
        auto_accept = true,
        completer = completers.yes_no_all(),
        on_submit = function(answer)
            log.info("replace", "on_submit", { answer = answer })
            answer = answer:lower()
            if answer == "y" then
                if self:_query_replace_one(query, replacement) then
                    if self:_query_replace_find_next(query) then
                        self:_query_replace_prompt(query, replacement)
                    end
                end
            elseif answer == "a" then
                self:_query_replace_all(query, replacement)
            else -- "n"
                if self:_query_replace_find_next(query) then
                    self:_query_replace_prompt(query, replacement)
                end
            end
        end,
        on_cancel = function()
            local mv = self:current_view()
            if mv then
                mv:unset_mark()
            end
        end,
    })
end

--- Replace the currently-highlighted match and return true if successful.
---@param query string
---@param replacement string
---@return boolean
function Editor:_query_replace_one(query, replacement)
    local main_view = self:current_view()
    if not main_view then
        return false
    end
    local buf = main_view.buffer

    if not main_view:p().anchor_line then
        return false
    end

    local sl, sc, el, ec = main_view:selection_range()
    if not sl then
        return false
    end
    ---@cast sc integer
    ---@cast el integer
    ---@cast ec integer

    local n = main_view:chars_between(sl, sc, el, ec)
    if n > 0 then
        buf:begin_edit()
        buf:delete_char(sl, sc, n)
        local rl, rc = buf:insert_char(sl, sc, replacement)
        buf:end_edit()
        main_view:p().line = rl
        main_view:p().col = rc
        main_view:_set_goal_col(rc)
    else
        main_view:p().line = sl
        main_view:p().col = sc
        main_view:_set_goal_col(sc)
    end
    main_view:unset_mark()
    return true
end

--- Find the next match and highlight it. Returns false if no more matches.
---@param query string
---@return boolean
function Editor:_query_replace_find_next(query)
    local main_view = self:current_view()
    if not main_view then
        return false
    end
    local buf = main_view.buffer
    local start = { line = main_view:p().line, offset = main_view:p().col }
    local iter = buf:search_forward(query, start, true)
    local match = iter()

    if not match then
        self.status_message = "no more matches"
        return false
    end

    main_view:p().anchor_line = match.line
    main_view:p().anchor_col = match.offset
    main_view:p().line = match.end_line
    main_view:p().col = match.end_offset
    main_view:_set_goal_col(main_view:p().col)
    return true
end

--- Replace all remaining matches by chaining through the minibuffer.
--- Each replacement yields back to the event loop, avoiding
--- long synchronous mutation chains that corrupt piece table state.
---@param query string
---@param replacement string
function Editor:_query_replace_all(query, replacement)
    local main_view = self:current_view()
    if not main_view then
        return
    end
    local buf = main_view.buffer

    -- Single edit group: one undo step for the entire replace-all.
    -- The group spans multiple main-loop iterations (funky but fine).
    buf:begin_edit()
    local count = 0
    self:push_background_task(function()
        if not self:_query_replace_one(query, replacement) then
            buf:end_edit()
            self.status_message = "replaced " .. count .. " occurrences"
            return true -- done
        end
        count = count + 1
        if count % 100 == 0 then
            log.info("replace", "progress", { count = count })
        end
        if not self:_query_replace_find_next(query) then
            buf:end_edit()
            self.status_message = "replaced " .. count .. " occurrences"
            return true -- done
        end
        return false -- more work
    end)
end

----------------------------------------------------------------------------------------------------
-- Convenience accessors (for keybindings that only have the editor)
----------------------------------------------------------------------------------------------------

--- Get the focused view (minibuffer view when active, otherwise main view).
---@return View|nil
function Editor:focused_view()
    if self.minibuffer and self.minibuffer.active and not self._universal_active then
        return self.minibuffer.view
    end
    return self:current_view()
end

--- Get the active view's buffer.
---@return Buffer|nil
function Editor:buffer()
    local view = self:current_view()
    return view and view.buffer
end

----------------------------------------------------------------------------------------------------
-- Scrolling
----------------------------------------------------------------------------------------------------

---@param height integer terminal height in rows
function Editor:scroll_to_cursor(height)
    local view = self:current_view()
    if view then
        view:scroll_to_cursor(height)
    end
end

--- Get the number of footer rows (modeline + minibuffer input rows + completions + eval).
---@return integer
function Editor:footer_rows()
    local mb = self.minibuffer
    local mb_rows = 0
    if mb and mb.active then
        -- Palette mode floats over the buffer (centered box), so it
        -- reserves NO bottom rows — only the modeline does.
        if not mb.palette then
            mb_rows = mb:input_rows()
        end
    elseif self._eval_result then
        mb_rows = 1
    end
    local comp_rows = (mb and mb.active and not mb.palette and mb.completion)
            and mb:comp_visible_rows()
        or 0
    return 1 + mb_rows + comp_rows
end

----------------------------------------------------------------------------------------------------
-- Modeline rendering (segment-based; see DEFAULT_MODELINE_SEGMENTS for the spec).
----------------------------------------------------------------------------------------------------

--- Render the modeline row into the overlay sink `fp` at row `y`.
--- Evaluates each segment's format fn, resolves bg/text colors, lays out
--- fill segments, and draws the alternating auto-separators. Skips segments
--- whose format returns "" and aren't `fill`. No-op before a scheme is loaded.
---@param view View the focused view
---@param w integer terminal width
---@param y integer screen row for the modeline
---@param fp function float-print sink (x, y, text, fg, bg) from the overlay manager
function Editor:render_modeline(view, w, y, fp)
    local scheme = ColorScheme.active
    if scheme == nil or self.modeline_segments == nil then
        return
    end

    -- 1. Evaluate formats → survivors. A segment with empty text and
    --    non-fill elides entirely (no block, no separators).
    local segs = {}
    for _, spec in ipairs(self.modeline_segments) do
        local text = spec.format(self, view)
        if text == nil then
            text = ""
        end
        local is_fill = spec.fill == true
        if text ~= "" or is_fill then
            segs[#segs + 1] = {
                text = text,
                fill = is_fill,
                w = cell_len(text),
                bg_spec = spec.bg,
                fg_spec = spec.fg,
            }
        end
    end
    local n = #segs
    if n == 0 then
        return
    end

    -- 2. Resolve colors: bg from spec; text = spec.fg override or
    --    auto-detected from bg luminance (dark bg → base06, light → base00).
    for _, s in ipairs(segs) do
        s.bg_color = resolve_seg_color(s.bg_spec, ui("modeline_bg"))
        if s.fg_spec ~= nil then
            s.fg_color = resolve_seg_color(s.fg_spec, ui("modeline_fg"))
        else
            s.fg_color = auto_text_color(scheme, s.bg_color)
        end
    end

    -- 3. Layout. available space = w − Σ(text widths) − (N−1 separators).
    --    Split `available` evenly among `fill` segments; remainder →
    --    leftmost fills first.
    local seps = n - 1
    local text_total = 0
    local fill_count = 0
    for _, s in ipairs(segs) do
        text_total = text_total + s.w
        if s.fill then
            fill_count = fill_count + 1
        end
    end
    local available = w - text_total - seps
    if available < 0 then
        available = 0
    end
    local pad_each = 0
    local remainder = 0
    if fill_count > 0 then
        pad_each = math.floor(available / fill_count)
        remainder = available - pad_each * fill_count
    end

    -- 4. Paint, left → right. Each segment: bg block of its allocation
    --    (spaces), then the text overdrawn at the start, then a separator
    --    cell (unless last). Separator glyph alternates ◣ / ◢ and its colors
    --    are derived from the two adjacent segments' bg colors.
    local x = 0
    for i, s in ipairs(segs) do
        local extra = 0
        if s.fill then
            extra = pad_each
            if remainder > 0 then
                extra = extra + 1
                remainder = remainder - 1
            end
        end
        local alloc = s.w + extra
        if alloc < 1 then
            alloc = s.w > 0 and s.w or 1
        end
        -- Truncate text to its allocation when it overflows (available was
        -- clamped to 0, so a non-fill segment wider than the row clips).
        local text = s.text
        if s.w > alloc then
            text = truncate_cells(text, alloc)
        end
        -- bg block fill for the whole allocation.
        fp(x, y, string.rep(" ", alloc), s.fg_color, s.bg_color)
        -- text overdrawn at the start.
        if text ~= "" then
            fp(x, y, text, s.fg_color, s.bg_color)
        end
        x = x + alloc
        -- Separator at the boundary between segs[i] and segs[i+1].
        if i < n then
            local rbg = segs[i + 1].bg_color
            if (i - 1) % 2 == 0 then
                -- Even boundary (0-based): ◣ lower-left, fg = left bg, bg = right bg.
                fp(x, y, "◣", s.bg_color, rbg)
            else
                -- Odd boundary: ◢ lower-right, fg = right bg, bg = left bg.
                fp(x, y, "◢", rbg, s.bg_color)
            end
            x = x + 1
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------------------------------------

--- Render the entire viewport.
function Editor:render()
    local render_t0 = profile.now_us()
    local term = self.term
    local w = term:width()
    local h = term:height()
    -- Defensive backstop: clamp all cursors before reading them for
    -- rendering so a stale past-eol position can never produce a broken
    -- caret / modeline. Motions/edits already clamp, but cursor state
    -- can also be set by undo/redo, file reload, or mode activation.
    for _, v in ipairs(self.views) do
        if v.file_loaded then
            v:_clamp_all_cursors()
        end
    end
    -- Hoisted early (before the clear + paint helpers) so the focus
    -- backdrop can consult mb.palette at clear time and so the paint
    -- helpers can close over `mb` directly.
    local mb = self.minibuffer

    -- Overlay frame: snapshot the view being rendered + clear the overlay
    -- queues. `view` is hoisted above the paint helpers so begin_frame runs
    -- before any chrome registers, and so `fp` (the float-print sink the
    -- chrome closures capture) is defined alongside the other paint helpers.
    local view = self:current_view()
    local ov = self.overlays
    ov:begin_frame(view)
    --- Float-print sink: route chrome (modeline / minibuffer / completions)
    --- through the overlay manager so it composes with extension overlays
    --- in a single z-ordered flush. `fp(x,y,text,fg,bg)` is the screen-space
    --- overlay equivalent of `term:print` — same signature, deferred paint.
    local function fp(x, y, text, fg, bg)
        ov:put_float(x, y, text, fg, bg)
    end

    -- Damage tracking (#4): decide the first viewport row that needs
    -- repainting. 0 = full screen; nil = derive from cursor/anchors;
    -- >0 = only from this row down. Full damage is forced when terminal
    -- size, footer geometry, palette state, scroll offset, or document
    -- line count changed since the last render.
    local footer_rows = self:footer_rows()
    local palette_active = mb and mb.palette or false
    local cur_min_cursor_row = self:_min_cursor_screen_row()
    local damage_start_row = self._damage_start_row
    if damage_start_row == nil then
        if self._last_min_cursor_row ~= nil then
            damage_start_row = math.min(cur_min_cursor_row, self._last_min_cursor_row)
        else
            damage_start_row = cur_min_cursor_row
        end
    end
    local line_count_changed = false
    if view then
        local cur_lc = view.buffer:line_count()
        line_count_changed = self._last_line_count ~= nil and cur_lc ~= self._last_line_count
    end
    if
        self._last_w ~= nil
        and (
            w ~= self._last_w
            or h ~= self._last_h
            or footer_rows ~= self._last_footer_rows
            or palette_active ~= self._last_palette
            or line_count_changed
            or (
                view
                and (
                    view.scroll_li ~= self._last_scroll_li
                    or view.scroll_sub_row ~= self._last_scroll_sub_row
                )
            )
        )
    then
        damage_start_row = 0
    end
    if damage_start_row < 0 then
        damage_start_row = 0
    end

    -- When the palette is open, the focus backdrop tints the whole
    -- buffer region — including empty rows below the last line — so
    -- clear with the black-blended bg instead of bright default_bg.
    do
        local clear_bg = ui("default_bg")
        if mb and mb.palette then
            clear_bg = blend(clear_bg, 0x000000, 195)
        end
        -- Full damage: clear the backbuffer. Partial damage: leave rows
        -- above damage_start_row untouched from the previous frame.
        if damage_start_row == 0 then
            term:clear(ui("default_fg"), clear_bg)
        end
    end
    -- The hardware terminal caret is always hidden; the caret is drawn
    -- as a reverse-video cell (toggled on/off by the blink timer)
    -- wherever it should appear (main view + minibuffer).
    term:hide_cursor()

    --- Focus-backdrop tint: when the palette (M-x) is open, darken the
    --- buffer region toward TRUE BLACK (not default_bg) so the backdrop
    --- reads as saturated OLED-dark rather than merely "dimmer". bg
    --- blends ~75% toward 0x000000 — clearly darker than base00 on any
    --- palette. fg blends ~65% toward 0x000000 so text recedes but
    --- stays legible against the now-blacker bg. Returns the originals
    --- unchanged when the palette isn't active. The modeline is painted
    --- separately and stays full-saturation.
    local BLACK = 0x000000
    local function focus_dim(fg, bg)
        if not (mb and mb.palette) then
            return fg, bg
        end
        return blend(fg, BLACK, 165), blend(bg, BLACK, 195)
    end

    --- Paint a text chunk's base layer with syntax-highlight spans.
    --- Falls back to a single plain-default print when highlighting is off
    --- or the chunk has no spans. Overlays (selection/cursor/drops) are
    --- painted afterwards by the caller and override these segments.
    --- row_bg: background to paint text-region cells with, so the
    --- active-line highlight carries through the syntax spans (which
    --- would otherwise repaint with default_bg). Defaults to
    --- default_bg for non-active rows.
    --- Paint a single grapheme run's base layer with syntax spans.
    --- `run` is an entry from `View:sub_row_runs`: it carries the run's
    --- 1-based byte range into `line_text` and the 0-based DISPLAY
    --- column (within the sub-row) where it starts. We emit the whole
    --- run's slice at `text_x + run.col`; syntax spans that intersect
    --- the run are overlaid on top at the same display column (a span
    --- never crosses a grapheme boundary, so any intersecting span is
    --- fully contained in the run). Wide / combining glyphs are printed
    --- as a single `term:print` so termbox advances the correct number
    --- of cells for us.
    --- row_bg: background to paint text-region cells with, so the
    --- active-line highlight carries through syntax spans.
    local t_hlseg, t_termprint = 0, 0
    local function paint_run(view, li, row, text_x, line_text, run, row_bg, line_segs)
        local chunk_start = run.byte_start - 1
        local chunk_end = run.byte_end
        local dfg = ui("default_fg")
        local dbg = row_bg or ui("default_bg")
        dfg, dbg = focus_dim(dfg, dbg)
        local chunk = line_text:sub(run.byte_start, run.byte_end)
        local x = text_x + run.col
        local tp = function(...)
            local tp0 = profile.now_us()
            term:print(...)
            t_termprint = t_termprint + (profile.now_us() - tp0)
        end
        if line_segs == nil or #line_segs == 0 then
            tp(x, row, chunk, dfg, dbg)
            return
        end
        local painted = 0 -- byte offset within chunk already painted
        for _, s in ipairs(line_segs) do
            -- s.cs/s.ce are line-relative bytes (0-based, [start, end)).
            -- Filter to this run's [chunk_start, chunk_end] and translate
            -- to run-relative offsets.
            if s.ce > chunk_start and s.cs < chunk_end then
                local cs = math.max(s.cs, chunk_start) - chunk_start
                local ce = math.min(s.ce, chunk_end) - chunk_start
                if cs > painted then
                    tp(x, row, chunk:sub(painted + 1, cs), dfg, dbg)
                end
                if ce > cs then
                    local seg_fg = focus_dim(s.fg, dbg)
                    tp(x, row, chunk:sub(cs + 1, ce), seg_fg, dbg)
                end
                if ce > painted then
                    painted = ce
                end
            end
            -- segs are pre-sorted by start byte, so once we're past
            -- the chunk, we can stop early.
            if s.cs >= chunk_end then
                break
            end
        end
        if painted < #chunk then
            tp(x, row, chunk:sub(painted + 1), dfg, dbg)
        end
    end

    --- Unified completion-list renderer shared by the inline minibuffer
    --- and the floating palette. Geometry is parameterized (x, y, width,
    --- max_visible) so both call sites paint identically, just at
    --- different sizes. Draws a scrollbar on the far right when the list
    --- overflows. Background `bg` is the surrounding bg (default_bg for
    --- inline, the box interior bg for palette). Reads mb._completions /
    --- _comp_index / _comp_scroll directly.
    --- print_highlighted: print a completion-text row with matched
    --- substrings (per match_byte_set) drawn in a distinct fg + style so
    --- the user can see WHY each candidate matched — the signature
    --- readability cue of a great command palette (Helm/ido style).
    --- Splits into contiguous matched / unmatched byte-runs and prints
    --- each run with its own fg, advancing by cell width so multi-byte
    --- chrome stays aligned. `mset` nil → single unmatch-fg pass (no
    --- highlighting), preserving the pre-highlight look on empty query.
    local function print_highlighted(
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
        local cur = mset and mset[1] or false
        if mset == nil then
            cur = false
        end
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

    local function paint_completions(x, y, width, max_visible, bg)
        local completions = mb._completions
        local total = #completions
        if total == 0 then
            return
        end
        local selected = mb._comp_index or 0
        local scroll = mb._comp_scroll or 0
        local n = math.min(total - scroll, max_visible)
        if n <= 0 then
            return
        end
        -- Reserve a scrollbar gutter on the far right only when the
        -- list actually overflows; otherwise the full width is usable.
        local needs_sb = total > max_visible
        local list_w = needs_sb and (width - 1) or width
        local cur_fg = ui("cursor_fg")
        local cur_bg = ui("cursor_bg")
        local norm_fg = ui("minibuffer_prompt")
        local meta_fg = ui("minibuffer_metadata")
        -- Match-highlighting colors (Helm/ido style): matched chars pop,
        -- unmatched recede. On the non-selected rows matched chars use
        -- the bright default fg (bold) over dim-gray unmatched text; on
        -- the selected bar matched chars use the blue accent (bold)
        -- over the natural dark cursor_fg so they read on the light bar.
        local bright_fg = ui("minibuffer_text")
        local dim_fg = meta_fg
        local accent_fg = norm_fg
        local query = mb:view_text()

        -- Metadata column: longest displayed text + 2-space gap.
        local max_text = 0
        for i = 1, n do
            local tlen = cell_len(completers.comp_text(completions[scroll + i]))
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
            local text = truncate_cells(completers.comp_text(item), list_w)
            local meta = show_meta and completers.comp_meta(item) or nil
            if ci == selected then
                -- Full-width reverse-video bar: fill the row with the
                -- selection bg first, then print text + meta on top so
                -- the highlight is contiguous across the gap.
                fp(x, row, string.rep(" ", list_w), cur_fg, cur_bg)
                local mset = match_byte_set(text, query)
                if next(mset) then
                    print_highlighted(x, row, text, accent_fg, cur_fg, cur_bg, mset, tb.bold)
                else
                    fp(x, row, text, cur_fg, cur_bg)
                end
                if meta and meta_col + cell_len(meta) <= list_w then
                    fp(x + meta_col, row, meta, cur_fg, cur_bg)
                end
            else
                local mset = match_byte_set(text, query)
                if next(mset) then
                    print_highlighted(x, row, text, bright_fg, dim_fg, bg, mset, tb.bold)
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
                fp(
                    sb_col,
                    y + i,
                    on_thumb and "█" or "│",
                    on_thumb and thumb_fg or track_fg,
                    bg
                )
            end
        end
    end

    -- Footer rows: modeline + optional completions row + minibuffer/eval
    local has_completions = mb and mb.active and mb.completion and #mb._completions > 0

    --- Persist the render damage state for next frame.
    ---@param cur_min_cursor_row integer
    function Editor:_finish_damage_state(
        cur_min_cursor_row,
        w,
        h,
        footer_rows,
        palette_active,
        view
    )
        self._last_min_cursor_row = cur_min_cursor_row
        self._last_w = w
        self._last_h = h
        self._last_footer_rows = footer_rows
        self._last_palette = palette_active
        self._last_scroll_li = view and view.scroll_li or nil
        self._last_scroll_sub_row = view and view.scroll_sub_row or nil
        self._last_line_count = view and view.buffer:line_count() or nil
        self._damage_start_row = nil
    end

    if not view or not view.file_loaded then
        local msg = "Loading..."
        local x = math.floor(w / 2) - math.floor(#msg / 2)
        local y = math.floor(h / 2)
        fp(x, y, msg, ui("default_fg"), ui("default_bg"))
        ov:emit_render()
        ov:flush()
        self:_finish_damage_state(cur_min_cursor_row, w, h, footer_rows, palette_active, view)
        profile.span("editor", "render_total", render_t0)
        term:present()
        return
    end

    local buf = view.buffer
    local line_count = buf:line_count()
    local max_y = h - footer_rows - 1

    -- Gutter width + centered text column. Centralized in View:text_geometry
    -- so the mouse click→buffer mapping stays in lockstep with what's
    -- painted here.
    local gutter_width, text_x, text_width, block_x, block_w = view:text_geometry(w)
    local avail_text = w - gutter_width
    if avail_text <= 0 then
        self:_finish_damage_state(cur_min_cursor_row, w, h, footer_rows, palette_active, view)
        profile.span("editor", "render_total", render_t0)
        term:present()
        return
    end

    -- Soft wrapping: set wrap_width to the text area width
    -- so the cache stays consistent with the current window size.
    local reflowed = false
    if view.wrap_width ~= text_width then
        view.wrap_width = text_width
        view:invalidate_wrap_cache()
        reflowed = true
    else
        -- Invalidate if buffer has been edited since last cache build
        local gen = tonumber(view.buffer._ptr.undo.count) + tonumber(view.buffer._ptr.redo.count)
        if view._wrap_gen ~= gen then
            view:invalidate_wrap_cache()
            view._wrap_gen = gen
        end
    end
    -- A resize-driven reflow shifts the cursor's screen row even when
    -- its logical (line, col) is unchanged; force a same-frame re-scroll
    -- (the guard would otherwise skip it and we'd lag a frame behind).
    if reflowed then
        view:scroll_to_cursor(h - footer_rows + 1, true)
    end

    -- Render visible lines (line-anchored, viewport-local)
    -- Notify the highlighter of the visible viewport's byte range so its
    -- lazy dispatcher (View:_hl_tick) can queue queries for absent buckets.
    -- vstart/vend come from a forward walk of `max_y` rows from the
    -- anchor — O(viewport), no full wrap-cache prefix build — so opening
    -- or jumping anywhere in a big file parses ~viewport-depth of lines.
    local vstart_li, vend_li
    do
        vstart_li = view.scroll_li or 0
        local sub = view.scroll_sub_row or 0
        local li = vstart_li
        local filled = (view:wrap_rows(li) or 1) - sub
        vend_li = li
        while filled <= max_y and li < line_count - 1 do
            li = li + 1
            filled = filled + (view:wrap_rows(li) or 1)
            vend_li = li
        end
        local starts = view:_hl_line_starts()
        local vstart_byte = starts[vstart_li + 1] or 0
        local vend_byte = (starts[vend_li + 2] or starts[#starts] or 0)
        if vend_byte > 0 then
            vend_byte = vend_byte - 1 -- exclude trailing \n of last visible line
        end
        view:_hl_notify_viewport(vstart_byte, vend_byte)
    end

    local rows_t0 = profile.now_us()
    local t_strip, t_wraprows, t_subruns, t_paint, t_body = 0, 0, 0, 0, 0
    local sub_count = 0
    -- Seed at the anchor and walk forward `damage_start_row` rows so the
    -- partial-rerender path starts at the right (li, sub). These walked
    -- rows are screen rows 0..(damage_start_row-1) which are UNCHANGED by
    -- this partial redraw and must be preserved — so drawing resumes at
    -- screen row `walked`, NOT row 0. (Drawing at row 0 here would paint
    -- the cursor's line at the top of the screen, making it look like the
    -- viewport snapped the cursor to the top — the bug this fixes.)
    local li = view.scroll_li or 0
    local sub_row = view.scroll_sub_row or 0
    local remaining = damage_start_row
    while remaining > 0 and li < line_count do
        local rows = view:wrap_rows(li) or 1
        local avail = rows - 1 - sub_row
        if remaining <= avail then
            sub_row = sub_row + remaining
            remaining = 0
        else
            remaining = remaining - avail - 1
            li = li + 1
            sub_row = 0
        end
    end
    local row = damage_start_row - remaining
    _ = vstart_li -- (kept for future diagnostics)
    while row <= max_y and li < line_count do
        local a = profile.now_us()
        local line_text = view:_line_text_stripped(li)
        t_strip = t_strip + (profile.now_us() - a)
        local display_text = line_text

        local content_len = #display_text
        -- Resolve syntax-highlight segments ONCE per logical line
        -- (line-relative byte ranges), then have each grapheme run
        -- filter that single list. The old path called
        -- highlight_segments per-run (~95 calls/row on long Rust
        -- lines → ~4.6k calls/frame, the dominant render cost).
        local hs_t0 = profile.now_us()
        local line_segs = view:highlight_segments(li, 0, content_len)
        t_hlseg = t_hlseg + (profile.now_us() - hs_t0)
        local b = profile.now_us()
        local total_sub = view:wrap_rows(li)
        t_wraprows = t_wraprows + (profile.now_us() - b)
        t_wraprows = t_wraprows + (profile.now_us() - b)
        -- Indent-guide columns (text-relative, 0-based) for this line:
        -- one │ at the LAST whitespace cell of each indent level (i.e.
        -- at ts-1, 2·ts-1, …). Placing the guide on the boundary cell
        -- (ts, 2·ts, …) would paint over the first real character when
        -- lead_w is an exact multiple of ts; g-1 stays within the
        -- leading whitespace. Computed once per logical line; only the
        -- first sub-row actually paints them (indentation lives at col 0).
        local guide_cols = {}
        do
            local ts = view.tab_width
            if ts and ts > 0 then
                local lead_w, i = 0, 1
                while i <= #display_text do
                    local b = display_text:byte(i)
                    if b == 32 then
                        lead_w = lead_w + 1
                    elseif b == 9 then
                        lead_w = (math.floor(lead_w / ts) + 1) * ts
                    else
                        break
                    end
                    i = i + 1
                end
                local g = ts
                while g <= lead_w do
                    guide_cols[#guide_cols + 1] = g - 1
                    g = g + ts
                end
            end
        end

        -- Render sub-rows for this logical line
        while sub_row < total_sub and row <= max_y do
            sub_count = sub_count + 1
            local body_t0 = profile.now_us()
            local ok, err = pcall(function()
                -- Active-line highlight: tint the whole row (gutter→edge)
                -- when this logical line holds the primary cursor, and
                -- brighten its line number. The single biggest "modern
                -- editor" cue in a TUI.
                local is_active = (view:p().line == li)
                local row_bg = is_active and ui("active_line_bg") or ui("default_bg")
                local num_fg = is_active and ui("line_number_active") or ui("line_number")
                -- Focus backdrop: dim the gutter numbers + the row bg so
                -- the whole buffer region (gutter + text) recedes behind
                -- the palette together.
                num_fg, row_bg = focus_dim(num_fg, row_bg)
                -- Pre-fill: outside the centered text column gets the
                -- default bg (so the column reads as centered); the
                -- column itself (gutter + text) gets row_bg so the active
                -- tint spans exactly the block. When no margin is set,
                -- block_x=0 and block_w=w so this collapses to a single
                -- full-width row_bg fill (the historical behavior).
                local _, empty_bg = focus_dim(ui("default_fg"), ui("default_bg"))
                term:print(0, row, string.rep(" ", w), empty_bg, empty_bg)
                term:print(block_x, row, string.rep(" ", block_w), row_bg, row_bg)
                -- Gutter: line number on first sub-row, blank on wrapped
                -- continuation rows. Painted on row_bg so the active tint
                -- shows through the gutter.
                if sub_row == 0 then
                    -- 1-col left margin + right-aligned number + 2-col right margin.
                    local line_num = tostring(li + 1)
                    local digits = gutter_width - 3
                    local num_pad = string.rep(" ", digits - #line_num)
                    term:print(block_x, row, " " .. num_pad .. line_num .. "  ", num_fg, row_bg)
                else
                    term:print(block_x, row, string.rep(" ", gutter_width), num_fg, row_bg)
                end

                -- Extract the sub-row's grapheme runs: each run carries its
                -- 0-based DISPLAY column (within the sub-row), its 1-based
                -- byte range into `line_text`, and its display width. We
                -- emit one term:print per run at text_x+run.col so wide /
                -- combining / ZWJ-cluster glyphs advance the correct number
                -- of terminal cells (termbox knows about wide glyphs).
                local runs_t0 = profile.now_us()
                local runs, row_w = view:sub_row_runs(li, sub_row)
                t_subruns = t_subruns + (profile.now_us() - runs_t0)
                local chunk_start -- sub-row's first byte (0-based), set below
                local chunk_end -- sub-row's last-after byte (0-based)
                if #runs > 0 then
                    chunk_start = runs[1].byte_start - 1
                    chunk_end = runs[#runs].byte_end
                else
                    chunk_start = 0
                    chunk_end = 0
                end
                if #runs > 0 then
                    -- Selection rendering: build the union of selected
                    -- byte ranges for THIS sub-row across ALL cursors
                    -- (multi-cursor selections render together).
                    -- sel_runs: list of {cs, ce} clamped to this sub-row,
                    -- then merged for overlapping spans.
                    local sel_runs = {}
                    for rsl, rsc, rel, rec in view:selection_ranges() do
                        ---@cast rsl integer
                        ---@cast rsc integer
                        ---@cast rel integer
                        ---@cast rec integer
                        if li >= rsl and li <= rel then
                            local cs = (li == rsl) and math.max(rsc, 0) or 0
                            local ce = (li == rel) and math.min(rec, content_len) or content_len
                            local chunk_cs = math.max(cs, chunk_start)
                            local chunk_ce = math.min(ce, chunk_end)
                            if chunk_cs < chunk_ce then
                                sel_runs[#sel_runs + 1] = { chunk_cs, chunk_ce }
                            end
                        end
                    end
                    table.sort(sel_runs, function(a, b)
                        return a[1] < b[1]
                    end)
                    -- Merge overlapping/adjacent runs
                    local merged = {}
                    for _, r in ipairs(sel_runs) do
                        if #merged > 0 and r[1] <= merged[#merged][2] then
                            merged[#merged][2] = math.max(merged[#merged][2], r[2])
                        else
                            merged[#merged + 1] = { r[1], r[2] }
                        end
                    end

                    -- Base layer: paint every grapheme run.
                    local paint_t0 = profile.now_us()
                    for _, run in ipairs(runs) do
                        paint_run(view, li, row, text_x, line_text, run, row_bg, line_segs)
                    end
                    t_paint = t_paint + (profile.now_us() - paint_t0)

                    -- Selection overlay (reverse-video). Marked bytes map
                    -- to graphemically-aligned display columns via byte_to_col.
                    for _, r in ipairs(merged) do
                        -- byte range within sub-row -> display columns
                        local dcs = view:byte_to_col(li, r[1]) - view:byte_to_col(li, chunk_start)
                        local dce = view:byte_to_col(li, r[2]) - view:byte_to_col(li, chunk_start)
                        if dcs < 0 then
                            dcs = 0
                        end
                        if dce > row_w then
                            dce = row_w
                        end
                        if dce > dcs then
                            -- Paint each grapheme run that intersects the
                            -- selection range at that run's OWN display
                            -- column (run.col). Advancing a running x here
                            -- would drift past non-selected runs sitting
                            -- before the selection start, drawing the
                            -- reversed text at the wrong column.
                            for _, run in ipairs(runs) do
                                if run.byte_end > r[1] and run.byte_start <= r[2] then
                                    local s = math.max(run.byte_start, r[1] + 1)
                                    local e = math.min(run.byte_end, r[2])
                                    if e >= s then
                                        local sel_text =
                                            line_text:sub(s, e):gsub(" ", "·"):gsub("\t", "→")
                                        term:print(
                                            text_x + run.col,
                                            row,
                                            sel_text,
                                            ui("selection_fg"),
                                            ui("selection_bg")
                                        )
                                    end
                                end
                            end
                            -- Newline marker: this run reaches the
                            -- last cell of the line's last sub-row AND
                            -- the original line had a trailing newline
                            -- → the selection includes EOL, so draw ↵ one
                            -- cell past content.
                            if
                                r[2] >= chunk_end
                                and chunk_end >= content_len
                                and #line_text > 0
                                and buf:line_text(li):byte(-1) == 10
                            then
                                local nl_x = text_x + row_w
                                if nl_x < w then
                                    term:print(
                                        nl_x,
                                        row,
                                        "↵",
                                        ui("selection_fg"),
                                        ui("selection_bg")
                                    )
                                end
                            end
                        end
                    end
                end

                -- Indent guides: faint │ at tab-stop boundaries inside
                -- leading whitespace. Painted AFTER the text layer (which
                -- would otherwise overwrite them with blank space cells)
                -- but BEFORE the cursor overlay. Only on the first sub-row
                -- (the only place indentation lives), and only for guides
                -- that fall within this sub-row's display-column range.
                if sub_row == 0 and #guide_cols > 0 then
                    local guide_fg = ui("indent_guide")
                    for _, g in ipairs(guide_cols) do
                        if g < row_w then
                            term:print(text_x + g, row, "│", guide_fg, row_bg)
                        end
                    end
                end

                -- Cursor overlay: paint every cursor whose position
                -- falls in THIS sub-row as a reverse-video cell of the
                -- underlying grapheme (or a blank when the cursor sits
                -- past end-of-content / on an empty line). Runs OUTSIDE
                -- the runs-guard so a cursor on an empty line still
                -- renders. c.col is a byte offset; translate to the
                -- sub-row's display column via byte_to_col so the
                -- caret lands on the correct cell for wide glyphs.
                for _, c in ipairs(view.cursors) do
                    if self._blink_on and c.line == li then
                        local csub_row = select(1, view:wrap_sub_position(li, c.col))
                        if csub_row == sub_row then
                            local ccol = view:byte_to_col(li, c.col)
                                - view:byte_to_col(li, chunk_start)
                            if ccol < 0 then
                                ccol = 0
                            end
                            -- Allow the cursor to sit one cell past the
                            -- last grapheme for end-of-content cursors.
                            if ccol <= row_w then
                                local ch = " "
                                -- Find the grapheme run covering c.col.
                                for _, run in ipairs(runs) do
                                    if
                                        c.col + 1 >= run.byte_start
                                        and c.col + 1 <= run.byte_end
                                    then
                                        ch = line_text:sub(run.byte_start, run.byte_end)
                                        break
                                    end
                                end
                                term:print(text_x + ccol, row, ch, ui("cursor_fg"), ui("cursor_bg"))
                            end
                        end
                    end
                end

                -- Pending-drop markers (drop mode staged by
                -- add_cursor_here before commit_pending_cursors).
                -- Painted with a yellow BACKGROUND so the user can see
                -- where the staged drops are. Same display-column
                -- mapping as the active-cursor overlay above.
                for _, c in ipairs(view.pending_cursors) do
                    if c.line == li then
                        local csub_row = select(1, view:wrap_sub_position(li, c.col))
                        if csub_row == sub_row then
                            local ccol = view:byte_to_col(li, c.col)
                                - view:byte_to_col(li, chunk_start)
                            if ccol < 0 then
                                ccol = 0
                            end
                            if ccol <= row_w then
                                local ch = " "
                                for _, run in ipairs(runs) do
                                    if
                                        c.col + 1 >= run.byte_start
                                        and c.col + 1 <= run.byte_end
                                    then
                                        ch = line_text:sub(run.byte_start, run.byte_end)
                                        break
                                    end
                                end
                                term:print(text_x + ccol, row, ch, ui("cursor_fg"), ui("drop_bg"))
                            end
                        end
                    end
                end
            end)
            t_body = t_body + (profile.now_us() - body_t0)
            if not ok then
                log.error(
                    "editor",
                    "render row failed",
                    { row = row, li = li, sub_row = sub_row, error = tostring(err) }
                )
                break
            end

            sub_row = sub_row + 1
            row = row + 1
        end

        li = li + 1
        sub_row = 0
    end
    profile.report("editor", "row_strip", t_strip)
    profile.report("editor", "row_wraprows", t_wraprows)
    profile.report("editor", "row_subruns", t_subruns, { sub_rows = sub_count })
    profile.report("editor", "row_paint", t_paint)
    profile.report("editor", "row_hlseg", t_hlseg)
    profile.report("editor", "row_termprint", t_termprint)
    profile.report("editor", "row_body", t_body)
    profile.span("editor", "row_loop", rows_t0)

    -- Cursor (only in main view when minibuffer is inactive)
    if not (mb and mb.active) then
        -- The visible caret is drawn as a reverse-video cell in the
        -- per-chunk loop above (toggled by the blink timer). The
        -- hardware terminal caret is always hidden (see term:hide_cursor
        -- at the top of render), so there is nothing to position here.
    end

    -- Modeline (at row h - footer_rows). Delegated to the segmented
    -- renderer (Editor:render_modeline) so users can override/reorder/
    -- append sections via `editor.modeline_segments`. Separators are
    -- auto-calculated (alternating ◢/◣) with colors derived from adjacent
    -- segment bg colors; text color is auto-detected from bg luminance.
    local modeline_y = h - footer_rows
    self:render_modeline(view, w, modeline_y, fp)

    -- Minibuffer — inline bottom strip (search, find-file, read-char,
    -- query-replace, …). NOT used for M-x, which renders as a centered
    -- floating palette (see the `mb.palette` branch below). The
    -- modeline's accent bg already separates the inline strip from the
    -- buffer; no spare row for a border rule (footer_rows accounts for
    -- exactly modeline + minibuffer + completions).
    if mb and mb.active and not mb.palette then
        local mb_view = mb.view
        local mb_buf = mb_view.buffer
        local prompt = mb.prompt
        local line_count = mb_buf:line_count()
        local line_offset = modeline_y + 1

        for li = 0, line_count - 1 do
            local line_text = mb_buf:line_text(li)
            -- Strip trailing newline for display
            if #line_text > 0 and line_text:byte(#line_text) == 10 then
                line_text = line_text:sub(1, #line_text - 1)
            end
            local row = line_offset + li
            if li == 0 then
                -- First line: prompt + text
                fp(0, row, prompt, ui("minibuffer_prompt"), ui("default_bg"))
                fp(#prompt, row, line_text, ui("minibuffer_text"), ui("default_bg"))
            else
                -- Subsequent lines: full width
                fp(0, row, line_text, ui("minibuffer_text"), ui("default_bg"))
            end
        end

        -- Cursor position: the hardware caret is hidden (see top of
        -- render), so we draw the caret as a reverse-video cell, gated
        -- on the blink phase, just like the main view.
        local cursor_row = line_offset + mb_view:p().line
        local cursor_col
        if mb_view:p().line == 0 then
            cursor_col = #prompt + mb_view:p().col
        else
            cursor_col = mb_view:p().col
        end
        if self._blink_on and cursor_col < w then
            local lt = mb_buf:line_text(mb_view:p().line)
            if #lt > 0 and lt:byte(#lt) == 10 then
                lt = lt:sub(1, #lt - 1)
            end
            local bcol = mb_view:p().col
            local ch = lt:sub(bcol + 1, bcol + 1)
            if #ch == 0 then
                ch = " "
            end
            -- Mode-aware caret: the minibuffer uses an underline BAR
            -- (char in the cursor accent color + underline style bit)
            -- so input contexts read distinctly from the main view's
            -- reverse-video block caret.
            local bar_fg = bit.bor(ui("cursor_bg"), tb.underline)
            fp(cursor_col, cursor_row, ch, bar_fg, ui("default_bg"))
        end

        -- Completions: shared renderer (inline geometry — full width,
        -- starting below the input row). Scrollbar + metadata handled
        -- inside the helper.
        if has_completions then
            paint_completions(0, line_offset + line_count, w, 5, ui("default_bg"))
        end
    elseif mb and mb.active and mb.palette then
        -- Command-palette mode (M-x): render the minibuffer as a
        -- centered floating box over the buffer, with rounded borders
        -- and the completions listed inside. Width and height are
        -- derived from the content + viewport, clamped to safe bounds.
        -- Painted ON TOP of already-rendered buffer rows (a solid bg
        -- box overwrites whatever was there), so footer_rows doesn't
        -- need to reserve space for it.
        local mb_view = mb.view
        local mb_buf = mb_view.buffer
        local prompt = mb.prompt
        local prompt_w = cell_len(prompt)

        -- Box dimensions.
        local box_w = math.min(math.max(48, prompt_w + 24), w - 4)
        local box_x = math.floor((w - box_w) / 2)
        -- Rows: top border + input + (completions) + bottom border.
        local n_comp = 0
        if has_completions then
            n_comp = math.min(#mb._completions - (mb._comp_scroll or 0), 5)
        end
        local box_h = 2 + 1 + n_comp + 1
        local box_y = math.floor((h - box_h) / 2)

        -- Glow accent border: vivid blue accent (minibuffer_prompt,
        -- base0D) + bold instead of the dim neutral border, so the
        -- floating box reads as the focused surface against the now-
        -- blackened backdrop. Same accent the prompt + selected-bar
        -- match-highlight use, tying the palette's chrome together.
        local border_fg = bit.bor(ui("minibuffer_prompt"), tb.bold)
        local bg = ui("default_bg")
        local prompt_fg = ui("minibuffer_prompt")
        local text_fg = ui("minibuffer_text")
        local meta_fg = ui("minibuffer_metadata")

        -- Clear the box interior with default_bg so it floats over the
        -- buffer cleanly.
        for r = 0, box_h - 1 do
            fp(box_x, box_y + r, string.rep(" ", box_w), bg, bg)
        end

        -- Top border: ╭─...─╮
        fp(box_x, box_y, "╭" .. string.rep("─", box_w - 2) .. "╮", border_fg, bg)

        -- Input row: prompt + text.
        local input_y = box_y + 1
        fp(box_x + 1, input_y, prompt, prompt_fg, bg)
        do
            local lt = mb_buf:line_text(0)
            if #lt > 0 and lt:byte(#lt) == 10 then
                lt = lt:sub(1, #lt - 1)
            end
            local max_text = box_w - 2 - prompt_w
            fp(box_x + 1 + prompt_w, input_y, truncate_cells(lt, max_text), text_fg, bg)
        end

        -- Caret (underline bar, same as inline minibuffer).
        if self._blink_on then
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
                fp(cursor_col, input_y, ch, bar_fg, bg)
            end
        end

        -- Completions: shared renderer (palette geometry — interior
        -- width, below the input row). Same paint path as inline.
        if has_completions and n_comp > 0 then
            paint_completions(box_x + 1, input_y + 1, box_w - 2, 5, bg)
        end

        -- Bottom border: ╰─...─╯
        fp(box_x, box_y + box_h - 1, "╰" .. string.rep("─", box_w - 2) .. "╯", border_fg, bg)
    -- Eval result (in minibuffer row when not active)
    elseif self._eval_result then
        local eval_row = modeline_y + 1
        fp(0, eval_row, "=> " .. self._eval_result, ui("status_message"), ui("default_bg"))
    end

    ov:emit_render()
    ov:flush()
    self:_finish_damage_state(cur_min_cursor_row, w, h, footer_rows, palette_active, view)
    profile.span("editor", "render_total", render_t0)
    term:present()
end

return Editor
