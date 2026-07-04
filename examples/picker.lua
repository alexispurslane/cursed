--- Example: a picker app buffer (see docs/app-buffers-design.md).
---
--- A non-file-backed MajorMode whose buffer text IS the list of items,
--- whose cursor line IS the selected row (whole-line caret highlight),
--- and where typing filters the list. Demonstrates the app-buffer DSL:
--- `on_enter` seeds the buffer, `printable` intercepts typing, custom
--- keybindings drive navigation, and display toggles (no gutter / no
--- wrap / whole-line cursor) reshape the standard render.
---
--- Load unsandboxed (just like init.lua) via:
---     M-x load file <RET> examples/picker.lua <RET>
--- then open it with:
---     M-x open picker <RET>
---
--- When loaded via `load-file`, this chunk runs against the main-thread
--- globals: `editor`, `require`, and `_G` are all available, so it can
--- define a command (`open picker`) that lives on the real editor.

local MajorMode = require("cursed.major_mode")
local View = require("cursed.view").View
local Buffer = require("cursed.buffer").Buffer

----------------------------------------------------------------------------------------------------
-- Picker helpers (pure buffer-text mutation; no custom rendering)
----------------------------------------------------------------------------------------------------

--- Reset `view`'s buffer to hold exactly `lines` (one buffer line each),
--- as one undo group, and place the primary cursor at the top. Used both
--- to seed the list on enter and to refilter on each keystroke.
local function set_lines(view, lines)
    local buf = view.buffer
    buf:close_edit()
    buf:begin_edit()
    -- Clear back to the single empty sentinel line.
    while buf:line_count() > 1 do
        buf:delete_char(0, 0, buf:line_len(0))
    end
    local content_len = buf:line_len(0) - 1
    if content_len > 0 then
        buf:delete_char(0, 0, content_len)
    end
    -- Insert the lines as one string (each terminated by '\n'); insert_char
    -- handles embedded newlines and splits them into per-line piece tables.
    if #lines > 0 then
        buf:insert_char(0, 0, table.concat(lines, "\n") .. "\n")
    end
    buf:end_edit()
    view:invalidate_wrap_cache()
    -- Cursor → top-left; the whole-line caret highlights row 0.
    local p = view:p()
    p.line = 0
    p.col = 0
    p.goal_col = 0
    p.visual_col = nil
    p.yank_line = nil
    p.yank_col = nil
end

--- Rebuild the buffer from `view._picker_items` filtered by
--- `view._picker_filter` (case-insensitive substring). The matched list is
--- cached on the view so `fire_on_select` can resolve cursor.line → item.
local function refilter(view)
    local items = view._picker_items or {}
    local f = view._picker_filter or ""
    local needle = #f > 0 and f:lower() or nil
    local matched = {}
    if needle then
        for _, it in ipairs(items) do
            if type(it) == "string" and it:lower():find(needle, 1, true) then
                matched[#matched + 1] = it
            end
        end
    else
        for _, it in ipairs(items) do
            if type(it) == "string" then
                matched[#matched + 1] = it
            end
        end
    end
    view._picker_matched = matched
    set_lines(view, matched)
end

--- Enter: confirm the selection and close the picker.
local function fire_on_select(view, editor)
    local matched = view._picker_matched or {}
    local idx = view:p().line + 1
    local item = matched[idx]
    if item == nil then
        return
    end
    editor.status_message = "picked: " .. item
    editor:close_view(view)
end

--- Backspace: trim the last filter char and refilter.
local function trim_filter(view)
    local f = view._picker_filter or ""
    if #f > 0 then
        view._picker_filter = f:sub(1, #f - 1)
        refilter(view)
    end
end

----------------------------------------------------------------------------------------------------
-- The Picker MajorMode
----------------------------------------------------------------------------------------------------

local Picker = MajorMode.new({
    name = "picker",
    -- Display toggles: no gutter/wrap, whole-line caret = the selected row.
    no_gutter = true,
    no_wrap = true,
    whole_line_cursor = true,
    -- App buffers don't use multiple cursors.
    multi_currency = false,
    -- Seed the buffer with the full (unfiltered) item list on enter.
    on_enter = function(view, _editor)
        view._picker_filter = view._picker_filter or ""
        refilter(view)
    end,
    keybindings = {
        ["up"] = "previous_line",
        ["down"] = "next_line",
        ["enter"] = function(view, editor)
            fire_on_select(view, editor)
        end,
        ["backspace"] = function(view, _editor)
            trim_filter(view)
        end,
        ["escape"] = function(view, editor)
            editor:close_view(view)
        end,
        ["ctrl-g"] = function(view, editor)
            editor:close_view(view)
        end,
        ["q"] = function(view, editor)
            editor:close_view(view)
        end,
    },
    -- Typing appends to the filter and refilters the buffer in place.
    printable = function(view, _editor, ch)
        view._picker_filter = (view._picker_filter or "") .. ch
        refilter(view)
    end,
})

----------------------------------------------------------------------------------------------------
-- Command: open picker (M-x open picker)
----------------------------------------------------------------------------------------------------

editor:define_command("open picker", function(_view, editor)
    -- A demo item set: files in the current directory (fallback to a
    -- hardcoded list). Swap `items` for any string list to repurpose the
    -- picker (buffers, git files, LSP symbols, …).
    local items
    local p = io.popen("ls -1 2>/dev/null")
    if p then
        items = {}
        for line in p:lines() do
            items[#items + 1] = line
        end
        p:close()
    end
    if items == nil or #items == 0 then
        items = { "alpha", "bravo", "charlie", "delta", "echo", "foxtrot" }
    end

    local buf = Buffer.new()
    local view = View.new(buf)
    view.file_loaded = true
    view._picker_items = items
    view._picker_filter = ""
    editor:add_view(view) -- sets view.editor, focuses, emits view_open
    view:activate_major_mode(Picker) -- mode_enter → on_enter → refilter seeds buffer
end)
