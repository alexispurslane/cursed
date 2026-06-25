--- Main entry point for the cursed editor.
---
--- Initializes terminal, creates an Editor, loads the file from CLI arg,
--- and runs the main event loop.

local ffi = require("ffi")
local bit = require("bit")
local tb = require("cursed.tb")
local shared = require("cursed.shared")
local kq_ffi = require("cursed.kqueue_ffi")
local Kqueue = require("cursed.kqueue").Kqueue
local pffi = require("cursed.posix_ffi")
local c = pffi.C
local keybind = require("cursed.keybind")
local commands = require("cursed.commands")
local Editor = require("cursed.editor")
local View = require("cursed.view").View
local Buffer = require("cursed.buffer").Buffer
local ColorScheme = require("cursed.colorscheme")
local find_file = require("cursed.find_file")
local log = require("cursed.log")

----------------------------------------------------------------------------------------------------
-- Keybind building (config-aware)
----------------------------------------------------------------------------------------------------

local Config = require("cursed.config")

--- Build the base keybind trie and extract the __printable handler.
--- Merges default keybindings with global overrides from init.lua.
---@param config Config loaded user configuration
---@return table trie
---@return function|nil printable_fn
---@return table<string, string|function> base_keybindings flat chord→action map
---@return table<string, string> chord_for_command reverse map command_name→formatted chord
local function build_keybind_trie(config)
    local bindings = {}
    local printable_fn ---@type function?
    local defaults = require("cursed.default_keybindings")

    -- Merge defaults
    for chord, func in pairs(defaults) do
        if chord == "__printable" then
            ---@cast func function
            printable_fn = func
        else
            bindings[chord] = func
        end
    end

    -- Merge global keybinding overrides from init.lua
    for chord, action in pairs(config.keybindings) do
        if chord == "__printable" then
            if type(action) == "function" then
                printable_fn = action
            end
        else
            bindings[chord] = action
        end
    end

    -- Build the reverse command_name→chord map from the FINAL merged
    -- bindings so displayed shortcuts reflect base + global overrides.
    local chord_for_command = keybind.build_chord_for_command(bindings)

    return keybind.Trie.build(bindings), printable_fn, bindings, chord_for_command
end

----------------------------------------------------------------------------------------------------
-- Inbox drain
----------------------------------------------------------------------------------------------------

local function drain_inbox(editor, ss)
    local msg = ss:pop(ss._ptr.inbox_io)
    while msg ~= nil do
        -- Ring-buffer producer: announce every message popped from the
        -- IO lane so observers (logging, future extensions) see all
        -- file load/save replies without bespoke per-type call sites.
        editor.event_system:emit("ring_buffer_message", msg.type, msg)
        if msg.type == shared.MSG_FILE_LOADED then
            local orig_data = msg.ptr
            local orig_len = tonumber(msg.arg or 0)
            ---@cast orig_len integer

            log.info(
                "main",
                "file loaded from inbox",
                { len = orig_len, has_ptr = tostring(orig_data ~= nil) }
            )

            if orig_data ~= nil and orig_len > 0 then
                local psize = tonumber(ffi.C.sysconf(shared._SC_PAGESIZE))
                local orig_cap = bit.band(orig_len + psize - 1, bit.bnot(psize - 1))

                local buf = Buffer.from_mmap(orig_data, orig_len, orig_cap)
                -- Find the view waiting for this file load (file_loaded == false)
                local target_view = nil
                for _, v in ipairs(editor.views) do
                    if not v.file_loaded then
                        target_view = v
                        break
                    end
                end
                if target_view then
                    local fp = target_view.buffer:filepath()
                    target_view.buffer = buf
                    if fp then
                        buf:set_filepath(fp)
                    end
                    target_view.file_loaded = true
                    -- Activate major mode based on filepath
                    if editor._config and fp then
                        target_view:activate_mode_for_filepath(fp, editor._config)
                    end
                end
            else
                local target_view = nil
                for _, v in ipairs(editor.views) do
                    if not v.file_loaded then
                        target_view = v
                        break
                    end
                end
                if target_view then
                    target_view.file_loaded = true
                    -- Activate major mode based on filepath
                    local fp = target_view.buffer:filepath()
                    if editor._config and fp then
                        target_view:activate_mode_for_filepath(fp, editor._config)
                    end
                end
            end
        elseif msg.type == shared.MSG_FILE_ERROR then
            log.error("main", "file error", { code = msg.arg })
            -- A load that errored (IO lane couldn't open/mmap) is still
            -- "resolved" in the sense that no reply is forthcoming.
            -- Mark the FIFO-first pending view loaded so the 200ms
            -- file-load watchdog doesn't spuriously bail on an error
            -- we already surfaced. Mirrors the MSG_FILE_LOADED handler.
            for _, v in ipairs(editor.views) do
                if not v.file_loaded then
                    v.file_loaded = true
                    break
                end
            end
        elseif msg.type == shared.MSG_FILE_SAVED then
            if msg.ptr ~= nil then
                local req = ffi.cast("struct SaveRequest *", msg.ptr)
                local fp = ffi.string(req.filepath)
                -- Munmap the serialized data
                ffi.C.munmap(req.data, req.data_cap)
                -- Free the filepath and the request struct
                c.free(req.filepath)
                c.free(req)
                -- Clear dirty on the view that owns this filepath
                for _, v in ipairs(editor.views) do
                    if v.buffer:filepath() == fp then
                        v.buffer:clear_dirty()
                        break
                    end
                end
                editor.status_message = "saved"
            else
                editor.status_message = "save failed"
            end
        elseif msg.type == shared.MSG_FILE_INSERTED then
            local orig_data = msg.ptr
            local orig_len = tonumber(msg.arg or 0)
            ---@cast orig_len integer

            if orig_data ~= nil and orig_len > 0 then
                local text = ffi.string(orig_data, orig_len)
                local psize = tonumber(ffi.C.sysconf(shared._SC_PAGESIZE))
                local orig_cap = bit.band(orig_len + psize - 1, bit.bnot(psize - 1))
                ffi.C.munmap(orig_data, orig_cap)

                local view = editor:current_view()
                if view then
                    view:insert_char(text)
                    editor.status_message = "inserted " .. orig_len .. " bytes"
                end
            else
                editor.status_message = "inserted empty file"
            end
        end

        msg = ss:pop(ss._ptr.inbox_io)
    end
end

----------------------------------------------------------------------------------------------------
-- Highlight inbox drain — install span replies from the highlight lane
----------------------------------------------------------------------------------------------------

local function drain_hl_inbox(editor, ss)
    local msg = ss:pop(ss._ptr.inbox_hl)
    while msg ~= nil do
        -- Same ring-buffer producer covers the highlight lane so a single
        -- `ring_buffer_message` listener sees every cross-thread message.
        editor.event_system:emit("ring_buffer_message", msg.type, msg)
        if msg.type == shared.MSG_HL_SPANS then
            if msg.ptr ~= nil then
                local hdr = ffi.cast("struct HlSpansHdr *", msg.ptr)
                local gen = tonumber(hdr.gen)
                local bucket_start = tonumber(hdr.bucket_start)
                local bucket_end = tonumber(hdr.bucket_end)
                local count = tonumber(hdr.count)
                local name_count = tonumber(hdr.name_count)
                local raw_ptr = ffi.cast("char *", msg.ptr)
                local spans_ptr =
                    ffi.cast("struct HlSpan *", raw_ptr + ffi.sizeof("struct HlSpansHdr"))
                local names_ptr = ffi.cast(
                    "struct HlName *",
                    raw_ptr + ffi.sizeof("struct HlSpansHdr") + count * ffi.sizeof("struct HlSpan")
                )
                -- Route to the view that owns the in-flight request.
                -- Ownership follows the return value: on `true`, the
                -- view took ownership (retained in cache via ffi.gc, or
                -- freed itself on a stale/skip-install path) and we must
                -- NOT free. On `false` (no view claimed it), free here.
                local claimed = false
                for _, v in ipairs(editor.views) do
                    if v._hl_install_spans then
                        if
                            v:_hl_install_spans(
                                gen,
                                bucket_start,
                                bucket_end,
                                count,
                                msg.ptr,
                                spans_ptr,
                                name_count,
                                names_ptr
                            )
                        then
                            claimed = true
                            break
                        end
                    end
                end
                if not claimed then
                    ffi.C.free(hdr)
                end
            end
        end
        msg = ss:pop(ss._ptr.inbox_hl)
    end
end

----------------------------------------------------------------------------------------------------
-- Key processing (ported from old main.lua, adapted for View/Editor)
----------------------------------------------------------------------------------------------------

--- ESC/Alt disambiguation timeout in milliseconds.
local ESC_TIMEOUT_MS = 50

--- Wall-clock microseconds, for cursor-blink timing in the main loop.
local function now_us()
    local tv = ffi.new("struct timeval[1]")
    pffi.C.gettimeofday(tv, nil)
    return tonumber(tv[0].tv_sec) * 1000000 + tonumber(tv[0].tv_usec)
end

--- Process a key event token through the chord trie and editing logic.
---@param editor Editor
---@param view View|nil
---@param trie table root trie node
---@param key_state table accumulated key tokens
---@param key_node table current trie position
---@param token string key token from event_to_token
---@param ev any struct tb_event cdata
---@param printable_fn function|nil
---@return table key_state
---@return table key_node
---@return string|nil "quit" to exit
local function process_key(editor, view, trie, key_state, key_node, token, ev, printable_fn)
    local modified = keybind.is_modified(ev)
    local in_chord = #key_state > 0

    -- Determine if this is a printable character
    local is_printable = false
    local ch
    if ev.key == 0 and tonumber(ev.ch) >= 32 and tonumber(ev.ch) < 127 then
        local ch_code = tonumber(ev.ch)
        ---@cast ch_code integer
        ch = string.char(ch_code)
        is_printable = true
    end

    -- Read-char (one-shot) interception. If a read-char interaction
    -- is active, the next printable key (or C-g/Escape cancel) is
    -- consumed by the editor's callback. Non-printable keys (arrows,
    -- function keys, chords) are NOT consumed so the user can still
    -- move around; the read-char interaction stays pending.
    if editor:_read_char_consume(token, ch) then
        return key_state, key_node, nil
    end

    -- M-digit / M-- prefix argument interception.
    -- alt-0..alt-9 accumulate digits; alt-- sets negative.
    -- These are intercepted before the trie so they don't conflict
    -- with any bound chords.
    if token then
        local digit = token:match("^alt%-(%d)$")
        if digit then
            ---@type integer
            local d = (tonumber(digit)) --[[@as integer]]
            editor:accumulate_digit(d)
            return key_state, key_node, nil
        end
        if token == "alt--" then
            editor:set_digit_negative()
            return key_state, key_node, nil
        end
    end

    -- When M-digit/M-- accumulation is active and a non-digit command
    -- key arrives, commit the accumulated digit into universal_args,
    -- then fall through to the trie.
    -- C-g and escape cancel instead.
    if editor._digit_active then
        if token == "ctrl-g" or token == "escape" then
            editor:cancel_digit_arg()
            key_state = {}
            key_node = trie
            return key_state, key_node, nil
        end
        editor:commit_digit_arg()
        -- Fall through to feed_trie; editor.universal_args is now set
        goto feed_trie
    end

    -- Unmodified printable character with no active chord:
    -- Ask __printable whether to feed the trie or self-insert.
    -- If __printable returns true, the character is a chord participant.
    -- If false/nil, __printable already handled insertion, done.
    --
    -- When universal arg is active, printable chars always self-insert
    -- into the minibuffer (argument collector) instead.
    if not modified and not in_chord and is_printable then
        -- Self-insert is a non-kill command; reset the merge flag.
        editor._last_was_kill = false
        if editor._universal_active then
            -- Feed printable char to the minibuffer's view for self-insert
            local mb_view = editor.minibuffer.view
            mb_view:delete_selection()
            mb_view:insert_char(ch)
            return key_state, key_node, nil
        end
        if printable_fn then
            local ok, claimed = pcall(printable_fn, view, editor, ch)
            if not ok then
                log.error("main", "printable error", { error = tostring(claimed) })
                return key_state, key_node, nil
            end
            if claimed then
                -- Character is a chord participant (e.g. vim chord mode)
                goto feed_trie
            end
        end
        -- Record self-insert for kmacro (only when minibuffer is
        -- inactive — minibuffer inputs are captured separately via
        -- the _recorded_mb_inputs stack)
        if editor._recording and not (editor.minibuffer and editor.minibuffer.active) then
            editor._recorded_commands[#editor._recorded_commands + 1] =
                { name = "__printable", ch = ch, universal_args = editor.universal_args }
        end
        -- __printable handled insertion, done
        return key_state, key_node, nil
    end

    -- When universal arg is active and a chord key arrives:
    -- C-u toggles the flag; C-g/escape cancel; backspace/delete edit the
    -- minibuffer; everything else terminates and dispatches.
    if editor._universal_active then
        if token == "ctrl-u" then
            editor:toggle_universal_arg()
            return key_state, key_node, nil
        end
        if token == "ctrl-g" or token == "escape" then
            editor:cancel_universal_arg()
            key_state = {}
            key_node = trie
            return key_state, key_node, nil
        end
        -- Backspace/delete edit the argument text in the minibuffer
        if token == "backspace" then
            local mb_view = editor.minibuffer.view
            if not mb_view:delete_selection() then
                editor.minibuffer.view = mb_view
                if mb_view:p().col > 0 then
                    mb_view:delete_char(-1)
                end
            end
            return key_state, key_node, nil
        end
        -- Any other chord key terminates universal arg collection.
        -- Compute the args and store on editor for the command to read.
        editor:get_universal_args()
        -- Fall through to feed_trie; editor.universal_args is now set
    end

    ::feed_trie::
    -- Modified key, non-printable, chord participant, or any key while in a chord
    local child = key_node.children[token]
    if child == nil then
        -- No match: reset chord state, show warning
        key_state = {}
        key_node = trie
        editor.universal_args = nil
        if in_chord then
            editor.status_message = "undefined chord"
        end
    elseif child.action ~= nil then
        -- Full match: dispatch the command.
        -- If action is a string, it's a command name to resolve from
        -- the commands table. If it's a function, call it directly.
        local act = child.action
        local cmd_name
        if type(act) == "string" then
            cmd_name = act
            act = commands[cmd_name]
            if not act then
                log.error("main", "unknown command", { name = cmd_name })
                editor.status_message = "unknown command: " .. cmd_name
                key_state = {}
                key_node = trie
            end
        end

        -- Prepare consecutive-kill merge tracking.
        -- _last_was_kill reflects the previous command; clear _kill_called
        -- so push_kill can flag the current command as a kill.
        editor._kill_called = false

        if act then
            -- Pre-command hook: emit before the command function runs.
            -- Carries the command name (nil when the chord maps directly
            -- to a function) and the focused view.
            editor.event_system:emit("pre_command_hook", cmd_name, view)
            -- Save minibuffer state BEFORE the command runs, so that
            -- commands which open the minibuffer (e.g. isearch) are
            -- still recorded correctly.
            local mb_was_active_before = editor.minibuffer and editor.minibuffer.active
            -- If the function accepts varargs, unpack universal args into the
            -- call (after nil-filling any named params beyond view/editor).
            -- If no varargs, just pass view, editor — universal args are
            -- available on editor.universal_args for manual inspection.
            local info = debug.getinfo(act, "u")
            local ok, result
            if info and info.isvararg and editor.universal_args then
                local gap = math.max(0, info.nparams - 2)
                ---@type table
                local args = editor.universal_args
                if gap == 0 then
                    ---@diagnostic disable-next-line: deprecated
                    ok, result = pcall(act, view, editor, unpack(args))
                else
                    -- Fill named-param gap with nils, then universal args go to ...
                    local call_args = { view, editor }
                    for _ = 1, gap do
                        call_args[#call_args + 1] = nil
                    end
                    for i = 1, #args do
                        ---@cast args table
                        call_args[#call_args + 1] = args[i]
                    end
                    ---@diagnostic disable-next-line: deprecated
                    ok, result = pcall(act, unpack(call_args))
                end
            else
                ok, result = pcall(act, view, editor)
            end
            if not ok then
                log.error("main", "keybinding error", { error = tostring(result) })
                editor.status_message = "error: " .. tostring(result)
            end
            -- Update consecutive-kill merge state after command dispatch.
            -- If push_kill was called, this was a kill command; otherwise it wasn't.
            editor._last_was_kill = editor._kill_called
            editor._kill_called = false
            -- Record the command invocation for kmacro
            -- (skip recording/control commands themselves, and skip
            -- any command dispatched while the minibuffer was active
            -- since minibuffer inputs are captured separately via
            -- the _recorded_mb_inputs stack)
            if
                editor._recording
                and cmd_name
                and cmd_name ~= "start_kmacro"
                and cmd_name ~= "end_kmacro"
                and cmd_name ~= "run_kmacro"
                and not mb_was_active_before
            then
                editor._recorded_commands[#editor._recorded_commands + 1] =
                    { name = cmd_name, universal_args = editor.universal_args }
            end
            -- Post-command hook: emit after the command ran (whether it
            -- succeeded or errored) and after kill-merge / kmacro
            -- bookkeeping. Fires before the chord state is reset and
            -- before an early "quit" return so listeners always see the
            -- command complete.
            editor.event_system:emit("post_command_hook", cmd_name, view)
            key_state = {}
            key_node = trie
            if result == "quit" then
                return key_state, key_node, "quit"
            end
        end
    elseif next(child.children) ~= nil then
        -- Prefix match: accumulate
        key_state[#key_state + 1] = token
        key_node = child
    else
        -- Leaf with no action (shouldn't happen, but reset)
        key_state = {}
        key_node = trie
    end

    return key_state, key_node, nil
end

----------------------------------------------------------------------------------------------------
-- Main
----------------------------------------------------------------------------------------------------

-- Catch SIGSEGV/SIGBUS so we can restore the terminal and log before dying
local SIGSEGV = 11
local SIGBUS = 7
ffi.C.signal(SIGSEGV, function(signum)
    log.error("main", "caught signal", { signal = tonumber(signum) })
    ffi.C.tb_shutdown()
    os.exit(128 + tonumber(signum))
end)
ffi.C.signal(SIGBUS, function(signum)
    log.error("main", "caught signal", { signal = tonumber(signum) })
    ffi.C.tb_shutdown()
    os.exit(128 + tonumber(signum))
end)

local function main()
    -- Configure logging
    log.configure({ level = "info", output = "/tmp/cursed.log" })
    log.info("main", "starting")

    local term, err = tb.Term.new()
    if not term then
        log.error("main", "terminal init failed", { error = err or "unknown" })
        io.stderr:write(
            ("cursed: failed to initialize terminal: %s\n"):format(err or "unknown error")
        )
        return 1
    end
    log.info("main", "terminal initialized")

    -- Truecolor / 256-color output mode + scheme loading.
    -- Probe the terminal's capability; fall back: 256 → normal (8-color).
    -- The active ColorScheme is captured in 0xRRGGBB (truecolor) or
    -- already-quantized 256-index form, matching the chosen mode.
    local output_mode = tb.output_normal
    local truecolor = false
    if term:has_truecolor() then
        output_mode = tb.output_truecolor
        truecolor = true
    else
        -- Fall back to 256-color for the best non-truecolor fidelity.
        output_mode = tb.output_256
        truecolor = false
    end
    term:set_output_mode(output_mode)
    log.info("main", "output mode set", {
        mode = output_mode,
        truecolor = truecolor,
    })

    -- Load the configured scheme file. The path resolves:
    --   1. config.colorscheme if it's an absolute path → that file
    --   2. config.colorscheme (a name) → <config_dir>/cursed/themes/<name>{.yaml,.toml}
    --   3. missing/unreadable → built-in gruvbox-dark-medium fallback
    -- We do the path resolution here AFTER Config.load() below; for
    -- now, stash the output-mode decision so the loader can quantize.
    -- (The actual scheme load happens post-config; see below.)

    -- Use INPUT_ESC so standalone Escape is delivered as key=27.
    term:set_input_mode(bit.bor(tb.input_esc, tb.input_mouse))

    local editor = Editor.new(term)
    -- Expose the editor as a process-global so user code (init.lua, M-:,
    -- user mode files) can reach it directly — e.g. register
    -- `editor.event_system` listeners. This is the Emacs-philosophy move:
    -- `~/.emacs` runs against the live Lisp image, not a sandbox; here
    -- init.lua runs against the live editor. See `cursed.config` for the
    -- unsandboxed loader.
    _G.editor = editor
    log.info("main", "editor created")

    local ok, empty_buf = pcall(Buffer.new)
    if not ok then
        log.error("main", "buffer creation failed", { error = tostring(empty_buf) })
        return 1
    end
    log.info("main", "buffer created")

    local view = View.new(empty_buf)
    editor:add_view(view)
    log.info("main", "initial view created")

    log.info("main", "loading config and keybindings")
    local config = Config.load()
    local trie, printable_fn, base_keybindings, chord_for_command = build_keybind_trie(config)
    editor._base_trie = trie
    editor._active_trie = trie
    editor._base_keybindings = base_keybindings
    editor._chord_for_command = chord_for_command
    editor._printable_fn = printable_fn
    editor._config = config
    log.info("main", "config and keybindings loaded")

    -- Resolve the colorscheme path now that config is loaded.
    -- The lookup logic lives in ColorScheme.resolve_path/list_names so
    -- the `load-theme` command shares the same search dirs at runtime.
    local xdg_cursed = ColorScheme.config_dir()
    -- Stash the user's concept→slot overrides on the module so every
    -- scheme load (startup AND live load-theme switches) honors them:
    -- e.g. concept_slots = { keyword = "base0D", modeline_bg = "base02" }
    ColorScheme.config_overrides = config.concept_slots
    local scheme_setting = config.colorscheme
    local scheme_path = ColorScheme.resolve_path(scheme_setting, xdg_cursed)
    local scheme = ColorScheme.load(scheme_path, truecolor)
    -- Expose the active scheme globally so the highlighter can resolve
    -- capture names. The highlighter reads `require("cursed.colorscheme").active`.
    ColorScheme.active = scheme
    log.info("main", "scheme loaded", {
        name = scheme.name,
        truecolor = scheme.truecolor,
        path = scheme_path or "(built-in)",
    })

    -- Register toggle commands for each major mode
    for mode_name, template in pairs(config.modes) do
        local cmd_name = mode_name .. "-mode"
        commands[cmd_name] = function(view, editor)
            if view:has_major_mode(template) then
                view:deactivate_major_mode(template)
                editor.status_message = mode_name .. "-mode deactivated"
            else
                view:activate_major_mode(template)
                editor.status_message = mode_name .. "-mode activated"
            end
        end
    end

    local ss = shared.SharedState.from_global()

    -- Expose the inbox_hl drain as an editor method so views can
    -- synchronously drain lane responses inline (the zero-flash
    -- sync-wait path in View:_hl_wait_response). The closure captures
    -- `editor` and `ss` from this scope.
    editor.drain_hl_inbox = function()
        drain_hl_inbox(editor, ss)
    end

    -- ------------------------------------------------------------------
    -- Central event system: default consumers.
    --
    -- Producer call sites (pre/post-command-hook, ring_buffer_message,
    -- mode_enter/mode_exit) live across main.lua and view.lua. All
    -- editor-lifetime DEFAULT consumers are registered in one place —
    -- `cursed.editor_listeners` — so there's a single home for the
    -- next listener and a single place to audit what observes the hub.
    -- Production extensions and major modes register their own
    -- listeners on `editor.event_system` independently (e.g. from
    -- `init.lua` against the global editor).
    -- ------------------------------------------------------------------
    require("cursed.editor_listeners").setup(editor)

    -- Request file load(s) from IO lane. Every file given on the
    -- command line is opened in its own View/Buffer; views are added
    -- in arg order and MSG_FILE_LOAD pushed in the same order so the
    -- FIFO MSG_FILE_LOADED handler in drain_inbox matches each reply
    -- to the right view (it picks the first `not file_loaded` view).
    -- The already-created initial `view` is reused for arg[1]; further
    -- args get fresh Buffer+View pairs.
    local first_file_view_index = nil
    local arg_count = 0
    if arg then
        for i = 1, #arg do
            if type(arg[i]) == "string" then
                arg_count = arg_count + 1
            end
        end
    end

    if arg_count == 0 then
        -- No file given on the command line: open a random temporary
        -- text file so the user edits a real on-disk file they can save.
        -- os.tmpname() returns a unique path without creating it; we
        -- create it empty and load it through the normal IO lane so the
        -- watchdog arms/clears like any other file (it loads instantly).
        local tmp_path = os.tmpname() .. ".txt"
        local nf = io.open(tmp_path, "wb")
        if nf then
            nf:close()
        end
        view.buffer:set_filepath(tmp_path)
        ss:push(ss._ptr.outbox_io, { type = shared.MSG_FILE_LOAD, ptr = tmp_path })
        log.info("main", "no file; opened temp", { path = tmp_path })
        log.info("main", "pushing FILE_LOAD", { path = tmp_path })
    else
        local arg_seen = 0
        for i = 1, #arg do
            local filepath = arg[i]
            if type(filepath) == "string" then
                arg_seen = arg_seen + 1
                -- Reuse the initial view for the first file; create a
                -- new Buffer+View for each subsequent file.
                local cur_view
                if arg_seen == 1 then
                    cur_view = view
                    first_file_view_index = 1
                else
                    local ok_nb, nb = pcall(Buffer.new)
                    if not ok_nb then
                        log.error("main", "buffer creation failed for cli arg", {
                            arg = filepath,
                            error = tostring(nb),
                        })
                        -- Skip this arg on failure; can't host a view.
                        goto next_arg
                    end
                    cur_view = View.new(nb)
                    editor:add_view(cur_view)
                    first_file_view_index = first_file_view_index or 1
                end

                -- Expand ~ and $ENV so the IO lane opens the real path,
                -- and so missing-file creation targets the right location.
                local expanded = find_file.expand_path(filepath)

                if find_file.is_directory(expanded) then
                    editor.status_message = "cannot open directory: " .. filepath
                    cur_view.file_loaded = true
                    log.info("main", "cli path is a directory", { path = filepath })
                else
                    -- If the file doesn't exist, create an empty one so
                    -- the IO lane's io.open succeeding mirrors `touch`.
                    -- On failure we fall through and let MSG_FILE_LOAD
                    -- surface the error.
                    local f = io.open(expanded, "rb")
                    if f == nil then
                        local ok_cre, err_cre = pcall(function()
                            local nf = io.open(expanded, "wb")
                            if nf then
                                nf:close()
                            else
                                error("could not create file", 0)
                            end
                        end)
                        if ok_cre then
                            log.info("main", "created missing file", { path = expanded })
                        else
                            log.error("main", "could not create missing file", {
                                path = expanded,
                                error = tostring(err_cre),
                            })
                        end
                    else
                        f:close()
                    end

                    cur_view.buffer:set_filepath(expanded)
                    ss:push(ss._ptr.outbox_io, { type = shared.MSG_FILE_LOAD, ptr = expanded })
                    log.info("main", "pushing FILE_LOAD", { path = expanded })
                end

                ::next_arg::
            end
        end

        -- add_view activates the newest view, so after opening several
        -- files the focus would rest on the last one. Reset to the
        -- first file's view to match user expectation (first arg active).
        if first_file_view_index then
            editor:set_active_view(first_file_view_index)
        end
    end

    -- File-load watchdog: if any view is still awaiting its initial
    -- load reply from the IO lane, set a 200ms deadline. Exceeding it
    -- bails out of the program (the load is hung — e.g. on a stale NFS
    -- mount). Cleared to nil once all views report file_loaded. The
    -- no-file case now opens a temp file, so this arms and clears on
    -- the (instant) local load; directory args pre-mark their view
    -- loaded and so never arm it.
    local load_deadline_us ---@type integer|nil microseconds; nil = no pending load
    for _, v in ipairs(editor.views) do
        if not v.file_loaded then
            load_deadline_us = now_us() + 200000 -- 200ms
            break
        end
    end
    if load_deadline_us then
        log.info("main", "file-load watchdog armed", { deadline_us = load_deadline_us })
    end

    -- Key chord state machine
    local key_state = {} -- accumulated key tokens for current chord
    local key_node = editor._active_trie -- current position in the trie

    -- Set up the central kqueue for the main lane. This merges:
    --   - termbox resize fd     (EVFILT_READ — SIGWINCH)
    --   - inbox_io wake ident   (EVFILT_USER — IO lane signals us)
    --
    -- Note: macOS /dev/tty does not support kqueue EVFILT_READ, so we
    -- can't watch the tty fd on the kqueue. Instead, we select() on
    -- (ttyfd, kqueue_fd) — the kqueue fd becomes readable when it has
    -- events pending. This gives us a single blocking primitive that
    -- handles both tty input and kqueue-delivered events.
    --
    -- We use select() instead of poll() because macOS poll() has broken
    -- behavior on /dev/tty (spurious POLLNVAL / persistent POLLIN).
    local ttyfd, resizefd = term:get_fds()
    local main_kq = Kqueue.wrap(ss._ptr.main_kq_fd)
    main_kq:add_fd(resizefd)
    main_kq:add_wake(assert(tonumber(ss._ptr.inbox_io.wake_ident)))
    main_kq:add_wake(assert(tonumber(ss._ptr.inbox_hl.wake_ident)))

    local kq_fd = tonumber(ss._ptr.main_kq_fd)

    -- Self-pipe for waking select() from request_quit().
    -- select() can't detect kqueue EVFILT_USER triggers on the kqueue fd
    -- (readability only appears after kevent() consumes events), so we
    -- use a plain pipe that select() can reliably watch.
    local wake_pipe = ffi.new("int[2]")
    pffi.C.pipe(wake_pipe)
    local wake_pipe_r = assert(tonumber(wake_pipe[0]), "pipe() failed")
    local wake_pipe_w = assert(tonumber(wake_pipe[1]), "pipe() failed")
    ---@cast wake_pipe_r integer
    ---@cast wake_pipe_w integer

    -- Wire up editor's wake-main callback so request_quit() can
    -- break out of select() without waiting for another keypress.
    editor._wake_main = function()
        local one = ffi.new("uint8_t[1]", 1)
        pffi.C.write(wake_pipe_w, one, 1)
    end

    log.info("main", "kqueue setup", {
        kq_fd = kq_fd,
        ttyfd = ttyfd,
        resizefd = resizefd,
        wake_pipe_r = wake_pipe_r,
        wake_pipe_w = wake_pipe_w,
    })

    -- select() on (ttyfd, kqueue_fd, wake_pipe_r)
    -- Pre-allocate fd_set buffer; we zero and re-fill each iteration.
    -- FD_SETSIZE on macOS is 1024 → 128 bytes is sufficient.
    local readfds = pffi.fd_set_new()
    ---@diagnostic disable-next-line: param-type-mismatch
    local maxfd = math.max(ttyfd, math.max(kq_fd, wake_pipe_r)) + 1

    -- Initial render (empty buffer; file load event will wake us via kq)
    editor:render()
    editor:tick_blink() -- initialize blink deadline before the loop
    log.info("main", "entering main loop")

    -- Exit code returned from main(). Set to nonzero by the file-load
    -- watchdog if a load exceeds 200ms. Routed through the normal
    -- loop-exit path so term:shutdown() always restores the terminal.
    local exit_code = 0

    -- Main loop: select(ttyfd, kq_fd, wake_pipe_r), then dispatch
    while ss:running() do
        -- Zero and rebuild fd_set each iteration (select mutates it)
        ffi.fill(readfds, 128, 0)
        pffi.fd_set_set(readfds, ttyfd)
        pffi.fd_set_set(readfds, kq_fd)
        pffi.fd_set_set(readfds, wake_pipe_r)

        -- select() timeout. We always wake by the next cursor-blink
        -- toggle so the drawn caret can blink even while fully idle,
        -- and otherwise honour background-task / chord deadlines.
        local now = now_us()
        local deadline
        if #editor._background_tasks > 0 then
            deadline = now
        elseif #key_state > 0 then
            -- In a chord (e.g. C-x waiting for next key): use a short
            -- timeout so we don't block indefinitely between the two
            -- key events. Terminals may deliver them in separate writes.
            deadline = now + 100000 -- 100ms
        end
        if editor._blink_next_us ~= 0 then
            if deadline == nil or editor._blink_next_us < deadline then
                deadline = editor._blink_next_us
            end
        end
        -- File-load watchdog: while any view is still awaiting its
        -- initial load reply, also bound select() by the 200ms watchdog
        -- deadline so we wake in time to bail (or to clear it once the
        -- load resolves).
        if load_deadline_us ~= nil then
            if deadline == nil or load_deadline_us < deadline then
                deadline = load_deadline_us
            end
        end
        local tv
        if deadline == nil then
            tv = nil -- block indefinitely
        else
            local wait_us = deadline - now
            if wait_us < 0 then
                wait_us = 0
            end
            tv = ffi.new("struct timeval", 0, wait_us)
        end

        local select_rv = pffi.C.select(maxfd, readfds, nil, nil, tv)

        -- Drain any pending kqueue events (non-blocking)
        if select_rv > 0 and pffi.fd_set_isset(readfds, kq_fd) then
            local events, n = main_kq:wait(0)
            for i = 0, n - 1 do
                local ev = events[i]
                if tonumber(ev.filter) == kq_ffi.EVFILT_USER then
                    -- inbox_io (ident 1) carries file load/save replies;
                    -- inbox_hl (ident 2) carries highlight span replies.
                    if tonumber(ev.ident) == tonumber(ss._ptr.inbox_hl.wake_ident) then
                        drain_hl_inbox(editor, ss)
                    else
                        drain_inbox(editor, ss)
                    end
                end
            end
        end

        -- Drain wake pipe (self-pipe trick for request_quit)
        if select_rv > 0 and pffi.fd_set_isset(readfds, wake_pipe_r) then
            local drain_buf = ffi.new("uint8_t[32]")
            pffi.C.read(wake_pipe_r, drain_buf, 32)
        end

        -- Unconditionally attempt a non-blocking inbox drain. macOS
        -- select() does NOT reliably report kqueue-fd readability for
        -- EVFILT_USER triggers (the same race request_quit works around
        -- with a self-pipe), so a file-load reply pushed by the IO lane
        -- before main entered select() can go undelivered until the 200ms
        -- watchdog deadline — causing a spurious bail. ss:pop is safe to
        -- call when the ring is empty, so draining here every iteration
        -- closes the race without depending on select/kevent signalling.
        drain_inbox(editor, ss)
        drain_hl_inbox(editor, ss)

        -- File-load watchdog: re-check pending loads after the inbox
        -- drain above (a MSG_FILE_LOADED/MSG_FILE_ERROR may have just
        -- resolved a view). If everything is loaded now, clear the
        -- watchdog so it never fires spuriously post-startup. If a load
        -- is still pending past the 200ms deadline, bail out cleanly.
        if load_deadline_us ~= nil then
            local any_pending = false
            for _, v in ipairs(editor.views) do
                if not v.file_loaded then
                    any_pending = true
                    break
                end
            end
            if not any_pending then
                load_deadline_us = nil
                log.info("main", "file-load watchdog cleared (all views loaded)")
            elseif now_us() >= load_deadline_us then
                io.stderr:write("cursed: file load timed out after 200ms; aborting\n")
                log.error("main", "file load timeout")
                exit_code = 2
                break
            end
        end

        -- Process all buffered termbox events.
        -- termbox2 reads from the tty in one read() call and buffers
        -- events internally (global.in bytebuf). After select() returns
        -- for the first event, subsequent events may already be in
        -- termbox2's buffer but NOT on the tty fd — so select() would
        -- block. We drain all pending events here.
        --
        -- After the minibuffer closes (submit/cancel), continue
        -- draining events. The Enter/Tab that submitted the minibuffer
        -- was already consumed by the trie dispatch, so it won't
        -- leak into the main view.
        local mb_was_active = editor.minibuffer and editor.minibuffer.active
        local had_input = false
        repeat
            mb_was_active = editor.minibuffer and editor.minibuffer.active
            local ev = term:peek_event(0)
            if ev == nil then
                break
            end
            had_input = true

            local view_cur = editor:current_view()
            local focused_view = editor:focused_view()

            if ev.type == tb.event_key then
                local key = tonumber(ev.key)
                local mod = tonumber(ev.mod)
                local ch_val = tonumber(ev.ch)

                -- If the minibuffer just closed (auto_accept), stale
                -- Enter/Tab events from the terminal may still arrive
                -- in a later select() cycle. Consume them here before
                -- they reach process_key and dispatch as newline/indent.
                -- Flag _just_closed: count of stale events to suppress.
                -- After auto_accept, both Tab and Enter may arrive —
                -- we need to consume both.
                local stale_count = editor._mb_just_closed
                    or (editor.minibuffer and editor.minibuffer._just_closed)
                    or 0
                if stale_count > 0 and mod == 2 and (key == 13 or key == 9) then
                    -- Decrement the counter
                    if editor.minibuffer and editor.minibuffer._just_closed then
                        editor.minibuffer._just_closed = editor.minibuffer._just_closed - 1
                        if editor.minibuffer._just_closed <= 0 then
                            editor.minibuffer._just_closed = nil
                        end
                    end
                    if editor._mb_just_closed then
                        editor._mb_just_closed = editor._mb_just_closed - 1
                        if editor._mb_just_closed <= 0 then
                            editor._mb_just_closed = nil
                        end
                    end
                    goto continue_drain
                end
                -- Any other key clears the stale-event flags
                editor._mb_just_closed = nil
                if editor.minibuffer then
                    editor.minibuffer._just_closed = nil
                end

                editor.status_message = nil -- clear transient status
                editor._eval_result = nil -- clear eval result

                -- If the active trie was rebuilt (mode change), reset chord state
                if editor._trie_changed then
                    key_state = {}
                    key_node = editor._active_trie
                    editor._trie_changed = nil
                end

                -- ESC/Alt disambiguation
                if key == 27 and mod == 0 then
                    local follow = term:peek_event(ESC_TIMEOUT_MS)
                    if follow and follow.type == tb.event_key then
                        -- Alt+key: add ALT mod and process
                        follow.mod = bit.bor(tonumber(follow.mod), tb.mod_alt)
                        local token = keybind.event_to_token(follow)
                        if token ~= nil then
                            local new_state, new_node, quit = process_key(
                                editor,
                                focused_view,
                                editor._active_trie,
                                key_state,
                                key_node,
                                token,
                                follow,
                                editor._printable_fn
                            )
                            key_state = new_state
                            key_node = new_node
                            if quit then
                                editor:request_quit()
                                break
                            end
                        end
                    else
                        -- Standalone Escape
                        local new_state, new_node, quit = process_key(
                            editor,
                            focused_view,
                            editor._active_trie,
                            key_state,
                            key_node,
                            "escape",
                            ev,
                            editor._printable_fn
                        )
                        key_state = new_state
                        key_node = new_node
                        if quit then
                            editor:request_quit()
                            break
                        end
                    end
                else
                    local token = keybind.event_to_token(ev)
                    if token ~= nil then
                        local new_state, new_node, quit = process_key(
                            editor,
                            focused_view,
                            editor._active_trie,
                            key_state,
                            key_node,
                            token,
                            ev,
                            editor._printable_fn
                        )
                        key_state = new_state
                        key_node = new_node
                        if quit then
                            editor:request_quit()
                            break
                        end
                    end
                end
            elseif ev.type == tb.event_mouse then
                if view_cur and view_cur.file_loaded then
                    local key = tonumber(ev.key)
                    local mx = tonumber(ev.x)
                    local my = tonumber(ev.y)

                    if key == tb.key_mouse_left then
                        local mod = tonumber(ev.mod)
                        local gw = math.max(3, #tostring(view_cur:line_count()) + 1)
                        local line, col
                        if mx >= gw then
                            -- Convert click x/y to logical line + sub-col
                            local cli, sub_row = view_cur:screen_row_to_line(view_cur.scroll_y + my)
                            line = math.min(cli, view_cur:line_count() - 1)
                            local sub_col = mx - gw
                            local byte_off = view_cur:wrap_byte_offset(line, sub_row, sub_col)
                            col = math.min(byte_off, view_cur:content_len(line))
                        else
                            local cli, _ = view_cur:screen_row_to_line(view_cur.scroll_y + my)
                            line = math.min(cli, view_cur:line_count() - 1)
                            col = 0
                        end
                        ---@cast line integer
                        ---@cast col integer
                        if mod and bit.band(mod, tb.mod_alt) ~= 0 then
                            -- Alt-click: add a cursor at the click point.
                            view_cur:add_cursor(line, col)
                        else
                            -- Plain click: replace cursors with a single one.
                            view_cur:set_single_cursor(line, col)
                        end
                        view_cur:_set_goal_col(view_cur:p().col)
                    elseif key == tb.key_mouse_wheel_up then
                        local text_rows = term:height() - editor:footer_rows()
                        view_cur:scroll_viewport(-3, text_rows)
                    elseif key == tb.key_mouse_wheel_down then
                        local text_rows = term:height() - editor:footer_rows()
                        view_cur:scroll_viewport(3, text_rows)
                    end
                end
            end
            ::continue_drain::
        until editor._quit_requested or #key_state == 0
        -- When in a chord (prefix matched), stop draining — we need
        -- select() to wait for the next key with a timeout, in case
        -- it hasn't arrived on the tty yet. When quit was requested
        -- or the chord completed, we stop too.

        if editor._quit_requested then
            break
        end

        -- Always clear universal args after command dispatch.
        -- Commands that need them should read during execution;
        -- after this point they're consumed.
        editor.universal_args = nil

        -- Fire minibuffer on_change (e.g. isearch live update)
        editor:minibuffer_notify_change()

        -- Process one step of a single background task (round-robin)
        editor:tick_background_tasks()

        -- Advance the cursor blink timer. On input, reset to "on" first
        -- so the caret stays solid while actively typing; on idle
        -- (select woke on the blink deadline) the phase toggles here.
        if had_input then
            editor:reset_blink()
        end
        editor:tick_blink()

        -- Update view and render only after processing input/wake
        local cur_view = editor:current_view()
        if cur_view then
            cur_view:scroll_to_cursor(term:height() - (editor:footer_rows() - 1))
        end
        editor:render()
    end

    term:shutdown()
    ss:stop()

    return exit_code
end

-- main.lua is loaded via lua_pcall(L, 0, 1, ...) in main.c, so only the
-- FIRST return value here is observed. xpcall returns (ok, retval); on
-- success surface main()'s actual exit code (e.g. 2 on file-load
-- timeout). On an unhandled error, the handler restores the terminal
-- and exits 1 before xpcall can return, so `ok` is effectively always
-- true here — `ok and rc or 1` is just defensive.
local ok, rc = xpcall(main, function(err)
    log.error("main", "unhandled error", { error = tostring(err) })
    pcall(function()
        ffi.C.g_shared_state.running = false
    end)
    pcall(function()
        ffi.C.tb_shutdown()
    end)
    io.stderr:write(tostring(err) .. "\n")
    os.exit(1)
end)
return ok and rc or 1
