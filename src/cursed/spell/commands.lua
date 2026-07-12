--- Spell commands.
---
--- `flyspell_correct`    — iterate-pick through all misspellings from
---                          point forward using the inline completion
---                          menu. Tab/Enter accept + advance, C-g stops.
--- `autocorrect_word`    — replace the word at point with enchant's top
---                          suggestion (no menu). Universal-arg falls
---                          through to `flyspell_correct` for the word.
--- `flyspell_buffer`     — re-check the whole current buffer.
--- `flyspell_add_to_dict` — add the word at point to the user's personal
---                          dictionary (`*@word` via enchant pipe).
--- `flyspell_ignore_word` — like add_to_dict but session-only: clears
---                          the store entry so it stops squiggling.

local M = {}

local spell = require("cursed.spell")

--- Replace the byte range [s_col, e_col) on `line` in `view.buffer`
--- with `replacement`. One undo group.
---@param view View
---@param line integer 0-based
---@param s_col integer 0-based byte offset
---@param e_col integer 0-based byte offset
---@param replacement string
local function replace_range(view, line, s_col, e_col, replacement)
    local buf = view.buffer
    view:batch_edit(false, function(_c)
        local sl, sc = line, s_col
        local el, ec = line, e_col
        if ec > sc then
            buf:delete_char(sl, sc, ec - sc)
        end
        local rl, rc = sl, sc
        if #replacement > 0 then
            rl, rc = buf:insert_char(sl, sc, replacement)
        end
        return sl, sc, rl, rc, "replace", el, ec
    end)
    view:_set_goal_col(view:p().col)
end

--- Move the primary cursor to (line, col), clamp into view, and ensure
--- the new position is visible. Mirrors the render loop's post-command
--- scroll convention (`scroll_to_cursor(h - footer + 1, true)`).
---@param view View
---@param editor Editor
---@param line integer 0-based
---@param col integer 0-based byte offset
local function goto_pos(view, editor, line, col)
    local p = view:p()
    p.line = line
    p.col = col
    view:_set_goal_col(col)
    local h = editor.term:height() - (editor:footer_rows() - 1)
    view:scroll_to_cursor(h, true)
end

--- Iterate-pick loop: position the cursor on each misspelled word from
--- point forward, open the completion menu with the word's suggestions,
--- and advance on accept or stop on C-g.
---
--- Implementation: the completion_menu's accept() already replaces the
--- word at the cursor with the selected suggestion. We need to hook in
--- AFTER accept to advance to the next word. We install a one-shot
--- on_close callback (the `on_close(accepted, text)` hook added to
--- completion_menu.lua for this purpose).
---@param view View
---@param editor Editor
function M.flyspell_correct(view, editor)
    local store = spell.store(editor)
    if store == nil then
        editor.status_message = "spell: not initialized"
        return
    end
    local buf = view.buffer
    if buf == nil then
        return
    end
    local p = view:p()
    -- Find the first misspelling at-or-after the cursor.
    local entry = store:find_next(buf, p.line, p.col)
    if entry == nil then
        editor.status_message = "spell: no misspellings from point"
        return
    end
    -- Save the old completer; install the spell completer for the
    -- duration of the loop.
    local cm = editor.completion_menu
    local old_completer = cm._completer
    local spell_completer = require("cursed.spell.completers").spell(editor)
    cm:set_completer(spell_completer)

    --- Step to the next correctable misspelling (skipping entries
    --- with no suggestions — enchant returns `# word offset` for
    --- words it has no suggestions for, and the picker has nothing
    --- to offer). Install the on_close hook.
    local function step()
        local p2 = view:p()
        local e = store:find_next(buf, p2.line, p2.col)
        while e ~= nil and (e.suggestions == nil or #e.suggestions == 0) do
            editor.status_message = "spell: '"
                .. (e.word or "?")
                .. "' has no suggestions; skipping"
            p2.line = e.line
            p2.col = e.e_col
            e = store:find_next(buf, p2.line, p2.col)
        end
        if e == nil then
            cm:set_completer(old_completer)
            cm.on_close = nil
            editor.status_message = "spell: done"
            return
        end
        -- Move cursor to the END of the flagged word so build_ctx's
        -- prefix detection picks up the WHOLE word as the prefix (prefix
        -- = trailing word-run immediately left of the cursor). Accept
        -- then deletes [word_start_col, cursor) = [s_col, e_col) and
        -- replaces it with the chosen suggestion.
        goto_pos(view, editor, e.line, e.e_col)
        -- Install the on_close hook BEFORE force_open so accept→close
        -- chains to the next step.
        cm.on_close = function(accepted, _text)
            ---@diagnostic disable-next-line: unused-local
            _text = _text
            if not accepted then
                -- Cancelled (C-g) — stop, restore completer.
                cm:set_completer(old_completer)
                cm.on_close = nil
                editor.status_message = "spell: quit"
                return
            end
            -- Advance past the replaced word. The cursor is now at the
            -- end of the inserted suggestion; find_next searches
            -- strictly after e_col, which is the right place to resume.
            -- Defer one tick so the view's position is settled post-accept.
            editor:schedule_after(0, function()
                step()
                return true
            end)
        end
        -- Force the menu open with the spell completer.
        cm:force_open()
    end

    step()
end

--- Replace the word at point with the top suggestion. With a universal
--- argument, defer to `flyspell_correct` for that one word.
---@param view View
---@param editor Editor
function M.autocorrect_word(view, editor, ...)
    -- When a universal-arg is present, hand off to the picker.
    if select("#", ...) > 0 then
        M.flyspell_correct(view, editor)
        return
    end
    local store = spell.store(editor)
    if store == nil then
        editor.status_message = "spell: not initialized"
        return
    end
    local buf = view.buffer
    if buf == nil then
        return
    end
    local p = view:p()
    local entry = store:word_at(buf, p.line, p.col)
    if entry == nil or entry.suggestions == nil or #entry.suggestions == 0 then
        editor.status_message = "spell: no suggestion for word at point"
        return
    end
    local repl = entry.suggestions[1]
    replace_range(view, entry.line, entry.s_col, entry.e_col, repl)
    editor.status_message = "spell: corrected → " .. repl
end

--- Re-check the whole current buffer.
---@param view View
---@param editor Editor
function M.flyspell_buffer(view, editor)
    local d = editor._spell
    if d == nil then
        editor.status_message = "spell: not initialized"
        return
    end
    local buf = view.buffer
    if buf == nil then
        return
    end
    d:on_buffer_open(buf)
    d:on_edit(buf)
    editor.status_message = "spell: re-checking buffer"
end

--- Add the word at point to the user's personal dictionary. No-op when
--- the cursor isn't on a flagged word.
---@param view View
---@param editor Editor
function M.flyspell_add_to_dict(view, editor)
    local client = spell.client(editor)
    local store = spell.store(editor)
    if client == nil or store == nil then
        editor.status_message = "spell: not initialized"
        return
    end
    local buf = view.buffer
    if buf == nil then
        return
    end
    local p = view:p()
    local entry = store:word_at(buf, p.line, p.col)
    if entry == nil then
        editor.status_message = "spell: no word at point"
        return
    end
    -- enchant's ispell-pipe protocol: `*word\n` adds `word` to the
    -- personal dictionary.
    local k = tostring(buf._ptr)
    local pid = client._procs[k]
    if pid == nil then
        editor.status_message = "spell: no enchant process"
        return
    end
    local proc = require("cursed.proc_client")
    proc.send_stdin(pid, "*" .. entry.word .. "\n")
    editor.status_message = "spell: added '" .. entry.word .. "' to dictionary"
    -- Schedule a re-check so the squiggle disappears.
    editor._spell:on_edit(buf)
end

--- Ignore the word at point for the current session: clears its store
--- entry so it stops squiggling. Doesn't touch the personal dictionary.
---@param view View
---@param editor Editor
function M.flyspell_ignore_word(view, editor)
    local store = spell.store(editor)
    if store == nil then
        editor.status_message = "spell: not initialized"
        return
    end
    local buf = view.buffer
    if buf == nil then
        return
    end
    local p = view:p()
    local entry = store:word_at(buf, p.line, p.col)
    if entry == nil then
        editor.status_message = "spell: no word at point"
        return
    end
    -- Drop just this entry from the store's items list.
    local s = store:for_buf(buf)
    if s ~= nil and s.items ~= nil then
        for i = #s.items, 1, -1 do
            local it = s.items[i]
            if it.line == entry.line and it.s_col == entry.s_col and it.word == entry.word then
                table.remove(s.items, i)
                break
            end
        end
    end
    editor.status_message = "spell: ignored '" .. entry.word .. "' for session"
end

return M
