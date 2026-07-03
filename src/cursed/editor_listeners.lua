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
end

return EditorListeners
