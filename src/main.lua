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

--- Prime the editor's base keybindings from the defaults table.
--- Separates the __printable handler and stores the base bindings,
--- then rebuilds the base trie. Called BEFORE Config.load() so that
--- init.lua (and any `editor:global_set_key` it issues) operates on a
--- fully-initialized editor and is applied for real rather than
--- clobbered by a later trie build. The returned `config.keybindings`
--- table is applied on top via `editor:global_set_key` after load.
---@param editor Editor the editor to prime
local function prime_default_keybindings(editor)
    local defaults = require("cursed.default_keybindings")
    local bindings = {}
    local printable_fn ---@type function?
    for chord, func in pairs(defaults) do
        if chord == "__printable" then
            ---@cast func function
            printable_fn = func
        else
            bindings[chord] = func
        end
    end
    editor._base_keybindings = bindings
    editor._printable_fn = printable_fn
    editor:rebuild_base_trie()
    editor._active_trie = editor._base_trie
    editor._chord_for_command = keybind.build_chord_for_command(bindings)
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
                local bench = require("cursed.bench")
                local psize = tonumber(ffi.C.sysconf(shared._SC_PAGESIZE))
                local orig_cap = bit.band(orig_len + psize - 1, bit.bnot(psize - 1))

                local t_mmap = bench.now_us()
                local buf = Buffer.from_mmap(orig_data, orig_len, orig_cap)
                bench.span("main", "file_open build_lines", t_mmap, { len = orig_len })
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
                    target_view:set_buffer(buf, { loaded = true })
                    if fp then
                        buf:set_filepath(fp)
                    end
                    target_view.file_loaded = true
                    -- Activate major mode based on filepath
                    local t_mode = bench.now_us()
                    if editor._config and fp then
                        target_view:activate_mode_for_filepath(fp, editor._config)
                    end
                    bench.span("main", "file_open activate_mode", t_mode, { path = fp })
                    editor.event_system:emit("file_loaded", target_view, buf)
                    -- Total wall time from Editor:open_file() to here
                    if target_view._bench_open_t0 then
                        bench.span(
                            "main",
                            "file_open TOTAL",
                            target_view._bench_open_t0,
                            { path = fp, len = orig_len }
                        )
                        target_view._bench_open_t0 = nil
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
                    local bench = require("cursed.bench")
                    target_view.file_loaded = true
                    -- Activate major mode based on filepath
                    local fp = target_view.buffer:filepath()
                    local t_mode = bench.now_us()
                    if editor._config and fp then
                        target_view:activate_mode_for_filepath(fp, editor._config)
                    end
                    bench.span("main", "file_open activate_mode", t_mode, { path = fp })
                    -- The (possibly empty) file is now "opened" even
                    -- though no content buffer was swapped in.
                    editor.event_system:emit("buffer_open", target_view.buffer, target_view)
                    editor.event_system:emit("file_loaded", target_view, target_view.buffer)
                    if target_view._bench_open_t0 then
                        bench.span(
                            "main",
                            "file_open TOTAL (empty)",
                            target_view._bench_open_t0,
                            { path = fp }
                        )
                        target_view._bench_open_t0 = nil
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
                    v._bench_open_t0 = nil
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
                        editor.event_system:emit("buffer_saved", v.buffer, v)
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
                local ef = io.open("/tmp/cursed_err.log", "a")
                if ef then
                    ef:write("=== keybinding error " .. os.date() .. " ===\n")
                    ef:write(tostring(result) .. "\n")
                    ef:write(debug.traceback("", 2) .. "\n")
                    ef:close()
                end
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
    -- Prime default keybindings on the editor BEFORE Config.load() so
    -- init.lua (and any `editor:global_set_key` it issues) runs against
    -- a fully-initialized editor and is applied for real rather than
    -- clobbered by a later trie build.
    prime_default_keybindings(editor)
    local config = Config.load()
    editor._config = config
    -- Apply init.lua's returned `keybindings` table on top via the same
    -- live path (`__printable` override handled there too).
    for chord, action in pairs(config.keybindings) do
        editor:global_set_key(chord, action)
    end
    -- Margin: global config applied to every view at load. The initial
    -- view is added before config loads, so backfill it here; views
    -- added later (find-file, etc.) inherit via Editor:add_view.
    editor.margin = config.margin
    for _, v in ipairs(editor.views) do
        v.margin = config.margin
    end
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

    -- Register the inbox EVFILT_USER wakes BEFORE any MSG_FILE_LOAD is
    -- pushed. The IO lane replies in well under a millisecond and
    -- triggers EVFILT_USER on this kq; if the filter isn't registered
    -- yet, the trigger is dropped and select() won't wake until the
    -- 200ms watchdog — i.e. the "Loading..." flash. Registering early
    -- makes main(kq_fd) readable the instant the reply arrives, so
    -- select() returns immediately. (resizefd is added later, once
    -- termbox is up; it has no ordering dependency.)
    local main_kq = Kqueue.wrap(ss._ptr.main_kq_fd)
    main_kq:add_wake(assert(tonumber(ss._ptr.inbox_io.wake_ident)))
    main_kq:add_wake(assert(tonumber(ss._ptr.inbox_hl.wake_ident)))

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

    -- Announce editor readiness. Fires AFTER init.lua (config.load, run
    -- above) and default listeners are registered, so both user and
    -- built-in `editor.event_system:on("editor_open", ...)` handlers
    -- observe it. NOTE: the initial empty view's view_open fires earlier
    -- (during Editor setup, before init.lua) and so is not observable by
    -- init.lua listeners — hook editor_open (or iterate editor.views
    -- there) for "on startup, walk every existing view" needs.
    editor.event_system:emit("editor_open")

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
        view._bench_open_t0 = require("cursed.bench").now_us()
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
                    cur_view._bench_open_t0 = require("cursed.bench").now_us()
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
    -- load reply from the IO lane, schedule a 200ms timer. Exceeding it
    -- bails out of the program (the load is hung — e.g. on a stale NFS
    -- mount). Cancelled once all views report file_loaded. The no-file
    -- case now opens a temp file, so this arms and clears on the
    -- (instant) local load; directory args pre-mark their view loaded
    -- and so never arm it.
    local load_watchdog_task = nil
    for _, v in ipairs(editor.views) do
        if not v.file_loaded then
            load_watchdog_task = editor:schedule_after(200000, function()
                local any_pending = false
                for _, vv in ipairs(editor.views) do
                    if not vv.file_loaded then
                        any_pending = true
                        break
                    end
                end
                if not any_pending then
                    return true
                end
                io.stderr:write("cursed: file load timed out after 200ms; aborting\n")
                log.error("main", "file load timeout")
                editor._exit_code = 2
                editor:request_quit()
                return true
            end)
            log.info("main", "file-load watchdog armed", { delay_us = 200000 })
            break
        end
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
    main_kq:add_fd(resizefd)

    local kq_fd = tonumber(ss._ptr.main_kq_fd)

    -- Self-pipe for waking select() from request_quit(). select() DOES
    -- reliably watch the kqueue fd, but request_quit() wants a wake
    -- primitive it can fire from arbitrary call sites (incl. async/signalled
    -- contexts where calling kevent() directly would be unsafe); a plain
    -- pipe write is async-signal-safe, so we route quit wakes through it.
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

    -- True while the left mouse button is held after a press, so motion
    -- events extend the selection instead of relocating the cursor.
    local mouse_drag = false
    -- Handle for the chord-timeout background task, cancelled once the
    -- chord resolves.
    local chord_timeout_task = nil

    -- Initial render (empty buffer; file load event will wake us via kq)
    editor:render()
    editor:schedule_blink() -- start the periodic blink timer
    log.info("main", "entering main loop")

    -- Main loop: select(ttyfd, kq_fd, wake_pipe_r), then dispatch
    while ss:running() do
        -- Zero and rebuild fd_set each iteration (select mutates it)
        ffi.fill(readfds, 128, 0)
        pffi.fd_set_set(readfds, ttyfd)
        pffi.fd_set_set(readfds, kq_fd)
        pffi.fd_set_set(readfds, wake_pipe_r)

        -- select() timeout. Background tasks now carry their own
        -- deadlines; the editor returns the earliest one so we always
        -- wake in time for timers (blink, chord timeout, load watchdog)
        -- without bespoke deadline math here.
        local now = now_us()
        local deadline = editor:next_task_deadline()
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

        -- Eager non-blocking inbox drain. select() reliably wakes on the
        -- main kq_fd when an EVFILT_USER trigger fires (the inbox wakes are
        -- registered before any MSG_FILE_LOAD is pushed, so no trigger is
        -- ever dropped). This unconditional drain is defense-in-depth: it
        -- shaves one loop-iteration of latency off a reply that lands in
        -- the brief window between select() returning (e.g. for tty input)
        -- and the kq event being consumed, and tolerates any future
        -- change to the wake registration ordering. ss:pop is a no-op on
        -- an empty ring, so this is cheap.
        drain_inbox(editor, ss)
        drain_hl_inbox(editor, ss)

        -- File-load watchdog: re-check pending loads after the inbox
        -- drain above (a MSG_FILE_LOADED/MSG_FILE_ERROR may have just
        -- resolved a view). If everything is loaded now, cancel the
        -- watchdog task so it never fires spuriously post-startup.
        if load_watchdog_task ~= nil then
            local any_pending = false
            for _, v in ipairs(editor.views) do
                if not v.file_loaded then
                    any_pending = true
                    break
                end
            end
            if not any_pending then
                editor:cancel_task(load_watchdog_task)
                load_watchdog_task = nil
                log.info("main", "file-load watchdog cleared (all views loaded)")
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

                    -- Map a mouse (mx,my) to a buffer (line,col) using the
                    -- same centered geometry Editor:render paints, so clicks
                    -- land under the rendered glyph regardless of margin.
                    local function mouse_to_pos()
                        local w = term:width()
                        local _, text_x = view_cur:text_geometry(w)
                        local cli, sub_row = view_cur:screen_row_to_line(view_cur.scroll_y + my)
                        local line = math.min(cli, view_cur:line_count() - 1)
                        local col
                        if mx >= text_x then
                            local sub_col = mx - text_x
                            local byte_off = view_cur:wrap_byte_offset(line, sub_row, sub_col)
                            col = math.min(byte_off, view_cur:content_len(line))
                        else
                            -- Gutter or left of the centered block: col 0.
                            col = 0
                        end
                        return line, col
                    end

                    if key == tb.key_mouse_left then
                        local mod = tonumber(ev.mod) or 0
                        local is_motion = bit.band(mod, tb.mod_motion) ~= 0
                        local line, col = mouse_to_pos()
                        ---@cast line integer
                        ---@cast col integer
                        if is_motion then
                            -- Drag (button held + motion): extend the
                            -- selection by moving the primary cursor; the
                            -- mark set on press stays anchored at the drag
                            -- start. Ignored when no press began a drag
                            -- (e.g. motion while Alt was held), so motion
                            -- events never spawn extra cursors.
                            if mouse_drag then
                                local c = view_cur:p()
                                c.line = line
                                c.col = col
                                view_cur:_clamp_cursor(c)
                                view_cur:_set_goal_col(c.col)
                            end
                        elseif mod and bit.band(mod, tb.mod_alt) ~= 0 then
                            -- Alt-click press: add a cursor at the click
                            -- point. (Alt-drag is not specially handled.)
                            view_cur:add_cursor(line, col)
                            view_cur:_set_goal_col(view_cur:p().col)
                        else
                            -- Press (start of a potential drag): place a
                            -- single cursor and drop a mark at the same
                            -- spot so an empty selection is ready. If the
                            -- user doesn't drag, the release clears it so a
                            -- plain click leaves no selection.
                            view_cur:set_single_cursor(line, col)
                            view_cur:set_mark()
                            mouse_drag = true
                            view_cur:_set_goal_col(view_cur:p().col)
                        end
                    elseif key == tb.key_mouse_release then
                        -- End of a drag (or a plain click with no drag).
                        -- A click that never moved leaves an empty
                        -- selection (anchor == cursor); clear the mark so a
                        -- plain click behaves as simple cursor placement.
                        if mouse_drag then
                            local c = view_cur:p()
                            if c.anchor_line == c.line and c.anchor_col == c.col then
                                view_cur:unset_mark()
                            end
                        end
                        mouse_drag = false
                    elseif key == tb.key_mouse_wheel_up then
                        local text_rows = term:height() - editor:footer_rows()
                        view_cur:scroll_viewport(-3, text_rows)
                    elseif key == tb.key_mouse_wheel_down then
                        local text_rows = term:height() - editor:footer_rows()
                        view_cur:scroll_viewport(3, text_rows)
                    end
                end
            end
            -- Chord timeout: while we're holding a prefix chord, ensure
            -- a timer is queued to reset it if the next key doesn't
            -- arrive promptly. Cancel it once the chord resolves.
            if #key_state > 0 then
                if chord_timeout_task == nil then
                    chord_timeout_task = editor:schedule_after(100000, function()
                        if #key_state > 0 then
                            key_state = {}
                            key_node = editor._active_trie
                            editor.status_message = "chord timeout"
                        end
                        chord_timeout_task = nil
                        return true
                    end)
                end
            else
                if chord_timeout_task ~= nil then
                    editor:cancel_task(chord_timeout_task)
                    chord_timeout_task = nil
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

        -- Reset blink on input so the caret stays solid while typing.
        -- The blink toggle itself is a scheduled background task; run
        -- timers here after input processing so a deadline-only wake
        -- flips the phase before render.
        if had_input then
            editor:reset_blink()
        end
        editor:tick_background_tasks()

        -- Update view and render only after processing input/wake
        local cur_view = editor:current_view()
        if cur_view then
            cur_view:scroll_to_cursor(term:height() - (editor:footer_rows() - 1))
        end
        editor:render()
    end

    editor.event_system:emit("editor_close")
    term:shutdown()
    ss:stop()

    return editor._exit_code
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
