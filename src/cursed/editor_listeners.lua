--- Editor-level event listeners.
---
--- A single `setup(editor)` call registers every DEFAULT editor-level
--- consumer of `editor.event_system`: debug logging of command flow
--- and cross-thread traffic, and last-command history tracking (#7).
---
---@diagnostic disable: inject-field, undefined-field, need-check-nil, param-type-mismatch
--- The extracted handler functions access dynamically-added Editor fields
--- (_hover_*, _diag_*, _squiggle_demo, etc.) that LLS cannot resolve at
--- module scope but are valid at runtime.
---
--- Keep ALL editor-lifetime listeners here — not inline in main.lua —
--- so there's one place to audit "what observes command dispatch /
--- ring-buffer messages / mode transitions" and one place to add the
--- next one. Production extensions and major modes register their own
--- listeners on `editor.event_system` independently (e.g. from
--- `init.lua` against the global editor).

local log = require("cursed.log")
local lsp = require("cursed.lsp_client")
local commands_mod = require("cursed.commands")
local ColorScheme = require("cursed.colorscheme")
local utf8 = require("cursed.utf8")
local tb = require("cursed.tb")
local mdview = require("cursed.mdview")
local bit = require("bit")
local ffi = require("ffi")

local EditorListeners = {}

--- Project marker files/dirs whose presence identifies a project root.
--- Walked upward from the buffer's directory; the first enclosing dir
--- that contains ANY marker is the root. Ordered loosely by specificity
--- (language-specific configs first, then generic VCS markers).
local PROJECT_MARKERS = {
    "tsconfig.json",
    "package.json",
    "Cargo.toml",
    "go.mod",
    "pyproject.toml",
    "setup.py",
    "CMakeLists.txt",
    "Makefile",
    ".git",
    ".hg",
    ".svn",
}

ffi.cdef("int access(const char *path, int mode);")
local F_OK = 0

--- Check whether a path exists (file or directory).
--- @param path string absolute path
--- @return boolean
local function path_exists(path)
    return ffi.C.access(path, F_OK) == 0
end

--- Debounce window (microseconds) for full-text didChange: bursts of
--- keystrokes coalesce into ONE sync after typing pauses.
local DOCHANGE_DEBOUNCE_US = 150 * 1000 -- 150ms

--- Debounce window (microseconds) before auto-firing a hover request
--- after the cursor stops moving. Suppresses request storms while
--- scrolling / typing; matches typical editor hover latency.
local HOVER_DEBOUNCE_US = 500 * 1000 -- 500ms

--- Lexically canonicalize a POSIX path: resolve `.` and `..` segments
--- so the result has no `..` components. Does NOT touch symlinks (unlike
--- realpath(3)) --- the server sees the same path the user typed, just
--- normalized. Leading `..` on a relative path are preserved (can't
--- resolve above root without knowing the base); callers should join a
--- base first when the path is relative.
--- @param p string path, absolute or relative
--- @return string canonicalized path
local function canonicalize_path(p)
    local parts = {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then
            -- Pop the last real segment (but never pop the root marker).
            if #parts > 0 and parts[#parts] ~= "" then
                parts[#parts] = nil
            end
        elseif seg ~= "." and seg ~= "" then
            parts[#parts + 1] = seg
        end
    end
    local out = table.concat(parts, "/")
    if p:sub(1, 1) == "/" then
        return "/" .. out
    end
    return out
end

--- Resolve a buffer's filepath to an absolute, canonicalized path.
--- Joins a relative path onto the workspace root (or PWD), then
--- lexically canonicalizes `.`/`..` segments. Returns nil for unsaved
--- buffers (no filepath set).
--- @param buf any Buffer
--- @param workspace_dir string|nil
--- @return string|nil path absolute canonical path
local function absolute_filepath(buf, workspace_dir)
    local path = buf:filepath()
    if path == nil or #path == 0 then
        return nil
    end
    if path:sub(1, 1) ~= "/" then
        local base = workspace_dir
        if base == nil or #base == 0 then
            base = os.getenv("PWD") or "/"
        end
        path = base .. "/" .. path
    end
    return canonicalize_path(path)
end

--- Build a `file://` URI for a buffer relative to the workspace root.
--- Uses `absolute_filepath` so the server sees a well-formed absolute
--- URI even when the editor was launched with a relative path (e.g.
--- `cursed ../../other/src/file.ts`). Non-canonical URIs with `..`
--- segments are silently ignored by some servers (notably
--- typescript-language-server), yielding empty symbol/diagnostic results.
--- Returns nil for unsaved buffers (no filepath set).
--- @param buf any Buffer
--- @param workspace_dir string|nil
--- @return string|nil uri
local function uri_for_buffer(buf, workspace_dir)
    local path = absolute_filepath(buf, workspace_dir)
    if path == nil then
        return nil
    end
    return ("file://%s"):format(path)
end

--- Find the project root for a buffer by walking up from its directory
--- looking for project markers (tsconfig.json, package.json, .git, etc.).
--- Returns the first enclosing directory that contains a marker, or
--- the buffer's own directory as a fallback (so the server always gets
--- a sensible rootUri even for standalone files).
--- @param buf any Buffer
--- @param workspace_dir string|nil editor's workspace root (used to resolve relative paths)
--- @return string|nil root_dir absolute project root directory
local function find_project_root(buf, workspace_dir)
    local path = absolute_filepath(buf, workspace_dir)
    if path == nil then
        return nil
    end
    -- Start from the file's parent directory.
    local dir = path:match("^(.+)/[^/]+$")
    if dir == nil then
        return nil
    end
    -- Walk upward looking for any project marker.
    while dir ~= nil and dir ~= "" and dir ~= "/" do
        for _, marker in ipairs(PROJECT_MARKERS) do
            if path_exists(dir .. "/" .. marker) then
                return dir
            end
        end
        local parent = dir:match("^(.+)/[^/]+$")
        if parent == nil or parent == dir then
            break
        end
        dir = parent
    end
    -- No marker found; use the file's directory as a fallback so the
    --- server still gets a rootUri near the file rather than the cwd.
    return path:match("^(.+)/[^/]+$")
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

--- True when a cached diagnostic version is stale relative to the
--- buffer's current lsp_version (both non-nil and diverged).
---@param cached_version integer|nil
---@param buf Buffer
---@return boolean
local function version_stale(cached_version, buf)
    return cached_version ~= nil and buf.lsp_version ~= nil and cached_version ~= buf.lsp_version
end

-- ============================================================================
-- Event handler functions (extracted from setup() for testability & clarity)
-- ============================================================================

--- Debug logging for pre-command dispatch.
---@param _editor Editor
---@param cmd_name string
---@param view View|nil
local function on_pre_command_debug(_editor, cmd_name, view)
    log.debug("event", "pre_command_hook", {
        command = cmd_name,
        view = view and "active" or nil,
    })
end

--- Debug logging for post-command dispatch.
---@param _editor Editor
---@param cmd_name string
---@param view View|nil
local function on_post_command_debug(_editor, cmd_name, view)
    log.debug("event", "post_command_hook", {
        command = cmd_name,
        view = view and "active" or nil,
    })
end

--- Debug logging for ring-buffer messages.
---@param _editor Editor
---@param msg_type integer
---@param msg table
local function on_ring_buffer_debug(_editor, msg_type, msg)
    log.debug("event", "ring_buffer_message", {
        msg_type = msg_type,
        has_ptr = tostring(msg.ptr ~= nil),
        arg = msg.arg,
    })
end

--- Auto-register textobject commands when a view opens.
---@param _ed Editor
---@param view View
local function on_view_open_textobjects(_ed, view)
    commands_mod.register_textobject_commands(view)
end

--- Auto-register mode-specific textobject commands on mode entry.
--- Passes the instance's textobjects explicitly since mode_enter fires
--- BEFORE the entering mode is appended to view._major_modes.
---@param _ed Editor
---@param instance MajorMode
---@param view View
local function on_mode_enter_textobjects(_ed, instance, view)
    commands_mod.register_textobject_commands(view, instance.textobjects)
end

--- Re-register textobject commands when a parse tree lands.
--- Covers ordering edge cases where a ts textobject's command wasn't
--- registered at mode_enter time.
---@param _ed Editor
---@param view View
local function on_hl_tree_ready_textobjects(_ed, view)
    commands_mod.register_textobject_commands(view)
end

--- Track last-command / command-before-this for repeat (#7).
--- Records the command name and, if universal args were used, the
--- complex command (for repeat-complex-command). Skips recording the
--- repeat machinery itself so chaining works correctly.
---@param ed Editor
---@param cmd_name string|nil
---@param _view View|nil
local function on_post_command_history(ed, cmd_name, _view)
    if cmd_name == nil then
        return
    end
    if cmd_name == "repeat" or cmd_name == "repeat_complex_command" then
        return
    end
    ed._command_before_this = ed._last_command
    ed._last_command = cmd_name
    if ed.universal_args ~= nil then
        ed._last_complex_command = {
            name = cmd_name,
            universal_args = ed.universal_args,
        }
    end
end

--- Centralized LSP activation on mode entry.
--- Checks whether the entering mode declares lsp_servers (a first-wins
--- list of executables). Spawns-or-gets a language server subprocess
--- against the editor's workspace root, registers its stdout on the
--- main kqueue, and sets up per-buffer LSP state. didOpen is deferred
--- until the server's initialize handshake completes.
---@param ed Editor
---@param instance MajorMode
---@param _view View
local function on_mode_enter_lsp(ed, instance, _view)
    if ed.main_kq == nil then
        return
    end
    local exe_names = instance.lsp_servers
    if exe_names == nil or #exe_names == 0 then
        return
    end
    --- Compute the per-buffer project root so files from different
    --- workspaces get their own server instance (tsserver refuses to
    --- serve files outside its rootUri). Falls back to the editor's
    --- workspace_dir (getcwd) when the buffer has no filepath / no
    --- markers — matching the pre-existing behavior for that case.
    local buf = _view.buffer
    local root_dir = nil
    if buf ~= nil then
        root_dir = find_project_root(buf, ed.workspace_dir)
    end
    if root_dir == nil then
        root_dir = ed.workspace_dir
    end
    if root_dir == nil then
        log.warn("event", "lsp spawn skipped: no workspace_dir", { mode = instance.name })
        return
    end
    local cid = lsp.spawn_for_mode(instance.name, exe_names, root_dir)
    if cid == nil or cid == 0 then
        log.info("event", "lsp executable not found on PATH", { mode = instance.name })
        return
    end

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
end

--- Document sync: debounced full-text didChange after edits.
--- Checks whether the buffer's lsp_version has advanced past what the
--- server last received; if so, (re)schedules a short debounce.
---@param ed Editor
---@param _cmd_name string|nil
---@param view View|nil
local function on_post_command_doc_sync(ed, _cmd_name, view)
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
        return
    end
    if buf.lsp_version <= sent then
        return
    end
    if buf._lsp_debounce_task ~= nil then
        ed:cancel_task(buf._lsp_debounce_task)
    end
    buf._lsp_debounce_task = ed:schedule_after(DOCHANGE_DEBOUNCE_US, function()
        buf._lsp_debounce_task = nil
        if buf.lsp_client_id == nil then
            return true
        end
        local v = buf.lsp_version
        if v <= lsp.doc_sent_version(cid, uri) then
            return true
        end
        lsp.sync_change(cid, uri, v, function()
            return buf:write_text_direct()
        end)
        return true
    end)
end

--- Document sync: didClose when a buffer is destroyed.
---@param _ed Editor
---@param buf Buffer
---@param _view View|nil
local function on_buffer_close_doc_sync(_ed, buf, _view)
    if buf.lsp_client_id == nil then
        return
    end
    lsp.sync_close(buf.lsp_client_id, buf.lsp_uri)
    buf.lsp_client_id = nil
    buf.lsp_uri = nil
    buf.lsp_language_id = nil
    buf._lsp_debounce_task = nil
end

--- Clear diagnostics for a closing buffer.
---@param _ed Editor
---@param buf Buffer
---@param _view View|nil
local function on_buffer_close_clear_diags(_ed, buf, _view)
    if buf.lsp_uri ~= nil then
        lsp.clear_diagnostics(buf.lsp_uri)
    end
end

--- Apply a deferred LSP goto on file_loaded.
--- Also drains background-opened workspace edits parked in
--- _pending_apply_edits.
---@param ed Editor
---@param view View|nil
---@param _buf Buffer|nil
local function on_file_loaded_goto(ed, view, _buf)
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
        view:clamp_cursor()
        view:invalidate_wrap_cache()
        local starts = view:_hl_line_starts()
        local cur = view:p()
        local byte = (starts[cur.line + 1] or 0) + cur.col
        view:_hl_cold_requery(byte)
    end
    if view and view._pending_apply_edits ~= nil then
        ed:_drain_pending_apply_edits(view)
    end
end

--- Handle background file open failure.
---@param ed Editor
---@param view View|nil
---@param err_str string|nil
local function on_file_load_error(ed, view, err_str)
    if view == nil then
        return
    end
    if view._pending_apply_edits ~= nil then
        ed:_drain_pending_apply_edits(view, false)
    else
        log.warn("event", "file_load_error", { error = tostring(err_str) })
    end
    ed:close_view(view)
end

--- Handle textDocument/publishDiagnostics notification.
---@param _ed Editor
---@param params table
---@param cid integer
local function on_publish_diagnostics(_ed, params, cid)
    lsp.store_diagnostics(params, cid)
end

--- Handle workspace/applyEdit server request.
---@param ed Editor
---@param params table
---@param rid integer
---@param cid integer
local function on_workspace_apply_edit(ed, params, rid, cid)
    local label = (params and params.label) or "workspace/applyEdit"
    local ws_edit = params and params.edit
    log.info("lsp", "applyEdit received", { label = label, client_id = cid })
    if ws_edit == nil then
        ed.status_message = "applyEdit: no edit payload"
        log.warn("lsp", "applyEdit had no edit payload", { client_id = cid })
        lsp.respond(cid, rid, { applied = false })
        return
    end
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
        lsp.respond(cid, rid, { applied = n_touched > 0 })
    end)
end

--- Squiggle DEMO overlay (no LSP data source).
---@param ed Editor
local function on_render_squiggle_demo(ed)
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
        return
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
    ov:put_underline(line, lo - 1, hi, rgb)
end

--- LSP diagnostic squiggles overlay.
---@param ed Editor
local function on_render_diagnostic_squiggles(ed)
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
    if version_stale(entry.version, buf) then
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
        local end_past_eof = el >= line_count
        if end_past_eof then
            el = line_count - 1
        end
        if el < sl then
            goto continue
        end
        if el < top_li or sl > bottom_li then
            goto continue
        end
        local lo_line = math.max(sl, top_li)
        local hi_line = math.min(el, bottom_li)
        for line = lo_line, hi_line do
            local text = buf:line_text(line)
            local clen = view:content_len(line)
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
end

--- Gutter sign: colored "!" for worst diagnostic severity on a line.
---@param ed Editor
---@param view View
---@param li integer
---@return table|nil
local function gutter_diagnostic(ed, view, li)
    local buf = view.buffer
    if buf == nil or buf.lsp_uri == nil then
        return nil
    end
    local entry = lsp.diagnostics_for_uri(buf.lsp_uri)
    if entry == nil then
        return nil
    end
    if version_stale(entry.version, buf) then
        return nil
    end
    local line_count = view:line_count()
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

--- Gutter sign: yellow "!" on lines with available code actions.
---@param ed Editor
---@param view View
---@param li integer
---@return table|nil
local function gutter_code_action(ed, view, li)
    local buf = view.buffer
    if buf == nil or buf.lsp_uri == nil then
        return nil
    end
    local cached = ed._code_action_lines_by_uri[buf.lsp_uri]
    if cached == nil then
        return nil
    end
    if version_stale(cached.version, buf) then
        return nil
    end
    if cached.lines[li] then
        local scheme = ColorScheme.active
        local fg = scheme and scheme:color("code_action") or 0xE5C07B
        return { fg = fg, bg = nil, char = "!" }
    end
    return nil
end

--- Diagnostic hover popup overlay.
---@param ed Editor
local function on_render_diagnostic_hover(ed)
    local ov = ed.overlays
    local dismissed = ed._diag_hover_dismissed_sig
    local view = ed:current_view()
    local buf = view and view.buffer
    local entry = buf and buf.lsp_uri and lsp.diagnostics_for_uri(buf.lsp_uri) or nil
    local active, active_sig
    local c
    if entry ~= nil and view ~= nil and view.file_loaded then
        c = view.cursors and view.cursors[1]
        if c ~= nil then
            local line_count = view:line_count()
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
    if visible and ed.minibuffer and ed.minibuffer.active then
        visible = false
    end
    if visible and ed._whichkey_node ~= nil then
        visible = false
    end
    ed._diag_hover_active_sig = active_sig
    ed._diag_hover_visible = visible
    if not visible or active == nil or c == nil or ov == nil then
        return
    end

    local msg = active.message
    if msg == nil or msg == "" then
        msg = "(no message)"
    end
    if active.source ~= nil and active.source ~= "" then
        msg = "[" .. active.source .. "] " .. msg
    end
    local term = ed.term
    local max_w = math.min(math.max(20, term:width() - 4), 64)
    local lines = wrap_message(msg, max_w - 2)
    local border_fg = bit.bor(ui(sev_concept(active.severity or 0)), tb.bold)
    draw_float_box(ov, ed, c, lines, border_fg)
end

--- LSP hover popup overlay (cursor-idle, debounced).
---@param ed Editor
local function on_render_lsp_hover(ed)
    local ov = ed.overlays
    if ov == nil then
        return
    end
    local view = ed:current_view()
    local c = view and view.cursors and view.cursors[1]

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
        ed._hover_md = nil
        ed._hover_w = nil
        ed._hover_seq = (ed._hover_seq or 0) + 1
        if ed._hover_task ~= nil then
            ed:cancel_task(ed._hover_task)
            ed._hover_task = nil
        end
        if sig ~= nil and not hover_suppressed(ed) then
            local buf = sig.buf
            local cid = buf.lsp_client_id
            local uri = buf.lsp_uri
            if cid ~= nil and uri ~= nil and lsp.is_ready(cid) then
                local captured = { seq = 0, buf = buf, cid = cid, uri = uri }
                captured.seq = ed._hover_seq
                ed._hover_task = ed:schedule_after(HOVER_DEBOUNCE_US, function()
                    ed._hover_task = nil
                    if captured.buf ~= sig.buf then
                        return true
                    end
                    if hover_suppressed(ed) then
                        return true
                    end
                    if not lsp.is_ready(captured.cid) then
                        return true
                    end
                    local v = ed:current_view()
                    if v ~= sig.view then
                        return true
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
                        return true
                    end
                    lsp.on_response(ed, hover_id, function(_e, result, is_error)
                        if seq ~= ed._hover_seq then
                            return
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
                        local term = ed.term
                        local max_w = math.min(math.max(20, term:width() - 4), 64)
                        ed._hover_md = value
                        ed._hover_w = max_w - 2
                    end)
                    return true
                end)
            end
        end
    end

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
    local modeline_y = term_h - ed:footer_rows()
    local max_content_h = math.max(1, modeline_y - 2)
    local content_h = math.min(mdview.measure(md, content_w, max_content_h), max_content_h)
    if content_h < 1 then
        return
    end

    local box_w = content_w + 2
    local box_h = content_h + 2

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
        return
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
end

--- Register the default editor-level event listeners.
--- Idempotent-ish: intended to be called exactly once at editor
--- startup (from main.lua). Producers (pre/post-command-hook,
--- ring_buffer_message, mode_enter/exit) live at their call sites;
--- this module only registers consumer side.
---@param editor Editor
function EditorListeners.setup(editor)
    local es = editor.event_system

    -- Debug logging of command flow + cross-thread traffic
    es:on("pre_command_hook", on_pre_command_debug)
    es:on("post_command_hook", on_post_command_debug)
    es:on("ring_buffer_message", on_ring_buffer_debug)

    -- Auto-generated textobject commands
    es:on("view_open", on_view_open_textobjects)
    es:on("mode_enter", on_mode_enter_textobjects)
    es:on("hl_tree_ready", on_hl_tree_ready_textobjects)

    -- Last-command history (repeat machinery)
    es:on("post_command_hook", on_post_command_history)

    -- Centralized LSP activation on mode entry
    es:on("mode_enter", on_mode_enter_lsp)

    -- Document sync: debounced didChange after edits
    es:on("post_command_hook", on_post_command_doc_sync)

    -- Document sync: didClose + clear diagnostics on buffer close
    es:on("buffer_close", on_buffer_close_doc_sync)
    es:on("buffer_close", on_buffer_close_clear_diags)

    -- Deferred LSP goto / workspace applyEdits on file load
    es:on("file_loaded", on_file_loaded_goto)
    es:on("file_load_error", on_file_load_error)

    -- LSP inbound notifications
    es:on("lsp_notification:textDocument/publishDiagnostics", on_publish_diagnostics)

    -- LSP server-initiated requests
    es:on("lsp_server_request:workspace/applyEdit", on_workspace_apply_edit)

    -- Squiggle demo overlay
    es:on("render_overlay", on_render_squiggle_demo)

    -- LSP diagnostic squiggles overlay
    es:on("render_overlay", on_render_diagnostic_squiggles)

    -- Gutter signs
    editor.gutter_sign_fns[#editor.gutter_sign_fns + 1] = gutter_diagnostic
    editor.gutter_sign_fns[#editor.gutter_sign_fns + 1] = gutter_code_action

    -- Diagnostic hover popup overlay
    es:on("render_overlay", on_render_diagnostic_hover)

    -- LSP hover popup overlay (cursor-idle, debounced)
    es:on("render_overlay", on_render_lsp_hover)
end

return EditorListeners
