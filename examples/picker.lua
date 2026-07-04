--- Example: a picker app buffer (see docs/app-buffers-design.md).
---
--- A non-file-backed MajorMode whose buffer text IS the list of items,
--- whose cursor line IS the selected row (whole-line caret highlight),
--- and where typing filters the list. Demonstrates the app-buffer DSL:
--- `on_enter` seeds the buffer, `printable` intercepts typing, custom
--- keybindings drive navigation, and display toggles (no gutter / no
--- wrap / whole-line cursor) reshape the standard render.
---
--- The filter is displayed as raw text on buffer line 0 with a unicode
--- separator line beneath it. When the cursor is on the filter line the
--- mode delegates to the editor's built-in self-insert and delete, giving
--- the "TUI app" full text-editing for free — no custom input handling.
--- Moving off the filter line syncs the text back to the filter string and
--- re-runs the filter.
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
local log = require("cursed.log")

----------------------------------------------------------------------------------------------------
-- Picker helpers (pure buffer-text mutation; no custom rendering)
----------------------------------------------------------------------------------------------------

--- Buffer line indices for the fixed header region.
local HEADER_FILTER_LINE = 0
local HEADER_SEPARATOR_LINE = 1
local HEADER_LINES = 2

--- Build a unicode-dash separator line spanning `width` columns.
---@param width integer terminal width in columns
---@return string
local function build_separator(width)
    return string.rep("─", width)
end

--- Reset `view`'s buffer to hold the filter text on line 0, a separator on
--- line 1, then `lines` (the matched items) on subsequent lines — all as
--- one undo group. If the primary cursor is on the filter line its column
--- is preserved across the rebuild (so in-place editing feels seamless).
--- Otherwise the cursor lands on the first item.
local function set_lines(view, filter, lines)
    local buf = view.buffer
    local term_w = view.editor and view.editor.term:width() or 80

    -- Snapshot cursor state before clearing.
    local cursor_line = view:p().line
    local cursor_on_filter = cursor_line == HEADER_FILTER_LINE
    local saved_col = view:p().col
    log.info("picker", "set_lines", {
        cursor_line = cursor_line,
        cursor_on_filter = cursor_on_filter,
        saved_col = saved_col,
        filter = filter,
        n_items = #lines,
        buf_lines_before = tonumber(buf:line_count()),
    })

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
    -- Assemble: filter, separator, then item lines.
    local all = { filter, build_separator(term_w) }
    for _, l in ipairs(lines) do
        all[#all + 1] = l
    end
    if #all > 0 then
        buf:insert_char(0, 0, table.concat(all, "\n") .. "\n")
    end
    buf:end_edit()
    view:invalidate_wrap_cache()

    -- Restore or reposition cursor.
    local p = view:p()
    local target_line, target_col
    if cursor_on_filter then
        target_line = HEADER_FILTER_LINE
        target_col = math.min(saved_col, #filter)
    else
        target_line = HEADER_LINES
        target_col = 0
    end
    log.info("picker", "set_lines cursor", {
        target_line = target_line,
        target_col = target_col,
        buf_lines_after = tonumber(buf:line_count()),
    })
    p.line = target_line
    p.col = target_col
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
    set_lines(view, f, matched)
end

--- Sync the filter string from the buffer's line 0, then refilter.
--- Used when the user moves off the filter line (enter / down / up) after
--- editing it directly.
local function sync_filter_from_buffer(view)
    local text = view.buffer:line_text(HEADER_FILTER_LINE) or ""
    -- Buffer lines include their trailing newline; strip it.
    if text:sub(-1) == "\n" then
        text = text:sub(1, -2)
    end
    view._picker_filter = text
    refilter(view)
end

--- Trim the last character from `view._picker_filter` and refilter.
--- Used for backspace when the cursor is in the items area (lines below
--- the header).
local function trim_filter(view)
    local f = view._picker_filter or ""
    if #f > 0 then
        view._picker_filter = f:sub(1, #f - 1)
        refilter(view)
    end
end

--- Enter: confirm the selection and close the picker.
--- (The header consumes HEADER_LINES buffer lines, so we subtract that
--- offset to index into the matched-items array.)
local function fire_on_select(view, editor)
    local matched = view._picker_matched or {}
    local idx = view:p().line - HEADER_LINES + 1
    local item = matched[idx]
    if item == nil then
        return
    end
    editor.status_message = "picked: " .. item
    editor:close_view(view)
end

--- Move the cursor to the first item line after syncing the filter.
local function move_to_items(view)
    sync_filter_from_buffer(view)
    local p = view:p()
    p.line = HEADER_LINES
    p.col = 0
    p.goal_col = 0
    view:change_display_opts({ whole_line_cursor = true })
end

--- Move the cursor to the filter line (from the items area).
local function move_to_filter(view)
    local filter_len = #(view._picker_filter or "")
    local p = view:p()
    p.line = HEADER_FILTER_LINE
    p.col = filter_len
    p.goal_col = filter_len
    view:change_display_opts({ whole_line_cursor = false })
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
    -- Cursor starts on the filter line, so use a normal single-cell
    -- cursor there (whole_line_cursor is for selecting items).
    on_enter = function(view, _editor)
        view._picker_filter = view._picker_filter or ""
        refilter(view)
        view:change_display_opts({ whole_line_cursor = false, no_completion = true })
    end,
    keybindings = {
        ["up"] = function(view, _editor)
            local p = view:p()
            if p.line <= HEADER_FILTER_LINE then
                return -- already at the filter line, can't go higher
            end
            if p.line == HEADER_SEPARATOR_LINE then
                move_to_filter(view)
            elseif p.line == HEADER_LINES then
                move_to_filter(view) -- skip separator
            else
                p.line = p.line - 1
            end
        end,
        ["down"] = function(view, _editor)
            local p = view:p()
            if p.line == HEADER_FILTER_LINE then
                move_to_items(view) -- sync filter, refilter, jump to items
            elseif p.line == HEADER_SEPARATOR_LINE then
                p.line = HEADER_LINES
                p.col = 0
                p.goal_col = 0
                view:change_display_opts({ whole_line_cursor = true })
            else
                local max_line = view.buffer:line_count() - 2 -- minus sentinel
                if p.line < max_line then
                    p.line = p.line + 1
                end
            end
        end,
        ["enter"] = function(view, editor)
            local line = view:p().line
            if line == HEADER_FILTER_LINE then
                move_to_items(view) -- sync + refilter + jump
            elseif line >= HEADER_LINES then
                fire_on_select(view, editor)
            end
            -- separator line: no-op
        end,
        ["backspace"] = function(view, _editor)
            local line = view:p().line
            if line == HEADER_FILTER_LINE then
                -- Native deletion on the filter line: delete the character
                -- before the cursor, sync the new text to _picker_filter,
                -- then refilter (set_lines preserves cursor position).
                local p = view:p()
                if p.col > 0 then
                    view:delete_char(-1)
                end
                sync_filter_from_buffer(view)
            elseif line >= HEADER_LINES then
                trim_filter(view)
            end
            -- separator line: no-op
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
    -- Typing behaviour depends on cursor position.
    --   Filter line → delegate to the editor's built-in self-insert
    --                  (editor._printable_fn), then sync & refilter.
    --   Items area  → append to _picker_filter string & refilter.
    --   Separator   → no-op.
    printable = function(view, editor, ch)
        local line = view:p().line
        log.info("picker", "printable", {
            ch = ch,
            line = line,
            filter_before = view._picker_filter,
            buf_lines = view.buffer and tonumber(view.buffer:line_count()),
        })
        if line == HEADER_FILTER_LINE then
            -- Let the editor handle the insertion normally — the mode
            -- piggybacks on decades of text-editing infrastructure for
            -- free (selection deletion, grapheme awareness, electric
            -- pairs, universal-arg repeats, …).
            editor._printable_fn(view, editor, ch)
            log.info("picker", "printable after insert", {
                line_after = view:p().line,
                col_after = view:p().col,
                filter_line_text = view.buffer:line_text(0),
            })
            sync_filter_from_buffer(view)
            return nil -- handled
        elseif line >= HEADER_LINES then
            view._picker_filter = (view._picker_filter or "") .. ch
            refilter(view)
            return nil -- handled
        end
        -- Separator line: no-op.
        return nil
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
