--- commands: named operations that can be invoked by keybindings or M-x.
---
--- Each command is a function(view, editor, ...) where the varargs receive
--- universal argument values from C-u. The first vararg is the boolean
--- flag (true = normal, false = inverted), followed by any parsed args.
--- Commands that don't need universal args can ignore the varargs.
--- Names use snake_case; M-x accepts spaces which are converted to underscores.
--- Inline arguments after a colon are parsed by the universal argument
--- parser: e.g. "M-x goto line:42" passes the number 42 to the command.

local kill_ring = require("cursed.kill_ring")
local completers = require("cursed.completers")
local ColorScheme = require("cursed.colorscheme")
local log = require("cursed.log")
local universal_arg = require("cursed.universal_arg")
local advice = require("cursed.advice")

local commands = {}

----------------------------------------------------------------------------------------------------
-- Motion commands
----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
-- Helper: extract a repeat count from universal argument varargs.
-- Returns a signed integer. For numeric args, uses the number directly.
-- For string args, uses the string length. Direction is flipped if the
-- flag is false (inverted).
----------------------------------------------------------------------------------------------------

--- Compute a repeat count from universal argument varargs.
---@param flag boolean true = normal direction, false = inverted
---@param ... any remaining universal args (numbers or strings)
---@return integer count signed repeat count
local function repeat_count(flag, ...)
    if flag == nil then
        -- No universal args at all: default to 1 in normal direction
        return 1
    end
    local n = 1
    local argc = select("#", ...)
    for i = 1, argc do
        local arg = select(i, ...)
        local ty = type(arg)
        if ty == "number" then
            n = n * arg
        elseif ty == "string" then
            n = n * #arg
        end
    end
    if not flag then
        n = -n
    end
    return n
end

commands.move_line_start = function(view, _editor, ...)
    local flag = ...
    if flag == false then
        view:move_line_end()
    else
        view:move_line_start()
    end
end

commands.move_line_end = function(view, _editor, ...)
    local flag = ...
    if flag == false then
        view:move_line_start()
    else
        view:move_line_end()
    end
end

commands.backward_char = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_char(-n)
end

commands.forward_char = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_char(n)
end

commands.previous_line = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_line(-n)
end

commands.next_line = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_line(n)
end

commands.scroll_down = function(view, editor, ...)
    local n = repeat_count(...)
    local page_size = editor.term:height() - editor:footer_rows()
    view:scroll_page(-n, page_size)
end

commands.scroll_up = function(view, editor, ...)
    local n = repeat_count(...)
    local page_size = editor.term:height() - editor:footer_rows()
    view:scroll_page(n, page_size)
end

commands.forward_word = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_word(n, "word")
end

commands.backward_word = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_word(-n, "word")
end

--- Sentence / subsentence motion is expressed purely over the
--- textobject range via move_word, which already implements the
--- dir-aware contract (forward→next unit when between, backward→prev)
--- plus the end/start-of-document guards. The range's (el,ec) is
--- right after the punctuation char and (sl,sc) is the first char
--- after the previous gap — exactly Emacs' landing points — so no
--- match-table / boundary-pattern machinery is needed.

--- Emacs `forward-sentence` (M-e). Universal arg repeats.
--- Multi-cursor aware.
commands.forward_sentence = function(view, _editor, ...)
    return view:move_word(math.abs(repeat_count(...)), "sentence")
end

--- Emacs `backward-sentence` (M-a): move to the start of the
--- current sentence, or (if already there) the previous one.
--- Universal arg repeats. Multi-cursor aware.
commands.backward_sentence = function(view, _editor, ...)
    return view:move_word(-math.abs(repeat_count(...)), "sentence")
end

--- Forward subsentence motion (next clause boundary).
--- Same landing semantics as forward_sentence over "subsentence".
commands.forward_subsentence = function(view, _editor, ...)
    return view:move_word(math.abs(repeat_count(...)), "subsentence")
end

--- Backward subsentence motion (previous clause boundary).
commands.backward_subsentence = function(view, _editor, ...)
    return view:move_word(-math.abs(repeat_count(...)), "subsentence")
end

commands.beginning_of_buffer = function(view, _editor, ...)
    local flag = ...
    if flag == false then
        view:p().line = view:line_count() - 1
        view:p().col = view:content_len(view:p().line)
        view:_set_goal_col(view:p().col)
    else
        view:p().line = 0
        view:p().col = 0
        view:_set_goal_col(0)
    end
end

commands.end_of_buffer = function(view, _editor, ...)
    local flag = ...
    if flag == false then
        view:p().line = 0
        view:p().col = 0
        view:_set_goal_col(0)
    else
        view:p().line = view:line_count() - 1
        view:p().col = view:content_len(view:p().line)
        view:_set_goal_col(view:p().col)
    end
end

----------------------------------------------------------------------------------------------------
-- Editing commands
----------------------------------------------------------------------------------------------------

commands.delete_char = function(view, editor, ...)
    local n = repeat_count(...)
    view:delete_char(n)
end

commands.backward_delete_char = function(view, editor, ...)
    if not view:delete_selection() then
        local n = repeat_count(...)
        view:delete_char(-n)
    end
end

commands.newline = function(view, editor, ...)
    local n = repeat_count(...)
    for _ = 1, math.max(1, n) do
        view:insert_newline()
    end
end

commands.self_insert = function(view, _editor, ch)
    view:delete_selection()
    -- Note: self_insert is special; the keybinding wrapper passes `ch`
    -- directly since it comes from __printable. The command form is
    -- mainly for M-x invocation where there's no character to insert.
end

commands.kill_line = function(view, editor, flag, ...)
    local n = repeat_count(flag, ...)
    if n < 0 then
        -- Negative count: kill backward to start of line
        local count = math.abs(n)
        for _ = 1, count do
            if view:p().col == 0 then
                -- Kill the newline (join with previous line)
                if view:p().line > 0 then
                    local killed = "\n"
                    view:delete_char(-1)
                    editor:push_kill(killed)
                end
            else
                local killed = view:text_between(view:p().line, 0, view:p().line, view:p().col)
                view:delete_char(-view:p().col)
                editor:push_kill(killed)
            end
        end
    else
        -- Positive count: kill to end of line (or merge with next line)
        for _ = 1, math.abs(n) do
            local content_len = view:content_len(view:p().line)
            local killed
            if view:p().col < content_len then
                killed = view:text_between(view:p().line, view:p().col, view:p().line, content_len)
                view:delete_char(content_len - view:p().col)
            elseif view:p().line < view:line_count() - 1 then
                killed = "\n"
                view:delete_char(1)
            else
                break
            end
            editor:push_kill(killed)
        end
    end
end

commands.open_line = function(view, editor, ...)
    local n = repeat_count(...)
    for _ = 1, math.max(1, n) do
        view:insert_newline()
        view:cursor_up()
    end
end

commands.copy_region = function(view, editor)
    if not view:has_selection() then
        return
    end
    local sl, sc, el, ec = view:selection_range()
    ---@cast sc integer
    ---@cast el integer
    ---@cast ec integer
    local text = view:text_between(sl, sc, el, ec)
    view:unset_mark()
    if #text > 0 then
        editor:push_kill(text)
    end
end

commands.kill_word = function(view, editor, ...)
    local n = repeat_count(...)
    for _ = 1, math.abs(n) do
        if view:has_selection() then
            local sl, sc, el, ec = view:selection_range()
            ---@cast sc integer
            ---@cast el integer
            ---@cast ec integer
            local killed = view:text_between(sl, sc, el, ec)
            view:delete_selection()
            editor:push_kill(killed)
        else
            local start_line = view:p().line
            local start_col = view:p().col
            view:move_word(-1, "word")
            local count = view:chars_between(view:p().line, view:p().col, start_line, start_col)
            if count > 0 then
                local killed = view:text_between(view:p().line, view:p().col, start_line, start_col)
                view:delete_char(count)
                editor:push_kill(killed)
            end
        end
    end
end

commands.kill_word_forward = function(view, editor, ...)
    local n = repeat_count(...)
    for _ = 1, math.abs(n) do
        if view:has_selection() then
            local sl, sc, el, ec = view:selection_range()
            ---@cast sc integer
            ---@cast el integer
            ---@cast ec integer
            local killed = view:text_between(sl, sc, el, ec)
            view:delete_selection()
            editor:push_kill(killed)
        else
            local start_line = view:p().line
            local start_col = view:p().col
            view:move_word(1, "word")
            local count = view:chars_between(start_line, start_col, view:p().line, view:p().col)
            if count > 0 then
                local killed = view:text_between(start_line, start_col, view:p().line, view:p().col)
                view:p().line = start_line
                view:p().col = start_col
                view:delete_char(count)
                editor:push_kill(killed)
            end
        end
    end
end

commands.transpose_chars = function(view, editor, ...)
    local n = repeat_count(...)
    n = math.max(1, n)
    local buf = view.buffer
    for _ = 1, n do
        local p = view:p()
        if p.col >= 1 then
            local text = buf:line_text(p.line)
            local a = text:sub(p.col, p.col)
            local b = text:sub(p.col + 1, p.col + 1)
            if #a == 0 or #b == 0 then
                return
            end
            -- One undo group: delete the pair then insert swapped,
            -- all via direct buffer primitives (no nested batch_edit
            -- grouping that would split this into two undo steps).
            local col = p.col - 1
            buf:close_edit()
            buf:begin_edit()
            buf:delete_char(p.line, col, 2)
            buf:insert_char(p.line, col, b .. a)
            buf:end_edit()
            p.line = p.line
            p.col = col + 2
            view:_set_goal_col(p.col)
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Kill ring commands
----------------------------------------------------------------------------------------------------

commands.recenter = function(view, editor)
    local h = editor.term:height() - (editor:footer_rows() - 1)
    view:recenter(h)
end

commands.yank = function(view, editor)
    local text = kill_ring:top()
    if not text then
        editor.status_message = "kill ring is empty"
        return
    end
    -- Delete selection if present
    view:delete_selection()
    -- Remember start position for yank-pop
    local start_line = view:p().line
    local start_col = view:p().col
    view:insert_char(text)
    view:p().yank_line = start_line
    view:p().yank_col = start_col
end

commands.yank_pop = function(view, editor)
    -- Only works right after C-y or M-y
    if view:p().yank_line == nil then
        editor.status_message = "previous command was not a yank"
        return
    end
    local text = kill_ring:next()
    if not text then
        editor.status_message = "no more kill ring entries"
        return
    end
    -- Delete the previously yanked text, then insert the next entry —
    -- one undo group (caller-managed grouping, Buffer is now naive).
    local sl = view:p().yank_line
    local sc = view:p().yank_col
    local buf = view.buffer
    buf:close_edit()
    buf:begin_edit()
    local el = view:p().line
    local ec = view:p().col
    local n = view:chars_between(sl, sc, el, ec)
    if n > 0 then
        local rl, rc = buf:delete_char(sl, sc, n)
        view:p().line = rl
        view:p().col = rc
    end
    -- Insert the next kill ring entry
    local insert_line = view:p().line
    local insert_col = view:p().col
    if #text > 0 then
        local rl, rc = buf:insert_char(view:p().line, view:p().col, text)
        view:p().line = rl
        view:p().col = rc
        view:_set_goal_col(rc)
    end
    buf:end_edit()
    -- Update yank start for further M-y
    view:p().yank_line = insert_line
    view:p().yank_col = insert_col
end

----------------------------------------------------------------------------------------------------
-- Mark / Selection commands
----------------------------------------------------------------------------------------------------

commands.set_mark = function(view, editor)
    if view:has_selection() then
        view:unset_mark()
        editor.status_message = "mark deactivated"
    else
        view:set_mark()
        editor.status_message = "mark set"
    end
end

commands.swap_mark_and_cursor = function(view, _editor)
    if view:has_selection() then
        view:swap_mark_and_cursor()
    else
        view:set_mark()
    end
end

commands.keyboard_quit = function(view, editor)
    if editor._digit_active then
        editor:cancel_digit_arg()
    end
    if editor.minibuffer and editor.minibuffer.active then
        editor:minibuffer_cancel()
        return
    end
    local main_view = editor:current_view()
    if main_view then
        -- If drop mode is active (pending drops staged): first C-g
        -- cancels the pending drops without touching live cursors.
        if main_view:has_pending_cursors() then
            main_view:cancel_pending_cursors()
            if editor then
                editor.status_message = "drop canceled"
            end
            return
        end
        -- If multi-cursor: first C-g collapses to a single cursor
        -- (the primary). Subsequent presses also clear the mark.
        if #main_view.cursors > 1 then
            commands.single_cursor(main_view, editor)
            return
        end
        main_view:unset_mark()
    end
    editor.status_message = nil
end

----------------------------------------------------------------------------------------------------
-- Undo / Redo commands
----------------------------------------------------------------------------------------------------

commands.undo = function(view, editor, ...)
    local n = repeat_count(...)
    for _ = 1, math.abs(n) do
        editor:undo()
    end
end

commands.redo = function(view, editor, ...)
    local n = repeat_count(...)
    for _ = 1, math.abs(n) do
        editor:redo()
    end
end

commands.undo_in_selection = function(view, editor, ...)
    local n = repeat_count(...)
    for _ = 1, math.abs(n) do
        if not view:undo_in_selection() then
            editor.status_message = "no further undo information in selection"
            break
        end
    end
end

commands.redo_in_selection = function(view, editor, ...)
    local n = repeat_count(...)
    for _ = 1, math.abs(n) do
        if not view:redo_in_selection() then
            editor.status_message = "no further redo information in selection"
            break
        end
    end
end

----------------------------------------------------------------------------------------------------
-- File commands
----------------------------------------------------------------------------------------------------

commands.save = function(view, editor)
    editor:save()
end

commands.save_as = function(view, editor)
    local filepath = editor.universal_args and editor.universal_args[2]
    editor:read_from_minibuffer({
        prompt = "Write file: ",
        value = filepath and tostring(filepath),
        initial = view.buffer:filepath(),
        completion = true,
        completer = completers.find_file,
        on_submit = function(input)
            if #input == 0 then
                return
            end
            editor:save_as(input)
        end,
    })
end

commands.find_file = function(view, editor)
    local filepath = editor.universal_args and editor.universal_args[2]
    editor:read_from_minibuffer({
        prompt = "Find file: ",
        value = filepath and tostring(filepath),
        completion = true,
        completer = completers.find_file,
        on_submit = function(input)
            if #input == 0 then
                return
            end
            editor:open_file(input)
        end,
    })
end

commands.insert_file = function(view, editor)
    local filepath = editor.universal_args and editor.universal_args[2]
    editor:read_from_minibuffer({
        prompt = "Insert file: ",
        value = filepath and tostring(filepath),
        completion = true,
        completer = completers.find_file,
        on_submit = function(input)
            if #input == 0 then
                return
            end
            editor:insert_file(input)
        end,
    })
end

commands.ibuffer = function(view, editor)
    editor:read_from_minibuffer({
        prompt = "Buffers: ",
        completion = true,
        auto_accept = true,
        completer = completers.ibuffer(editor),
        on_submit = function(input)
            local idx = tonumber(input:match("^(%d+)"))
            if idx and idx >= 1 and idx <= #editor.views then
                editor:set_active_view(idx)
                return
            end
            editor.status_message = "invalid buffer"
        end,
    })
end

commands.kill_buffer = function(view, editor)
    local current = editor:current_view()
    editor:read_from_minibuffer({
        prompt = "Kill buffer: ",
        initial = current and (current.buffer:filepath() or "[no file]") or nil,
        completion = true,
        auto_accept = true,
        completer = completers.kill_buffer(editor),
        on_submit = function(input)
            for _, v in ipairs(editor.views) do
                local path = v.buffer:filepath()
                if path and input:find(path, 1, true) then
                    if #editor.views <= 1 then
                        editor.status_message = "cannot kill sole buffer"
                        return
                    end
                    editor:close_view(v)
                    return
                end
            end
            editor.status_message = "no matching buffer"
        end,
    })
end

commands.quit = function(_view, _editor)
    return "quit"
end

commands.goto_line = function(view, editor)
    local line_num = editor.universal_args and editor.universal_args[2]
    editor:read_from_minibuffer({
        prompt = "Goto line: ",
        value = line_num and tostring(line_num),
        on_submit = function(input)
            local n = tonumber(input)
            if not n or n < 1 then
                editor.status_message = "invalid line number"
                return
            end
            local line = math.min(n - 1, view:line_count() - 1)
            view:p().line = line
            view:p().col = 0
            view:_set_goal_col(0)
        end,
    })
end

----------------------------------------------------------------------------------------------------
-- Search commands
----------------------------------------------------------------------------------------------------

commands.isearch_forward = function(view, editor)
    local query = editor.universal_args and editor.universal_args[2]
    if editor.minibuffer and editor.minibuffer.active then
        editor:isearch_next()
        return
    end
    editor:start_isearch(1, query and tostring(query))
end

commands.isearch_backward = function(view, editor)
    local query = editor.universal_args and editor.universal_args[2]
    if editor.minibuffer and editor.minibuffer.active then
        editor:isearch_prev()
        return
    end
    editor:start_isearch(-1, query and tostring(query))
end

----------------------------------------------------------------------------------------------------
-- Query replace
----------------------------------------------------------------------------------------------------

commands.query_replace = function(view, editor)
    local query = editor.universal_args and editor.universal_args[2]
    if not view or not view.file_loaded then
        return
    end
    -- If already in the replace minibuffer, this is a re-invocation; ignore
    if
        editor.minibuffer
        and editor.minibuffer.active
        and editor.minibuffer.prompt:find("Replace")
    then
        return
    end
    editor:start_query_replace(query and tostring(query))
end

----------------------------------------------------------------------------------------------------
-- Eval command
---------------------------------------------------------------------------------------------------

commands.eval_expression = function(view, editor)
    local expr = editor.universal_args and editor.universal_args[2]
    editor:read_from_minibuffer({
        prompt = "M-: ",
        value = expr and tostring(expr),
        completion = true,
        on_submit = function(input)
            if #input == 0 then
                return
            end
            local chunk, err = load(input)
            if not chunk then
                chunk, err = load("return " .. input)
            end
            if not chunk then
                editor._eval_result = "Error: " .. tostring(err)
                return
            end
            local env = { editor = editor, view = editor:current_view() }
            for k, v in pairs(commands) do
                if advice.callable(v) then
                    env[k] = function(...)
                        return v(view, editor, ...)
                    end
                end
            end
            -- Unsandboxed (#20): reads fall through to `_G` and writes
            -- propagate to `_G`. M-: can do anything main-thread code
            -- can — reach the global `editor`, `require` modules, register
            -- `editor.event_system` listeners, push background tasks, …
            -- `editor`, `view`, and command-name shims remain as
            -- convenience bare names.
            setmetatable(env, {
                __index = _G,
                __newindex = function(_t, k, v)
                    _G[k] = v
                end,
            })
            ---@diagnostic disable-next-line:deprecated
            setfenv(chunk, env)
            local ok, result = pcall(chunk)
            if not ok then
                editor._eval_result = "Error: " .. tostring(result)
            elseif result ~= nil then
                editor:show_eval_result(result)
            end
        end,
    })
end

----------------------------------------------------------------------------------------------------
-- Execute command by name (M-x)
----------------------------------------------------------------------------------------------------

commands.load_theme = function(view, editor)
    local xdg = ColorScheme.config_dir()
    -- List names lazily inside the completer so newly-added files in
    -- the themes dir are picked up without restarting.
    local names_fn = function()
        return ColorScheme.list_names(xdg)
    end
    -- Capture the scheme active when the prompt opened so C-g reverts a
    -- live-previewed (but uncommitted) theme back to what the user had.
    local saved_scheme = ColorScheme.active
    local truecolor = saved_scheme and saved_scheme.truecolor or false
    editor:read_from_minibuffer({
        prompt = "Load theme: ",
        completion = true,
        completer = completers.themes(names_fn),
        on_change = function(text, comp_index)
            -- Live preview: resolve the highlighted completion (or the
            -- typed text if none is selected) and apply it immediately.
            -- The render loop picks up the new active scheme next frame.
            local name
            if comp_index and comp_index > 0 then
                local item = editor.minibuffer._completions[comp_index]
                name = item and completers.comp_text(item) or nil
            elseif #text > 0 then
                name = text
            end
            if name then
                ColorScheme.apply(name, truecolor)
            end
        end,
        on_cancel = function()
            -- Restore the scheme that was active when the prompt opened.
            if saved_scheme ~= nil then
                ColorScheme.active = saved_scheme
                ColorScheme.generation = ColorScheme.generation + 1
            end
        end,
        on_submit = function(input)
            if #input == 0 then
                -- Empty submit: keep whatever was last previewed.
                editor.status_message = "theme: "
                    .. (ColorScheme.active and ColorScheme.active.name or "(none)")
                return
            end
            local scheme, status = ColorScheme.apply(input, truecolor)
            editor.status_message = status
            log.info("commands", "theme switched", {
                name = scheme.name,
                setting = input,
            })
        end,
    })
end

commands.execute_command = function(view, editor)
    local cmd_name = editor.universal_args and editor.universal_args[2]
    editor:read_from_minibuffer({
        prompt = "M-x ",
        value = cmd_name and tostring(cmd_name),
        completion = true,
        palette = true,
        completer = completers.commands(commands.names, function(name)
            -- Resolve the canonical command name to its bound chord via
            -- the editor's reverse map (rebuilt whenever the active trie
            -- is rebuilt, so major-mode overrides are reflected).
            local map = editor._chord_for_command
            return map and map[name] or nil
        end),
        on_submit = function(input)
            if #input == 0 then
                return
            end
            -- Split on first ":" for inline argument (parsed by
            -- the universal argument parser).
            local cmd_part, arg_part = input:match("^(.-):(.+)$")
            if not cmd_part then
                cmd_part = input
                arg_part = nil
            end
            local name = cmd_part:gsub(" ", "_"):lower()
            local cmd = commands[name]
            if not advice.callable(cmd) or name == "lookup" or name == "names" then
                editor.status_message = ("no command: %s"):format(cmd_part)
                return
            end
            -- Parse inline args through the universal argument parser
            -- and set on editor.universal_args for the command to read.
            if arg_part then
                local parsed = universal_arg.parse_universal_args(arg_part)
                editor.universal_args = { true }
                for i = 1, #parsed do
                    editor.universal_args[#editor.universal_args + 1] = parsed[i]
                end
            else
                editor.universal_args = nil
            end
            -- Dispatch using the same logic as the keybinding path
            -- in main.lua: if the command is vararg and universal
            -- args are present, unpack them after view/editor.
            local info = debug.getinfo(cmd, "u")
            local ok, result
            if info and info.isvararg and editor.universal_args then
                local gap = math.max(0, info.nparams - 2)
                ---@type table
                local args = editor.universal_args
                if gap == 0 then
                    ---@diagnostic disable-next-line: deprecated
                    ok, result = pcall(cmd, view, editor, unpack(args))
                else
                    local call_args = { view, editor }
                    for _ = 1, gap do
                        call_args[#call_args + 1] = nil
                    end
                    for i = 1, #args do
                        ---@cast args table
                        call_args[#call_args + 1] = args[i]
                    end
                    ---@diagnostic disable-next-line: deprecated
                    ok, result = pcall(cmd, unpack(call_args))
                end
            else
                ok, result = pcall(cmd, view, editor)
            end
            editor.universal_args = nil
            if not ok then
                editor.status_message = ("command error: %s"):format(tostring(result))
                local ef = io.open("/tmp/cursed_err.log", "a")
                if ef then ef:write(tostring(result) .. "\\n" .. debug.traceback("", 2) .. "\\n====\\n"); ef:close() end
            elseif result == "quit" then
                editor:request_quit()
            end
        end,
    })
end

----------------------------------------------------------------------------------------------------
-- Keyboard-driven commands (formerly inline keybindings)
----------------------------------------------------------------------------------------------------

commands.arrow_up = function(view, editor)
    local mb = editor.minibuffer
    if mb and mb.active and mb.completion and #mb._completions > 0 then
        mb:comp_up()
        return
    end
    commands.previous_line(view, editor)
end

commands.arrow_down = function(view, editor)
    local mb = editor.minibuffer
    if mb and mb.active and mb.completion and #mb._completions > 0 then
        mb:comp_down()
        return
    end
    commands.next_line(view, editor)
end

commands.enter_key = function(view, editor)
    if editor.minibuffer and editor.minibuffer.active then
        if editor.minibuffer.completion then
            editor.minibuffer:comp_submit()
        end
        editor:minibuffer_submit()
        return
    end
    commands.newline(view, editor)
end

commands.tab_key = function(view, editor, ...)
    local mb = editor.minibuffer
    if mb and mb.active and mb.completion then
        mb:comp_expand()
        return
    end
    -- Main buffer: insert tab or spaces
    local n = repeat_count(...)
    for _ = 1, math.max(1, n) do
        if view.expand_tab then
            local spaces = string.rep(" ", view.indent_width)
            view:insert_char(spaces)
        else
            view:insert_char("\t")
        end
    end
end

commands.universal_argument = function(view, editor)
    if editor._universal_active then
        editor:toggle_universal_arg()
    else
        editor:start_universal_arg()
    end
end

commands.history_up = function(view, editor)
    if editor.minibuffer and editor.minibuffer.active then
        editor.minibuffer:history_up()
    end
end

commands.history_down = function(view, editor)
    if editor.minibuffer and editor.minibuffer.active then
        editor.minibuffer:history_down()
    end
end

commands.escape_key = function(view, editor)
    if editor._digit_active then
        editor:cancel_digit_arg()
        return
    end
    if editor.minibuffer and editor.minibuffer.active then
        editor:minibuffer_cancel()
        return
    end
    local main_view = editor:current_view()
    if main_view then
        -- If drop mode is active (pending drops staged): first Escape
        -- cancels the pending drops without touching live cursors.
        if main_view:has_pending_cursors() then
            main_view:cancel_pending_cursors()
            if editor then
                editor.status_message = "drop canceled"
            end
            return
        end
        -- If multi-cursor: first Escape collapses to a single cursor.
        if #main_view.cursors > 1 then
            commands.single_cursor(main_view, editor)
            return
        end
        main_view:unset_mark()
    end
end

----------------------------------------------------------------------------------------------------
-- Keyboard macro (kmacro) commands
----------------------------------------------------------------------------------------------------

commands.start_kmacro = function(view, editor)
    editor._recording = true
    editor._recorded_commands = {}
    editor._recorded_mb_inputs = {}
    editor.status_message = "defining kmacro..."
end

commands.end_kmacro = function(view, editor)
    if not editor._recording then
        editor.status_message = "not defining kmacro"
        return
    end
    editor._recording = false
    local recorded = editor._recorded_commands
    local mb_inputs = editor._recorded_mb_inputs
    editor._recorded_commands = {}
    editor._recorded_mb_inputs = {}
    if #recorded == 0 then
        editor.status_message = "kmacro is empty, discarded"
        return
    end
    editor:read_from_minibuffer({
        prompt = "Name kmacro: ",
        on_submit = function(input)
            if #input == 0 then
                editor.status_message = "kmacro discarded"
                return
            end
            local saved = {
                commands = recorded,
                mb_inputs = mb_inputs,
            }
            editor._kmacros[input] = saved
            editor.status_message = "kmacro '" .. input .. "' defined"
        end,
    })
end

commands.run_kmacro = function(view, editor)
    local names = {}
    for name, _ in pairs(editor._kmacros) do
        names[#names + 1] = name
    end
    if #names == 0 then
        editor.status_message = "no kmacros defined"
        return
    end
    table.sort(names)
    editor:read_from_minibuffer({
        prompt = "Run kmacro: ",
        completion = true,
        auto_accept = true,
        completer = function(text)
            if #text == 0 then
                return names
            end
            local results = {}
            for _, name in ipairs(names) do
                if name:sub(1, #text) == text then
                    results[#results + 1] = name
                end
            end
            return results
        end,
        on_submit = function(input)
            local macro = editor._kmacros[input]
            if not macro then
                editor.status_message = "no kmacro named '" .. input .. "'"
                return
            end
            local commands = macro.commands
            -- Set up the minibuffer input stack for replay;
            -- read_from_minibuffer will pop from this instead of
            -- opening an interactive prompt.
            local mb_copy = {}
            for i, v in ipairs(macro.mb_inputs) do
                mb_copy[i] = v
            end
            editor._mb_input_stack = mb_copy
            -- Replay the recorded commands onto the current main view
            local v = editor:current_view()
            if not v then
                return
            end
            local cmd = require("cursed.commands")
            for i, entry in ipairs(commands) do
                if entry.name == "__printable" then
                    -- Self-insert: just insert the character
                    v:delete_selection()
                    local saved_args = editor.universal_args
                    editor.universal_args = entry.universal_args
                    local n = 1
                    if editor.universal_args then
                        for i = 2, #editor.universal_args do
                            local arg = editor.universal_args[i]
                            local ty = type(arg)
                            if ty == "number" then
                                n = n * arg
                            elseif ty == "string" then
                                n = n * #arg
                            end
                        end
                    end
                    editor.universal_args = saved_args
                    n = math.abs(n)
                    for _ = 1, n do
                        view:insert_char(entry.ch)
                    end
                else
                    local fn = cmd[entry.name]
                    if fn then
                        local saved_args = editor.universal_args
                        editor.universal_args = entry.universal_args
                        local ok, result = pcall(fn, v, editor)
                        editor.universal_args = saved_args
                        if not ok then
                            log.error("commands", "kmacro replay error", {
                                name = entry.name,
                                error = tostring(result),
                            })
                            editor.status_message = "kmacro error: " .. tostring(result)
                            return
                        end
                        if result == "quit" then
                            editor:request_quit()
                            return
                        end
                    end
                end
            end
            editor._mb_input_stack = {}
        end,
    })
end

----------------------------------------------------------------------------------------------------
-- Repeat / last-command machinery (#7)
--
-- last-command history is tracked by a `post_command_hook` listener in
-- `cursed.editor_listeners`; the entries below rerun from it.
----------------------------------------------------------------------------------------------------

--- Resolve and dispatch a command by name, restoring the captured
--- universal args. Mirrors kmacro replay semantics: named-command
--- dispatch via the commands table with `editor.universal_args`
--- restored (commands read args manually). Errors are surfaced as a
--- status message instead of propagating.
---@param editor Editor
---@param name string command name in the commands table
---@param universal_args table|nil args to restore, or nil for none
---@return boolean ok dispatch succeeded
local function rerun_command(editor, name, universal_args)
    local fn = commands[name]
    if not advice.callable(fn) then
        editor.status_message = "cannot repeat: " .. tostring(name)
        return false
    end
    local v = editor:current_view()
    if not v then
        return false
    end
    local saved_args = editor.universal_args
    editor.universal_args = universal_args
    local ok, result = pcall(fn, v, editor)
    editor.universal_args = saved_args
    if not ok then
        log.error("commands", "repeat error", { name = name, error = tostring(result) })
        editor.status_message = "repeat error: " .. tostring(result)
        return false
    end
    if result == "quit" then
        editor:request_quit()
    end
    return true
end

--- Emacs `repeat` (C-x z): rerun the most recent dispatched command.
--- Subsequent presses of `C-x z` repeat again — the repeat commands are
--- skipped from history tracking, so `last-command` stays pinned to
--- the original command being repeated.
commands["repeat"] = function(_view, editor)
    local last = editor._last_command
    if last == nil then
        editor.status_message = "nothing to repeat"
        return
    end
    rerun_command(editor, last, nil)
end

--- Emacs `repeat-complex-command`: rerun the most recent command that
--- was invoked with a universal argument, restoring those args.
commands.repeat_complex_command = function(_view, editor)
    local complex = editor._last_complex_command
    if complex == nil then
        editor.status_message = "no complex command to repeat"
        return
    end
    rerun_command(editor, complex.name, complex.universal_args)
end

----------------------------------------------------------------------------------------------------
-- Multi-cursor commands (cursor-creators)
----------------------------------------------------------------------------------------------------

--- Get the selection text of the primary cursor (or empty if none).
local function primary_selection_text(view)
    local p = view:p()
    if not p.anchor_line then
        return nil
    end
    local sl, sc, el, ec = view:selection_ranges_one(p)
    ---@cast sl integer
    ---@cast sc integer
    ---@cast el integer
    ---@cast ec integer
    return view:text_between(sl, sc, el, ec)
end

--- Select the next occurrence of the current selection's text.
--- Adds a new cursor with an anchor at the match start and head at the
--- match end. Repeats add successive cursors forward.
commands.select_next_match = function(view, _editor)
    local query = primary_selection_text(view)
    if not query or #query == 0 then
        return
    end
    local p = view:p()
    -- Search forward from the cursor (end of current selection).
    local start_pt = { line = p.line, offset = p.col }
    local iter = view.buffer:search_forward(query, start_pt, true)
    local m = iter()
    if not m then
        -- Wrap around to the top of the document.
        iter = view.buffer:search_forward(query, { line = 0, offset = 0 }, true)
        m = iter()
        if not m then
            return
        end
    end
    -- Add a new cursor anchoring the matched region.
    local nc = view:make_cursor(m.end_line, m.end_offset)
    nc.anchor_line = m.line
    nc.anchor_col = m.offset
    nc.shadow_undo = tonumber(view.buffer._ptr.undo.count)
    nc.shadow_redo = tonumber(view.buffer._ptr.redo.count)
    table.insert(view.cursors, 1, nc)
end

--- Select the previous occurrence of the current selection's text.
commands.select_prev_match = function(view, _editor)
    local query = primary_selection_text(view)
    if not query or #query == 0 then
        return
    end
    local p = view:p()
    -- Search backward from the anchor (start of current selection).
    local start_pt = { line = p.anchor_line or p.line, offset = p.anchor_col or p.col }
    local iter = view.buffer:search_backward(query, start_pt, true)
    local m = iter()
    if not m then
        -- Wrap around to the end of the document.
        local ll = view:line_count() - 1
        iter =
            view.buffer:search_backward(query, { line = ll, offset = view:content_len(ll) }, true)
        m = iter()
        if not m then
            return
        end
    end
    local nc = view:make_cursor(m.end_line, m.end_offset)
    nc.anchor_line = m.line
    nc.anchor_col = m.offset
    nc.shadow_undo = tonumber(view.buffer._ptr.undo.count)
    nc.shadow_redo = tonumber(view.buffer._ptr.redo.count)
    table.insert(view.cursors, 1, nc)
end

--- Select every occurrence of the current selection's text.
--- Replaces cursors with one per match (selections active).
commands.select_all_matches = function(view, _editor)
    local query = primary_selection_text(view)
    if not query or #query == 0 then
        return
    end
    local u = tonumber(view.buffer._ptr.undo.count)
    local r = tonumber(view.buffer._ptr.redo.count)
    local new_cursors = {}
    local iter = view.buffer:search_forward(query, { line = 0, offset = -1 }, true)
    for m in iter do
        local c = view:make_cursor(m.end_line, m.end_offset)
        c.anchor_line = m.line
        c.anchor_col = m.offset
        c.shadow_undo = u
        c.shadow_redo = r
        new_cursors[#new_cursors + 1] = c
    end
    if #new_cursors > 0 then
        view.cursors = new_cursors
    end
end

--- Drop a pending cursor at the primary's position. The cursor is NOT
--- yet active: a marker is rendered at the dropped point, the primary
--- caret stays where it is so the user can move and drop again, but
--- the pending drops stay put. commit_pending_cursors (alt-m by
--- default) promotes all pending drops to live cursors at once so
--- subsequent motions move every cursor in unison. Escape cancels.
commands.add_cursor_here = function(view, editor)
    local p = view:p()
    view:drop_cursor(p.line, p.col)
    if editor then
        local n = #view.pending_cursors
        editor.status_message = (
            n
            .. (n == 1 and " drop" or " drops")
            .. " staged (alt-ret to commit, esc to cancel)"
        )
    end
end

--- Promote staged drops to live cursors (in addition to the primary).
--- Bound to alt-m by default (mnemonic: "more"). After commit,
--- motions/edits apply to every cursor in unison.
commands.commit_pending_cursors = function(view, editor)
    if not view:has_pending_cursors() then
        return
    end
    local n = #view.pending_cursors
    view:commit_pending_cursors()
    if editor then
        editor.status_message = (#view.cursors .. " cursors active")
    end
end

--- Split the primary selection into one cursor per line.
--- If the selection spans multiple lines, each line gets a cursor at
--- the start of the (sub-)region on that line; the multi-line region
--- collapses to one cursor per line with no selection.
--- If the selection is on a single line, this is a no-op.
commands.split_selection_into_lines = function(view, _editor)
    local p = view:p()
    if not p.anchor_line then
        return
    end
    local sl, sc, el, ec = view:selection_ranges_one(p)
    ---@cast sl integer
    ---@cast sc integer
    ---@cast el integer
    ---@cast ec integer
    if sl == el then
        return
    end
    local new_cursors = {}
    for li = sl, el do
        local cc
        if li == sl then
            cc = sc
        else
            cc = 0
        end
        local c = view:make_cursor(li, cc)
        new_cursors[#new_cursors + 1] = c
    end
    -- last cursor positions at ec on the last line; overwrite
    if #new_cursors > 0 then
        new_cursors[#new_cursors].col = ec
        new_cursors[#new_cursors].goal_col = ec
    end
    view.cursors = new_cursors
end

--- Add a cursor one row (screen row) above the primary, same column.
--- Implements rectangular column-arrow navigation: cursor is added
--- (not moved) so the existing cursor stays. Repeat to extend up.
commands.add_cursor_up = function(view, _editor)
    local p = view:p()
    if p.line <= 0 then
        return
    end
    local target_line = p.line - 1
    local col = math.min(p.goal_col, view:content_len(target_line))
    local nc = view:make_cursor(target_line, col)
    table.insert(view.cursors, 1, nc)
end

--- Add a cursor one row below the primary, same column.
commands.add_cursor_down = function(view, _editor)
    local p = view:p()
    if p.line >= view:line_count() - 1 then
        return
    end
    local target_line = p.line + 1
    local col = math.min(p.goal_col, view:content_len(target_line))
    local nc = view:make_cursor(target_line, col)
    table.insert(view.cursors, 1, nc)
end

--- Collapse to a single primary cursor (drop all others). Bound to
--- escape by default (when no other escape context is active).
commands.single_cursor = function(view, _editor)
    local p = view:p()
    view.cursors = { view:make_cursor(p.line, p.col) }
    view:unset_mark_all()
    view:cancel_pending_cursors()
end

----------------------------------------------------------------------------------------------------
-- Extended motion commands
----------------------------------------------------------------------------------------------------

--- Move to the first non-whitespace character on the current line.
--- Emacs `back-to-indentation` (bound to M-m in Emacs, but alt-m is
--- already taken here by commit-pending-cursors; bound to C-x M-m).
commands.back_to_indentation = function(view, _editor, ...)
    local n = repeat_count(...)
    local step = n >= 0 and 1 or -1
    view:each_cursor(function(c)
        local line = c.line
        line = math.min(math.max(0, line + (n - 1) * step), view:line_count() - 1)
        local text = view.buffer:line_text(line)
        local content_len = #text
        if content_len > 0 and text:byte(content_len) == 10 then
            content_len = content_len - 1
        end
        local col = 0
        while col < content_len do
            local b = text:byte(col + 1)
            if b ~= 32 and b ~= 9 then
                break
            end
            col = col + 1
        end
        c.line = line
        c.col = math.min(col, content_len)
        c.goal_col = c.col
        c.visual_col = nil
        c.yank_line = nil
        c.yank_col = nil
        return true
    end)
end

--- Scan from `line` in direction `dir` (+1/-1) for the next paragraph
--- boundary: a line whose content is all whitespace that is preceded
--- (in the direction of travel) by a non-blank line. Returns the line
--- index of the boundary (or the document edge if none).
--- Move forward to the start of the next paragraph (blank-line
--- separated). Emacs `forward-paragraph` (M-{).
commands.forward_paragraph = function(view, _editor, ...)
    local n = repeat_count(...)
    local dir = n >= 0 and 1 or -1
    local count = math.abs(n)
    view:each_cursor(function(c)
        local line = c.line
        for _ = 1, count do
            line = view:paragraph_boundary(line, dir)
        end
        c.line = line
        c.col = 0
        c.goal_col = 0
        c.visual_col = nil
        c.yank_line = nil
        c.yank_col = nil
        return true
    end)
end

--- Move backward to the start of the previous paragraph.
--- Emacs `backward-paragraph` (M-}).
commands.backward_paragraph = function(view, editor, ...)
    local flag, rest = ...
    if flag == false then
        commands.forward_paragraph(view, editor, true, math.abs(rest and -rest or 1))
    else
        commands.forward_paragraph(view, editor, true, -math.abs(rest or 1))
    end
end

--- Move forward over a "bigword" (whitespace-delimited token).
--- Emacs `forward-word` here maps to the `bigword` textobject.
commands.forward_bigword = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_word(n, "bigword")
end

--- Move backward over a bigword.
commands.backward_bigword = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_word(-n, "bigword")
end

--- Like beginning_of_buffer but moves to JUST the last non-newline
--- position (already the current behavior; Emacs sometimes reports
--- end-of-buffer at line_count). Provided for completeness under its
--- emacs alias so M-x and kmacros can call it by the familiar name.
commands.end_of_buffer = commands.end_of_buffer

----------------------------------------------------------------------------------------------------
-- Mark / selection helper commands
----------------------------------------------------------------------------------------------------

--- Select the word containing (or nearest) point: outward in BOTH
--- directions to the full word boundaries. Proto expand-region
--- behavior (not Emacs' [point, word-end)).
commands.mark_word = function(view, _editor)
    local p = view:p()
    view:select_range("word", p.line, p.col)
end

--- Select the bigword (whitespace-delimited token) containing point.
commands.mark_bigword = function(view, _editor)
    local p = view:p()
    view:select_range("bigword", p.line, p.col)
end

--- Select the subsentence (clause) containing point.
commands.mark_subsentence = function(view, _editor)
    local p = view:p()
    view:select_range("subsentence", p.line, p.col)
end

--- Select the paragraph containing point: outward in BOTH directions
--- to the full paragraph (the content run between blank lines). Proto
--- expand-region behavior.
commands.mark_paragraph = function(view, _editor, ...)
    local p = view:p()
    view:select_range("paragraph", p.line, p.col)
end

--- Select the entire buffer: mark at start, point at end.
--- Emacs `mark-whole-buffer` (C-x h).
--- Operates on the primary cursor; clears other cursors since a
--- whole-buffer selection is conceptually single-cursor.
commands.mark_whole_buffer = function(view, _editor)
    local lc = view:line_count()
    local last = view:content_len(lc - 1)
    local p = view:p()
    view.cursors = { view:make_cursor(0, 0) }
    view:set_mark()
    p = view:p()
    p.line = lc - 1
    p.col = last
    view:_set_goal_col(last)
end

----------------------------------------------------------------------------------------------------
-- Kill-region and region-aware kills
----------------------------------------------------------------------------------------------------

--- Kill the active selection(s), pushing the deleted text onto the
--- kill ring. Multi-cursor: every selection is killed as one undo
--- group, each region pushed to the kill ring. If no region is
--- active, this is a no-op. Emacs `kill-region` (C-w).
commands.kill_region = function(view, editor)
    if not view:has_selection() then
        return
    end
    local parts = {}
    for sl, sc, el, ec in view:selection_ranges() do
        ---@cast sl integer
        ---@cast sc integer
        ---@cast el integer
        ---@cast ec integer
        parts[#parts + 1] = view:text_between(sl, sc, el, ec)
    end
    view:delete_selection()
    for _, text in ipairs(parts) do
        editor:push_kill(text)
    end
end

----------------------------------------------------------------------------------------------------
-- Sentence spans (motion / transpose / copy / mark / kill)
--
-- All sentence commands are expressed over the textobject range
-- (sl,sc,el,ec,boundary_len) resolved by View:_pattern_range via the
-- "sentence" / "subsentence" textobject fn. The range's coordinates ARE
-- the Emacs landing points: ec is right after the terminating
-- punctuation, sl is the first char after the previous gap. Motion
-- delegates to move_word (which implements the dir-aware
-- between-units contract + doc-end guards); kill / copy / transpose
-- consume the range directly. Spans cross line boundaries because the
-- underlying buffer search is multi-line.
----------------------------------------------------------------------------------------------------

--- Kill the current sentence region [`sl,sc`, `el,ec`) as one undo
--- group, pushing the deleted text onto the kill ring.
local function kill_sentence_region(view, editor, sl, sc, el, ec)
    local count = view:chars_between(sl, sc, el, ec)
    if count <= 0 then
        return
    end
    local killed = view:text_between(sl, sc, el, ec)
    view:p().line = sl
    view:p().col = sc
    view:_set_goal_col(sc)
    view:delete_char(count)
    editor:push_kill(killed)
end

--- Kill from point to the end of the current sentence.
--- Emacs `kill-sentence` (M-k). Universal arg repeats.
commands.kill_sentence = function(view, editor, ...)
    local n = repeat_count(...)
    local p = view:p()
    local fn = view:_textobject_fn("sentence")
    for _ = 1, math.abs(n) do
        local _, _, el, ec = fn(view, p.line, p.col, 1)
        if not el then
            return
        end
        kill_sentence_region(view, editor, p.line, p.col, el, ec)
    end
end

--- Kill from point back to the start of the current sentence.
--- Emacs `backward-kill-sentence` (C-M-k / C-x DEL). Universal arg repeats.
commands.backward_kill_sentence = function(view, editor, ...)
    local n = repeat_count(...)
    local p = view:p()
    local fn = view:_textobject_fn("sentence")
    for _ = 1, math.abs(n) do
        local sl, sc = fn(view, p.line, p.col, -1)
        if not sl then
            return
        end
        kill_sentence_region(view, editor, sl, sc, p.line, p.col)
    end
end

--- Copy the sentence containing point (from the end of the previous
--- sentence terminator to the end of the current one, or EOF) onto
--- the kill ring without deleting. Emacs has no built-in
--- `copy-sentence`; this is the sentence analog of `copy-region`
--- (M-w). Multi-cursor: operates on the primary cursor.
--- Emacs idiom for the same effect is `M-x mark-sentence` then M-w.
commands.copy_sentence = function(view, editor)
    local p = view:p()
    local fn = view:_textobject_fn("sentence")
    local sl, sc, el, ec = fn(view, p.line, p.col, nil)
    if not sl then
        editor.status_message = "empty sentence"
        return
    end
    local text = view:text_between(sl, sc, el, ec)
    if #text == 0 then
        editor.status_message = "empty sentence"
        return
    end
    editor:push_kill(text)
    editor.status_message = "sentence copied"
end

--- Set the mark at the end of the current sentence and move point to
--- the start of the sentence, selecting the whole sentence.
--- Emacs `mark-sentence` (M-x). No default key; reachable via M-x
--- so the selection can then be killed (C-w) or copied (M-w).
commands.mark_sentence = function(view, _editor)
    local p = view:p()
    view:select_range("sentence", p.line, p.col)
end

--- Interchange the current sentence with the previous one.
--- Emacs `transpose-sentences` (M-x; no default binding). Swaps the
--- current sentence range [sl,sc, el,ec) with the previous sentence
--- range, preserving the inter-sentence gap, leaving point at the end
--- of the (now-first) current sentence. Multi-cursor: primary only
--- (matches Emacs' single-point transpose). Universal arg repeats.
commands.transpose_sentences = function(view, editor, ...)
    local n = repeat_count(...)
    local loop = math.max(1, math.abs(n))
    local fn = view:_textobject_fn("sentence")
    for _ = 1, loop do
        local p = view:p()
        local sl, sc, el, ec = fn(view, p.line, p.col, nil)
        if not sl then
            return
        end
        ---@cast sl integer
        ---@cast sc integer
        -- Step one char before the current sentence's start to land on
        -- the boundary gap, then dir=-1 resolves to the PREVIOUS unit.
        local pline, pcol = sl, sc - 1
        if pcol < 0 then
            if sl > 0 then
                pline = sl - 1
                pcol = view:content_len(pline)
            else
                editor.status_message = "don't have two previous sentences"
                return
            end
        end
        local psl, psc, pel, pec = fn(view, pline, pcol, -1)
        if not psl then
            editor.status_message = "don't have two previous sentences"
            return
        end
        ---@cast psl integer
        ---@cast psc integer
        ---@cast pel integer
        ---@cast pec integer
        ---@cast el integer
        ---@cast ec integer
        -- Bodies (content + punctuation, NO trailing gap):
        --   P-body = [psl,psc, pel,pec)
        --   gap    = [pel,pec, sl,sc)   (prev's trailing whitespace)
        --   C-body = [sl,sc, el,ec)
        local text_p = view:text_between(psl, psc, pel, pec)
        local gap = view:text_between(pel, pec, sl, sc)
        local text_c = view:text_between(sl, sc, el, ec)
        if #text_p == 0 and #text_c == 0 then
            return
        end
        -- One undo group: delete [psl,psc, el,ec) then insert C+gap+P.
        local del_n = view:chars_between(psl, psc, el, ec)
        local buf = view.buffer
        buf:close_edit()
        buf:begin_edit()
        local rl, rc = psl, psc
        if del_n > 0 then
            rl, rc = buf:delete_char(psl, psc, del_n)
        end
        if #text_c + #gap + #text_p > 0 then
            rl, rc = buf:insert_char(rl, rc, text_c .. gap .. text_p)
        end
        buf:end_edit()
        -- Land at the end of the inserted current sentence text.
        p.line = rl
        p.col = rc
        view:_set_goal_col(rc)
    end
end

----------------------------------------------------------------------------------------------------
-- Whole-line, line-joining, and whitespace kills
----------------------------------------------------------------------------------------------------

--- Kill the entire current line (from col 0 to end of line content,
--- INCLUDING the newline). With a positive count N, kills N whole
--- lines. Pushes the killed text (including trailing newlines) onto
--- the kill ring, merging with prior consecutive kills. Emacs
--- `kill-whole-line` (C-S-backspace; bound here to C-x C-k C-k).
commands.kill_whole_line = function(view, editor, ...)
    local n = repeat_count(...)
    local count = math.abs(n)
    local killed_parts = {}
    for _ = 1, count do
        local line = view:p().line
        if line >= view:line_count() then
            break
        end
        local content_len = view:content_len(line)
        local text = view:text_between(line, 0, line, content_len)
        local at_last = line == view:line_count() - 1
        if at_last then
            -- Final line: kill the content but not a phantom newline.
            if content_len > 0 then
                killed_parts[#killed_parts + 1] = text
                view:p().col = 0
                view:delete_char(content_len)
            end
        else
            killed_parts[#killed_parts + 1] = text .. "\n"
            -- Move to col 0 then delete forward across the line + newline.
            view:p().col = 0
            view:delete_char(content_len + 1)
        end
        view:_set_goal_col(view:p().col)
    end
    for _, t in ipairs(killed_parts) do
        editor:push_kill(t)
    end
end

--- Kill from point to the end of the current paragraph.
--- Composes forward_paragraph with kill_region. Emacs idiom (no
--- standard binding; bound to C-x M-k).
commands.kill_paragraph = function(view, editor, ...)
    local n = repeat_count(...)
    local count = math.abs(n)
    view:set_mark()
    for _ = 1, count do
        commands.forward_paragraph(view, editor, true, 1)
    end
    commands.kill_region(view, editor)
end

--- Join the current line with the previous one, deleting the
--- indentation/newline between. With a prefix arg, joins the next
--- line down instead (Emacs `delete-indentation` semantics).
--- Emulates M-^ without a full electric-indent implementation.
--- Join the current line with the previous one, deleting the indentation/newline between.
--- With a negative prefix arg, joins the next line down instead
--- (forward). Operates on the primary cursor as a single edit group
--- (Emacs `delete-indentation` is single-cursor).
commands.delete_indentation = function(view, _editor, ...)
    local flag = ...
    local forward = flag == false
    local p = view:p()
    local line = p.line
    local target
    if forward then
        if line >= view:line_count() - 1 then
            return
        end
        target = line + 1
    else
        if line <= 0 then
            return
        end
        target = line - 1
    end
    local buf = view.buffer
    -- Compute the deletion point and count in PRE-edit coordinates,
    -- then perform a single direct buffer mutation as one edit group
    -- (no nested batch_edit / each_cursor).
    local del_line, del_col, del_n, new_line, new_col
    if forward then
        local cl = view:content_len(line)
        local ttext = buf:line_text(target)
        local lead = ttext:match("^%s*") or ""
        del_line, del_col = line, cl
        del_n = 1 + #lead
        new_line, new_col = line, cl
    else
        local tlen = view:content_len(target)
        local ctext = buf:line_text(line)
        local lead = ctext:match("^%s*") or ""
        del_line, del_col = target, tlen
        del_n = 1 + #lead
        new_line, new_col = target, tlen
    end
    buf:close_edit()
    buf:begin_edit()
    local rl, rc = buf:delete_char(del_line, del_col, del_n)
    buf:end_edit()
    p.line = rl
    p.col = rc
    view:_set_goal_col(rc)
end

--- Delete all spaces and tabs around point on the current line.
--- Emacs `delete-horizontal-space` (M-\).
--- Multi-cursor aware: each cursor's surrounding whitespace is
--- removed in one undo group via batch_edit.
commands.delete_horizontal_space = function(view, _editor)
    local buf = view.buffer
    -- Pre-compute each cursor's whitespace span from PRE-edit state.
    local spans = {}
    for _, c in ipairs(view.cursors) do
        local text = buf:line_text(c.line)
        local len = #text
        if len > 0 and text:byte(len) == 10 then
            len = len - 1
        end
        local left = c.col
        while left > 0 do
            local b = text:byte(left)
            if b ~= 32 and b ~= 9 then
                break
            end
            left = left - 1
        end
        local right = c.col
        while right < len do
            local b = text:byte(right + 1)
            if b ~= 32 and b ~= 9 then
                break
            end
            right = right + 1
        end
        spans[c] = { left = left, right = right }
    end
    view:batch_edit(false, function(c)
        local s = spans[c]
        local del_n = s.right - s.left
        if del_n <= 0 then
            return c.line, c.col, c.line, c.col, { c.line, c.col }
        end
        local sl, sc = c.line, s.left
        c.col = s.left
        -- Single-line deletion (horizontal whitespace only): the
        -- region end is (sl, sc + del_n) with no line change.
        local el, ec = sl, sc + del_n
        local rl, rc = buf:delete_char(sl, sc, del_n)
        return sl, sc, rl, rc, { el, ec }
    end)
    view:_set_goal_col(view:p().col)
end

--- Collapse all whitespace around point to a single space.
--- Emacs `just-one-space` (M-SPC). If universal arg is non-default,
--- leaves N spaces instead of one. Multi-cursor aware via batch_edit.
commands.just_one_space = function(view, _editor, ...)
    local n = repeat_count(...)
    local target = math.max(1, math.abs(n))
    local buf = view.buffer
    local spaces = string.rep(" ", target)
    local spans = {}
    for _, c in ipairs(view.cursors) do
        local text = buf:line_text(c.line)
        local len = #text
        if len > 0 and text:byte(len) == 10 then
            len = len - 1
        end
        local left = c.col
        while left > 0 do
            local b = text:byte(left)
            if b ~= 32 and b ~= 9 then
                break
            end
            left = left - 1
        end
        local right = c.col
        while right < len do
            local b = text:byte(right + 1)
            if b ~= 32 and b ~= 9 then
                break
            end
            right = right + 1
        end
        spans[c] = { left = left, right = right }
    end
    view:batch_edit(false, function(c)
        local s = spans[c]
        local del_n = s.right - s.left
        local sl, sc = c.line, s.left
        c.col = s.left
        local el, ec
        if del_n > 0 then
            -- Single-line deletion (horizontal whitespace only).
            el, ec = sl, sc + del_n
            buf:delete_char(sl, sc, del_n)
        else
            el, ec = sl, sc
        end
        local rl, rc
        if #spaces > 0 then
            rl, rc = buf:insert_char(sl, sc, spaces)
        else
            rl, rc = sl, sc
        end
        return sl, sc, rl, rc, "replace", el, ec
    end)
    view:_set_goal_col(view:p().col)
end

--- Delete blank lines around the current line. If the current line is
--- blank, deletes all consecutive blank lines around it leaving one;
--- if it's non-blank, deletes any blank lines immediately after it.
--- Emacs `delete-blank-lines` (C-x C-o).
commands.delete_blank_lines = function(view, _editor)
    local buf = view.buffer
    local lc = view:line_count()
    local function is_blank(li)
        local t = buf:line_text(li)
        local n = #t
        if n == 0 then
            return true
        end
        if t:byte(n) == 10 then
            n = n - 1
        end
        return n == 0 or t:match("^%s*$") ~= nil
    end
    local line = view:p().line
    -- Determine the range of consecutive blank lines containing `line`,
    -- expanding upward and downward through blanks.
    local top = line
    while top > 0 and is_blank(top - 1) do
        top = top - 1
    end
    local bottom = line
    while bottom < lc - 1 and is_blank(bottom + 1) do
        bottom = bottom + 1
    end
    local cur_blank = is_blank(line)
    if cur_blank then
        -- leave exactly one blank line: delete blanks (top+1..bottom)
        if bottom > top then
            view:p().line = top
            view:p().col = 0
            view:_set_goal_col(0)
            local chars = 0
            for li = top, bottom - 1 do
                chars = chars + view:content_len(li) + 1 -- +1 for newline
            end
            if chars > 0 then
                view:delete_char(chars)
            end
        end
    else
        -- delete blank lines immediately after this content line
        if bottom > line then
            view:p().col = view:content_len(line)
            view:_set_goal_col(view:p().col)
            local chars = 0
            for li = line + 1, bottom do
                chars = chars + view:content_len(li) + 1
            end
            if chars > 0 then
                view:delete_char(chars)
            end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- browse-kill-ring (M-x)
----------------------------------------------------------------------------------------------------

--- Pop the top entry of the kill ring into the region without yanking
--- first. Useful when you want to replace a selection with the most
--- recent kill in one step.
commands.browse_kill_region = function(view, editor)
    if not view:has_selection() then
        return
    end
    local text = kill_ring:top()
    if not text then
        editor.status_message = "kill ring is empty"
        return
    end
    view:replace_selections(function(_t)
        return text
    end)
    kill_ring.yank_idx = 1
end

----------------------------------------------------------------------------------------------------
-- Browse the kill ring via minibuffer
----------------------------------------------------------------------------------------------------

--- List kill-ring entries in the minibuffer and insert the selected
--- one at point (or replace the selection). Emacs `browse-kill-ring`
--- (M-x browse-kill-ring).
commands.browse_kill_ring = function(view, editor)
    if #kill_ring.ring == 0 then
        editor.status_message = "kill ring is empty"
        return
    end
    local entries = {}
    for i, text in ipairs(kill_ring.ring) do
        local one_line = text:gsub("\n", "\\n")
        if #one_line > 60 then
            one_line = one_line:sub(1, 57) .. "..."
        end
        entries[i] = string.format("%d: %s", i, one_line)
    end
    editor:read_from_minibuffer({
        prompt = "Kill ring: ",
        completion = true,
        auto_accept = true,
        completer = function(text)
            if #text == 0 then
                return entries
            end
            local results = {}
            for _, e in ipairs(entries) do
                if e:sub(1, #text) == text then
                    results[#results + 1] = e
                end
            end
            return results
        end,
        on_submit = function(input)
            local idx_str = input:match("^(%d+):")
            local idx = idx_str and tonumber(idx_str) or tonumber(input:match("^(%d+)"))
            if not idx or idx < 1 or idx > #kill_ring.ring then
                editor.status_message = "invalid kill ring index"
                return
            end
            local text = kill_ring.ring[idx]
            view:delete_selection()
            local sl = view:p().line
            local sc = view:p().col
            view:insert_char(text)
            view:p().yank_line = sl
            view:p().yank_col = sc
        end,
    })
end

----------------------------------------------------------------------------------------------------
-- zap-to-char / zap-up-to-char
----------------------------------------------------------------------------------------------------

--- Shared core for zap-to-char and zap-up-to-char: read one char,
--- search forward/backward, kill from point to (or just before) the
--- match, push onto the kill ring.
local function zap_impl(view, editor, up_to, direction)
    local main = editor:current_view()
    if not main or not main.file_loaded then
        return
    end
    local prompt = (up_to and "Zap up to char: " or "Zap to char: ")
    if direction < 0 then
        prompt = (up_to and "Zap back up to char: " or "Zap back to char: ")
    end
    editor:read_char(prompt, function(ch)
        if ch == nil then
            return
        end
        local p = view:p()
        local start_pt = { line = p.line, offset = p.col }
        local iter, find_dir
        local ncount = 1
        if editor.universal_args then
            for i = 2, #editor.universal_args do
                local arg = editor.universal_args[i]
                if type(arg) == "number" then
                    ncount = ncount * arg
                elseif type(arg) == "string" then
                    ncount = ncount * #arg
                end
            end
        end
        if direction > 0 then
            find_dir = 1
            iter = view.buffer:search_forward(ch, start_pt, true)
        else
            find_dir = -1
            iter = view.buffer:search_backward(ch, start_pt, true)
        end
        local m
        for _ = 1, math.max(1, ncount) do
            m = iter()
            if not m then
                break
            end
            -- advance the search start for the next iteration
            if find_dir > 0 then
                start_pt = { line = m.end_line, offset = m.end_offset }
            else
                start_pt = { line = m.line, offset = m.offset - 1 }
            end
        end
        if not m then
            editor.status_message = "search failed"
            return
        end
        local sl, sc, el, ec
        if find_dir > 0 then
            -- forward: region is [point, match-end-up-to-or-inclusive)
            sl, sc = p.line, p.col
            if up_to then
                el, ec = m.line, m.offset
            else
                el, ec = m.end_line, m.end_offset
            end
        else
            -- backward: match is BEFORE point. The matched char is at
            -- [m.line, m.offset .. m.end_offset). Region ends at point.
            el, ec = p.line, p.col
            if up_to then
                -- zap-up-to-char: exclude the matched char (start at its end)
                sl, sc = m.end_line, m.end_offset
            else
                -- zap-to-char: include the matched char (start at its start)
                sl, sc = m.line, m.offset
            end
        end
        local count = view:chars_between(sl, sc, el, ec)
        if count <= 0 then
            return
        end
        local killed = view:text_between(sl, sc, el, ec)
        view:p().line = sl
        view:p().col = sc
        view:_set_goal_col(sc)
        -- Region start is (sl, sc) in normalized order regardless of
        -- direction, so always delete forward by `count`.
        view:delete_char(count)
        editor:push_kill(killed)
    end)
end

--- Kill from point up to (and including) the next occurrence of a
--- char read from the user. Emacs `zap-to-char` (M-z).
commands.zap_to_char = function(view, editor, ...)
    local flag = ...
    local dir = (flag == false) and -1 or 1
    zap_impl(view, editor, false, dir)
end

--- Kill from point up to (but NOT including) the next occurrence of a
--- char read from the user. Emacs `zap-up-to-char` variant.
commands.zap_up_to_char = function(view, editor, ...)
    local flag = ...
    local dir = (flag == false) and -1 or 1
    zap_impl(view, editor, true, dir)
end

----------------------------------------------------------------------------------------------------
-- Transpose commands
----------------------------------------------------------------------------------------------------

--- Strip a single trailing newline from a line text blob.
--- Returns (core, had_newline).
local function strip_trailing_nl(s)
    local l = #s
    if l > 0 and s:byte(l) == 10 then
        return s:sub(1, l - 1), true
    end
    return s, false
end

--- Transpose the current line with the previous one.
--- Emacs `transpose-lines` (C-x C-t). Multi-cursor aware: every
--- cursor's line is swapped with the line above as ONE undo group.
--- Because a line-content swap preserves the line count, cursors are
--- processed top-down (smallest line first); cursors sharing a line
--- collapse (each unique line is transposed once). Adjacent cursors
--- bubble deterministically (the lower line sees the already-swapped
--- content above it, exactly like running transpose-line at each
--- cursor in sequence). Universal arg repeats the whole sweep.
commands.transpose_lines = function(view, editor, ...)
    local n = repeat_count(...)
    local loop = math.max(1, math.abs(n))
    local buf = view.buffer
    for _ = 1, loop do
        -- Collect the set of cursor lines (deduped) and sort ascending
        -- so we splice top-down. After each splice the line count is
        -- unchanged, so a later cursor's pre-snapshot line index still
        -- points at the (possibly content-swapped) right line.
        local seen = {}
        local lines = {}
        for _, c in ipairs(view.cursors) do
            if c.line > 0 and not seen[c.line] then
                seen[c.line] = true
                lines[#lines + 1] = c
            end
        end
        if #lines == 0 then
            editor.status_message = "cannot transpose first line"
            return
        end
        table.sort(lines, function(a, b)
            return a.line < b.line
        end)
        buf:close_edit()
        buf:begin_edit()
        for _, c in ipairs(lines) do
            local L = c.line
            local this_text = buf:line_text(L)
            local prev_text = buf:line_text(L - 1)
            local this_core, this_nl = strip_trailing_nl(this_text)
            local prev_core, prev_nl = strip_trailing_nl(prev_text)
            local prev_len = #prev_core
            local this_len = #this_core
            -- Splice the region [L-1, 0 .. L, this_len) (the previous
            -- line content + its newline + the current line content)
            -- and replace with the swapped "this\nprev" form.
            local del_n = prev_len + 1 + this_len
            local ins = this_core .. "\n" .. prev_core
            if this_nl or prev_nl then
                ins = ins .. "\n"
            end
            if del_n > 0 then
                buf:delete_char(L - 1, 0, del_n)
            end
            if #ins > 0 then
                buf:insert_char(L - 1, 0, ins)
            end
        end
        buf:end_edit()
        -- After the sweep, each cursor stays on its (index-unchanged)
        -- line; clamp its column to the new line's content length.
        for _, c in ipairs(view.cursors) do
            local L = c.line
            local cl = view:content_len(L)
            if c.col > cl then
                c.col = cl
            end
            c.goal_col = c.col
            c.visual_col = nil
            c.yank_line = nil
            c.yank_col = nil
        end
    end
end

--- Find the word [`start`,`end`) on `line` that contains or is
--- nearest before/after col `c`. Words are `%w+` runs. Returns
--- (s, e) byte offsets (1-based inclusive start, 1-based exclusive
--- end) for the word, or nil if there is none on this line.
local function find_word_at(line_text, c)
    local pos = 1
    local cb = c + 1
    while true do
        local s, e = line_text:find("%w+", pos)
        if not s then
            break
        end
        -- Point is "inside" a word only if strictly past its start
        -- (s < cb), so that a point sitting on the first char of a
        -- word is treated as between-word (before = prev word).
        if s < cb and cb <= e then
            return s, e
        end
        pos = e + 1
    end
    return nil
end

--- Find the word immediately AFTER col `c` on the line (the next
--- word whose start is > c). Returns (s, e) 1-based inclusive/exclusive.
local function find_word_after(line_text, c)
    local pos = 1
    local cb = c + 1
    while true do
        local s, e = line_text:find("%w+", pos)
        if not s then
            return nil
        end
        if s > cb then
            return s, e
        end
        pos = e + 1
    end
end

--- Find the word immediately BEFORE col `c` on the line (the nearest
--- word whose end < c). Returns (s, e) 1-based inclusive/exclusive.
local function find_word_before(line_text, c)
    local pos = 1
    local cb = c + 1
    local found_s, found_e
    while true do
        local s, e = line_text:find("%w+", pos)
        if not s then
            break
        end
        if e < cb then
            found_s, found_e = s, e
        end
        pos = e + 1
    end
    return found_s, found_e
end

--- Transpose the words around (or before) point.
--- Emacs `transpose-words` (M-t). Single-cursor, single-line case:
--- swaps the word before point with the word after point. If point is
--- inside a word, that word counts as the "before" word.
commands.transpose_words = function(view, _editor, ...)
    local n = repeat_count(...)
    local loop = math.max(1, math.abs(n))
    for _ = 1, loop do
        local p = view:p()
        local buf = view.buffer
        local line_text = buf:line_text(p.line)
        -- strip trailing newline for matching purposes
        local tlen = #line_text
        if tlen > 0 and line_text:byte(tlen) == 10 then
            line_text = line_text:sub(1, tlen - 1)
        end
        -- Locate the two words to transpose. Emacs semantics: the
        -- word before point and the word after point are swapped.
        -- If point is inside a word, that word is the "before" word.
        local b1s, b1e = find_word_at(line_text, p.col)
        if not b1s then
            b1s, b1e = find_word_before(line_text, p.col)
        end
        -- The "after" word is the first word starting after b1e.
        local a1s, a1e
        if b1s then
            -- find_word_after takes a 0-based col; pass b1e-1 so the
            -- boundary `s > cb` matches words starting after b1e
            -- (b1e is 1-based exclusive end, i.e. the 0-based col of
            -- the char right after the word).
            a1s, a1e = find_word_after(line_text, b1e - 1)
        end
        if not b1s or not a1s then
            return
        end
        local first = line_text:sub(b1s, b1e)
        local second = line_text:sub(a1s, a1e)
        -- Build the new line: swap the two words' text in place.
        local lo_s, lo_e = b1s, b1e
        local hi_s, hi_e = a1s, a1e
        local new_line = line_text:sub(1, lo_s - 1)
            .. second
            .. line_text:sub(lo_e + 1, hi_s - 1)
            .. first
            .. line_text:sub(hi_e + 1)
        -- Apply as ONE edit group: delete the whole span
        -- [lo_s-1 .. hi_e-1] (0-based) then insert the swapped span,
        -- all via direct buffer primitives (not view:delete_char /
        -- view:insert_char, which each manage their OWN edit group via
        -- batch_edit and would split this transpose into two undo).
        local del_start_col = lo_s - 1
        local del_count = hi_e - (lo_s - 1)
        local insert_text = second .. line_text:sub(lo_e + 1, hi_s - 1) .. first
        buf:close_edit()
        buf:begin_edit()
        local rl, rc = p.line, del_start_col
        if del_count > 0 then
            rl, rc = buf:delete_char(p.line, del_start_col, del_count)
        end
        if #insert_text > 0 then
            rl, rc = buf:insert_char(rl, rc, insert_text)
        end
        buf:end_edit()
        -- Position at end of the (now second) word, i.e. right after
        -- the swapped-in first word.
        p.line = rl
        p.col = rc
        view:_set_goal_col(rc)
    end
end

----------------------------------------------------------------------------------------------------
-- Case-change commands
----------------------------------------------------------------------------------------------------

--- Apply a case transform to the word following point (or, with a
--- negative prefix arg, the word preceding point). Count repeats.
--- Emacs `upcase-word` (M-u), `downcase-word` (M-l), `capitalize-word` (M-c).
local function case_word(view, editor, transform, ...)
    local n = repeat_count(...)
    local count = math.abs(n)
    local forward = n >= 0
    for _ = 1, count do
        if view:has_selection() then
            view:replace_selections(transform)
        else
            local start_line = view:p().line
            local start_col = view:p().col
            if forward then
                view:move_word(1, "word")
            else
                view:move_word(-1, "word")
            end
            local el, ec = view:p().line, view:p().col
            local sl, sc
            if forward then
                sl, sc = start_line, start_col
            else
                sl, sc = el, ec
                el, ec = start_line, start_col
            end
            local cnt = view:chars_between(sl, sc, el, ec)
            if cnt > 0 then
                local text = view:text_between(sl, sc, el, ec)
                view:p().line = sl
                view:p().col = sc
                view:_set_goal_col(sc)
                view:delete_char(cnt)
                view:insert_char(transform(text))
            end
        end
    end
end

commands.upcase_word = function(view, editor, ...)
    case_word(view, editor, function(s)
        return s:upper()
    end, ...)
end

commands.downcase_word = function(view, editor, ...)
    case_word(view, editor, function(s)
        return s:lower()
    end, ...)
end

commands.capitalize_word = function(view, editor, ...)
    case_word(view, editor, function(s)
        -- Capitalize first alphanumeric char, lowercase the rest.
        return (
            s:gsub("^(.-)(%w)(.*)$", function(pre, ch, rest)
                return pre .. ch:upper() .. rest:lower()
            end)
        )
    end, ...)
end

--- Convert the region to upper case. Emacs `upcase-region`
--- (C-x C-u). Multi-cursor: each selection is transformed.
commands.upcase_region = function(view, _editor)
    view:replace_selections(function(text)
        return text:upper()
    end)
end

--- Convert the region to lower case. Emacs `downcase-region`
--- (C-x C-l). Multi-cursor: each selection is transformed.
commands.downcase_region = function(view, _editor)
    view:replace_selections(function(text)
        return text:lower()
    end)
end

----------------------------------------------------------------------------------------------------
-- Region inflection / casing transforms
--
-- All operate on the active selection(s) of every cursor via
-- View:replace_selections (one undo group, multi-cursor aware).
-- Mirrors Emacs `string-inflection`-style transforms; lowercase /
-- uppercase are already available as downcase-region / upcase-region.
----------------------------------------------------------------------------------------------------

--- Split text into word tokens, honoring camelCase / PascalCase and
--- kebab/snake/whitespace delimiters. Returns an array of lowercase
--- word strings (empties filtered).
local function split_words(s)
    -- Insert boundary before an uppercase letter that follows a
    -- lowercase letter or digit (camelCase / digitThenUpper).
    s = s:gsub("([%l%d])(%u)", "%1 %2")
    -- Insert boundary before an uppercase run that's followed by a
    -- lowercase (so "HTTPRequest" -> "HTTP Request").
    s = s:gsub("(%u)(%u%l)", "%1 %2")
    -- Replace every non-alphanumeric run with a space, then collect.
    local words = {}
    for w in s:gmatch("%w+") do
        words[#words + 1] = w:lower()
    end
    return words
end

--- snake_case: lowercased words joined by underscores.
commands.snake_case_region = function(view, _editor)
    view:replace_selections(function(text)
        return table.concat(split_words(text), "_")
    end)
end

--- kebab-case (lisp-case): lowercased words joined by hyphens.
commands.kebab_case_region = function(view, _editor)
    view:replace_selections(function(text)
        return table.concat(split_words(text), "-")
    end)
end

--- camelCase: first word lowercase, subsequent words capitalized,
--- concatenated with no separators.
commands.camelcase_region = function(view, _editor)
    view:replace_selections(function(text)
        local words = split_words(text)
        if #words == 0 then
            return ""
        end
        for i = 2, #words do
            words[i] = words[i]:sub(1, 1):upper() .. words[i]:sub(2)
        end
        return table.concat(words)
    end)
end

--- Minor words skipped inside a title (always capitalized at the
--- start and end of the title).
local TITLE_MINOR = {
    ["a"] = true,
    ["an"] = true,
    ["the"] = true,
    ["and"] = true,
    ["but"] = true,
    ["or"] = true,
    ["nor"] = true,
    ["for"] = true,
    ["yet"] = true,
    ["so"] = true,
    ["on"] = true,
    ["in"] = true,
    ["at"] = true,
    ["to"] = true,
    ["from"] = true,
    ["by"] = true,
    ["of"] = true,
    ["with"] = true,
    ["as"] = true,
    ["into"] = true,
    ["onto"] = true,
    ["upon"] = true,
    ["over"] = true,
    ["under"] = true,
    ["per"] = true,
    ["via"] = true,
    ["is"] = true,
    ["it"] = true,
    ["be"] = true,
}

--- Title Case: capitalize the first letter of each word, lowercasing
--- the rest, EXCEPT minor words (articles / short prepositions /
--- conjunctions) are left lowercase inside the title. The first and
--- last words are always capitalized.
commands.title_case_region = function(view, _editor)
    view:replace_selections(function(text)
        -- Split preserving word tokens and the non-word separators
        -- between them, so spaces / punctuation survive the transform.
        local out = {}
        local word_idx = 0
        local last_i = 1
        local i = 1
        local len = #text
        -- First pass: collect words to know first/last for the
        -- first/last-word rule.
        local words = split_words(text)
        local last_word = words[#words]
        while i <= len do
            local s, e = text:find("%w+", i)
            if not s then
                break
            end
            if s > last_i then
                out[#out + 1] = text:sub(last_i, s - 1)
            end
            local w = text:sub(s, e)
            local lower = w:lower()
            word_idx = word_idx + 1
            local is_first = word_idx == 1
            local is_last = lower == last_word and word_idx == #words
            if is_first or is_last or not TITLE_MINOR[lower] then
                out[#out + 1] = lower:sub(1, 1):upper() .. lower:sub(2)
            else
                out[#out + 1] = lower
            end
            last_i = e + 1
            i = e + 1
        end
        if last_i <= len then
            out[#out + 1] = text:sub(last_i)
        end
        return table.concat(out)
    end)
end

--- Remove all whitespace between words in the selection (squeeze the
--- words together). Useful for joining tokens / stripping spaces.
commands.remove_spaces_region = function(view, _editor)
    view:replace_selections(function(text)
        return (text:gsub("%s+", ""))
    end)
end

----------------------------------------------------------------------------------------------------
-- Balanced-expression (sexp) commands
--
-- Operate on the innermost balanced pair enclosing point (including
-- the delimiters), or — for motion — the adjacent pair when point sits
-- between pairs. ALL of these are pure RANGE composition over the
-- "sexp" textobject function (View:_textobject_fn("sexp"), built by
-- cursed.textobject.sexp). They never touch the matching primitives
-- directly and never recover a pair set: the range-finder owns the
-- pair set privately and returns (sl, sc, el, ec, boundary_len).
--
-- dir convention passed to the fn:
--   nil / >0  containing-or-next-forward  (mark, select, forward, down)
--   <0         containing-or-prev-backward (backward)
--   0          containing-only             (up, backward-up — exit current)
--
-- Transpose is one undo group (direct buffer primitives, no nested
-- batch_edit grouping splitting the swap).
----------------------------------------------------------------------------------------------------

--- Resolve the sexp textobject fn once (cached by _textobject_fn).
--- Returns the callable textobject.fn or nil if no sexp is defined.
---@return function|nil
local function sexp_fn(view)
    return view:_textobject_fn("sexp")
end

--- Select the innermost balanced pair enclosing point (or the next
--- pair forward when between pairs). Proto expand-region semantics.
--- Emacs `mark-sexp` variant.
commands.mark_sexp = function(view, _editor)
    local p = view:p()
    view:select_range("sexp", p.line, p.col)
end

--- Kill the innermost balanced pair enclosing point (incl. delimiters).
--- Emacs `kill-sexp`-ish. Single undo group; pushes the killed text.
commands.kill_sexp = function(view, editor)
    local p = view:p()
    local fn = sexp_fn(view)
    if not fn then
        return
    end
    local sl, sc, el, ec = fn(view, p.line, p.col, nil)
    if not sl then
        return
    end
    local n = view:chars_between(sl, sc, el, ec)
    if n <= 0 then
        return
    end
    local killed = view:text_between(sl, sc, el, ec)
    local buf = view.buffer
    buf:close_edit()
    buf:begin_edit()
    local rl, rc = buf:delete_char(sl, sc, n)
    buf:end_edit()
    p.line = rl
    p.col = rc
    view:_set_goal_col(rc)
    editor:push_kill(killed)
end

--- Copy the innermost balanced pair enclosing point (incl. delimiters)
--- to the kill ring without deleting.
commands.copy_sexp = function(view, editor)
    local p = view:p()
    local fn = sexp_fn(view)
    if not fn then
        return
    end
    local sl, sc, el, ec = fn(view, p.line, p.col, nil)
    if not sl then
        return
    end
    local text = view:text_between(sl, sc, el, ec)
    if #text == 0 then
        editor.status_message = "empty sexp"
        return
    end
    editor:push_kill(text)
    editor.status_message = "sexp copied"
end

--- Interchange the current balanced pair with the previous top-level
--- pair. Emacs `transpose-sexps` (C-M-t). Single-point; one undo group.
--- "Previous" = the pair whose range ends before the current pair's
--- start; found by querying the sexp fn backward from just before the
--- current range's start.
commands.transpose_sexp = function(view, editor)
    local p = view:p()
    local fn = sexp_fn(view)
    if not fn then
        return
    end
    local cs_sl, cs_sc, cs_el, cs_ec = fn(view, p.line, p.col, nil)
    if not cs_sl then
        editor.status_message = "no sexp here"
        return
    end
    -- Query the previous pair by stepping one position before the
    -- current range's start and asking for the backward-adjacent pair.
    local pl, pc = cs_sl, cs_sc - 1
    if pc < 0 then
        if pl > 0 then
            pl = pl - 1
            pc = view:content_len(pl)
        else
            editor.status_message = "no previous sexp"
            return
        end
    end
    local ps_ol, ps_oc, ps_el, ps_ec = fn(view, pl, pc, -1)
    if not ps_ol then
        editor.status_message = "no previous sexp"
        return
    end
    local text_p = view:text_between(ps_ol, ps_oc, ps_el, ps_ec)
    local text_c = view:text_between(cs_sl, cs_sc, cs_el, cs_ec)
    if #text_p == 0 and #text_c == 0 then
        return
    end
    -- Swap spans [ps_ol, cs_ec) -> text_c + text_p, preserving the gap
    -- between the previous pair's end and the current pair's start.
    local gap = view:text_between(ps_el, ps_ec, cs_sl, cs_sc)
    local del_n = view:chars_between(ps_ol, ps_oc, cs_el, cs_ec)
    local buf = view.buffer
    buf:close_edit()
    buf:begin_edit()
    local rl, rc = ps_ol, ps_oc
    if del_n > 0 then
        rl, rc = buf:delete_char(ps_ol, ps_oc, del_n)
    end
    if #text_c + #gap + #text_p > 0 then
        rl, rc = buf:insert_char(rl, rc, text_c .. gap .. text_p)
    end
    buf:end_edit()
    p.line = rl
    p.col = rc
    view:_set_goal_col(rc)
end

--- Move point forward past the next balanced pair (or the one
--- containing point, if inside one). Emacs `forward-sexp` (C-M-f).
--- Pure range composition via View:move_word, which lands at
--- (el, ec + boundary_len) = just past the closer (boundary_len=0).
commands.forward_sexp = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_word(n, "sexp")
end

--- Move point backward before the previous balanced pair (or the one
--- containing point). Emacs `backward-sexp` (C-M-b). Pure range
--- composition via View:move_word, which lands at the range's (sl, sc).
commands.backward_sexp = function(view, _editor, ...)
    local n = repeat_count(...)
    view:move_word(-math.abs(n), "sexp")
end

--- Move point INTO the next nested pair: forward to the next opener
--- strictly after point and just past it. Emacs `down-list` (C-M-d).
--- dir=2 asks the sexp fn for the next opener after point as a
--- degenerate range; landing at (sl, sc+1) steps just past the opener.
commands.down_list = function(view, _editor, ...)
    local n = repeat_count(...)
    local count = math.abs(n) or 1
    local p = view:p()
    local fn = sexp_fn(view)
    if not fn then
        return
    end
    for _ = 1, count do
        local sl, sc = fn(view, p.line, p.col, 2)
        if not sl then
            return
        end
        p.line = sl
        p.col = sc + 1
    end
    view:_set_goal_col(p.col)
end

--- Move point OUT of the current pair (forward to just past its
--- closing delimiter). Emacs `up-list`. dir=0 = containing-only: a
--- no-op when point isn't inside any pair. Lands at the range's end.
commands.up_list = function(view, _editor, ...)
    local n = repeat_count(...)
    local count = math.abs(n)
    local p = view:p()
    local fn = sexp_fn(view)
    if not fn then
        return
    end
    for _ = 1, count do
        local _, _, el, ec = fn(view, p.line, p.col, 0)
        if not el then
            return
        end
        p.line = el
        p.col = ec
    end
    view:_set_goal_col(p.col)
end

--- Move point OUT of the current pair backward (to before its opening
--- delimiter). Emacs `backward-up-list`. dir=0 = containing-only.
--- Lands at the range's start. When point sits ON the opener itself
--- (so the containing pair's opener == point), stepping to it would be
--- a no-op; instead we step one char back to escape that delimiter and
--- re-query, so the NEXT enclosing pair (the parent) is returned and
--- backward-up climbs out — the symmetric counterpart of up_list
--- always landing *past* the closer.
commands.backward_up_list = function(view, _editor, ...)
    local n = repeat_count(...)
    local count = math.abs(n)
    local p = view:p()
    local fn = sexp_fn(view)
    if not fn then
        return
    end
    for _ = 1, count do
        local sl, sc = fn(view, p.line, p.col, 0)
        if not sl then
            return
        end
        if sl == p.line and sc == p.col then
            -- Sitting on the opener: re-query from one char before to
            -- escape this pair's delimiter and get the parent pair.
            local bl, bc = sl, sc - 1
            if bc < 0 then
                if bl > 0 then
                    bl = bl - 1
                    bc = view:content_len(bl)
                else
                    return
                end
            end
            local sl2, sc2 = fn(view, bl, bc, 0)
            if not sl2 then
                return
            end
            sl, sc = sl2, sc2
        end
        p.line = sl
        p.col = sc
    end
    view:_set_goal_col(p.col)
end

----------------------------------------------------------------------------------------------------
-- Quoted insert (C-q)
----------------------------------------------------------------------------------------------------

--- Read one char and insert it literally at point (even if it is
--- normally a control character such as Tab, Newline, or C-g).
--- Emacs `quoted-insert` (C-q).
commands.quoted_insert = function(view, editor)
    editor:read_char("Quoted insert: ", function(ch)
        if ch == nil then
            return
        end
        view:delete_selection()
        -- Translate a few printable control aliases the user might
        -- type via C-q <letter> (terminals deliver these as ctrl
        -- tokens, which read_char can't see as a printable byte).
        -- The common ones (Tab, Newline) map to their literal chars.
        view:insert_char(ch)
    end)
end

----------------------------------------------------------------------------------------------------
-- Regex incremental search (C-M-s / C-M-r)
----------------------------------------------------------------------------------------------------

--- Incremental forward regexp search. Emacs `isearch-forward-regexp`
--- (C-M-s).
commands.isearch_forward_regexp = function(view, editor)
    local query = editor.universal_args and editor.universal_args[2]
    if editor.minibuffer and editor.minibuffer.active then
        editor:isearch_next()
        return
    end
    editor:start_isearch(1, query and tostring(query), { regex = true })
end

--- Incremental backward regexp search. Emacs `isearch-backward-regexp`
--- (C-M-r).
commands.isearch_backward_regexp = function(view, editor)
    local query = editor.universal_args and editor.universal_args[2]
    if editor.minibuffer and editor.minibuffer.active then
        editor:isearch_prev()
        return
    end
    editor:start_isearch(-1, query and tostring(query), { regex = true })
end

----------------------------------------------------------------------------------------------------
-- replace-string / replace-regexp
----------------------------------------------------------------------------------------------------

--- Apply `replacement` for every match of `query` from point to
--- end-of-region (or end-of-document). All replacements share one
--- edit group (one undo step). Cursor lands at the end of the last
--- replacement. Multi-cursor is NOT supported here (matches Emacs'
--- single-point replace-string); the primary cursor is used.
local function apply_replace(view, editor, query, replacement, regex, rsl, rsc, rel, rec)
    local buf = view.buffer
    local p = view:p()
    -- Determine region end.
    local end_line, end_col
    if rel ~= nil then
        end_line, end_col = rel, rec
    else
        end_line = view:line_count() - 1
        end_col = view:content_len(end_line)
    end
    -- If a region: only replace within it. Move the cursor to the
    -- region START (or current point) before searching.
    local start_line, start_col
    if rsl ~= nil then
        start_line, start_col = rsl, rsc
    else
        start_line, start_col = p.line, p.col
    end
    buf:close_edit()
    buf:begin_edit()
    local search_start = { line = start_line, offset = start_col }
    local iter, err
    if regex then
        iter, err = buf:search_regex(query, search_start, false)
    else
        iter = buf:search_forward(query, search_start, true)
        err = nil
    end
    if not iter then
        editor.status_message = "invalid regexp: " .. tostring(err)
        buf:end_edit()
        return
    end
    local count = 0
    local last_line = start_line
    local last_col = start_col
    -- For non-regex searches the buffer mutates and stale iterators are
    -- invalid, so re-create the iterator after each replacement.
    while true do
        local m = iter()
        if not m then
            break
        end
        -- Clamp to the region end if a region was given.
        if rel ~= nil then
            if m.line > end_line or (m.line == end_line and m.end_offset > end_col) then
                break
            end
        end
        -- Delete the match and insert the replacement at match start.
        local mlen = view:chars_between(m.line, m.offset, m.end_line, m.end_offset)
        local rl, rc
        if mlen > 0 then
            rl, rc = buf:delete_char(m.line, m.offset, mlen)
        else
            rl, rc = m.line, m.offset
        end
        if #replacement > 0 then
            rl, rc = buf:insert_char(rl, rc, replacement)
        end
        last_line = rl
        last_col = rc
        count = count + 1
        -- Advance the search iterator past the replacement.
        search_start = { line = rl, offset = rc }
        -- Rebuild the iterator from the new position: the buffer has
        -- mutated, so stale iterators are invalid. Re-compile each step.
        if regex then
            iter, err = buf:search_regex(query, search_start, false)
            if not iter then
                break
            end
        else
            iter = buf:search_forward(query, search_start, true)
        end
    end
    buf:end_edit()
    p.line = last_line
    p.col = last_col
    view:_set_goal_col(last_col)
    view:unset_mark()
    editor.status_message = "replaced " .. count .. (count == 1 and " occurrence" or " occurrences")
end

--- Non-interactive replace driver: reads a query then a replacement
--- via the minibuffer, then applies every match from point (or within
--- the active region) to end-of-region as a single undo group.
--- `regex` selects literal vs POSIX-regex search.
local function run_replace(view, editor, regex)
    local main = editor:current_view()
    if not main or not main.file_loaded then
        return
    end
    -- Determine the operation region: if a selection is active, limit
    -- replacements to [sel-start, sel-end); otherwise [point, end-of-doc).
    local has_region = main:p().anchor_line ~= nil
    local rsl, rsc, rel, rec
    if has_region then
        rsl, rsc, rel, rec = main:selection_range()
        if rsl == nil then
            has_region = false
        end
    end
    local origin_line = main:p().line
    local origin_col = main:p().col
    local label = regex and "Replace regexp: " or "Replace: "
    editor:read_from_minibuffer({
        prompt = label,
        on_cancel = function()
            local mv = editor:current_view()
            if mv then
                mv:unset_mark()
            end
        end,
        on_submit = function(query)
            if #query == 0 then
                return
            end
            editor:read_from_minibuffer({
                prompt = label .. query .. " with: ",
                on_submit = function(replacement)
                    apply_replace(
                        view,
                        editor,
                        query,
                        replacement,
                        regex,
                        has_region and rsl or nil,
                        has_region and rsc or nil,
                        has_region and rel or nil,
                        has_region and rec or nil
                    )
                end,
                on_cancel = function()
                    local mv = editor:current_view()
                    if mv and has_region then
                        mv:p().line = origin_line
                        mv:p().col = origin_col
                        mv:_set_goal_col(origin_col)
                        mv:unset_mark()
                    end
                end,
            })
        end,
    })
end

--- Non-interactive replace from point (or within region) to end.
--- Emacs `replace-string` (M-x replace-string).
commands.replace_string = function(view, editor)
    run_replace(view, editor, false)
end

--- Non-interactive regexp replace from point (or within region) to end.
--- Emacs `replace-regexp` (M-x replace-regexp).
commands.replace_regexp = function(view, editor)
    run_replace(view, editor, true)
end

----------------------------------------------------------------------------------------------------
-- Look up / enumerate commands
----------------------------------------------------------------------------------------------------

--- Look up a command by its user-facing name (spaces → underscores, case-insensitive).
---@param name string
---@return function|nil
function commands.lookup(name)
    return commands[name:gsub(" ", "_"):lower()]
end

--- Return an iterator over all command names (for completion).
---@return function
function commands.names()
    local sorted = {}
    for name, fn in pairs(commands) do
        if advice.callable(fn) and name ~= "lookup" and name ~= "names" then
            sorted[#sorted + 1] = name
        end
    end
    table.sort(sorted)
    local i = 0
    return function()
        i = i + 1
        return sorted[i]
    end
end

return commands
