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
local bit = require("bit")

local EditorListeners = {}

--- Debounce window (microseconds) for full-text didChange: bursts of
--- keystrokes coalesce into ONE sync after typing pauses.
local DOCHANGE_DEBOUNCE_US = 150 * 1000 -- 150ms

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
    es:on("file_loaded", function(_ed, view, _buf)
        local g = view and view._pending_goto
        if g == nil then
            return
        end
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
            for line = sl, el do
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
        local term_w = term:width()
        local term_h = term:height()
        local max_w = math.min(math.max(20, term_w - 4), 64)
        local lines = wrap_message(msg, max_w - 2) -- inset by 1 each side
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

        -- Anchor at the cursor's screen cell.
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
        local border_fg = bit.bor(ui(sev_concept(active.severity or 0)), tb.bold)

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
    end)
end

return EditorListeners
