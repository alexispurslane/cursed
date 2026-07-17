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
local CompletionMenu = require("cursed.completion_menu")
local log = require("cursed.log")
local profile = require("cursed.profile")
local async = require("cursed.async")
local io_client = require("cursed.io_client")

--- Cached space-fill buffer: avoids per-frame string.rep allocations
--- in the render path. Grown lazily to the widest request seen.
local _spaces = ""

local function spaces(n)
    if n <= 0 then
        return ""
    end
    if n > #_spaces then
        _spaces = string.rep(" ", n)
    end
    return string.sub(_spaces, 1, n)
end

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
            -- Pick the last non-minor mode (skip minor modes like
            -- auto-fill, visual-movement for the modeline name).
            for i = #view._major_modes, 1, -1 do
                local m = view._major_modes[i]
                if not m.is_minor and m.name then
                    mode_name = m.name
                    break
                end
            end
            return " ◆ " .. mode_name .. " "
        end,
    },
    {
        -- LSP status: shows the language server serving the active view's
        -- modes. Walks modes high→low precedence and surfaces the first
        -- that declares `lsp_servers`; glyph follows the lane-relayed
        -- status: ready=⛏ srv, spawning=⛏ srv…, dead/killed=⛏ srv✝,
        -- missing=⛏ srv—. Reads live from the client_id-keyed registry
        -- (status echoes from the LSP lane so exit/crash/kill reflect
        -- immediately).
        bg = "modeline_bg",
        fill = false,
        format = function(_editor, view)
            local lsp = require("cursed.lsp_client")
            --- Prefer the buffer's bound client_id (now that servers dedup
            --- per (exe, workspace_dir), `exe_to_client` holds only the
            --- last cid for an exe name and may point at a different
            --- project root's server). Fall back to declared-mode lookup
            --- when no client is bound yet (pre-spawn).
            local buf = view.buffer
            local srv, status
            if buf and buf.lsp_client_id ~= nil then
                srv, status = lsp.status_for_client(buf.lsp_client_id)
            end
            if srv == nil then
                for i = #view._major_modes, 1, -1 do
                    local names = view._major_modes[i].lsp_servers
                    if names and #names > 0 then
                        srv, status = lsp.server_status_for(names)
                        break
                    end
                end
            end
            if srv then
                local suffix = ""
                if status == "spawning" then
                    suffix = "…"
                elseif status == "dead" or status == "killed" then
                    suffix = "✝"
                elseif status == "missing" then
                    suffix = "—"
                end
                return (" ⛏ " .. srv .. suffix .. " ")
            end
            return ""
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
---@field main_kq table|nil editor's main kqueue instance (attached by main.lua); LSP stdout registered here
---@field workspace_dir string|nil editor workspace root (cwd at startup, attached by main.lua); used as the LSP rootUri
---@field drain_hl_inbox fun()|nil inline inbox_hl drain (attached by main.lua) for the zero-flash sync-wait path
---@field proc table|nil proc-lane facade (attached by main.lua): spawn/send_stdin/kill against the proc lane
---@field views View[] list of open views
---@field active_view integer 1-based index into views
---@field term Term
---@field status_message string|nil
---@field minibuffer Minibuffer
---@field completion_menu CompletionMenu in-buffer completion popup (parallel to the minibuffer)
---@field _isearch_origin_line integer|nil saved cursor line before isearch
---@field _isearch_origin_col integer|nil saved cursor col before isearch
---@field _isearch_direction integer 1=forward, -1=backward
---@field _isearch_regex boolean|nil true when active isearch is a regex search
---@field _isearch_match table|nil current match highlight range {line, offset, end_line, end_offset}
---@field _query_ranges table|nil parallel array of {end_line, end_offset} for pending cursors in replace mode
---@field _replace_regexp_active boolean|nil true while in a query-replace-regexp y/n batch walk
---@field _query_replace_template string|nil replacement template (\&, \1..\9) for the active regexp-replace
---@field _query_captures table|nil parallel to pending_cursors: {end_line, end_offset, caps} per match
---@field _query_replacements table|nil stashed accepted replacements {line, offset, end_line, end_offset, text}
---@field _replace_regexp_origin_line integer|nil saved primary cursor line for C-g cancel
---@field _replace_regexp_origin_col integer|nil saved primary cursor col for C-g cancel
---@field _diag_hover_visible boolean|nil true while a diagnostic hover popup is currently visible
---@field _eval_result string|nil pretty-printed eval result to show in minibuffer area
---@field _spell table|nil spellcheck driver (set up by cursed.spell.setup)
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
---@field _base_keymap table|nil nested base keymap (no mode overlays)
---@field _keymap_chain table[]|nil ordered keymap chain [{mode_km, ...}, base_km] for the active view
---@field _current_keymap table|nil the resolved keymap for the current chain (walked by key dispatch); nil at top level, set to a sub-keymap in prefix mode
---@field _prefix_tokens string[] accumulated token path for the current prefix chord (for which-key display)
---@field _keymap_chain_changed boolean? set when _keymap_chain was rebuilt (main loop resets chord state)
---@field _prefix_timeout_task table|nil scheduled task handle for prefix timeout
---@field _chord_for_command table<string, string>|nil reverse map command_name→formatted chord
---@field _digit_active boolean true when M-digit/M-- argument accumulation is in progress
---@field _digit_value integer accumulated digit value (starts at 0)
---@field _digit_negative boolean true when M-- was pressed (negate the arg)
---@field _last_was_kill boolean true when the most recent dispatched command was a kill (for consecutive-kill merging)
---@field _kill_called boolean true when push_kill was called during the current command dispatch
---@field _printable_fn function? the __printable handler
---@field _read_char_cb function|nil active callback for read-char (one-shot)
---@field _read_char_prompt string the prompt shown during read-char
---@field _transient_handlers function[] stack of transient key handlers (LIFO)
---@field _config Config the loaded user configuration
---@field margin integer|nil max text render width; when set, the (gutter+text) column is centered in the window
---@field _blink_on boolean caret visible (drawn) this blink phase
---@field _blink_task table|nil handle of the scheduled blink toggle task
---@field event_system EventSystem central event hub (pre/post-command, mode_enter/exit, ring-buffer, ...)
---@field overlays OverlayManager screen-space overlay layer (file-anchored + floating)
---@field modeline_segments table[] ordered modeline segment specs (bg/format/fill/fg)
---@field _last_command string|nil name of the most recently dispatched command (Emacs `last-command`)
---@field _extend boolean true while a `*_select` command is running its motion, so the motion's transient-anchor drop (close_edit_for_motion) is suppressed and the shift-selection extends instead of being cleared
---@field _command_before_this string|nil the command before the most recent one (Emacs `command-before-this`)
---@field _last_complex_command { name: string, universal_args: table }|nil most recent command invoked with universal args (for repeat-complex-command)
---@field _command_frecency table per-command frecency data { uses = integer[] } for frecency-sorted M-x
---@field _exit_code integer exit code surfaced by async tasks
---@field _whichkey_keymap table|nil the keymap to show in which-key
---@field _whichkey_page integer which-key hint popup page index (0-based; reset when the prefix node changes)
---@field gutter_sign_fns fun(editor: Editor, view: View, li: integer): {fg: integer, bg: integer?, char: string}?[] per-line gutter sign callbacks; each returns a glyph spec or nil (blank). One fixed column per callback, painted on every sub-row of the line; evaluated once per visible logical line.
---@field _code_action_lines_by_uri table<string, {lines: table<integer, boolean>, version: integer?}> per-URI cache of line-number sets with available code actions, keyed by URI; each entry carries the buffer version at snapshot time for staleness detection.
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
        completion_menu = nil, -- CompletionMenu singleton (set below)
        _isearch_origin_line = nil,
        _isearch_origin_col = nil,
        _isearch_direction = 1,
        _isearch_regex = nil,
        _isearch_match = nil,
        _query_ranges = nil,
        _replace_regexp_active = nil,
        _query_replace_template = nil,
        _query_captures = nil,
        _query_replacements = nil,
        _replace_regexp_origin_line = nil,
        _replace_regexp_origin_col = nil,
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
        _chord_for_command = {},
        _base_keymap = nil,
        _keymap_chain = nil,
        _current_keymap = nil,
        _prefix_tokens = {},
        _keymap_chain_changed = nil,
        _prefix_timeout_task = nil,
        overlays = nil, -- OverlayManager singleton (set below)
        modeline_segments = nil, -- segment spec list (seeded from DEFAULT_MODELINE_SEGMENTS below)
        _digit_active = false,
        _digit_value = 0,
        _digit_negative = false,
        _pending_ops_count = 0, -- tracked for headless drain loop; event bus handles callbacks
        _pending_ops = {}, -- [lane_idx] = { [op_id] = true } — in-flight async ops
        _last_was_kill = false,
        _kill_called = false,
        _printable_fn = nil,
        _read_char_cb = nil,
        _read_char_prompt = "",
        _transient_handlers = {},
        _config = nil,
        _blink_on = true, -- caret visible (drawn) this phase
        _last_command = nil, -- most recent dispatched command name
        _extend = false, -- true while a `*_select` command runs (suppressed transient-anchor drop)
        _command_before_this = nil, -- command before the most recent
        _last_complex_command = nil, -- most recent command-with-args, for repeat-complex-command
        _whichkey_keymap = nil,
        _whichkey_page = 0,
        _command_frecency = {}, -- { [cmd_name] = { uses = {timestamp, ...} } }
        gutter_sign_fns = {}, -- overrideable per-line gutter-sign callbacks (see Editor.gutter_sign_fns)
        _code_action_lines_by_uri = {}, -- per-URI set of line numbers with available code actions
    }, Editor)
    editor.event_system = EventSystem.new(editor)
    editor.overlays = OverlayManager.new(editor)
    editor.modeline_segments = {}
    for _, seg in ipairs(DEFAULT_MODELINE_SEGMENTS) do
        editor.modeline_segments[#editor.modeline_segments + 1] = seg
    end
    -- In-buffer completion popup (parallel to the minibuffer). Default
    -- source: buffer-word dabbrev, which dogfoods the whole loop
    -- end-to-end without requiring LSP; swap via set_completer.
    editor.completion_menu = CompletionMenu.new(editor)
    -- Spell-merge wrapper: when the cursor sits on a flagged word, spell
    -- suggestions rank first, then the mode-declared source's results
    -- follow, then (when in dabbrev/fallback mode) system dictionary
    -- completions provide a last-resort source of suggestions.
    -- Delegates trigger_chars/pending to the mode source (spell
    -- has no trigger chars / no async state).
    local mode_source = completers.mode_dispatch(editor)
    local spell_completer = require("cursed.spell.completers").spell(editor)
    local dict = require("cursed.dictionary")
    local merged = setmetatable({}, {
        __call = function(_, ctx)
            local prefix = ctx and ctx.prefix or ""
            -- Fallback (buffer_words / dabbrev) when no mode in the
            -- chain declares its own completer. We check all modes
            -- top-to-bottom so a lower mode with a completer counts.
            local mode_has_completer = false
            if ctx ~= nil and ctx.view ~= nil and ctx.view._major_modes ~= nil then
                for i = #ctx.view._major_modes, 1, -1 do
                    if ctx.view._major_modes[i].completer ~= nil then
                        mode_has_completer = true
                        break
                    end
                end
            end
            local mode_is_fallback = not mode_has_completer
            -- Only consult the system dictionary when the mode source is
            -- the fallback (buffer_words / dabbrev) — LSP sources already
            -- provide relevant project symbols.
            local dict_items
            if mode_is_fallback and #prefix >= 2 then
                dict_items = dict.lookup(prefix, 15)
            else
                dict_items = nil
            end

            local spell_items = spell_completer(ctx)
            local mode_items = mode_source(ctx)

            -- Collect into deduped output: spell → mode → dict.
            local seen = {}
            local out = {}
            local function add_items(items)
                if items == nil then
                    return
                end
                for _, it in ipairs(items) do
                    local key = type(it) == "table" and it.text or it
                    if key ~= nil and not seen[key] then
                        seen[key] = true
                        out[#out + 1] = it
                    end
                end
            end
            add_items(spell_items)
            add_items(mode_items)
            add_items(dict_items)
            return out
        end,
    })
    function merged.trigger_chars()
        return mode_source.trigger_chars and mode_source.trigger_chars()
    end
    function merged.pending()
        return mode_source.pending and mode_source.pending() or false
    end
    editor.completion_menu:set_completer(merged)
    editor.completion_menu:setup()
    -- Spell subsystem (squiggles + completion + commands). Lazy-imported
    -- so a missing `enchant-2` binary never blocks editor startup.
    require("cursed.spell").setup(editor)
    return editor
end

--- Signal the main loop to exit. Sets the quit flag and wakes select()
--- via the kqueue so it doesn't block until the next keypress.
function Editor:request_quit()
    self._quit_requested = true
    self._wake_main()
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

--- Start the lane heartbeat checker. Fires every second: reads all lane
--- heartbeats atomically (resetting them to 0), then emits events for
--- missed or dead lanes. Self-scheduling: each invocation creates the
--- next one, so it never clogs the background task queue.
---
--- Events emitted:
---   lane_missed_heartbeat(lane_idx, lane_name)  — first missed beat
---   lane_dead(lane_idx, lane_name)              — 3 consecutive misses
---   lane_alive(lane_idx, lane_name)             — recovered after ≥1 miss
---
--- Lane names: "io", "hl", "lsp", "proc", "task"
function Editor:start_heartbeat_checker()
    local shared = require("cursed.shared")
    local ss = shared.SharedState.from_global()
    local NUM_LANES = shared.NUM_LANES
    local MISS_THRESHOLD = 3
    local lane_names = { "io", "hl", "lsp", "proc", "task" }
    local misses = {} ---@type table<integer, integer>

    local function check()
        local beats = ss:heartbeat_read_reset()
        for i = 0, NUM_LANES - 1 do
            if beats[i] == 1 then
                if misses[i] and misses[i] > 0 then
                    self.event_system:emit("lane_alive", i, lane_names[i + 1])
                end
                misses[i] = 0
            else
                misses[i] = (misses[i] or 0) + 1
                if misses[i] == 1 then
                    self.event_system:emit("lane_missed_heartbeat", i, lane_names[i + 1])
                elseif misses[i] == MISS_THRESHOLD then
                    self.event_system:emit("lane_dead", i, lane_names[i + 1])
                end
            end
        end
        -- Schedule the next check. Each check returns true (one-shot)
        -- so it's removed from the queue; the fresh schedule_after
        -- creates a new task 1s in the future.
        self:schedule_after(1000000, check)
        return true
    end

    self:schedule_after(1000000, check)
end

----------------------------------------------------------------------------------------------------
-- Keybinding convenience API (#5).
--
-- Emacs-style ergonomic wrappers over the keymap chain. A keymap is a
-- nested table (token → token → command). These methods make binding
-- LIVE by mutating the base keymap or mode keymap tables directly;
-- the keymap chain picks up changes lazily (no trie rebuild needed).
----------------------------------------------------------------------------------------------------

--- Bind a key chord globally (Emacs `global-set-key`). `action` is either
--- a command name (string, resolved from the commands table at dispatch
--- time) or a `function(view, editor, ...)`. The chord is validated
--- eagerly so a typo surfaces now, not on first press.
---@param chord string chord specifier ("ctrl-x ctrl-s", "alt-:", "f5", …)
---@param action string|function command name or function
function Editor:global_set_key(chord, action)
    if self._base_keymap == nil then
        error("editor:global_set_key: keymap not yet initialized (call after startup prime)", 2)
    end
    if chord == "__printable" then
        if type(action) == "function" then
            self._base_keymap.__printable = action
        end
        return
    end
    local tokens, err = keybind.parse_chord(chord)
    if not tokens then
        error(("editor:global_set_key: bad chord %q: %s"):format(chord, err or "?"), 2)
    end
    keybind.Keymap.add(self._base_keymap, tokens, action)
end

--- Mirror every base keybinding subtree rooted at `from_token`
--- under `to_token` instead (e.g. "ctrl-x" → "alt-q"), deep-copying
--- the full subtree. Useful when a terminal eats a prefix key (Ghostty
--- swallows bare C-x) so the family is reachable via an alternative the
--- terminal passes through. Clears any existing leaf on the bare
--- `to_token` so it acts as a pure prefix.
---@param from_token string first component to clone (e.g. "ctrl-x")
---@param to_token string    new first component (e.g. "alt-q")
function Editor:mirror_prefix(from_token, to_token)
    if self._base_keymap == nil then
        error("editor:mirror_prefix: keymap not yet initialized", 2)
    end
    local from_sub = self._base_keymap[from_token]
    if from_sub == nil then
        return false
    end
    -- Deep-copy the subtree so mutations don't alias
    self._base_keymap[to_token] = keybind.deep_copy(from_sub)
    return true
end

--- Bind a key chord in a specific major mode (Emacs `define-key`).
--- `mode` is either a Mode object (e.g. `modes.lua`) or a mode name
--- string (resolved against `config.modes`). Uses Keymap.add_with_base
--- so the mode prefix inherits from the base keymap via __index
--- metatables where the mode hasn't set an explicit binding.
---@param mode Mode|string the mode whose keymap to extend
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
    mode_obj:ensure_keymap(self._base_keymap)
    keybind.Keymap.add_with_base(mode_obj.keymap, self._base_keymap, tokens, action)
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

--- Track an in-flight async operation on a lane so it can be cancelled
--- with an error event if the lane dies and is restarted.
---@param lane_idx integer LANE_IDX_* constant
---@param op_id integer the request/task/proc id
function Editor:track_pending_op(lane_idx, op_id)
    local lane_ops = self._pending_ops[lane_idx]
    if not lane_ops then
        lane_ops = {}
        self._pending_ops[lane_idx] = lane_ops
    end
    lane_ops[op_id] = true
end

--- Clear a completed async operation from the pending-op tracker.
---@param lane_idx integer
---@param op_id integer
function Editor:clear_pending_op(lane_idx, op_id)
    local lane_ops = self._pending_ops[lane_idx]
    if lane_ops then
        lane_ops[op_id] = nil
    end
end

--- Flush all pending ops for a dead lane by emitting synthetic error
--- events so awaiting coroutines can resume instead of hanging.
--- Clears the pending set after emitting.
---@param lane_idx integer
function Editor:flush_lane_pending(lane_idx)
    local lane_ops = self._pending_ops[lane_idx]
    if not lane_ops then
        return
    end
    local shared = require("cursed.shared")
    local es = self.event_system
    -- Event patterns per lane. Each maps op_id to an event name and payload.
    -- HL and PROC are future-proofed — no callers use them yet but the
    -- flush path is correct when they do.
    local patterns = {
        [shared.LANE_IDX_IO] = {
            event = "file_op",
            payload = function(id)
                return { err = "IO lane restarted" }
            end,
        },
        [shared.LANE_IDX_HL] = {
            event = "hl_spans",
            payload = function(id)
                return { err = "HL lane restarted" }
            end,
        },
        [shared.LANE_IDX_LSP] = {
            event = "lsp_response",
            payload = function(id)
                return nil, true, id
            end,
        },
        [shared.LANE_IDX_PROC] = {
            event = "process_out",
            payload = function(id)
                return "failed", 0
            end,
        },
        [shared.LANE_IDX_TASK] = {
            event = "task_result",
            payload = function(id)
                return { success = false, error = "task lane restarted" }
            end,
        },
    }
    local pattern = patterns[lane_idx]
    if not pattern then
        self._pending_ops[lane_idx] = nil
        return
    end
    for op_id in pairs(lane_ops) do
        es:emit(pattern.event .. ":" .. tostring(op_id), pattern.payload(op_id))
    end
    self._pending_ops[lane_idx] = nil
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

--- Run (or resume) a background task coroutine. The entry must be a table.
--- Returns true if done (remove from queue), false if suspended (re-queue).
---@param entry table
---@return boolean done
local function _tick_run_entry(entry)
    if not entry.co then
        local fn = entry.fn or entry[1]
        if type(fn) ~= "function" then
            return true
        end
        entry.co = coroutine.create(fn)
    end
    if not entry.co then
        return true
    end

    local co_status = coroutine.status(entry.co)
    -- May have already completed via an event handler resume.
    if co_status == "dead" then
        return true
    elseif async.is_awaiting(entry.co) then
        -- Waiting for an async event; event handler resumes it.
        return false
    end

    local ok, result = coroutine.resume(entry.co)
    local status = coroutine.status(entry.co)
    if not ok then
        log.error("editor", "background task error", { error = tostring(result) })
        return true
    elseif status == "dead" then
        -- If the function returned false (wanting re-queue),
        -- clear the dead coroutine so a fresh one is created next tick.
        local rerun = result ~= false
        if not rerun then
            entry.co = nil
        end
        return rerun
    else
        -- Suspended (manual yield, or re-suspended after event-handler resume).
        return false
    end
end

--- Execute all due deadline tasks, then one continuous task per tick.
--- Phase 1: run every deadline task whose deadline has passed.
--- Phase 2: run one non-deadline (continuous) task.
--- Re-queues unfinished tasks. Returns the earliest remaining deadline.
---@return integer|nil deadline_us
function Editor:tick_background_tasks()
    local tasks = self._background_tasks
    if #tasks == 0 then
        return nil
    end

    local now = now_us()
    local pending = {} ---@type table[] deadline tasks not yet due
    local continuous = {} ---@type table[] runnable tasks
    local next_deadline ---@type integer|nil

    -- Phase 1: classify, normalise plain functions, and run all due deadline tasks.
    for _, raw in ipairs(tasks) do
        local entry = raw
        -- Normalise plain-function (legacy) entries into table form.
        if type(entry) == "function" then
            entry = { fn = entry }
        end

        if type(entry) == "table" and entry.deadline ~= nil then
            if now >= entry.deadline then
                -- Due deadline task: run it.
                if not _tick_run_entry(entry) then
                    -- Suspend ended; re-queue as continuous (deadline passed).
                    entry.deadline = nil
                    continuous[#continuous + 1] = entry
                end
            else
                -- Not due yet: keep as-is.
                pending[#pending + 1] = entry
                if next_deadline == nil or entry.deadline < next_deadline then
                    next_deadline = entry.deadline
                end
            end
        else
            -- Continuous task (no deadline): collect for Phase 2.
            continuous[#continuous + 1] = entry
        end
    end

    -- Phase 2: run ONE continuous task.
    local ran_one = false
    local remaining = {} ---@type table[]
    for _, entry in ipairs(continuous) do
        if not ran_one then
            if not _tick_run_entry(entry) then
                remaining[#remaining + 1] = entry
            end
            ran_one = true
        else
            remaining[#remaining + 1] = entry
        end
    end

    -- Rebuild queue: pending (timers not yet due) first,
    -- then remaining continuous tasks.
    self._background_tasks = {}
    for _, entry in ipairs(pending) do
        self._background_tasks[#self._background_tasks + 1] = entry
    end
    for _, entry in ipairs(remaining) do
        self._background_tasks[#self._background_tasks + 1] = entry
    end

    -- If continuous tasks remain, tell select() to wake immediately.
    if #remaining > 0 then
        return now
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

--- Set the active view index and copy the keymap chain from the
--- new active view. Also fires view_blur / buffer_blur (for the
--- previously-active view) and view_focus / buffer_focus (for the
--- newly-active view) when the focused view object actually changes.
---@param idx integer 1-based index into self.views
function Editor:set_active_view(idx)
    local old_view = self:current_view()
    self.active_view = idx
    local view = self:current_view()
    if view and view._keymap_chain then
        self._keymap_chain = view._keymap_chain
    elseif view and self._base_keymap then
        -- View has no chain yet (e.g. startup before any modes): build it
        view:rebuild_keymap_chain(self._base_keymap)
        self._keymap_chain = view._keymap_chain
    else
        -- No views at all: fall back to base only
        self._keymap_chain = { self._base_keymap }
    end
    self._keymap_chain_changed = true
    -- Rebuild chord_for_command from the base keymap
    self._chord_for_command = keybind.Keymap.build_chord_for_command(self._base_keymap or {})
    self:_emit_focus_change(old_view, view)
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
    -- Drop the shared parse-tree slot for this view so the table doesn't
    -- outlive its documents (dead views don't hold a tree ref). Main held
    -- any in-use acquired trees via its own ts_tree_copy refs, so a racing
    -- acquire is unaffected.
    if view._hl_view_id and view._hl_view_id ~= 0 then
        local s = shared.SharedState.from_global()
        s:release_tree(view._hl_view_id)
    end
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

    -- Open directories in the file manager
    if find_file.is_directory(expanded) then
        local fm = require("cursed.file_manager")
        fm.open_directory(self, expanded)
        return
    end

    local buf = Buffer.new()
    buf:set_filepath(expanded)
    local view = View.new(buf)
    view._bench_open_t0 = t0
    self:add_view(view)

    log.debug("editor", "open_file begin", { path = expanded })

    local req_id = io_client.reserve_id()
    self._pending_ops_count = (self._pending_ops_count or 0) + 1
    local event_name = "file_load:" .. req_id
    local handler
    handler = self.event_system:on(event_name, function(_, payload)
        self.event_system:off(event_name, handler)
        self._pending_ops_count = self._pending_ops_count - 1
        if payload.err then
            io_client.clear_pending(req_id)
            editor.status_message = payload.err
            return
        end
        local mmap_ptr = payload.mmap
        local file_size = payload.size
        ---@cast file_size integer
        local fp = view.buffer:filepath()
        if mmap_ptr == nil then
            -- Empty file: the placeholder buffer in `view` is valid.
            view.file_loaded = true
            if editor._config and fp then
                view:activate_mode_for_filepath(fp, editor._config)
            end
            editor.event_system:emit("file_loaded", view, view.buffer)
        else
            local psize = tonumber(ffi.C.sysconf(require("cursed.shared")._SC_PAGESIZE)) or 4096
            local cap = file_size > 0 and bit.band(file_size + psize - 1, bit.bnot(psize - 1))
                or psize
            local loaded_buf = Buffer.from_mmap(mmap_ptr, file_size, cap)
            view:set_buffer(loaded_buf, { loaded = true })
            if fp then
                loaded_buf:set_filepath(fp)
            end
            view.file_loaded = true
            local t_mode = bench.now_us()
            if editor._config and fp then
                view:activate_mode_for_filepath(fp, editor._config)
            end
            bench.span("main", "file_open activate_mode", t_mode, { path = fp })
            editor.event_system:emit("file_loaded", view, loaded_buf)
            if view._bench_open_t0 then
                bench.span("main", "file_open TOTAL", view._bench_open_t0, { path = fp })
                view._bench_open_t0 = nil
            end
        end
        io_client.clear_pending(req_id)
    end)

    local ss = shared.SharedState.from_global()
    io_client.track_pending(req_id)
    ss:push(ss._ptr.outboxes[shared.LANE_IDX_IO], {
        type = shared.MSG_FILE_LOAD,
        arg = req_id,
        ptr = expanded,
    })
end

--- Open a file into a NEW view WITHOUT focusing it — no `active_view`
--- change, no view_focus/buffer_focus, the previously focused view
--- keeps rendering. Used by workspace edit application so a rename /
--- fix-all can mutate files the user never opened: the background view
--- loads asynchronously, fires mode_enter (→ didOpen) on load just like
--- a focused open, and `view._pending_apply_edits` carries the edits to
--- apply once `file_loaded` lands. The user can switch to it later; it's
--- a real View in `self.views` (Emacs-style background visit).
--- Returns the new (still-loading) view, or nil if `filepath` is a dir.
---@param filepath string raw path from the edit's file:// URI
---@return View? view
function Editor:open_file_background(filepath)
    local expanded = find_file.expand_path(filepath)
    if find_file.is_directory(expanded) then
        local fm = require("cursed.file_manager")
        fm.open_directory(self, expanded)
        return nil
    end
    local buf = Buffer.new()
    buf:set_filepath(expanded)
    local view = View.new(buf)
    view.editor = self
    view.margin = self.margin
    table.insert(self.views, view)
    self.event_system:emit("view_open", view)
    log.debug("editor", "open_file_background begin", { path = expanded })

    local req_id = io_client.reserve_id()
    self._pending_ops_count = (self._pending_ops_count or 0) + 1
    local event_name = "file_load:" .. req_id
    local handler
    handler = self.event_system:on(event_name, function(_, payload)
        self.event_system:off(event_name, handler)
        self._pending_ops_count = self._pending_ops_count - 1
        if payload.err then
            io_client.clear_pending(req_id)
            editor.status_message = payload.err
            return
        end
        local mmap_ptr = payload.mmap
        local file_size = payload.size
        ---@cast file_size integer
        local fp = view.buffer:filepath()
        if mmap_ptr == nil then
            view.file_loaded = true
            if editor._config and fp then
                view:activate_mode_for_filepath(fp, editor._config)
            end
            editor.event_system:emit("file_loaded", view, view.buffer)
        else
            local psize = tonumber(ffi.C.sysconf(require("cursed.shared")._SC_PAGESIZE)) or 4096
            local cap = file_size > 0 and bit.band(file_size + psize - 1, bit.bnot(psize - 1))
                or psize
            local loaded_buf = Buffer.from_mmap(mmap_ptr, file_size, cap)
            view:set_buffer(loaded_buf, { loaded = true })
            if fp then
                loaded_buf:set_filepath(fp)
            end
            view.file_loaded = true
            if editor._config and fp then
                view:activate_mode_for_filepath(fp, editor._config)
            end
            editor.event_system:emit("file_loaded", view, loaded_buf)
        end
        io_client.clear_pending(req_id)
    end)

    local ss = shared.SharedState.from_global()
    io_client.track_pending(req_id)
    ss:push(ss._ptr.outboxes[shared.LANE_IDX_IO], {
        type = shared.MSG_FILE_LOAD,
        arg = req_id,
        ptr = expanded,
    })
    return view
end

----------------------------------------------------------------------------------------------------
-- LSP Location navigation
--
-- Jump to an LSP Location (`uri` + 0-based `line`/UTF-16 `char`): reuse
-- the view whose buffer already backs that URI when one is open, else
-- open the file (async load) and defer cursor placement to the
-- `file_loaded` listener via `view._pending_goto`. The UTF-16 → byte
-- conversion reuses cursed.utf8; clamps to line/col bounds so a stale
-- symbol (e.g. after an edit) lands on a valid cell.
----------------------------------------------------------------------------------------------------

local utf8_mod = require("cursed.utf8")

--- Resolve a buffer filepath to an absolute path the same way
--- `uri_for_buffer` does (editor_listeners): absolute stays absolute,
--- relative is joined onto the workspace root (PWD fallback). Returns
--- nil for an nil/empty path.
--- @param filepath string?
--- @param workspace_dir string? editor workspace root
--- @return string?
local function abs_path(filepath, workspace_dir)
    if filepath == nil or filepath == "" then
        return nil
    end
    if filepath:sub(1, 1) == "/" then
        return filepath
    end
    local base = workspace_dir or os.getenv("PWD") or "/"
    return base .. "/" .. filepath
end

--- Strip a `file://` URI to an absolute path (mirrors completers).
--- @param uri string?
--- @return string?
local function uri_to_path(uri)
    if uri == nil then
        return nil
    end
    local p = uri:gsub("^file://localhost", ""):gsub("^file://", "")
    if p == "" then
        return nil
    end
    return p
end

--- Place the primary cursor at an already-loaded view's BYTE position
--- (NOT an LSP UTF-16 char). Clamps line/col to bounds, forces a
--- scroll-into-view on the next render, and does the zero-flash
--- highlighter cold requery so far jumps render on the first frame.
--- Shared by `place_cursor_lsp` (UTF-16 → byte first) and the
--- tree-sitter outline's byte-column jump. Clears any selection.
--- @param view View
--- @param line integer 0-based line index
--- @param byte_col integer 0-based BYTE column
local function place_cursor_byte(view, line, byte_col)
    local lc = view:line_count()
    local li = line or 0
    if li < 0 then
        li = 0
    elseif li >= lc then
        li = math.max(0, lc - 1)
    end
    local clen = view:content_len(li)
    local col = byte_col or 0
    if col > clen then
        col = clen
    end
    view:set_single_cursor(li, col)
    -- Force the next render's auto-scroll: nil guards mean "always scroll".
    view._scroll_guard_line = nil
    view._scroll_guard_col = nil
    -- Zero-flash highlight resync (mirrors undo/redo/format): a far jump
    -- lands the viewport in cold highlighter territory, and the lazy
    -- per-frame viewport fill would otherwise leave the new region
    -- plain until async bucket responses land. Cold-requerying
    -- synchronously at the cursor's byte makes the jumped-to location
    -- render correctly on the first frame. Safe no-op when no highlighter
    -- mode is active (`_hl_enabled == false`).
    view:clamp_cursor()
    view:invalidate_wrap_cache()
    local c = view:p()
    local starts = view:_hl_line_starts()
    local byte = (starts[c.line + 1] or 0) + c.col
    view:_hl_cold_requery(byte)
end

--- Place the primary cursor at an LSP position in an already-loaded
--- view (the text is available for UTF-16 → byte conversion), forcing
--- a scroll-into-view on the next render. Clears any selection.
--- @param view View
--- @param line integer 0-based LSP line
--- @param char integer 0-based UTF-16 code-unit offset
local function place_cursor_lsp(view, line, char)
    local buf = view.buffer
    local lc = view:line_count()
    local li = line or 0
    if li < 0 then
        li = 0
    elseif li >= lc then
        li = math.max(0, lc - 1)
    end
    local text = buf:line_text(li) or ""
    local byte_col = utf8_mod.utf16_to_byte_col(text, char or 0)
    place_cursor_byte(view, li, byte_col)
end

--- Jump within an already-loaded view to a tree-sitter BYTE position
--- (0-based line + 0-based byte column). Used by the tree-sitter
--- document outline (the goto_symbol no-LSP fallback) whose nodes
--- carry byte columns, not LSP UTF-16 chars. A no-op + status message
--- when the view is nil/not yet loaded.
--- @param view View|nil the view to jump in
--- @param line integer? 0-based line
--- @param byte_col integer? 0-based byte column
function Editor:goto_byte(view, line, byte_col)
    if view == nil or not view.file_loaded then
        self.status_message = "target view not loaded"
        return
    end
    place_cursor_byte(view, line or 0, byte_col or 0)
end

--- Jump to an LSP Location: URI + 0-based line + UTF-16 character.
--- Reuses the view whose buffer backs `uri` when one is open; otherwise
--- opens the file (async via the IO lane) and defers cursor placement
--- to the `file_loaded` listener via `view._pending_goto`. A no-op +
--- status message when the URI is unusable.
--- @param uri string?
--- @param line integer?
--- @param char integer?
function Editor:jump_to_location(uri, line, char)
    local path = uri_to_path(uri)
    if path == nil then
        self.status_message = "symbol has no location"
        return
    end
    line = line or 0
    char = char or 0
    -- Find an already-open view whose buffer's resolved path matches.
    local found_idx = nil
    for i, v in ipairs(self.views) do
        local fp = v.buffer and v.buffer:filepath()
        local ap = abs_path(fp, self.workspace_dir)
        if ap ~= nil and ap == path then
            found_idx = i
            break
        end
    end
    if found_idx ~= nil then
        local view = self.views[found_idx]
        if found_idx ~= self.active_view then
            self:set_active_view(found_idx)
        end
        -- Only place the cursor when the file is actually loaded; if
        -- the same path was just queued (file_loaded == false), defer.
        if view.file_loaded then
            place_cursor_lsp(view, line, char)
        else
            view._pending_goto = { line = line, char = char }
        end
        return
    end
    -- Not open: open it and defer cursor placement until it loads.
    self:open_file(path)
    local new_view = self.views[#self.views]
    if new_view ~= nil then
        new_view._pending_goto = { line = line, char = char }
    end
end

---------------------------------------------------------------------------------------------------
-- Workspace edit application (applyEdit, client-side)
--
-- A CodeAction's `.edit` (or a workspace/applyEdit request's `params.edit`)
-- is a WorkspaceEdit whose shape per the spec is:
--   { changes?: { [uri]: TextEdit[] },
--     documentChanges?: (TextDocumentEdit | CreateFile | RenameFile | DeleteFile)[] }
-- We resolve each uri's edits to the open view/buffer that backs it (if any)
-- and apply them as ONE undo group via Buffer:apply_lsp_edits. Edits on
-- already-open docs are the common case (organize imports, refactor,
-- extract). Edits targeting NOT-YET-OPEN docs are NOT skipped: the file
-- is background-opened into a new (unfocused, Emacs-style) view via
-- Editor:open_file_background and the edits are parked on
-- `view._pending_apply_edits` until the IO lane lands the text; the
-- `file_loaded` listener then applies + didChange-syncs them. This is
-- what makes renames complete (a rename touches files the user never
-- opened). Resource operations (CreateFile/RenameFile/DeleteFile) ARE
-- reported as skipped — we don't write files from LSP edits yet. After
-- mutation each affected view gets the same clamp / wrap-cache invalidate
-- / highlighter cold-requery resync the `format` command + undo path
-- use, plus a didChange so the server's view of the document tracks ours.
-- Because background file loads are ASYNCHRONOUS, apply_workspace_edit is
-- inherently async when any target was unopened: callers needing the
-- final touched/skipped verdict (the workspace/applyEdit response) pass
-- an `on_complete` callback, fired exactly once when all edits settle
-- (synchronously when nothing needed a background open).
---------------------------------------------------------------------------------------------------

--- Find the open view whose buffer backs `uri` (lsp_uri match). Returns
--- nil if no view currently displays the document.
--- @param uri string file:// URI
--- @return View|nil
function Editor:view_for_lsp_uri(uri)
    if uri == nil then
        return nil
    end
    for _, v in ipairs(self.views) do
        local b = v.buffer
        if b ~= nil and b.lsp_uri == uri then
            return v
        end
    end
    return nil
end

--- Per-view post-bulk-mutation resync shared by apply_workspace_edit +
--- `format`. Clamps cursors, invalidates the wrap cache, and re-roots the
--- synchronous highlighter so the mutated span renders correctly on the
--- next frame instead of going plain until async buckets land. Safe no-op
--- when no highlighter mode is active.
--- @param view View
local function resync_after_external_edit(view)
    view:clamp_cursor()
    view:invalidate_wrap_cache()
    local c = view:p()
    local starts = view:_hl_line_starts()
    local byte = (starts[c.line + 1] or 0) + c.col
    view:_hl_cold_requery(byte)
end

--- Apply an LSP WorkspaceEdit across the editor's open documents. Handles
--- both `changes` (uri → TextEdit[] map) and `documentChanges` (array of
--- `TextDocumentEdit`; resource operations CreateFile/RenameFile/DeleteFile
--- are reported as skipped via `skips` since we don't write files from
--- LSP edits yet). Edits whose target document is ALREADY open are applied
--- synchronously as one undo group per buffer via Buffer:apply_lsp_edits
--- (sorts + applies right-to-left so coords stay valid), then resync'd +
--- didChange-synced back to the bound server. Edits whose target is NOT
--- open are applied to a freshly background-opened view (Editor:
--- open_file_background — no focus steal, Emacs-style): the edits are
--- parked on `view._pending_apply_edits` and applied by the `file_loaded`
--- listener (as Editor:_drain_pending_apply_edits) once the IO lane lands
--- the text, then sync'd the same way. Because file loads are async (IO
--- lane), this entrypoint is INHERENTLY ASYNC when any target is unopened:
--- `on_complete(result)` fires once every pending open has loaded + been
--- mutated (or immediately, synchronously, when every target was already
--- open / the edit was a no-op). Callers needing the final touched/skipped
--- verdict (the workspace/applyEdit response) MUST pass on_complete.
---@param ws_edit table WorkspaceEdit `{ changes?, documentChanges? }`
---@param on_complete? fun(result:{touched:string[], skipped:string[]}) fires exactly once when all edits are settled; synchronous when nothing needed a background open
---@return {touched:string[], skipped:string[]} touched/skipped SO FAR — the complete verdict (including background opens) arrives via on_complete
function Editor:apply_workspace_edit(ws_edit, on_complete)
    local lsp = require("cursed.lsp_client")
    local touched = {}
    local skipped = {}
    local result = { touched = touched, skipped = skipped }
    if type(ws_edit) ~= "table" then
        if on_complete ~= nil then
            on_complete(result)
        end
        return result
    end

    -- Collect (uri → TextEdit[]) pairs from both shapes, then apply each
    -- exactly once. `changes` is a flat map; `documentChanges` is an array.
    local per_uri = {} ---@type table<string, table[]>
    local function collect(uri, edits)
        if type(uri) ~= "string" or uri == "" then
            return
        end
        if type(edits) ~= "table" then
            return
        end
        per_uri[uri] = per_uri[uri] or {}
        for _, e in ipairs(edits) do
            per_uri[uri][#per_uri[uri] + 1] = e
        end
    end

    local changes = ws_edit.changes
    if type(changes) == "table" then
        for uri, edits in pairs(changes) do
            collect(uri, edits)
        end
    end

    local doc_changes = ws_edit.documentChanges
    if type(doc_changes) == "table" then
        for _, dc in ipairs(doc_changes) do
            if type(dc) == "table" then
                -- TextDocumentEdit: { textDocument: { uri }, edits: TextEdit[] }
                local td = dc.textDocument
                if type(td) == "table" and type(td.uri) == "string" and dc.edits ~= nil then
                    collect(td.uri, dc.edits)
                else
                    -- CreateFile / RenameFile / DeleteFile / skip
                    local kind = dc.kind or "resourceOperation"
                    skipped[#skipped + 1] = tostring(kind)
                end
            end
        end
    end

    -- Apply one uri's edits to an ALREADY-OPEN view's buffer: one undo
    -- group via Buffer:apply_lsp_edits (right-to-left so coords stay
    -- valid), resync, then didChange-sync the mutated text back to the
    -- doc's bound server so its view tracks ours. Shared by the
    -- synchronous (open-document) path here and the deferred
    -- (background-open) path in _drain_pending_apply_edits.
    local function apply_to_view(view, edits)
        local buf = view.buffer
        if buf == nil then
            return false
        end
        buf:apply_lsp_edits(edits)
        resync_after_external_edit(view)
        -- Sync the (now-mutated) text back to the server. Pass
        -- buf.lsp_client_id directly inline so LLS keeps the `~= nil`
        -- narrowing from the if-guard (an intermediate local would widen
        -- back to integer|nil). The doc owns its bound client (chosen at
        -- mode_enter by the file's language); for a rename every affected
        -- doc belongs to the requesting server, so this is correct.
        if buf.lsp_client_id ~= nil and buf.lsp_uri ~= nil then
            local v = buf.lsp_version or 0
            lsp.sync_change(buf.lsp_client_id, buf.lsp_uri, v, function()
                return buf:write_text_direct()
            end)
        end
        return true
    end

    -- Pending background opens: each one parks its edits on the new view
    -- (`view._pending_apply_edits` + a `done` continuation) and decrements
    -- `pending`; `finish` fires `on_complete` exactly once when the last
    -- settle lands — OR synchronously here when nothing needed a load.
    local pending = 0
    local settled = false
    local function finish()
        if settled then
            return
        end
        if pending == 0 then
            settled = true
            if on_complete ~= nil then
                on_complete(result)
            end
        end
    end

    -- URI → absolute path for the background-open path.
    local function uri_to_path(uri)
        return uri:gsub("^file://localhost", ""):gsub("^file://", "")
    end

    for uri, edits in pairs(per_uri) do
        local view = self:view_for_lsp_uri(uri)
        if view ~= nil and view.buffer ~= nil then
            -- Already open: apply synchronously now.
            if apply_to_view(view, edits) then
                touched[#touched + 1] = uri
            else
                skipped[#skipped + 1] = uri
            end
        else
            -- Not open: background-visit the file and defer the apply
            -- until `file_loaded` lands (mode_enter will have bound
            -- lsp_client_id/uri + didOpen'd the original text by then).
            local path = uri_to_path(uri)
            local new_view = self:open_file_background(path)
            if new_view == nil then
                skipped[#skipped + 1] = uri
            else
                pending = pending + 1
                new_view._pending_apply_edits = edits
                new_view._pending_apply_uri = uri
                -- `done(ok)` records the uri as touched (ok) or skipped
                -- (!ok) and decrements `pending`; `finish` fires
                -- `on_complete` exactly once when the last slot settles.
                -- Not-OK settles come from _drain_pending_apply_edits's
                -- error path (file_load_error / buffer vanished mid-load).
                new_view._pending_apply_done = function(ok)
                    if ok then
                        touched[#touched + 1] = uri
                    else
                        skipped[#skipped + 1] = uri
                    end
                    pending = pending - 1
                    finish()
                end
            end
        end
    end

    -- Everything that was already open has settled; finish synchronously
    -- unless background opens are still in flight (those call finish from
    -- their done continuations / _drain_pending_apply_edits).
    finish()
    return result
end

--- Drain a background-opened view's parked workspace edits once its file
--- has loaded. Parked by Editor:apply_workspace_edit on
--- `view._pending_apply_edits` (+ `_pending_apply_uri` /
--- `_pending_apply_done`); fired from the editor_listeners `file_loaded`
--- handler after the goto (if any) is placed. Applies the edits as one
--- undo group, resyncs the view, didChange-syncs the mutated text to
--- the doc's bound server (already didOpen'd during this load's
--- mode_enter), then runs the `done(true)` continuation so
--- apply_workspace_edit's on_complete fires + the LSP applyEdit request
--- can be answered. The `ok` arg (default true) is set false by the
--- load-failure path (file_load_error: file missing / mmap error):
--- then no apply runs and `done(false)` records the uri as skipped so the
--- verdict stays honest + the request never hangs. No-op when nothing
--- is parked (clears the fields unconditionally so a replay/edge
--- doesn't double-apply).
---@param view View
---@param ok? boolean default true; false = load failed, skip the apply
function Editor:_drain_pending_apply_edits(view, ok)
    if ok == nil then
        ok = true
    end
    local edits = view._pending_apply_edits
    if edits == nil then
        return
    end
    local done = view._pending_apply_done
    view._pending_apply_edits = nil
    view._pending_apply_uri = nil
    view._pending_apply_done = nil
    local lsp = require("cursed.lsp_client")
    local buf = view.buffer
    if ok and buf ~= nil then
        buf:apply_lsp_edits(edits)
        resync_after_external_edit(view)
        if buf.lsp_client_id ~= nil and buf.lsp_uri ~= nil then
            local v = buf.lsp_version or 0
            lsp.sync_change(buf.lsp_client_id, buf.lsp_uri, v, function()
                return buf:write_text_direct()
            end)
        end
    else
        ok = false -- buffer vanished mid-load / load failed → skip
    end
    if done ~= nil then
        done(ok)
    end
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
    self.event_system:emit("before_save", view, buf)
    io_client.send_file_save(buf)
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
    io_client.send_file_save(view.buffer)
end

-- the event bus, and pushes a MSG_FILE_* to the IO lane.
-- The IO lane pushes MSG_FILE_ERROR (with arg=req_id, ptr=malloc'd
-- error string) on failure or MSG_FILE_DIRLIST_RESP (with arg=req_id,
-- ptr=packed buffer) on a dirlist success. drain_inbox looks up the
-- request by id and invokes on_done(entries_or_nil, err_or_nil).
-- All paths expand ~ / $ENV at the same place find_file uses.
-- Errors and the dirlist-reply heap buffer are owned by main on
-- drain_inbox and freed in place (ffi.string → ffi.C.free).
----------------------------------------------------------------------------------------------------

--- Mint the next request id for an async file op. Delegates to
--- shared.next_file_op_id so the counter is process-global — survives
--- editor recreation and is stable across the headless / fork paths.
---@return integer
function Editor:_next_file_op_id()
    return shared.next_file_op_id()
end

--- Delete a file via IO lane (unlink(2)).
---@param filepath string absolute path (already expanded)
---@param on_done fun(success: boolean, err: string?)? optional callback
function Editor:delete_file(filepath, on_done)
    local ss = shared.SharedState.from_global()
    local req_id = self:_next_file_op_id()
    if on_done then
        self._pending_ops_count = (self._pending_ops_count or 0) + 1
        local event_name = "file_op:" .. req_id
        local handler
        handler = self.event_system:on(event_name, function(_, payload)
            self.event_system:off(event_name, handler)
            self._pending_ops_count = self._pending_ops_count - 1
            if payload.err then
                self:clear_pending_op(shared.LANE_IDX_IO, req_id)
                on_done(false, payload.err)
            else
                self:clear_pending_op(shared.LANE_IDX_IO, req_id)
                on_done(true, nil)
            end
        end)
    end
    self:track_pending_op(shared.LANE_IDX_IO, req_id)
    ss:push(ss._ptr.outboxes[shared.LANE_IDX_IO], {
        type = shared.MSG_FILE_DELETE,
        arg = req_id,
        ptr = filepath,
    })
end

--- Delete a file (coroutine variant). Returns a token for async.await().
---@param filepath string
---@return AsyncToken
function Editor:delete_async(filepath)
    local req_id = self:_next_file_op_id()
    self._pending_ops_count = (self._pending_ops_count or 0) + 1
    local ss = shared.SharedState.from_global()
    self:track_pending_op(shared.LANE_IDX_IO, req_id)
    ss:push(ss._ptr.outboxes[shared.LANE_IDX_IO], {
        type = shared.MSG_FILE_DELETE,
        arg = req_id,
        ptr = filepath,
    })
    return async.token(self.event_system, "file_op:" .. req_id, function()
        self._pending_ops_count = (self._pending_ops_count or 1) - 1
        self:clear_pending_op(shared.LANE_IDX_IO, req_id)
    end)
end

--- Create a new file via IO lane (O_CREAT|O_EXCL — fails if file exists).
---@param filepath string absolute path (already expanded)
---@param on_done fun(success: boolean, err: string?)? optional callback
function Editor:create_file(filepath, on_done)
    local ss = shared.SharedState.from_global()
    local req_id = self:_next_file_op_id()
    if on_done then
        self._pending_ops_count = (self._pending_ops_count or 0) + 1
        local event_name = "file_op:" .. req_id
        local handler
        handler = self.event_system:on(event_name, function(_, payload)
            self.event_system:off(event_name, handler)
            self._pending_ops_count = self._pending_ops_count - 1
            if payload.err then
                self:clear_pending_op(shared.LANE_IDX_IO, req_id)
                on_done(false, payload.err)
            else
                self:clear_pending_op(shared.LANE_IDX_IO, req_id)
                on_done(true, nil)
            end
        end)
    end
    self:track_pending_op(shared.LANE_IDX_IO, req_id)
    ss:push(ss._ptr.outboxes[shared.LANE_IDX_IO], {
        type = shared.MSG_FILE_CREATE,
        arg = req_id,
        ptr = filepath,
    })
end

--- Create a new file (coroutine variant). Returns a token for async.await().
---@param filepath string
---@return AsyncToken
function Editor:create_async(filepath)
    local req_id = self:_next_file_op_id()
    self._pending_ops_count = (self._pending_ops_count or 0) + 1
    local ss = shared.SharedState.from_global()
    self:track_pending_op(shared.LANE_IDX_IO, req_id)
    ss:push(ss._ptr.outboxes[shared.LANE_IDX_IO], {
        type = shared.MSG_FILE_CREATE,
        arg = req_id,
        ptr = filepath,
    })
    return async.token(self.event_system, "file_op:" .. req_id, function()
        self._pending_ops_count = (self._pending_ops_count or 1) - 1
        self:clear_pending_op(shared.LANE_IDX_IO, req_id)
    end)
end

--- Activates the minibuffer with a y/n prompt. Empty input (just
--- hitting Enter) is treated as "yes" to match user-set value when
--- caller supplies one; otherwise the caller must provide on_no for
--- the default-no case. `on_cancel` invokes on_no.
---@param msg string the question to display (e.g. "Delete this file?")
---@param on_yes function called with no args if the user typed 'y'
---@param on_no function? called if the user typed anything else / Esc
function Editor:confirm(msg, on_yes, on_no)
    self:read_from_minibuffer({
        prompt = msg .. " (Y/n) ",
        on_submit = function(input)
            local first = (input or ""):lower():sub(1, 1)
            -- Empty submit defaults to "yes" (matches user's setting
            -- preference). To get a default-no prompt, callers can use
            -- the lower-level read_from_minibuffer prompt directly.
            if first == "" or first == "y" then
                if on_yes then
                    on_yes()
                end
            else
                if on_no then
                    on_no()
                end
            end
        end,
        on_cancel = function()
            if on_no then
                on_no()
            end
        end,
    })
end

--- Async variant: returns an AsyncToken that resolves to a boolean
--- (true = yes, false = no/cancel). Must be awaited from a coroutine.
---@param msg string
---@return AsyncToken
function Editor:confirm_async(msg)
    self._async_ui_id = (self._async_ui_id or 0) + 1
    local token = async.token(self.event_system, "confirm:" .. self._async_ui_id)
    self:confirm(msg, function()
        self.event_system:emit(token._ev, true)
    end, function()
        self.event_system:emit(token._ev, false)
    end)
    return token
end

--- Async variant of read_from_minibuffer. Returns an AsyncToken that
--- resolves to `{ value = string, cancelled = boolean }`. Must be
--- awaited from a coroutine.
--- `opts.on_change` is passed through for live preview (isearch).
--- `opts.on_submit` and `opts.on_cancel` are replaced by the token.
---@param opts { prompt: string?, initial: string?, completion: boolean?, completer: function?, on_change: function?, value: any?, auto_accept: boolean?, palette: boolean? }
---@return AsyncToken
function Editor:read_minibuffer_async(opts)
    self._async_ui_id = (self._async_ui_id or 0) + 1

    -- Handle kmacro replay: pop a pre-recorded input and return a
    -- resolved token so async.await returns immediately.
    if #self._mb_input_stack > 0 then
        local value = table.remove(self._mb_input_stack, 1)
        if opts.on_change then
            opts.on_change(value)
        end
        return async.resolved({ value = value, cancelled = false })
    end

    -- Handle value short-circuit.
    if opts.value ~= nil then
        return async.resolved({ value = opts.value, cancelled = false })
    end

    local token = async.token(self.event_system, "mb_async:" .. self._async_ui_id)
    self:read_from_minibuffer({
        prompt = opts.prompt,
        initial = opts.initial,
        completion = opts.completion,
        completer = opts.completer,
        on_change = opts.on_change,
        value = opts.value,
        auto_accept = opts.auto_accept,
        palette = opts.palette,
        on_submit = function(input)
            self.event_system:emit(token._ev, { value = input, cancelled = false })
        end,
        on_cancel = function()
            self.event_system:emit(token._ev, { value = nil, cancelled = true })
        end,
    })
    return token
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
    ss:push(ss._ptr.outboxes[shared.LANE_IDX_IO], {
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
--- Push a transient key handler onto the LIFO stack. The handler
--- gets first crack at every key event before the trie. Returns an
--- id that can be passed to remove_transient_handler.
---
--- handler(editor, token, ch, is_printable) → true if consumed
---
---@param handler function
---@return integer id
function Editor:push_transient_handler(handler)
    local h = self._transient_handlers
    h[#h + 1] = handler
    return #h
end

--- Remove a transient handler by id. Idempotent.
---@param id integer
function Editor:remove_transient_handler(id)
    local h = self._transient_handlers
    if id and id <= #h then
        h[id] = nil
    end
end

----------------------------------------------------------------------------------------------------
-- One-shot read-char (zap-to-char, query-replace confirm, etc.)
--
-- The prompt is shown in the status area (left of the modeline)
-- so the user knows what is being read; the main loop checks
-- `editor:_read_char_consume(token, ch)` after every key event,
-- which returns true if the event was consumed.
---@param prompt string short prompt (e.g. "Zap to char: ")
---@param callback fun(ch: string|nil) called with the char (or nil on cancel)
function Editor:read_char(prompt, callback)
    -- Remove previous read-char handler if still active
    if self._read_char_handler_id then
        self:remove_transient_handler(self._read_char_handler_id)
        self._read_char_handler_id = nil
    end
    self._read_char_cb = callback
    self._read_char_prompt = prompt
    -- Push a transient handler that wraps _read_char_consume.
    -- The handler self-removes when consumed (see _read_char_consume).
    local editor = self
    self._read_char_handler_id = self:push_transient_handler(function(ed, token, ch, _)
        return ed:_read_char_consume(token, ch)
    end)
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
        -- Remove the transient handler
        if self._read_char_handler_id then
            self:remove_transient_handler(self._read_char_handler_id)
            self._read_char_handler_id = nil
        end
        if cb then
            cb(nil)
        end
        return true
    end
    if ch and #ch == 1 then
        local byte = ch:byte(1)
        if byte >= 32 then
            local cb = self._read_char_cb
            self._read_char_cb = nil
            self._read_char_prompt = ""
            -- Remove the transient handler
            if self._read_char_handler_id then
                self:remove_transient_handler(self._read_char_handler_id)
                self._read_char_handler_id = nil
            end
            if cb then
                cb(ch)
            end
            return true
        end
    end
    return false
end

--- Async variant: returns an AsyncToken that resolves to the character
--- (string) on input, or nil on cancel (C-g/Escape). Must be awaited
--- from a coroutine.
---
--- Usage:
---   local ch = async.await(editor:read_char_async("Zap to char: "))
---   if ch == nil then return end  -- cancelled
---
---@param prompt string
---@return AsyncToken
function Editor:read_char_async(prompt)
    self._async_ui_id = (self._async_ui_id or 0) + 1
    local token = async.token(self.event_system, "read_char:" .. self._async_ui_id)
    self:read_char(prompt, function(ch)
        self.event_system:emit(token._ev, ch)
    end)
    return token
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

    local mb_opts = {
        prompt = prompt,
        completion = true,
        on_change = function(query)
            self:_isearch_update(query)
        end,
        on_submit = function(query)
            -- Clear the typing-phase overlay highlight.
            self._isearch_match = nil
            self._isearch_origin_line = nil
            self._isearch_origin_col = nil
            self._isearch_regex = nil
            if #query == 0 then
                return
            end
            -- Populate pending cursors with every match in the buffer.
            local mv = self:current_view()
            if not mv or not mv.file_loaded then
                return
            end
            local buf = mv.buffer
            mv.pending_cursors = {}
            local iter, err = self:_isearch_iter(buf, query, { line = 0, offset = 0 }, 1)
            if iter then
                local count = 0
                for match in iter do
                    mv:drop_cursor(match.line, match.offset)
                    count = count + 1
                end
                if count > 0 then
                    self.status_message = count
                        .. " matches — alt-m to commit, C-x C-n/p to navigate, C-g to cancel"
                else
                    self.status_message = "no matches"
                end
            else
                self.status_message = "invalid regexp: " .. tostring(err)
            end
        end,
        on_cancel = function()
            -- Clean up overlay and restore original point.
            self._isearch_match = nil
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

--- Highlight a match as the typing-phase overlay and jump the cursor
--- to its start (not setting a selection).
---@param mv View
---@param match table {line, offset, end_line, end_offset}
function Editor:_isearch_show_match(mv, match)
    self._isearch_match = match
    mv:p().line = match.line
    mv:p().col = match.offset
    mv:_set_goal_col(mv:p().col)
    mv:unset_mark()
    self.status_message = nil
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
    -- Search forward from end of current match (or cursor if no match).
    local start
    if self._isearch_match then
        start = { line = self._isearch_match.end_line, offset = self._isearch_match.end_offset }
    else
        start = { line = main_view:p().line, offset = main_view:p().col }
    end
    local iter, err = self:_isearch_iter(buf, query, start, 1)
    if not iter then
        self.status_message = "invalid regexp: " .. tostring(err)
        return
    end
    local match = iter()
    if match then
        self:_isearch_show_match(main_view, match)
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
    -- Search backward from start of current match (or cursor if no match).
    local start
    if self._isearch_match then
        start = { line = self._isearch_match.line, offset = self._isearch_match.offset }
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
        self:_isearch_show_match(main_view, match)
    else
        self.status_message = "failing search"
    end

    self._isearch_direction = -1
    self.minibuffer.prompt = self._isearch_regex and "Search backward regexp: "
        or "Search backward: "
end

--- Internal: run isearch from the saved origin for the given query.
--- Highlights the first match as an overlay; does not set a selection.
---@param query string
function Editor:_isearch_update(query)
    if #query == 0 then
        self._isearch_match = nil
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
        self:_isearch_show_match(main_view, match)
    else
        self._isearch_match = nil
    end
end

--- Navigate the primary cursor through pending cursor candidates.
--- Called by select_next_match / select_prev_match when candidates exist.
---@param dir integer 1=next (forward), -1=prev (backward)
function Editor:_nav_candidate(dir)
    local mv = self:current_view()
    if not mv or #mv.pending_cursors == 0 then
        return
    end
    local cursors = mv.pending_cursors
    local pline = mv:p().line
    local pcol = mv:p().col

    if dir > 0 then
        -- Find the first candidate strictly after the primary cursor.
        for i = 1, #cursors do
            local c = cursors[i]
            if c.line > pline or (c.line == pline and c.col > pcol) then
                mv:p().line = c.line
                mv:p().col = c.col
                mv:_set_goal_col(c.col)
                return
            end
        end
        -- Wrap to first candidate.
        local c = cursors[1]
        if c then
            mv:p().line = c.line
            mv:p().col = c.col
            mv:_set_goal_col(c.col)
        end
    else
        -- Find the first candidate strictly before the primary cursor.
        for i = #cursors, 1, -1 do
            local c = cursors[i]
            if c.line < pline or (c.line == pline and c.col < pcol) then
                mv:p().line = c.line
                mv:p().col = c.col
                mv:_set_goal_col(c.col)
                return
            end
        end
        -- Wrap to last candidate.
        local c = cursors[#cursors]
        if c then
            mv:p().line = c.line
            mv:p().col = c.col
            mv:_set_goal_col(c.col)
        end
    end
end

--- Promote the pending candidate at the given index to a live cursor.
--- If _query_ranges is set (replace mode), applies the match range
--- as a full selection. Removes the promoted entry from both arrays.
---@param i integer 1-based index into mv.pending_cursors
---@return boolean true if a candidate was promoted
function Editor:_promote_candidate_at_index(i)
    local mv = self:current_view()
    if not mv then
        return false
    end
    local pending = mv.pending_cursors
    local ranges = self._query_ranges
    local c = pending[i]
    if not c then
        return false
    end
    local nc = mv:make_cursor(c.line, c.col)
    if ranges and ranges[i] then
        nc.anchor_line = nc.line
        nc.anchor_col = nc.col
        nc.line = ranges[i].end_line
        nc.col = ranges[i].end_offset
        nc.anchor_transient = nil
    end
    table.insert(mv.cursors, nc)
    table.remove(pending, i)
    if ranges then
        table.remove(ranges, i)
    end
    return true
end

--- Promote the pending candidate at the primary cursor's exact position
--- to a live cursor (delegates to _promote_candidate_at_index). Returns
--- false if no candidate sits exactly under the primary.
function Editor:_promote_candidate_at_primary()
    local mv = self:current_view()
    if not mv then
        return false
    end
    local p = mv:p()
    local pending = mv.pending_cursors
    for i = 1, #pending do
        local c = pending[i]
        if c.line == p.line and c.col == p.col then
            return self:_promote_candidate_at_index(i)
        end
    end
    return false
end

--- Find the closest pending candidate to the primary cursor, breaking
--- ties toward the past (the candidate at or before the primary in
--- document order). Used by add_cursor_at_candidate when no region is
--- active — generalizes _promote_candidate_at_primary so the primary
--- need not sit exactly on a candidate.
---@return integer|nil 1-based index, or nil if no candidates
function Editor:_find_nearest_candidate_past_biased()
    local mv = self:current_view()
    if not mv or #mv.pending_cursors == 0 then
        return nil
    end
    local p = mv:p()
    local pending = mv.pending_cursors
    local best_i, best_abs, best_past = nil, nil, false
    for i = 1, #pending do
        local c = pending[i]
        -- Flatten to a single document-ordered key for distance. Columns
        -- are bounded by a line's length, so a large per-line multiplier
        -- keeps cross-line ordering faithful to (line, col) tuples.
        local diff
        if c.line == p.line then
            diff = c.col - p.col
        else
            diff = (c.line - p.line) * 0x100000 + (c.col - p.col)
        end
        local adiff = math.abs(diff)
        local past = diff <= 0
        if best_i == nil or adiff < best_abs or (adiff == best_abs and past and not best_past) then
            best_i, best_abs, best_past = i, adiff, past
        end
    end
    return best_i
end

--- Promote every pending candidate whose position falls within the
--- primary cursor's active selection region. Entries are removed from
--- both pending_cursors and _query_ranges (in reverse so removals keep
--- lower indices valid). Clears the region's mark on success.
---@return integer count of promoted candidates
function Editor:_promote_candidates_in_region()
    local mv = self:current_view()
    if not mv then
        return 0
    end
    local p = mv:p()
    if not p.anchor_line then
        return 0
    end
    local sl, sc, el, ec = mv:selection_ranges_one(p)
    if sl == nil then
        return 0
    end
    ---@cast sl integer
    ---@cast sc integer
    ---@cast el integer
    ---@cast ec integer
    local pending = mv.pending_cursors
    local count = 0
    for i = #pending, 1, -1 do
        local c = pending[i]
        local after_start = c.line > sl or (c.line == sl and c.col >= sc)
        local before_end = c.line < el or (c.line == el and c.col <= ec)
        if after_start and before_end then
            self:_promote_candidate_at_index(i)
            count = count + 1
        end
    end
    if count > 0 then
        mv:unset_mark()
    end
    return count
end

--- Handle a printable key during query-replace candidate mode.
--- y = promote current candidate + advance to next.
--- n = skip current candidate + advance to next.
--- Returns true if the key was consumed.
---@param ch string single printable character
---@return boolean
function Editor:_handle_query_candidate_key(ch)
    if not self._query_ranges then
        return false
    end
    local mv = self:current_view()
    if not mv or #mv.pending_cursors == 0 then
        self._query_ranges = nil
        return false
    end
    if ch == "y" then
        self:_promote_candidate_at_primary()
        if #mv.pending_cursors > 0 then
            self:_nav_candidate(1)
        else
            self._query_ranges = nil
            self.status_message = "all candidates promoted — type to replace"
        end
        return true
    elseif ch == "n" then
        if #mv.pending_cursors > 0 then
            self:_nav_candidate(1)
        else
            self._query_ranges = nil
        end
        return true
    end
    return false
end

----------------------------------------------------------------------------------------------------
-- Query replace
----------------------------------------------------------------------------------------------------

--- Start an incremental query-replace session.
--- Same candidate-cursor model as isearch: typing previews with overlay,
--- Enter populates candidates with match ranges. alt-m promotes + sets
--- selections; typing then replaces all selections at once (multi-cursor).
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

    -- Save original point for C-g cancel. Reuse isearch overlay machinery.
    self._isearch_origin_line = main_view:p().line
    self._isearch_origin_col = main_view:p().col
    self._isearch_direction = 1 -- always forward for query-replace
    self._isearch_regex = false -- plain substring match

    local mb_opts = {
        prompt = "Query replace: ",
        completion = true,
        on_change = function(query)
            self:_isearch_update(query)
        end,
        on_submit = function(query)
            -- Clear the typing-phase overlay highlight.
            self._isearch_match = nil
            self._isearch_origin_line = nil
            self._isearch_origin_col = nil
            if #query == 0 then
                return
            end
            -- Populate pending cursors AND query ranges with every match.
            local mv = self:current_view()
            if not mv or not mv.file_loaded then
                return
            end
            local buf = mv.buffer
            mv.pending_cursors = {}
            self._query_ranges = {}
            -- Push transient key handler for y/n navigation (LIFO).
            -- Self-deactivates when _query_ranges is cleared.
            if not self._query_range_handler_id then
                local query_handler = keybind.handler({
                    ["y"] = function(ed)
                        return ed:_handle_query_candidate_key("y")
                    end,
                    ["n"] = function(ed)
                        return ed:_handle_query_candidate_key("n")
                    end,
                })
                self._query_range_handler_id = self:push_transient_handler(
                    function(ed, token, ch, is_printable)
                        if not ed._query_ranges then
                            return false
                        end
                        if not is_printable or not ch then
                            return false
                        end
                        return query_handler(ed, token, ch, is_printable)
                    end
                )
            end
            local iter, err = self:_isearch_iter(buf, query, { line = 0, offset = 0 }, 1)
            if iter then
                local count = 0
                for match in iter do
                    mv:drop_cursor(match.line, match.offset)
                    self._query_ranges[#self._query_ranges + 1] = {
                        end_line = match.end_line,
                        end_offset = match.end_offset,
                    }
                    count = count + 1
                end
                if count > 0 then
                    self.status_message = count
                        .. " matches — alt-m to commit (with selections), C-x C-n/p to navigate, C-g to cancel"
                else
                    self.status_message = "no matches"
                    self._query_ranges = nil
                end
            else
                self.status_message = "invalid regexp: " .. tostring(err)
                self._query_ranges = nil
            end
        end,
        on_cancel = function()
            -- Clean up overlay and restore original point.
            self._isearch_match = nil
            self._query_ranges = nil
            local mv = self:current_view()
            if mv and self._isearch_origin_line then
                mv:p().line = self._isearch_origin_line
                mv:p().col = self._isearch_origin_col
                mv:_set_goal_col(mv:p().col)
                mv:unset_mark()
            end
            self._isearch_origin_line = nil
            self._isearch_origin_col = nil
        end,
    }

    mb_opts.initial = initial_query

    self:read_from_minibuffer(mb_opts)
end

----------------------------------------------------------------------------------------------------
-- Query replace regexp (with capture-group support)
----------------------------------------------------------------------------------------------------

--- Expand a replacement template using capture substrings.
--- `\&` = whole match, `\1`..`\9` = groups, `\\` = literal backslash,
--- `\x` (any other) = literal x. Emacs-style.
---@param template string
---@param caps string[] caps[1]=whole match, caps[2..10]=groups 1..9
---@return string
local function expand_replacement(template, caps)
    return (
        template:gsub("\\(.)", function(c)
            if c == "&" then
                return caps[1] or ""
            elseif c == "\\" then
                return "\\"
            elseif c >= "0" and c <= "9" then
                local n = tonumber(c)
                ---@cast n integer
                return caps[n + 1] or ""
            end
            return c
        end)
    )
end
Editor._expand_replacement = expand_replacement -- exposed for tests

--- Start an incremental query-replace-regexp session.
--- Step 1: minibuffer for regexp (incremental overlay like isearch).
---          On submit, EVERY match becomes a pending cursor (visible
---          as drop markers, C-x C-n/p navigable) with its capture
---          groups stashed in parallel.
--- Step 2: minibuffer for replacement template (supports \&, \1..\9).
--- Step 3: y/n walk — y stashes this match's expanded replacement
---          (no buffer mutation), n skips, ! stashes all remaining +
---          commits. Commit applies stashed replacements in REVERSE
---          document order (one undo group) so stored positions stay
---          valid (each edit only shifts positions after it).
---@param initial_query string? optional pre-fill
function Editor:start_query_replace_regexp(initial_query)
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end

    if not initial_query and main_view:p().anchor_line then
        local sl, sc, el, ec = main_view:selection_range()
        if sl then
            ---@cast sc integer
            ---@cast el integer
            ---@cast ec integer
            initial_query = main_view:text_between(sl, sc, el, ec)
        end
    end

    self._isearch_origin_line = main_view:p().line
    self._isearch_origin_col = main_view:p().col
    self._isearch_direction = 1
    self._isearch_regex = true
    -- Preserve the true origin across step 1's overlay moves, since
    -- _isearch_origin_* are clobbered/restored during step 1.
    local saved_origin_line = self._isearch_origin_line
    local saved_origin_col = self._isearch_origin_col
    ---@cast saved_origin_line integer
    ---@cast saved_origin_col integer

    -- Step 1: regexp prompt with isearch live preview.
    local r1 = async.await(self:read_minibuffer_async({
        prompt = "Query replace regexp: ",
        completion = true,
        initial = initial_query,
        on_change = function(query)
            self:_isearch_update(query)
        end,
    }))

    -- Clean up isearch state now that the prompt is closed.
    self._isearch_match = nil
    self._isearch_regex = nil
    self._isearch_origin_line = nil
    self._isearch_origin_col = nil

    if r1.cancelled or #(r1.value or "") == 0 then
        if r1.cancelled then
            local mv = self:current_view()
            if mv and saved_origin_line then
                mv:p().line = saved_origin_line
                mv:p().col = saved_origin_col
                mv:_set_goal_col(mv:p().col)
                mv:unset_mark()
            end
        end
        return
    end
    local query = r1.value

    -- Populate pending cursors + capture groups for EVERY match.
    local mv = self:current_view()
    if not mv or not mv.file_loaded then
        return
    end
    mv.pending_cursors = {}
    self._query_captures = {}
    self._isearch_regex = true
    local iter, err = self:_isearch_iter(mv.buffer, query, { line = 0, offset = 0 }, 1)
    if not iter then
        self._isearch_regex = nil
        self.status_message = "invalid regexp: " .. tostring(err)
        return
    end
    local count = 0
    for match in iter do
        mv:drop_cursor(match.line, match.offset)
        self._query_captures[#self._query_captures + 1] = {
            end_line = match.end_line,
            end_offset = match.end_offset,
            caps = match.captures or { "" },
        }
        count = count + 1
    end
    if count == 0 then
        self.status_message = "no matches"
        self._query_captures = nil
        return
    end

    -- Step 2: replacement template prompt.
    local r2 = async.await(self:read_minibuffer_async({
        prompt = "Replace regexp " .. query .. " with: ",
    }))

    if r2.cancelled then
        self:_cancel_replace_regexp()
        return
    end
    self:_begin_replace_regexp_batch(r2.value, saved_origin_line, saved_origin_col, count)
end

--- Enter the y/n batch walk after both prompts are submitted.
---@param template string replacement template (\&, \1..\9)
---@param origin_line integer saved primary cursor line
---@param origin_col integer saved primary cursor col
---@param count integer total candidate count (for the prompt)
function Editor:_begin_replace_regexp_batch(template, origin_line, origin_col, count)
    local mv = self:current_view()
    if not mv or not mv.file_loaded or not mv:has_pending_cursors() then
        return
    end
    self._query_replace_template = template
    self._query_replacements = {}
    self._replace_regexp_origin_line = origin_line
    self._replace_regexp_origin_col = origin_col
    -- Jump the primary cursor to the first candidate so y/n act on a
    -- real candidate (without this, promote/skip at primary fails
    -- silently — the primary may sit where no candidate lives).
    local first = mv.pending_cursors[1]
    if first then
        mv:p().line = first.line
        mv:p().col = first.col
        mv:_set_goal_col(first.col)
    end
    mv:unset_mark()
    self._replace_regexp_active = true
    -- Push transient key handler for y/n/!/enter navigation (LIFO).
    -- Self-deactivates when _replace_regexp_active is cleared.
    if not self._replace_regexp_handler_id then
        local regexp_handler = keybind.handler({
            ["y"] = function(ed)
                return ed:_handle_replace_regexp_key("y")
            end,
            ["n"] = function(ed)
                return ed:_handle_replace_regexp_key("n")
            end,
            ["!"] = function(ed)
                return ed:_handle_replace_regexp_key("!")
            end,
        })
        self._replace_regexp_handler_id = self:push_transient_handler(
            function(ed, token, ch, is_printable)
                if not ed._replace_regexp_active then
                    return false
                end
                if is_printable and ch then
                    return regexp_handler(ed, token, ch, is_printable)
                end
                if token == "enter" then
                    ed:_commit_replace_regexp()
                    return true
                end
                return false
            end
        )
    end
    self.status_message = count
        .. " matches — y replace, n skip, ! all, RET commit, C-g cancel (C-x C-n/p to navigate)"
end

--- Find the index of the pending cursor sitting at the primary
--- cursor's position.
---@return integer|nil
function Editor:_replace_regexp_candidate_index()
    local mv = self:current_view()
    if not mv then
        return nil
    end
    local p = mv:p()
    local pending = mv.pending_cursors
    for i = 1, #pending do
        local c = pending[i]
        if c.line == p.line and c.col == p.col then
            return i
        end
    end
    return nil
end

--- Stash the candidate at the primary cursor as an accepted
--- replacement (expanded template + its match range), then remove it
--- from the pending/captures arrays. Returns true if a candidate was
--- stashed. Does NOT mutate the buffer (edits are deferred to commit).
---@return boolean
function Editor:_stash_candidate_at_primary()
    local mv = self:current_view()
    if not mv then
        return false
    end
    local i = self:_replace_regexp_candidate_index()
    if not i then
        return false
    end
    local caps_entry = self._query_captures and self._query_captures[i]
    if not caps_entry then
        return false
    end
    local c = mv.pending_cursors[i]
    local text = expand_replacement(self._query_replace_template, caps_entry.caps or { "" })
    self._query_replacements = self._query_replacements or {}
    self._query_replacements[#self._query_replacements + 1] = {
        line = c.line,
        offset = c.col,
        end_line = caps_entry.end_line,
        end_offset = caps_entry.end_offset,
        text = text,
    }
    table.remove(mv.pending_cursors, i)
    if self._query_captures then
        table.remove(self._query_captures, i)
    end
    return true
end

--- Drop the candidate at the primary cursor (skip without replacing).
---@return boolean
function Editor:_skip_candidate_at_primary()
    local mv = self:current_view()
    if not mv then
        return false
    end
    local i = self:_replace_regexp_candidate_index()
    if not i then
        return false
    end
    table.remove(mv.pending_cursors, i)
    if self._query_captures then
        table.remove(self._query_captures, i)
    end
    return true
end

--- Stash every remaining pending candidate, then commit all stashed
--- replacements in reverse document order (one undo group).
function Editor:_replace_regexp_replace_all()
    local mv = self:current_view()
    if not mv then
        return
    end
    while mv:has_pending_cursors() do
        -- Stash from the front each iteration; _stash_candidate_at_primary
        -- operates on whichever candidate is at the primary cursor, so
        -- jump the primary to the first pending cursor first.
        local first = mv.pending_cursors[1]
        if not first then
            break
        end
        mv:p().line = first.line
        mv:p().col = first.col
        if not self:_stash_candidate_at_primary() then
            break
        end
    end
    self:_commit_replace_regexp()
end

--- Handle a single printable key during the regexp-replace walk.
--- y = stash + advance, n = skip + advance, ! = stash all + commit.
---@param ch string single character
---@return boolean true if consumed
function Editor:_handle_replace_regexp_key(ch)
    if not self._replace_regexp_active then
        return false
    end
    if ch == "y" then
        self:_stash_candidate_at_primary()
        self:_advance_replace_regexp()
        return true
    elseif ch == "n" then
        self:_skip_candidate_at_primary()
        self:_advance_replace_regexp()
        return true
    elseif ch == "!" then
        self:_replace_regexp_replace_all()
        return true
    end
    return false
end

--- Advance to the next candidate, or commit if none remain.
function Editor:_advance_replace_regexp()
    local mv = self:current_view()
    if not mv then
        return
    end
    if not mv:has_pending_cursors() then
        self:_commit_replace_regexp()
        return
    end
    self:_nav_candidate(1)
end

--- Apply every stashed replacement in reverse document order within a
--- single undo group. Reverse order keeps stored positions valid:
--- each delete+insert only shifts positions AFTER it, and we've
--- already processed those.
function Editor:_commit_replace_regexp()
    local mv = self:current_view()
    self._replace_regexp_active = nil
    local reps = self._query_replacements or {}
    local template_ok = self._query_replace_template ~= nil
    -- Capture origin before _clear_replace_regexp_state nils it.
    local origin_line = self._replace_regexp_origin_line
    local origin_col = self._replace_regexp_origin_col
    -- Clear walk state up front (after the walk, before edits).
    self:_clear_replace_regexp_state()
    if not mv then
        return
    end
    if #reps == 0 then
        if template_ok then
            self.status_message = "no replacements made"
        end
        return
    end
    -- Reverse-document order: descending by (line, offset).
    table.sort(reps, function(a, b)
        if a.line ~= b.line then
            return a.line > b.line
        end
        return a.offset > b.offset
    end)
    local buf = mv.buffer
    buf:close_edit()
    buf:begin_edit()
    for i = 1, #reps do
        local r = reps[i]
        local n = mv:chars_between(r.line, r.offset, r.end_line, r.end_offset)
        ---@cast n integer
        local rl, rc = r.line, r.offset
        if n > 0 then
            rl, rc = buf:delete_char(r.line, r.offset, n)
        end
        if #r.text > 0 then
            rl, rc = buf:insert_char(rl, rc, r.text)
        end
    end
    buf:end_edit()
    -- Restore point to the saved origin (predictable, matches C-g).
    if origin_line then
        ---@cast origin_line integer
        ---@cast origin_col integer
        mv:p().line = origin_line
        mv:p().col = origin_col
        mv:_set_goal_col(origin_col)
        mv:unset_mark()
    end
    self.status_message = "replaced " .. #reps .. (#reps == 1 and " occurrence" or " occurrences")
end

--- Clear all regexp-replace walk state (does not touch the buffer).
function Editor:_clear_replace_regexp_state()
    local mv = self:current_view()
    if mv then
        mv.pending_cursors = {}
    end
    self._query_captures = nil
    self._query_replacements = nil
    self._query_replace_template = nil
    self._replace_regexp_active = nil
    self._replace_regexp_origin_line = nil
    self._replace_regexp_origin_col = nil
    self._isearch_match = nil
    self._isearch_regex = nil
end

--- Cancel the walk and restore the original point (no edits applied).
function Editor:_cancel_replace_regexp()
    -- Capture origin before _clear_replace_regexp_state nils it.
    local origin_line = self._replace_regexp_origin_line
    local origin_col = self._replace_regexp_origin_col
    self:_clear_replace_regexp_state()
    local mv = self:current_view()
    if mv and origin_line then
        ---@cast origin_line integer
        ---@cast origin_col integer
        mv:p().line = origin_line
        mv:p().col = origin_col
        mv:_set_goal_col(origin_col)
        mv:unset_mark()
    end
    self.status_message = "Quit"
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
        fp(x, y, spaces(alloc), s.fg_color, s.bg_color)
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

--- Clamp all cursors in all file-loaded views before rendering.
function Editor:_render_clamp_views()
    for _, v in ipairs(self.views) do
        if v.file_loaded then
            v:_clamp_all_cursors()
        end
    end
end

--- Clear the backbuffer and apply focus-backdrop tint.
---@param term table
function Editor:_render_clear(term)
    local mb = self.minibuffer
    local clear_bg = ui("default_bg")
    if mb and mb.palette then
        clear_bg = blend(clear_bg, 0x000000, 195)
    end
    term:clear(ui("default_fg"), clear_bg)
    term:hide_cursor()
end

--- Render the "Loading..." placeholder.
---@param term table
---@param ov OverlayManager
---@param fp function
function Editor:_render_loading(term, ov, fp)
    local msg = "Loading..."
    local x = math.floor(term:width() / 2) - math.floor(#msg / 2)
    local y = math.floor(term:height() / 2)
    fp(x, y, msg, ui("default_fg"), ui("default_bg"))
    ov:emit_render()
    ov:flush()
    term:present()
end

--- Compute text geometry and return a table of derived values.
---@param view View
---@param w integer terminal width
---@return table geo {gutter_w, text_x, text_w, block_x, block_w, line_digits, sign_fns, sign_count}
function Editor:_render_geometry(view, w)
    local gutter_w, text_x, text_w, block_x, block_w = view:text_geometry(w)
    local line_count = view.buffer:line_count()
    local sign_fns = self.gutter_sign_fns
    return {
        gutter_w = gutter_w,
        text_x = text_x,
        text_w = text_w,
        block_x = block_x,
        block_w = block_w,
        line_digits = #tostring(line_count),
        sign_fns = sign_fns,
        sign_count = sign_fns and #sign_fns or 0,
    }
end

--- Compute footer layout, wrap settings, and viewport byte range.
---@param mb Minibuffer
---@param view View
---@param geo table from _render_geometry
---@param term table
---@param fp function
---@param ov OverlayManager
---@return table layout {max_y, footer_tail, reflowed, vstart_li, vend_li}
function Editor:_render_layout(mb, view, geo, term, fp, ov)
    local w, h = term:width(), term:height()
    local text_w = geo.text_w
    local avail_text = w - geo.gutter_w -- window width minus gutter (no margin narrowing)

    -- Minibuffer chrome
    local mb_tail = self.minibuffer:_render(self, w, h, fp)
    local eval_rows = (not (mb and mb.active) and self._eval_result) and 1 or 0
    local footer_tail = mb_tail + eval_rows
    local max_y = h - footer_tail - 2

    -- Wrap width: always wrap at least at window width. When `wrap` is
    -- true AND margin is set AND narrower than the window, also narrow
    -- the wrap point to the margin width.
    local reflowed = false
    local wrap_target = text_w -- margin-narrowed width, or avail_text if margin is nil
    if not view.wrap then
        wrap_target = avail_text -- window width only, no margin narrowing
    end
    if view.wrap_width ~= wrap_target then
        view.wrap_width = wrap_target
        view:invalidate_wrap_cache()
        reflowed = true
    else
        local gen = tonumber(view.buffer._ptr.undo.count) + tonumber(view.buffer._ptr.redo.count)
        if view._wrap_gen ~= gen then
            view:invalidate_wrap_cache()
            view._wrap_gen = gen
        end
    end
    if reflowed then
        view:scroll_to_cursor(h - self:footer_rows() + 1, true)
    end

    -- Viewport byte range for highlighter
    local vstart_li = view.scroll_li or 0
    local sub = view.scroll_sub_row or 0
    local li = vstart_li
    local filled = (view:wrap_rows(li) or 1) - sub
    local vend_li = li
    local line_count = view.buffer:line_count()
    while filled <= max_y and li < line_count - 1 do
        li = li + 1
        filled = filled + (view:wrap_rows(li) or 1)
        vend_li = li
    end
    local starts = view:_hl_line_starts()
    local vstart_byte = starts[vstart_li + 1] or 0
    local vend_byte = (starts[vend_li + 2] or starts[#starts] or 0)
    if vend_byte > 0 then
        vend_byte = vend_byte - 1
    end
    view:_hl_notify_viewport(vstart_byte, vend_byte)

    return {
        max_y = max_y,
        footer_tail = footer_tail,
        reflowed = reflowed,
        vstart_li = vstart_li,
        vend_li = vend_li,
    }
end

--- Paint a TEXT segment with syntax highlighting, walking graphemes.
--- Highlight segments (`seg_segs`) are already scoped to this segment's byte
--- range (relative to `seg.buf_start`). Each grapheme is painted individually
--- so tabs are expanded at their display column and wide glyphs render
--- correctly.
---@param term table
---@param view View
---@param li integer
---@param row integer
---@param text_x integer text area x origin
---@param seg RowSegment (type="text")
---@param row_bg integer
---@param seg_segs table[]|nil sorted syntax highlight spans {cs,ce,fg}
---@param focus_dim function(fg,bg) -> fg,bg
---@param span_ctx table|nil {cur,n} monotonic cursor into view._spans for this logical line
local function _paint_text_segment(
    term,
    view,
    li,
    row,
    text_x,
    seg,
    row_bg,
    seg_segs,
    focus_dim,
    span_ctx
)
    local dfg, dbg = focus_dim(ui("default_fg"), row_bg or ui("default_bg"))
    local x = text_x + seg.col
    local text = seg.text
    local bo = seg.byte_offsets -- 0-based byte offsets per grapheme
    local widths = seg.widths
    local n = #widths
    if n == 0 then
        return
    end
    -- Accumulated column width within this segment (for tab expansion).
    local total_w = 0

    if seg_segs == nil or #seg_segs == 0 then
        -- No highlighting: paint each grapheme with default colors.
        for gi = 1, n do
            local gw = widths[gi]
            local gs = bo[gi] + 1 -- 1-based byte start
            local ge = (gi < n) and bo[gi + 1] or #text
            local ch = text:sub(gs, ge)
            -- Tab expansion
            if ch:byte(1) == 9 then
                local tw = view.tab_width or 8
                if tw > 0 then
                    local col = seg.col + total_w
                    ch = string.rep(" ", tw - (col % tw))
                end
            end
            -- Resolve properties spans covering this grapheme
            local line_byte = seg.buf_start + bo[gi]
            local props_fg, props_bg, props_underline = nil, nil, nil
            local props_bold, props_italic = false, false

            if span_ctx and span_ctx.n > 0 and view._spans then
                -- Advance cursor past spans that end before this byte
                while span_ctx.cur <= span_ctx.n do
                    local s = view._spans[span_ctx.cur]
                    if s.type ~= "properties" then
                        span_ctx.cur = span_ctx.cur + 1
                    elseif s.row_e < li or (s.row_e == li and s.col_e <= line_byte) then
                        span_ctx.cur = span_ctx.cur + 1
                    else
                        break
                    end
                end

                -- Collect all overlapping properties spans (later wins)
                local i = span_ctx.cur
                while i <= span_ctx.n do
                    local s = view._spans[i]
                    if s.type ~= "properties" then
                        i = i + 1
                    else
                        -- Check coverage
                        local covers = false
                        if s.row_s < li and s.row_e > li then
                            covers = true
                        elseif s.row_s == li and s.row_e > li then
                            covers = line_byte >= s.col_s
                        elseif s.row_s < li and s.row_e == li then
                            covers = line_byte < s.col_e
                        elseif s.row_s == li and s.row_e == li then
                            covers = line_byte >= s.col_s and line_byte < s.col_e
                        end

                        if not covers then
                            if s.row_s > li or (s.row_s == li and s.col_s > line_byte) then
                                break
                            end
                            i = i + 1
                        else
                            if s.fg then
                                props_fg = s.fg
                            end
                            if s.bg then
                                props_bg = s.bg
                            end
                            if s.underline_color then
                                props_underline = s.underline_color
                            end
                            if s.bold then
                                props_bold = s.bold
                            end
                            if s.italic then
                                props_italic = s.italic
                            end
                            i = i + 1
                        end
                    end
                end
            end

            local final_fg = props_fg or dfg
            local final_bg = props_bg or dbg
            if props_bold then
                final_fg = bit.bor(final_fg, tb.bold)
            end
            if props_italic then
                final_fg = bit.bor(final_fg, tb.italic)
            end

            term:print(x, row, ch, final_fg, final_bg)
            if props_underline then
                for col = 0, gw - 1 do
                    term:squiggle_cell(x + col, row, props_underline)
                end
            end
            x = x + gw
            total_w = total_w + gw
        end
        return
    end

    -- Syntax highlighting active: walk graphemes, checking each against
    -- the highlight segments.
    local seg_idx = 1
    local n_segs = #seg_segs

    for gi = 1, n do
        local gw = widths[gi]
        local gs_0 = bo[gi] -- 0-based byte start within seg.text
        local ge_0 = (gi < n) and bo[gi + 1] or #text -- 0-based exclusive end
        local ch = text:sub(gs_0 + 1, ge_0)

        -- Tab expansion
        if ch:byte(1) == 9 then
            local tw = view.tab_width or 8
            if tw > 0 then
                local col = seg.col + total_w
                ch = string.rep(" ", tw - (col % tw))
            end
        end

        -- Advance seg_idx past segments that end before this grapheme.
        while seg_idx <= n_segs and seg_segs[seg_idx].ce <= gs_0 do
            seg_idx = seg_idx + 1
        end

        local use_fg = dfg
        if seg_idx <= n_segs then
            local s = seg_segs[seg_idx]
            -- Check overlap: highlight segment covers any byte of this grapheme.
            if s.ce > gs_0 and s.cs < ge_0 then
                use_fg = focus_dim(s.fg, dbg)
            end
        end

        -- Resolve properties spans covering this grapheme
        local line_byte = seg.buf_start + gs_0
        local props_fg, props_bg, props_underline = nil, nil, nil
        local props_bold, props_italic = false, false

        if span_ctx and span_ctx.n > 0 and view._spans then
            -- Advance cursor past spans that end before this byte
            while span_ctx.cur <= span_ctx.n do
                local s = view._spans[span_ctx.cur]
                if s.type ~= "properties" then
                    span_ctx.cur = span_ctx.cur + 1
                elseif s.row_e < li or (s.row_e == li and s.col_e <= line_byte) then
                    span_ctx.cur = span_ctx.cur + 1
                else
                    break
                end
            end

            -- Collect all overlapping properties spans (later wins)
            local i = span_ctx.cur
            while i <= span_ctx.n do
                local s = view._spans[i]
                if s.type ~= "properties" then
                    i = i + 1
                else
                    -- Check coverage
                    local covers = false
                    if s.row_s < li and s.row_e > li then
                        covers = true
                    elseif s.row_s == li and s.row_e > li then
                        covers = line_byte >= s.col_s
                    elseif s.row_s < li and s.row_e == li then
                        covers = line_byte < s.col_e
                    elseif s.row_s == li and s.row_e == li then
                        covers = line_byte >= s.col_s and line_byte < s.col_e
                    end

                    if not covers then
                        if s.row_s > li or (s.row_s == li and s.col_s > line_byte) then
                            break
                        end
                        i = i + 1
                    else
                        if s.fg then
                            props_fg = s.fg
                        end
                        if s.bg then
                            props_bg = s.bg
                        end
                        if s.underline_color then
                            props_underline = s.underline_color
                        end
                        if s.bold then
                            props_bold = s.bold
                        end
                        if s.italic then
                            props_italic = s.italic
                        end
                        i = i + 1
                    end
                end
            end
        end

        local final_fg = props_fg or use_fg or dfg
        local final_bg = props_bg or dbg
        if props_bold then
            final_fg = bit.bor(final_fg, tb.bold)
        end
        if props_italic then
            final_fg = bit.bor(final_fg, tb.italic)
        end

        term:print(x, row, ch, final_fg, final_bg)
        if props_underline then
            for col = 0, gw - 1 do
                term:squiggle_cell(x + col, row, props_underline)
            end
        end
        x = x + gw
        total_w = total_w + gw
    end
end

--- Helper: extract the cursor character from a TEXT segment at a given
--- 0-based byte offset (relative to the segment). Returns the expanded
--- display text (tab → spaces).
---@param seg RowSegment (type="text")
---@param offset integer 0-based byte offset within the segment
---@param col_in_row integer display column of this position within the row
---@param tab_width integer tab stop width
---@return string
local function _segment_char_at(seg, offset, col_in_row, tab_width)
    local bo = seg.byte_offsets
    local widths = seg.widths
    local text = seg.text
    local n = #widths
    if n == 0 then
        return " "
    end
    -- Find the grapheme containing this byte offset.
    for gi = 1, n do
        local gs = bo[gi] -- 0-based byte start
        local ge = (gi < n) and bo[gi + 1] or #text -- 0-based exclusive end
        if offset >= gs and offset < ge then
            local ch = text:sub(gs + 1, ge)
            if ch:byte(1) == 9 then
                local tw = tab_width or 8
                if tw > 0 then
                    return string.rep(" ", tw - (col_in_row % tw))
                end
            end
            return ch
        end
    end
    return " "
end

--- Render the main content loop (viewport rows).
---@param view View
---@param term table
---@param mb Minibuffer
---@param ov OverlayManager
---@param focus_dim function
---@param geo table from _render_geometry
---@param layout table from _render_layout
function Editor:_render_content(view, term, mb, ov, focus_dim, geo, layout)
    local w = term:width()
    local max_y = layout.max_y
    local line_count = view.buffer:line_count()
    local sign_fns, sign_count = geo.sign_fns, geo.sign_count
    local li = view.scroll_li or 0
    local sub_row = view.scroll_sub_row or 0
    local row = 0

    -- Track the last row painted for cursor post-pass bounds.
    local content_end_row = 0

    while row <= max_y and li < line_count do
        local line_text = view:_line_text_stripped(li)
        local display_text = line_text
        local content_len = #display_text
        local total_sub = view:wrap_rows(li)

        -- Gutter signs (once per logical line)
        local signs
        if sign_count > 0 then
            signs = {}
            for i = 1, sign_count do
                signs[i] = sign_fns[i](self, view, li)
            end
        end

        -- Indent-guide columns
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

        -- Properties span cursor for this logical line
        local span_ctx = { cur = 1, n = 0 }
        if view._spans then
            span_ctx.n = #view._spans
            -- Fast-forward cursor to the first span that intersects this line
            while span_ctx.cur <= span_ctx.n do
                local s = view._spans[span_ctx.cur]
                if s.type ~= "properties" or s.row_e < li then
                    span_ctx.cur = span_ctx.cur + 1
                else
                    break
                end
            end
        end

        -- Sub-rows for this logical line
        while sub_row < total_sub and row <= max_y do
            content_end_row = row + 1
            local ok, err = pcall(function()
                local is_active = (view:p().line == li)
                local row_bg = is_active and ui("active_line_bg") or ui("default_bg")
                local num_fg = is_active and ui("line_number_active") or ui("line_number")
                num_fg, row_bg = focus_dim(num_fg, row_bg)

                local _, empty_bg = focus_dim(ui("default_fg"), ui("default_bg"))
                term:print(0, row, spaces(w), empty_bg, empty_bg)
                term:print(geo.block_x, row, spaces(geo.block_w), row_bg, row_bg)

                -- Gutter: line numbers + signs
                if not view.no_gutter and sub_row == 0 then
                    local line_num = view.no_line_numbers and "" or tostring(li + 1)
                    local num_pad = spaces(geo.line_digits - #line_num)
                    term:print(geo.block_x, row, " " .. num_pad .. line_num, num_fg, row_bg)
                end
                if not view.no_gutter and signs then
                    local sx = geo.block_x + 2 + geo.line_digits
                    for i = 1, #signs do
                        local s = signs[i]
                        if s then
                            term:print(sx + (i - 1), row, s.char, s.fg, s.bg or row_bg)
                        end
                    end
                end

                -- Segments from the token-aware wrap
                local segments, row_w = view:screen_row_segments(li, sub_row)

                -- Paint each segment
                for _, seg in ipairs(segments) do
                    if seg.type == "text" then
                        local seg_segs = view:highlight_segments(li, seg.buf_start, seg.buf_end)
                        _paint_text_segment(
                            term,
                            view,
                            li,
                            row,
                            geo.text_x,
                            seg,
                            row_bg,
                            seg_segs,
                            focus_dim,
                            span_ctx
                        )

                        -- Per-segment selection overlay
                        for rsl, rsc, rel, rec in view:selection_ranges() do
                            ---@cast rsl integer
                            ---@cast rsc integer
                            ---@cast rel integer
                            ---@cast rec integer
                            if li >= rsl and li <= rel then
                                local sel_cs = (li == rsl) and math.max(rsc, 0) or 0
                                local sel_ce = (li == rel) and math.min(rec, content_len)
                                    or content_len
                                -- Intersect with this segment's byte range.
                                local int_cs = math.max(sel_cs, seg.buf_start)
                                local int_ce = math.min(sel_ce, seg.buf_end)
                                if int_ce > int_cs then
                                    local dcs = view:byte_to_col(li, int_cs)
                                        - view:byte_to_col(li, seg.buf_start)
                                    local dce = view:byte_to_col(li, int_ce)
                                        - view:byte_to_col(li, seg.buf_start)
                                    -- Clamp to segment's display width.
                                    local seg_w_on_row = 0
                                    for _, gw in ipairs(seg.widths) do
                                        seg_w_on_row = seg_w_on_row + gw
                                    end
                                    if dcs < 0 then
                                        dcs = 0
                                    end
                                    if dce > seg_w_on_row then
                                        dce = seg_w_on_row
                                    end
                                    if dce > dcs then
                                        -- Paint selection over the intersecting portion.
                                        -- Walk graphemes in the intersection range.
                                        local bo = seg.byte_offsets
                                        local s_text = seg.text
                                        local acc_w = 0
                                        for gi = 1, #seg.widths do
                                            local gw = seg.widths[gi]
                                            local gs_0 = bo[gi]
                                            local ge_0 = (gi < #seg.widths) and bo[gi + 1]
                                                or #s_text
                                            local byte_start = seg.buf_start + gs_0
                                            local byte_end = seg.buf_start + ge_0
                                            if byte_start < int_ce and byte_end > int_cs then
                                                local ch = s_text:sub(gs_0 + 1, ge_0)
                                                if ch:byte(1) == 9 then
                                                    local tw = view.tab_width or 8
                                                    if tw > 0 then
                                                        local col_in_row = seg.col + acc_w
                                                        ch = string.rep(" ", tw - (col_in_row % tw))
                                                    end
                                                end
                                                ch = ch:gsub(" ", "·")
                                                term:print(
                                                    geo.text_x + seg.col + acc_w,
                                                    row,
                                                    ch,
                                                    ui("selection_fg"),
                                                    ui("selection_bg")
                                                )
                                            end
                                            acc_w = acc_w + gw
                                        end
                                    end
                                end
                            end
                        end

                        -- Per-segment isearch match overlay
                        local im = self._isearch_match
                        if im then
                            local s_col, e_col
                            if im.line == li and im.end_line == li then
                                s_col, e_col = im.offset, im.end_offset
                            elseif im.line == li then
                                s_col, e_col = im.offset, content_len
                            elseif im.end_line == li then
                                s_col, e_col = 0, im.end_offset
                            elseif li > im.line and li < im.end_line then
                                s_col, e_col = 0, content_len
                            end
                            if s_col and e_col and e_col > s_col then
                                -- Intersect with this segment's byte range.
                                local im_cs = math.max(s_col, seg.buf_start)
                                local im_ce = math.min(e_col, seg.buf_end)
                                if im_ce > im_cs then
                                    local m_fg, m_bg = ui("default_fg"), ui("search_match_bg")
                                    local bo = seg.byte_offsets
                                    local s_text = seg.text
                                    local acc_w = 0
                                    for gi = 1, #seg.widths do
                                        local gw = seg.widths[gi]
                                        local gs_0 = bo[gi]
                                        local ge_0 = (gi < #seg.widths) and bo[gi + 1] or #s_text
                                        local byte_start = seg.buf_start + gs_0
                                        local byte_end = seg.buf_start + ge_0
                                        if byte_start < im_ce and byte_end > im_cs then
                                            local ch = s_text:sub(gs_0 + 1, ge_0)
                                            if ch:byte(1) == 9 then
                                                local tw = view.tab_width or 8
                                                if tw > 0 then
                                                    local col_in_row = seg.col + acc_w
                                                    ch = string.rep(" ", tw - (col_in_row % tw))
                                                end
                                            end
                                            ov:put_float(
                                                geo.text_x + seg.col + acc_w,
                                                row,
                                                ch,
                                                m_fg,
                                                m_bg
                                            )
                                        end
                                        acc_w = acc_w + gw
                                    end
                                end
                            end
                        end
                    elseif seg.type == "replace" then
                        -- Stamp the DrawContext row. No highlight/selection/isearch overlay
                        -- applies to replaced visual content.
                        seg.draw_ctx:stamp_row(seg.row_idx, term, geo.text_x, row, geo.block_w)
                    end
                end

                -- Newline-at-end-of-line selection marker (only on the last sub-row
                -- when selection extends past content).
                if sub_row == total_sub - 1 then
                    for rsl, rsc, rel, rec in view:selection_ranges() do
                        ---@cast rsl integer
                        ---@cast rsc integer
                        ---@cast rel integer
                        ---@cast rec integer
                        if li >= rsl and li <= rel then
                            local ce = (li == rel) and math.min(rec, content_len) or content_len
                            if
                                ce >= content_len
                                and #line_text > 0
                                and view.buffer:line_text(li):byte(-1) == 10
                            then
                                local nl_x = geo.text_x + row_w
                                if nl_x < w then
                                    term:print(
                                        nl_x,
                                        row,
                                        "↵",
                                        ui("selection_fg"),
                                        ui("selection_bg")
                                    )
                                end
                                break
                            end
                        end
                    end
                end

                -- Indent guides
                if sub_row == 0 and #guide_cols > 0 then
                    local guide_fg = ui("indent_guide")
                    for _, g in ipairs(guide_cols) do
                        if g < row_w then
                            ov:put_float(geo.text_x + g, row, "│", guide_fg, row_bg)
                        end
                    end
                end

                -- Margin / fill-column indicator (shown when wrap is off but margin is set)
                if not view.wrap and view.margin and view.margin > 0 then
                    local indicator_x = geo.text_x + view.margin
                    if indicator_x < w then
                        ov:put_float(indicator_x, row, "│", ui("indent_guide"), row_bg)
                    end
                end
            end)
            if not ok then
                log.error(
                    "editor",
                    "render row failed",
                    { row = row, li = li, sub_row = sub_row, error = tostring(err) }
                )
                return
            end
            sub_row = sub_row + 1
            row = row + 1
        end
        li = li + 1
        sub_row = 0
    end

    -- Post-pass: cursor overlay (after all content rows rendered)
    if self._blink_on then
        for _, c in ipairs(view.cursors) do
            local csub_row, ccol = view:wrap_sub_position(c.line, c.col)
            -- Convert to absolute screen row.
            local sy = view:viewport_row_for_line(c.line, csub_row)
            if sy ~= nil and sy >= 0 and sy < content_end_row then
                -- Find the TEXT segment containing this cursor position.
                local segments, row_w = view:screen_row_segments(c.line, csub_row)
                local tw = view.tab_width or 8

                if view.whole_line_cursor then
                    local cfg = ui("cursor_fg")
                    local cbg = ui("cursor_bg")
                    ov:put_float(geo.text_x, sy, spaces(row_w), cfg, cbg)
                    -- Re-paint all TEXT segment graphemes in cursor fg/bg.
                    for _, seg in ipairs(segments) do
                        if seg.type == "text" then
                            local bo = seg.byte_offsets
                            local s_text = seg.text
                            local acc_w = 0
                            for gi = 1, #seg.widths do
                                local gw = seg.widths[gi]
                                local gs = bo[gi] + 1
                                local ge = (gi < #seg.widths) and bo[gi + 1] or #s_text
                                local ch = s_text:sub(gs, ge)
                                if ch:byte(1) == 9 then
                                    local col_in_row = seg.col + acc_w
                                    ch = string.rep(" ", tw - (col_in_row % tw))
                                end
                                if #ch > 0 then
                                    ov:put_float(geo.text_x + seg.col + acc_w, sy, ch, cfg, cbg)
                                end
                                acc_w = acc_w + gw
                            end
                        end
                    end
                else
                    local ch = " "
                    for _, seg in ipairs(segments) do
                        if
                            seg.type == "text"
                            and c.col + 1 >= seg.buf_start
                            and c.col + 1 <= seg.buf_end
                        then
                            local offset = c.col - seg.buf_start
                            ch = _segment_char_at(seg, offset, ccol, tw)
                            break
                        end
                    end
                    ov:put_float(geo.text_x + ccol, sy, ch, ui("cursor_fg"), ui("cursor_bg"))
                end
            end
        end
    end

    -- Post-pass: pending-drop markers
    for _, c in ipairs(view.pending_cursors) do
        local occluded = false
        for _, ac in ipairs(view.cursors) do
            if ac.line == c.line and ac.col == c.col then
                occluded = true
                break
            end
        end
        if occluded then
            goto continue_drop_post
        end
        local csub_row, ccol = view:wrap_sub_position(c.line, c.col)
        local sy = view:viewport_row_for_line(c.line, csub_row)
        if sy ~= nil and sy >= 0 and sy < content_end_row then
            local ch = " "
            local segments = view:screen_row_segments(c.line, csub_row)
            local tw = view.tab_width or 8
            for _, seg in ipairs(segments) do
                if
                    seg.type == "text"
                    and c.col + 1 >= seg.buf_start
                    and c.col + 1 <= seg.buf_end
                then
                    local offset = c.col - seg.buf_start
                    ch = _segment_char_at(seg, offset, ccol, tw)
                    break
                end
            end
            ov:put_float(geo.text_x + ccol, sy, ch, ui("cursor_fg"), ui("drop_bg"))
        end
        ::continue_drop_post::
    end
end

--- Render modeline, eval result, overlay flush, and present.
---@param view View
---@param term table
---@param mb Minibuffer
---@param ov OverlayManager
---@param fp function
---@param layout table from _render_layout
function Editor:_render_finalize(view, term, mb, ov, fp, layout)
    local h = term:height()
    local w = term:width()

    -- Modeline
    local modeline_y = h - layout.footer_tail - 1
    self:render_modeline(view, w, modeline_y, fp)

    -- Eval result
    local eval_rows = (not (mb and mb.active) and self._eval_result) and 1 or 0
    if eval_rows > 0 then
        fp(0, modeline_y + 1, "=> " .. self._eval_result, ui("status_message"), ui("default_bg"))
    end

    ov:emit_render()
    ov:flush()
    term:present()
end

--- Render the entire viewport.
function Editor:render()
    local render_t0 = profile.now_us()
    local term = self.term

    -- Phase 1: Clamp cursors + setup
    self:_render_clamp_views()
    local mb = self.minibuffer
    local ov = self.overlays
    local view = self:current_view()
    ov:begin_frame(view)
    local fp = function(x, y, text, fg, bg)
        ov:put_float(x, y, text, fg, bg)
    end
    local BLACK = 0x000000
    local function focus_dim(fg, bg)
        if not (mb and mb.palette) then
            return fg, bg
        end
        return blend(fg, BLACK, 165), blend(bg, BLACK, 195)
    end

    -- Phase 2: Clear
    self:_render_clear(term)

    -- Phase 3: Loading state
    if not view or not view.file_loaded then
        self:_render_loading(term, ov, fp)
        profile.span("editor", "render_total", render_t0)
        return
    end

    -- Phase 4: Geometry
    local geo = self:_render_geometry(view, term:width())
    if geo.text_w <= 0 then
        term:present()
        profile.span("editor", "render_total", render_t0)
        return
    end

    -- Phase 5: Layout
    local layout = self:_render_layout(mb, view, geo, term, fp, ov)

    -- Phase 6: Content
    self:_render_content(view, term, mb, ov, focus_dim, geo, layout)

    -- Phase 7: Finalize
    self:_render_finalize(view, term, mb, ov, fp, layout)

    profile.span("editor", "render_total", render_t0)
end

return Editor
