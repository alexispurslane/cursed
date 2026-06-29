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
    -- (a first-wins list of executable names inherited from its template
    -- via __index) and, if so, spawn-or-get a language server subprocess
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
        local client =
            lsp.spawn_or_get(ed.main_kq, exe_names, ed.workspace_dir, on_message, on_exit)
        if client == nil then
            log.info("event", "lsp executable not found on PATH", { mode = instance.name })
        end
    end)
end

return EditorListeners
