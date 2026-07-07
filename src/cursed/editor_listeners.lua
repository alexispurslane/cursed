--- Editor-level event listeners.
---
--- A single `setup(editor)` call registers every DEFAULT editor-level
--- consumer of `editor.event_system`: debug logging of command flow
--- and cross-thread traffic, and last-command history tracking (#7).
---
--- Keep ALL editor-lifetime listeners here — not inline in main.lua —
--- so there's one place to audit "what observes command dispatch /
--- ring-buffer messages / mode transitions" and one place to add the
--- next one. Production extensions and major modes register their own
--- listeners on `editor.event_system` independently (e.g. from
--- `init.lua` against the global editor).

local log = require("cursed.log")
local lsp = require("cursed.lsp_client")
local ColorScheme = require("cursed.colorscheme")
local utf8 = require("cursed.utf8")
local tb = require("cursed.tb")
local mdview = require("cursed.mdview")
local bit = require("bit")

local EditorListeners = {}

--- Debounce window (microseconds) for full-text didChange: bursts of
--- keystrokes coalesce into ONE sync after typing pauses.
local DOCHANGE_DEBOUNCE_US = 150 * 1000 -- 150ms

--- Debounce window (microseconds) before auto-firing a hover request
--- after the cursor stops moving. Suppresses request storms while
--- scrolling / typing; matches typical editor hover latency.
local HOVER_DEBOUNCE_US = 500 * 1000 -- 500ms

--- Build a `file://` URI for a buffer relative to the workspace root.
--- Uses realpath(3) to resolve the absolute path so the server sees a
--- canonical URI even when launched from a relative cwd. Returns nil
--- for unsaved buffers (no filepath set) — those aren't syncable.
--- @param buf any Buffer
--- @param workspace_dir string|nil
--- @return string|nil uri
local function uri_for_buffer(buf, workspace_dir)
    local path = buf:filepath()
    if path == nil or #path == 0 then
        return nil
    end
    -- Prefer the editor's workspace root as the absolute base; fall back
    -- to getcwd via os.tmpname trick. realpath() would resolve symlinks
    -- but needs POSIX FFI; most callers hand us absolute paths already.
    if path:sub(1, 1) ~= "/" then
        local base = workspace_dir
        if base == nil or #base == 0 then
            base = os.getenv("PWD") or "/"
        end
        path = base .. "/" .. path
    end
    return ("file://%s"):format(path)
end

-- UTF-16→byte conversion is shared from `cursed.utf8`.
local utf16_to_byte_col = utf8.utf16_to_byte_col

----------------------------------------------------------------------------------------------------
-- Diagnostic hover popup helpers
--
-- The hover box (like which-key's bordered float, but anchored above
-- the cursor) shows the active diagnostic's message when the cursor
-- sits inside a diagnostic span. Auto-shows by default; Esc/Ctrl-g
-- dismisses the CURRENT span's hover (re-shows for other spans / via
-- `show_diagnostic_hover`). State lives on the editor: _diag_hover_* .
----------------------------------------------------------------------------------------------------

--- Resolve a UI concept color from the active scheme (0xRRGGBB +
--- style) or fall back to termbox default.
---@param name string
---@return integer
local function ui(name)
    local scheme = ColorScheme.active
    if scheme == nil then
        return tb.color_default
    end
    return scheme:color(name)
end

--- Relative luminance of a truecolor attr (style bits stripped).
---@param color integer
---@return number
local function luminance(color)
    local c = bit.band(color, 0xFFFFFF)
    local r = bit.band(bit.rshift(c, 16), 0xFF) / 255
    local g = bit.band(bit.rshift(c, 8), 0xFF) / 255
    local b = bit.band(c, 0xFF) / 255
    return 0.299 * r + 0.587 * g + 0.114 * b
end

--- Auto-pick a readable text color for a resolved bg (bright on dark,
--- black on light). Mirrors whichkey.lua's helper so the hover matches
--- the modeline's legibility instead of the raw modeline_fg.
---@param bg integer resolved bg color int
---@return integer text color int
local function auto_text_color(bg)
    local scheme = ColorScheme.active
    if scheme == nil then
        return ui("modeline_fg")
    end
    if scheme.truecolor and luminance(bg) > 0.5 then
        return scheme:slot_color(0x00)
    end
    return scheme:slot_color(0x06)
end

--- Cell width of a string (counts UTF-8 codepoints; chrome is 1 cell).
---@param s string
---@return integer
local function cell_len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- Word-wrap `text` to at most `max_w` display cells, returning a
--- list of lines. Long words longer than max_w are hard-broken across
--- lines. Returns {""} for an empty/nil message (so the box still has a
--- content row).
---@param text string|nil
---@param max_w integer
---@return string[] lines
local function wrap_message(text, max_w)
    if text == nil or text == "" then
        return { "" }
    end
    if max_w < 1 then
        max_w = 1
    end
    local lines = {}
    local line = {}
    local line_w = 0
    for word in text:gmatch("%S*") do
        local ww = cell_len(word)
        if ww == 0 then
            goto continue -- pure whitespace token between words (gmatch yields it)
        end
        if line_w == 0 then
            -- first word on the line
            while ww > max_w do
                lines[#lines + 1] = word:sub(1, max_w)
                word = word:sub(max_w + 1)
                ww = cell_len(word)
            end
            line = { word }
            line_w = ww
        elseif line_w + 1 + ww <= max_w then
            line[#line + 1] = " "
            line[#line + 1] = word
            line_w = line_w + 1 + ww
        else
            -- flush current line, start a new one with this word
            lines[#lines + 1] = table.concat(line)
            while ww > max_w do
                lines[#lines + 1] = word:sub(1, max_w)
                word = word:sub(max_w + 1)
                ww = cell_len(word)
            end
            line = { word }
            line_w = ww
        end
        ::continue::
    end
    if line_w > 0 or #lines == 0 then
        lines[#lines + 1] = table.concat(line)
    end
    return lines
end

--- Normalize a hover `contents` field (MarkupContent / MarkedString /
--- MarkedString[]) to a single multi-line string. Markdown is rendered
--- as plain wrapped text (no fenced-code / inline rendering yet).
---@param contents any
---@return string
local function normalize_hover_contents(contents)
    if type(contents) == "string" then
        return contents
    end
    if type(contents) ~= "table" then
        return ""
    end
    if type(contents.value) == "string" then
        return contents.value
    end
    local parts = {}
    for _, e in ipairs(contents) do
        if type(e) == "string" then
            parts[#parts + 1] = e
        elseif type(e) == "table" and type(e.value) == "string" then
            parts[#parts + 1] = e.value
        end
    end
    if #parts == 0 then
        return ""
    end
    return table.concat(parts, "\n\n")
end

--- Severity 1..4 → colorscheme diagnostic concept name.
---@param severity integer
---@return string concept
local function sev_concept(severity)
    if severity == 1 then
        return "diagnostic_error"
    elseif severity == 2 then
        return "diagnostic_warn"
    elseif severity == 4 then
        return "diagnostic_hint"
    end
    return "diagnostic_info"
end

--- Paint a bordered floating box anchored at the cursor (`c.line`,
--- `c.col`), wrapping `lines` (already word-wrapped to fit `max_w - 2`).
--- Mirrors the diagnostic hover popup: prefers above the cursor, falls
--- back to below, clamps to the modeline; solid-filled so it occludes
--- buffer text. Reused by the diagnostic hover and the LSP hover popup.
--- `border_fg` is the resolved border color (with style bits); text/bg
--- are derived from the modeline scheme for legibility.
---@param ov any overlay surface (put_float / file_to_screen)
---@param ed Editor
---@param c table primary cursor {line, col}
---@param lines string[] already-wrapped content rows
---@param border_fg integer resolved border color + style
function draw_float_box(ov, ed, c, lines, border_fg)
    local term = ed.term
    local term_w = term:width()
    local term_h = term:height()
    local box_w = 2 -- borders
    for _, l in ipairs(lines) do
        local lw = cell_len(l) + 2
        if lw > box_w then
            box_w = lw
        end
    end
    if box_w > term_w then
        box_w = term_w
    end
    local box_h = #lines + 2 -- borders + content

    local csx, csy = ov:file_to_screen(c.line, c.col)
    if csx == nil or csy == nil then
        return -- cursor off-screen: nothing to anchor to
    end

    local modeline_y = term_h - ed:footer_rows()
    -- Prefer above the cursor; fall back to below if no room.
    local box_y_top = csy - box_h
    if box_y_top < 0 then
        box_y_top = csy + 1
    end
    if box_y_top + box_h > modeline_y then
        box_y_top = modeline_y - box_h
    end
    if box_y_top < 0 then
        return -- terminal too short to fit even once
    end

    -- Horizontal: start at the cursor's column, shift left to fit.
    local x = csx
    if x + box_w > term_w then
        x = term_w - box_w
    end
    if x < 0 then
        x = 0
    end

    local bg = ui("modeline_bg")
    local text_fg = auto_text_color(bg)

    -- Solid fill (so it paints over buffer text cleanly).
    for r = box_y_top, box_y_top + box_h - 1 do
        ov:put_float(x, r, string.rep(" ", box_w), text_fg, bg)
    end
    -- Borders.
    ov:put_float(x, box_y_top, "╭" .. string.rep("─", box_w - 2) .. "╮", border_fg, bg)
    ov:put_float(
        x,
        box_y_top + box_h - 1,
        "╰" .. string.rep("─", box_w - 2) .. "╯",
        border_fg,
        bg
    )
    -- Content rows (inset by 1).
    for i, l in ipairs(lines) do
        local y = box_y_top + i
        ov:put_float(x + 1, y, l, text_fg, bg)
    end
end

--- True when the LSP hover popup should NOT show / arm: another
--- transient UI is active, or the diagnostic hover is showing (no
--- stacking). Checked both at arm-time and paint-time.
---@param ed Editor
---@return boolean
local function hover_suppressed(ed)
    if ed.minibuffer and ed.minibuffer.active then
        return true
    end
    if ed._whichkey_node ~= nil then
        return true
    end
    if ed.completion_menu and ed.completion_menu.active then
        return true
    end
    if ed._diag_hover_visible then
        return true
    end
    return false
end

--- Does the diagnostic range [start,end) contain the cursor (cline,
--- ccol) at a 0-based byte column? Converts the diagnostic's UTF-16
--- character offsets against the live line text so non-ASCII tracks.
---@param diag table {sl,sc,el,ec}
---@param view View
---@param buf Buffer
---@param cline integer cursor line (0-based)
---@param ccol integer cursor byte column (0-based)
---@param line_count integer
---@return boolean
local function diag_contains(diag, view, buf, cline, ccol, line_count)
    local sl, sc, el, ec = diag.sl, diag.sc, diag.el, diag.ec
    if cline < sl or cline > el then
        return false
    end
    if cline == sl then
        local text = buf:line_text(sl)
        local clen = view:content_len(sl)
        local b_s = utf16_to_byte_col(text, sc or 0)
        if b_s > clen then
            b_s = clen
        end
        if sl == el then
            local b_e = utf16_to_byte_col(text, ec or b_s)
            if b_e > clen then
                b_e = clen
            end
            if b_s == b_e then
                return ccol == b_s -- zero-width: only at the exact point
            end
            return ccol >= b_s and ccol < b_e
        end
        return ccol >= b_s -- start line: cursor from start col to EOL is in range
    end
    if cline == el then
        local text = buf:line_text(el)
        local clen = view:content_len(el)
        local b_e = utf16_to_byte_col(text, ec or 0)
        if b_e > clen then
            b_e = clen
        end
        return ccol < b_e
    end
    return true -- strictly between sl and el: whole line is in range
end

--- A stable identity string for a diagnostic, used to remember "this
--- specific span was dismissed" so Esc dismisses only the current span
--- (other spans still auto-show; show_diagnostic_hover re-enables it).
---@param diag table
---@return string
local function diag_sig(diag)
    return string.format("%d:%d-%d:%d", diag.sl, diag.sc, diag.el, diag.ec)
end

--- Register the default editor-level event listeners.
--- Idempotent-ish: intended to be called exactly once at editor
--- startup (from main.lua). Producers (pre/post-command-hook,
--- ring_buffer_message, mode_enter/exit) live at their call sites;
--- this module only registers consumer side.
---@param editor Editor
function EditorListeners.setup(editor)
    local es = editor.event_system

    -- Debug logging of command flow + cross-thread traffic. Fires at
    -- debug level so production runs (info+) stay quiet.
    es:on("pre_command_hook", function(_editor, cmd_name, view)
        log.debug("event", "pre_command_hook", {
            command = cmd_name,
            view = view and "active" or nil,
        })
    end)
    es:on("post_command_hook", function(_editor, cmd_name, view)
        log.debug("event", "post_command_hook", {
            command = cmd_name,
            view = view and "active" or nil,
        })
    end)
    es:on("ring_buffer_message", function(_editor, msg_type, msg)
        log.debug("event", "ring_buffer_message", {
            msg_type = msg_type,
            has_ptr = tostring(msg.ptr ~= nil),
            arg = msg.arg,
        })
    end)

    -- Auto-generated textobject commands (#textobjects): on every
    -- view_open (covers the initial empty view + the default
    -- textobjects) and every mode_enter (covers mode-specific
    -- textobjects like lua's `statement`), register mark_<name> /
    -- forward_<name> / backward_<name> / *_select commands for any
    -- textobject in the view's merged set that doesn't already have
    -- a command. Idempotent (never overwrites hand-written / user-
    -- bound commands); see commands.register_textobject_commands.
    local commands_mod = require("cursed.commands")
    es:on("view_open", function(_ed, view)
        commands_mod.register_textobject_commands(view)
    end)
    es:on("mode_enter", function(_ed, instance, view)
        -- mode_enter fires BEFORE the entering mode is appended to
        -- view._major_modes, so view:_get_textobjects() wouldn't yet
        -- see the new mode's textobjects. Pass the instance's
        -- textobjects explicitly so e.g. lua's `statement` gets its
        -- commands immediately on mode entry.
        commands_mod.register_textobject_commands(view, instance.textobjects)
    end)
    -- A parse tree just landed for the view. Re-register textobject
    -- commands: a mode may declare tree-sitter textobjects (TO.ts{...})
    -- that are only meaningful once a tree exists, but the commands
    -- themselves are registered the same way (they re-acquire the tree
    -- lazily at call time). Belt-and-suspenders alongside mode_enter —
    -- covers any ordering edge where a ts textobject's command wasn't
    -- registered at mode_enter time.
    es:on("hl_tree_ready", function(_ed, view)
        commands_mod.register_textobject_commands(view)
    end)

    -- Last-command history (#7): Emacs `last-command` /
    -- `command-before-this` + rerun. The post_command hook fires with
    -- cmd_name (nil for chords bound directly to functions — those have
    -- no command name and are skipped) and while editor.universal_args
    -- still holds the args used for THIS dispatch (the main loop clears
    -- it after process_key returns, i.e. after all post-command hooks).
    --
    -- We skip recording the repeat machinery itself so pressing
    -- `repeat` repeatedly chains against the *original* last command
    -- rather than turning last-command into "repeat".
    es:on("post_command_hook", function(ed, cmd_name, _view)
        if cmd_name == nil then
            return
        end
        if cmd_name == "repeat" or cmd_name == "repeat_complex_command" then
            return
        end
        ed._command_before_this = ed._last_command
        ed._last_command = cmd_name
        -- A "complex command" is one invoked with universal args.
        -- repeat-complex-command reruns the most recent of these.
        if ed.universal_args ~= nil then
            ed._last_complex_command = {
                name = cmd_name,
                universal_args = ed.universal_args,
            }
        end
    end)

    -- Centralized LSP activation (#mode_enter). Every mode transition
    -- flows through one generic `mode_enter` event carrying the instance
    -- + view; we check whether the entering mode declares `lsp_servers`
    -- (a first-wins list of executables — bare strings OR candidate
    -- tables `{bin, args, env}` — inherited from its template via
    -- __index) and, if so, spawn-or-get a language server subprocess
    -- against the editor's workspace root, registering its stdout on the
    -- editor's main kqueue so the main loop drains it via
    -- `lsp.on_kqueue_read(fd)`. This is the SINGLE automatic,
    -- editor-managed LSP hook — it fires for both the manual `*-mode`
    -- toggle commands AND `activate_mode_for_filepath` (file open),
    -- dedups per-executable, and needs no per-mode wiring.
    es:on("mode_enter", function(ed, instance, _view)
        if ed.main_kq == nil then
            return -- kq not wired yet (pre-loop startup); nothing to spawn
        end
        local exe_names = instance.lsp_servers
        if exe_names == nil or #exe_names == 0 then
            return
        end
        if ed.workspace_dir == nil then
            log.warn("event", "lsp spawn skipped: no workspace_dir", { mode = instance.name })
            return
        end
        local on_message = function(msg)
            log.debug("event", "lsp message", {
                mode = instance.name,
                method = msg and (msg.method or msg.id) or nil,
            })
        end
        local on_exit = function(code)
            log.info("event", "lsp exited", { mode = instance.name, code = code })
        end
        -- Bind mode → client_id (dedups by exe set across modes that
        -- declare the same server binary; the lane owns the process).
        local cid = lsp.spawn_for_mode(instance.name, exe_names, ed.workspace_dir)
        if cid == nil or cid == 0 then
            log.info("event", "lsp executable not found on PATH", { mode = instance.name })
            return
        end

        -- Document sync setup: this is the FIRST time we know which
        -- buffer ↔ which server (client_id). Per-buffer LSP state lives
        -- on the Buffer object itself (lsp_client_id/uri/language_id/
        -- version). didOpen is deferred until the server's initialize
        -- handshake completes (READY) — handled inside the facade; the
        -- READY transition flushes pending opens. If the buffer was
        -- already tracked (mode re-enter), skip.
        local buf = _view.buffer
        if buf ~= nil and buf.lsp_client_id == nil then
            local uri = uri_for_buffer(buf, ed.workspace_dir)
            if uri ~= nil then
                local lang = instance.language or instance.name
                buf.lsp_client_id = cid
                buf.lsp_uri = uri
                buf.lsp_language_id = lang
                buf.lsp_version = buf.lsp_version or 0
                lsp.sync_open(cid, uri, lang, function()
                    return buf:write_text_direct()
                end)
            end
        end
    end)

    -- Document sync: debounced full-text didChange after edits. Every
    -- user-initiated mutation is a command, so post_command_hook is the
    -- single chokepoint. If the buffer is LSP-tracked + open and its
    -- lsp_version (bumped in Buffer:insert_char/delete_char/undo/redo)
    -- has advanced past what the server last received, (re)schedule a
    -- short debounce so bursts of keystrokes coalesce into ONE didChange.
    es:on("post_command_hook", function(ed, _cmd_name, view)
        if view == nil then
            return
        end
        local buf = view.buffer
        if buf == nil or buf.lsp_client_id == nil then
            return
        end
        local cid = buf.lsp_client_id
        local uri = buf.lsp_uri
        local sent = lsp.doc_sent_version(cid, uri)
        if sent < 0 then
            return -- doc not open yet (didOpen pending or never sent)
        end
        if buf.lsp_version <= sent then
            return -- no new edits since last sync
        end
        if buf._lsp_debounce_task ~= nil then
            ed:cancel_task(buf._lsp_debounce_task)
        end
        buf._lsp_debounce_task = ed:schedule_after(DOCHANGE_DEBOUNCE_US, function()
            buf._lsp_debounce_task = nil
            if buf.lsp_client_id == nil then
                return true -- one-shot
            end
            local v = buf.lsp_version
            if v <= lsp.doc_sent_version(cid, uri) then
                return true -- one-shot
            end
            lsp.sync_change(cid, uri, v, function()
                return buf:write_text_direct()
            end)
            return true -- one-shot
        end)
    end)

    -- Document sync: didClose when a buffer is destroyed. Tells the
    -- server to release its copy of the doc. Clears the buffer's LSP
    -- fields; a pending debounce task (if any) no-ops via the nil check.
    es:on("buffer_close", function(_ed, buf, _view)
        if buf.lsp_client_id == nil then
            return
        end
        lsp.sync_close(buf.lsp_client_id, buf.lsp_uri)
        buf.lsp_client_id = nil
        buf.lsp_uri = nil
        buf.lsp_language_id = nil
        buf._lsp_debounce_task = nil
    end)

    -- Drop diagnostics for a buffer being closed so its squiggles don't
    -- linger for a uri that may be reused by a re-opened doc; the server
    -- re-publishes on the next didOpen if the file comes back.
    es:on("buffer_close", function(_ed, buf, _view)
        if buf.lsp_uri ~= nil then
            lsp.clear_diagnostics(buf.lsp_uri)
        end
    end)

    -- Apply a deferred LSP goto placed on `view._pending_goto` by
    -- `Editor:jump_to_location` when the target file wasn't open yet
    -- (so the cursor couldn't be placed until the IO lane delivered the
    -- text). Fires once on the `file_loaded` event the load path emits,
    -- converts the LSP UTF-16 char to a byte col against the now-loaded
    -- line, clamps to bounds, and forces a scroll-into-view.
    --
    -- ALSO drains a background-opened view's parked workspace edits
    -- (`view._pending_apply_edits`, parked by Editor:apply_workspace_edit
    -- when a workspace/applyEdit's target file wasn't already open).
    -- The two pending slots are independent: a goto (jump_to_location)
    -- and an apply (workspace/applyEdit) don't both park on one view, but
    -- either path may miss its target being already loaded, so both are
    -- checked here and no-op cleanly when absent.
    es:on("file_loaded", function(ed, view, _buf)
        local g = view and view._pending_goto
        if g ~= nil then
            view._pending_goto = nil
            local lc = view:line_count()
            local li = g.line or 0
            if li < 0 then
                li = 0
            elseif li >= lc then
                li = math.max(0, lc - 1)
            end
            local text = view.buffer:line_text(li) or ""
            local byte_col = utf16_to_byte_col(text, g.char or 0)
            local clen = view:content_len(li)
            if byte_col > clen then
                byte_col = clen
            end
            view:set_single_cursor(li, byte_col)
            view._scroll_guard_line = nil
            view._scroll_guard_col = nil
            -- Zero-flash highlight resync (mirrors undo/redo/format): the
            -- fresh file's highlighter is cold at load, and the jumped-to
            -- location is far from line 0, so cold-requery synchronously at
            -- the cursor's byte so the FIRST render after load shows correct
            -- syntax instead of a flash of plain text as viewport buckets
            -- fill asynchronously. No-op when no highlighter mode is active.
            view:clamp_cursor()
            view:invalidate_wrap_cache()
            local starts = view:_hl_line_starts()
            local cur = view:p()
            local byte = (starts[cur.line + 1] or 0) + cur.col
            view:_hl_cold_requery(byte)
        end
        -- Background-opened workspace edits: apply + sync now that the
        -- file is loaded (mode_enter already didOpen'd the original text
        -- during this load, so didChange-sync the mutation it applies).
        if view and view._pending_apply_edits ~= nil then
            ed:_drain_pending_apply_edits(view)
        end
    end)

    -- A background file open failed (MSG_FILE_ERROR): the view stays
    -- file_loaded=false and would otherwise (a) hang any LSP
    -- workspace/applyEdit waiting on its parked edits and (b) steal the
    -- NEXT file load's data via main's first-not-loaded match. Finish
    -- the parked apply as skipped (done(false) releases the pending slot
    -- + on_complete so the applyEdit response still ships), then close
    -- the zombie view so it's removed from self.views. No-op when the
    -- failed open wasn't a workspace-edit target (no parked edits → just
    -- close the empty stub view).
    es:on("file_load_error", function(ed, view, err_str)
        if view == nil then
            return
        end
        if view._pending_apply_edits ~= nil then
            ed:_drain_pending_apply_edits(view, false)
        else
            log.warn("event", "file_load_error", { error = tostring(err_str) })
        end
        ed:close_view(view)
    end)

    -- LSP inbound notifications are re-emitted on the event bus by
    -- main's drain_lsp_inbox as `"lsp_notification:" .. method` carrying
    -- `(params, client_id)`. The publishDiagnostics handler is the only
    -- one cursed consumes today; it flattens the parsed params into the
    -- per-uri flat records the squiggle + diagnostic-jump paths read.
    -- Other methods are simply un-subscribed (the emit is then a no-op).
    es:on("lsp_notification:textDocument/publishDiagnostics", function(_ed, params, cid)
        lsp.store_diagnostics(params, cid)
    end)

    -- Server-initiated requests are re-emitted as
    -- `"lsp_server_request:" .. method` carrying
    -- `(params, request_id, client_id)`. Handle workspace/applyEdit by
    -- applying params.edit via Editor:apply_workspace_edit (uri→buffer,
    -- one undo group per doc, post-apply resync + didChange sync). For
    -- targets not already open, the edit is applied to a freshly
    -- background-opened (unfocused, Emacs-style) view whose file loads
    -- async via the IO lane — so apply_workspace_edit is INHERENTLY
    -- ASYNC when any target is unopened: the LSP response (with the
    -- real `applied` verdict) + the status message are produced in the
    -- `on_complete` callback once every pending open settles (or
    -- synchronously when every target was already open / it's a
    -- no-op). Other methods are unsubscribed.
    es:on("lsp_server_request:workspace/applyEdit", function(ed, params, rid, cid)
        local label = (params and params.label) or "workspace/applyEdit"
        local ws_edit = params and params.edit
        log.info("lsp", "applyEdit received", { label = label, client_id = cid })
        if ws_edit == nil then
            ed.status_message = "applyEdit: no edit payload"
            log.warn("lsp", "applyEdit had no edit payload", { client_id = cid })
            lsp.respond(cid, rid, { applied = false })
            return
        end
        -- on_complete fires exactly once: synchronously here when every
        -- target document was already open (pending == 0 immediately), or
        -- after the last background-opened file loads + is mutated.
        ed:apply_workspace_edit(ws_edit, function(r)
            local n_touched = #r.touched
            local n_skipped = #r.skipped
            if n_touched > 0 then
                ed.status_message = ('applied "%s" (%d doc%s)'):format(
                    label,
                    n_touched,
                    n_touched == 1 and "" or "s"
                )
            elseif n_skipped > 0 then
                ed.status_message = ('applyEdit "%s": no open docs (%d skipped)'):format(
                    label,
                    n_skipped
                )
            else
                ed.status_message = ('applyEdit "%s": nothing to apply'):format(label)
            end
            log.info("lsp", "applyEdit settled", {
                label = label,
                touched = n_touched,
                skipped = n_skipped,
                client_id = cid,
            })
            -- Per spec `applied` is a whole-edit verdict: true iff at
            -- least one document was actually mutated. Background-opened
            -- files that were opened + mutated count as touched.
            lsp.respond(cid, rid, { applied = n_touched > 0 })
        end)
    end)

    -- Squiggle DEMO (no LSP data source yet): when
    -- `editor._squiggle_demo` is on (toggle via M-x toggle_squiggle_demo),
    -- squiggle the primary cursor's current word in diagnostic_error
    -- red. Validates the full pipeline — patched termbox2 curly underline
    -- + underline color, the overlay `put_underline` range op resolving
    -- byte offsets to screen cells, and file-anchored tracking through
    -- scroll/wrap/edit — before wiring real diagnostics.
    es:on("render_overlay", function(ed)
        if not ed._squiggle_demo then
            return
        end
        local ov = ed.overlays
        if ov == nil then
            return
        end
        local view = ed:current_view()
        if not view or not view.file_loaded then
            return
        end
        local c = view.cursors and view.cursors[1]
        if c == nil then
            return
        end
        local buf = view.buffer
        if buf == nil then
            return
        end
        local line = c.line
        local len = view:content_len(line)
        if len <= 0 then
            return
        end
        local text = buf:line_text(line)
        -- byte-based identifier expansion around the cursor (1-based).
        local function ident(b)
            return b ~= nil
                and (
                    (b >= 65 and b <= 90)
                    or (b >= 97 and b <= 122)
                    or (b >= 48 and b <= 57)
                    or b == 95
                )
        end
        local pos = c.col + 1
        if pos > len then
            pos = len
        end
        if not ident(text:byte(pos)) then
            return -- cursor not on a word char: nothing to squiggle
        end
        local lo = pos
        while lo > 1 and ident(text:byte(lo - 1)) do
            lo = lo - 1
        end
        local hi = pos
        while hi < len and ident(text:byte(hi + 1)) do
            hi = hi + 1
        end
        local scheme = ColorScheme.active
        local rgb = scheme and scheme:color("diagnostic_error") or 0xFF5353
        -- put_underline takes 0-based byte offsets, range [s, e).
        ov:put_underline(line, lo - 1, hi, rgb)
    end)

    -- LSP diagnostics: query the latest publishDiagnostics for the
    -- current view's buffer uri and squiggle each Diagnostic range.
    -- Diagnostics carry 0-based UTF-16 `character` offsets (LSP default
    -- positionEncoding); we convert to byte offsets against the live
    -- line text so the squiggle tracks edits without waiting for a
    -- re-publish. Version-gating drops stale batches so out-of-date
    -- offsets never paint misaligned squiggles. Comparable to the demo
    -- listener but driven by real server data; severity → colorscheme
    -- diagnostic color (error/warn/info/hint).
    es:on("render_overlay", function(ed)
        local ov = ed.overlays
        if ov == nil then
            return
        end
        local view = ed:current_view()
        if not view or not view.file_loaded then
            return
        end
        local buf = view.buffer
        if buf == nil or buf.lsp_uri == nil then
            return
        end
        local entry = lsp.diagnostics_for_uri(buf.lsp_uri)
        if entry == nil then
            return
        end
        -- Stale check: if the server reported a concrete doc version and
        -- the buffer has since advanced, the offsets no longer align —
        -- skip until the next publishDiagnostics for the new version.
        if entry.version ~= nil and buf.lsp_version ~= nil and entry.version ~= buf.lsp_version then
            return
        end
        local scheme = ColorScheme.active
        local function sev_rgb(severity)
            local name = (severity == 1 and "diagnostic_error")
                or (severity == 2 and "diagnostic_warn")
                or (severity == 4 and "diagnostic_hint")
                or "diagnostic_info"
            return scheme and scheme:color(name) or 0xFF5353
        end
        local line_count = view:line_count()
        -- Visible viewport line range. Only queue squiggles for lines that
        -- can actually appear on screen this frame. Without this, the
        -- listener queued EVERY diagnostic range in the document (hundreds
        -- on view.lua), and each _paint_underline call then walked the
        -- wrap cache from the scroll anchor (O(distance)) only to find the
        -- line off-screen and paint nothing — ~80ms/frame of pure waste.
        local top_li = view.scroll_li or 0
        local max_y = ed.term:height() - ed:footer_rows() - 1
        local bottom_li = view:viewport_line_at_row(max_y)
        for _, diag in ipairs(entry.items) do
            local sl = diag.sl
            local el = diag.el
            if sl == nil or el == nil or sl < 0 or sl >= line_count then
                goto continue
            end
            local sc = diag.sc or 0
            local ec = diag.ec or sc
            local rgb = sev_rgb(diag.severity)
            -- Clamp the end line to the last real line. If the server's
            -- `end` landed past EOF (common when a diagnostic runs to the
            -- end of the file), the final real line should be fully
            -- squiggled rather than cut at a stale `ec`.
            local end_past_eof = el >= line_count
            if end_past_eof then
                el = line_count - 1
            end
            if el < sl then
                goto continue
            end
            -- Viewport filter: skip ranges entirely off-screen, and clamp
            -- the per-line loop to the visible window so a multi-line
            -- diagnostic can't queue thousands of off-screen squiggles.
            if el < top_li or sl > bottom_li then
                goto continue
            end
            local lo_line = math.max(sl, top_li)
            local hi_line = math.min(el, bottom_li)
            for line = lo_line, hi_line do
                local text = buf:line_text(line)
                local clen = view:content_len(line)
                -- LSP range is [start, end): exclusive end. Start col on
                -- the first line, col 0 on the others. End col on the
                -- last line; full-to-EOL on intermediate lines (and on the
                -- last line when the range conceptually runs past EOF).
                local b_s = (line == sl) and utf16_to_byte_col(text, sc) or 0
                local b_e
                if line == el and not end_past_eof then
                    b_e = utf16_to_byte_col(text, ec)
                else
                    b_e = clen
                end
                if b_s < 0 then
                    b_s = 0
                end
                if b_s > clen then
                    b_s = clen
                end
                if b_e < b_s then
                    b_e = b_s
                end
                if b_e > clen then
                    b_e = clen
                end
                if b_e > b_s then
                    ov:put_underline(line, b_s, b_e, rgb)
                end
            end
            ::continue::
        end
    end)

    -- Gutter sign: a colored "!" marking the worst diagnostic severity
    -- overlapping the line (error > warn > info > hint). Mirrors the
    -- squiggle listener above (same uri lookup + version-gating) but
    -- resolves to a single per-line glyph rather than per-range
    -- underlines. Registered into editor.gutter_sign_fns so it occupies
    -- one fixed gutter column; returns nil (blank slot) for lines with
    -- no diagnostic. bg=nil lets the render path fall back to the row
    -- bg so the sign tracks the active-line tint.
    editor.gutter_sign_fns[#editor.gutter_sign_fns + 1] = function(ed, view, li)
        local buf = view.buffer
        if buf == nil or buf.lsp_uri == nil then
            return nil
        end
        local entry = lsp.diagnostics_for_uri(buf.lsp_uri)
        if entry == nil then
            return nil
        end
        if entry.version ~= nil and buf.lsp_version ~= nil and entry.version ~= buf.lsp_version then
            return nil
        end
        local line_count = view:line_count()
        -- Find the worst (lowest-numbered) severity among diags whose
        -- [sl, el] range covers `li`. Lower number = more severe.
        local worst = nil
        for _, diag in ipairs(entry.items) do
            local sl = diag.sl
            local el = diag.el
            if sl ~= nil and el ~= nil and sl >= 0 and sl < line_count then
                if el >= line_count then
                    el = line_count - 1
                end
                if li >= sl and li <= el then
                    local sev = diag.severity or 3
                    if worst == nil or sev < worst then
                        worst = sev
                    end
                end
            end
        end
        if worst == nil then
            return nil
        end
        local scheme = ColorScheme.active
        local name = (worst == 1 and "diagnostic_error")
            or (worst == 2 and "diagnostic_warn")
            or (worst == 4 and "diagnostic_hint")
            or "diagnostic_info"
        return { fg = scheme and scheme:color(name) or 0xFF5353, bg = nil, char = "!" }
    end

    -- Gutter sign: a yellow "!" on lines that have available code actions.
    -- The cache is populated by the `code_actions` command response handler
    -- (commands.code_actions). Each entry carries a snapshot of the buffer's
    -- lsp_version; if the buffer has been edited since (version mismatch),
    -- the stale cache is ignored (returns nil) so the sign disappears.
    editor.gutter_sign_fns[#editor.gutter_sign_fns + 1] = function(ed, view, li)
        local buf = view.buffer
        if buf == nil or buf.lsp_uri == nil then
            return nil
        end
        local cached = ed._code_action_lines_by_uri[buf.lsp_uri]
        if cached == nil then
            return nil
        end
        -- Version check: if the buffer has been modified since the cache
        -- was populated, the cached lines are stale — don't show them.
        if
            cached.version ~= nil
            and buf.lsp_version ~= nil
            and cached.version ~= buf.lsp_version
        then
            return nil
        end
        if cached.lines[li] then
            local scheme = ColorScheme.active
            local fg = scheme and scheme:color("code_action") or 0xE5C07B
            return { fg = fg, bg = nil, char = "!" }
        end
        return nil
    end

    -- Diagnostic hover popup: when the primary cursor sits inside a
    -- diagnostic span, show that diagnostic's message as a floating
    -- bordered box just above the cursor (falling back to below when
    -- there's no room above, clamped to the modeline). Auto-shows by
    -- default; Esc/Ctrl-g dismisses the CURRENT span's hover
    -- (commands.escape_key / commands.keyboard_quit set
    -- _diag_hover_dismissed_sig); `show_diagnostic_hover` clears it.
    -- State on the editor is refreshed every frame here so the popup
    -- tracks cursor movement with no cursor-event plumbing.
    es:on("render_overlay", function(ed)
        local ov = ed.overlays
        local dismissed = ed._diag_hover_dismissed_sig
        local view = ed:current_view()
        local buf = view and view.buffer
        local entry = buf and buf.lsp_uri and lsp.diagnostics_for_uri(buf.lsp_uri) or nil
        local active, active_sig
        local c -- primary cursor (hoisted; reused when painting the popup)
        if entry ~= nil and view ~= nil and view.file_loaded then
            c = view.cursors and view.cursors[1]
            if c ~= nil then
                local line_count = view:line_count()
                -- Among diagnostics containing the cursor, pick the
                -- latest-starting (most specific / innermost) — the
                -- "nearest, bias down" tie-break.
                local best_start = -1
                for _, diag in ipairs(entry.items) do
                    if
                        diag.sl ~= nil
                        and diag.el ~= nil
                        and diag_contains(diag, view, buf, c.line, c.col, line_count)
                    then
                        local start_key = diag.sl * 1000000 + (diag.sc or 0)
                        if start_key > best_start then
                            best_start = start_key
                            active = diag
                        end
                    end
                end
                active_sig = active and diag_sig(active) or nil
            end
        end
        local visible = active_sig ~= nil and active_sig ~= dismissed
        -- Don't stack on top of the minibuffer / which-key popups.
        if visible and ed.minibuffer and ed.minibuffer.active then
            visible = false
        end
        if visible and ed._whichkey_node ~= nil then
            visible = false
        end
        -- Publish state for the dismiss/show commands to read.
        ed._diag_hover_active_sig = active_sig
        ed._diag_hover_visible = visible
        if not visible or active == nil or c == nil or ov == nil then
            return
        end

        -- Build the message text + wrap to a max width.
        local msg = active.message
        if msg == nil or msg == "" then
            msg = "(no message)"
        end
        if active.source ~= nil and active.source ~= "" then
            msg = "[" .. active.source .. "] " .. msg
        end
        local term = ed.term
        local max_w = math.min(math.max(20, term:width() - 4), 64)
        local lines = wrap_message(msg, max_w - 2) -- inset by 1 each side
        local border_fg = bit.bor(ui(sev_concept(active.severity or 0)), tb.bold)
        draw_float_box(ov, ed, c, lines, border_fg)
    end)

    -- LSP hover popup (cursor-idle, debounced). After the cursor
    -- stops moving for HOVER_DEBOUNCE_US, fire `textDocument/hover` and
    -- show the returned `contents` in the same bordered float as the
    -- diagnostic hover. This is RENDER-OVERLAY DRIVEN, NOT event-driven:
    -- every frame we compare the current cursor (view buffer + line +
    -- col) against the last position we armed a debounce for. On change
    -- we clear any visible hover, bump `_hover_seq` (rejecting in-flight
    -- responses whose position no longer matches), cancel the pending
    -- debounce, and (re)arm one for the new position. That makes hover
    -- track the cursor regardless of HOW it moved — keyboard commands,
    -- mouse clicks / drags, wheel scroll — with zero cursor-event
    -- plumbing (the same trick the diagnostic hover uses). Suppressed
    -- while the minibuffer / which-key / completion popup is active or
    -- the diagnostic hover is showing (no stacking).
    es:on("render_overlay", function(ed)
        local ov = ed.overlays
        if ov == nil then
            return
        end
        local view = ed:current_view()
        local c = view and view.cursors and view.cursors[1]

        -- Cursor-position signature (nil when no hover-eligible cursor).
        local sig
        if
            view ~= nil
            and view.file_loaded
            and c ~= nil
            and view.buffer ~= nil
            and view.buffer.lsp_uri ~= nil
        then
            sig = { view = view, buf = view.buffer, line = c.line, col = c.col }
        end

        -- Detect movement: re-arm on change.
        local prev = ed._hover_armed_sig
        local moved = not (
            prev ~= nil
            and sig ~= nil
            and prev.view == sig.view
            and prev.buf == sig.buf
            and prev.line == sig.line
            and prev.col == sig.col
        )
        if moved then
            ed._hover_armed_sig = sig
            ed._hover_md = nil -- cursor moved: clear immediately
            ed._hover_w = nil
            ed._hover_seq = (ed._hover_seq or 0) + 1 -- reject in-flight responses
            if ed._hover_task ~= nil then
                ed:cancel_task(ed._hover_task)
                ed._hover_task = nil
            end
            -- (Re)arm the debounce if the new position is hover-eligible
            -- and nothing is suppressing hover right now.
            if sig ~= nil and not hover_suppressed(ed) then
                local buf = sig.buf
                local cid = buf.lsp_client_id
                local uri = buf.lsp_uri
                if cid ~= nil and uri ~= nil and lsp.is_ready(cid) then
                    local captured = { seq = 0, buf = buf, cid = cid, uri = uri }
                    captured.seq = ed._hover_seq
                    ed._hover_task = ed:schedule_after(HOVER_DEBOUNCE_US, function()
                        ed._hover_task = nil
                        -- Re-validate at fire time: buffer/LSP may have
                        -- changed or a suppressor may have appeared.
                        if captured.buf ~= sig.buf then -- buffer swapped under us
                            return true
                        end
                        if hover_suppressed(ed) then
                            return true -- one-shot; re-arms on next movement
                        end
                        if not lsp.is_ready(captured.cid) then
                            return true
                        end
                        -- Cursor col may have advanced (it didn't, or this
                        -- task would've been cancelled) but re-read line
                        -- text fresh for UTF-16 conversion.
                        local v = ed:current_view()
                        if v ~= sig.view then
                            return true -- active view changed
                        end
                        local p = v:p()
                        local text = captured.buf:line_text(p.line) or ""
                        local char = utf8.byte_to_utf16_col(text, p.col)
                        local seq = captured.seq
                        local hover_id = lsp.request_hover(
                            captured.cid,
                            captured.uri,
                            { line = p.line, character = char }
                        )
                        if hover_id == nil then
                            return true -- not ready; one-shot arms again later
                        end
                        lsp.on_response(ed, hover_id, function(_e, result, is_error)
                            if seq ~= ed._hover_seq then
                                return -- stale: cursor moved since armed
                            end
                            if is_error or result == nil then
                                ed._hover_md = nil
                                ed._hover_w = nil
                                return
                            end
                            local value = normalize_hover_contents(result.contents)
                            if value == nil or value == "" then
                                ed._hover_md = nil
                                ed._hover_w = nil
                                return
                            end
                            -- Cache the raw markdown + the width it
                            -- was sized for. The paint path measures
                            -- + renders it via mdview (markdown
                            -- formatting, tree-sitter code blocks,
                            -- inline code, links-as-label+(url)).
                            local term = ed.term
                            local max_w = math.min(math.max(20, term:width() - 4), 64)
                            ed._hover_md = value
                            ed._hover_w = max_w - 2
                        end)
                        return true -- one-shot
                    end)
                end
            end
        end

        -- Paint if content is available + nothing is suppressing.
        local md = ed._hover_md
        local content_w = ed._hover_w
        if md == nil or content_w == nil then
            return
        end
        if hover_suppressed(ed) then
            return
        end
        if c == nil then
            return
        end

        local term = ed.term
        local term_w = term:width()
        local term_h = term:height()
        -- Cap content height so the popup never swallows the screen
        -- (the same ceiling draw_float_box implies via modeline_y).
        local modeline_y = term_h - ed:footer_rows()
        local max_content_h = math.max(1, modeline_y - 2)
        local content_h = math.min(mdview.measure(md, content_w, max_content_h), max_content_h)
        if content_h < 1 then
            return
        end

        local box_w = content_w + 2 -- 1-cell border on each side
        local box_h = content_h + 2

        -- Anchor: mirror draw_float_box — prefer above the cursor, fall
        -- back to below, then clamp into the modeline region.
        local csx, csy = ov:file_to_screen(c.line, c.col)
        if csx == nil or csy == nil then
            return
        end
        local box_y_top = csy - box_h
        if box_y_top < 0 then
            box_y_top = csy + 1
        end
        if box_y_top + box_h > modeline_y then
            box_y_top = modeline_y - box_h
        end
        if box_y_top < 0 then
            return -- terminal too short to fit even once
        end
        local x = csx
        if x + box_w > term_w then
            x = term_w - box_w
        end
        if x < 0 then
            x = 0
        end

        local bg = ui("modeline_bg")
        local text_fg = auto_text_color(bg)
        local border_fg = bit.bor(ui("modeline_fg"), tb.bold)

        -- Solid fill via direct term:print (so the popup occludes
        -- buffer text), then mdview renders the markdown content on
        -- top, then the border is queued as floats (paints during
        -- ov:flush, AFTER mdview.render's direct writes — same layer
        -- order the mdview demo popup uses).
        for r = 0, box_h - 1 do
            term:print(x, box_y_top + r, (" "):rep(box_w), text_fg, bg)
        end
        mdview.render(term, x + 1, box_y_top + 1, content_w, md, text_fg, bg, content_h)
        local top = "╭" .. string.rep("─", box_w - 2) .. "╮"
        local bot = "╰" .. string.rep("─", box_w - 2) .. "╯"
        ov:put_float(x, box_y_top, top, border_fg, bg)
        ov:put_float(x, box_y_top + box_h - 1, bot, border_fg, bg)
        for r = 1, box_h - 2 do
            ov:put_float(x, box_y_top + r, "│", border_fg, bg)
            ov:put_float(x + box_w - 1, box_y_top + r, "│", border_fg, bg)
        end
    end)
end

return EditorListeners
