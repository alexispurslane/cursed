--- Shared completion-list rendering utilities.
---
--- Consolidates the completion-list painting logic that was duplicated
--- between `minibuffer.lua` and `completion_menu.lua`. Provides:
---
---   • `cell_len`, `truncate_cells`  — display-cell string operations
---   • `match_byte_set`              — drives match highlighting
---   • `print_highlighted`           — paint one item row with match spans
---   • `comp_text`, `comp_meta`      — normalize completion-item access
---   • `paint_candidate_list`        — unified scrollable list + scrollbar
---
--- The canonical home for `comp_text` / `comp_meta` moved here from
--- `minibuffer.lua`; callers that previously reached them via the
--- `completers` module are updated to import from here.

local bit = require("bit")
local tb = require("cursed.tb")

--- Display width of `s` in terminal cells: codepoint count. Assumes no
--- double-wide CJK (true for cursed's chrome).
---@param s string
---@return integer
local function cell_len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- Truncate `s` to at most `max` display cells, never splitting a
--- multibyte codepoint.
---@param s string
---@param max integer max cells
---@return string
local function truncate_cells(s, max)
    if max <= 0 then
        return ""
    end
    local cells = 0
    local byte_end = 0
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local len = b < 0x80 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
        if cells + 1 > max then
            break
        end
        byte_end = i + len - 1
        cells = cells + 1
        i = i + len
    end
    return s:sub(1, byte_end)
end

--- Extract the display text from a completion item.
---@param item string|{text: string, metadata: string?}
---@return string
local function comp_text(item)
    if type(item) == "table" then
        return item.text or ""
    end
    return item
end

--- Extract the metadata string from a completion item (nil if absent).
---@param item string|{text: string, metadata: string?}
---@return string|nil
local function comp_meta(item)
    if type(item) == "table" then
        return item.metadata
    end
    return nil
end

--- Set of byte positions in `display` covered by the first occurrence
--- of each whitespace-separated term of `query`. Drives match-
--- highlighting in the list (matched chars pop, unmatched recede).
---@param display string visible (already-truncated) item text
---@param query string the prefix/word being completed
---@return table set of byte-index -> true (1-based, inclusive)
local function match_byte_set(display, query)
    local set = {}
    if not query or query == "" then
        return set
    end
    local lower = display:lower()
    for term in query:lower():gmatch("%S+") do
        local i, j = lower:find(term, 1, true)
        if i then
            for b = i, j do
                set[b] = true
            end
        end
    end
    return set
end

--- Print one completion-text row with matched substrings (per
--- `match_byte_set`) drawn in a distinct fg + style so the user can see
--- WHY each candidate matched. Splits into contiguous matched /
--- unmatched byte-runs and prints each with its own fg, advancing by
--- cell width so multi-byte chrome stays aligned. `mset` nil → single
--- unmatch-fg pass (no highlighting).
---@param fp function float-print sink (x, y, text, fg, bg)
---@param cx integer screen col
---@param cy integer screen row
---@param text string
---@param matched_fg integer
---@param unmatch_fg integer
---@param bg_p integer
---@param mset table|nil
---@param matched_style integer|nil additional style bits OR'd onto matched fg
local function print_highlighted(
    fp,
    cx,
    cy,
    text,
    matched_fg,
    unmatch_fg,
    bg_p,
    mset,
    matched_style
)
    local n = #text
    if n == 0 then
        return
    end
    local sx = cx
    local run_start = 1
    local cur = (mset ~= nil) and (mset[1] or false) or false
    for i = 2, n + 1 do
        local m = (mset ~= nil) and (mset[i] or false) or false
        if m ~= cur or i == n + 1 then
            local seg_end = i - 1
            if seg_end >= run_start then
                local sub = text:sub(run_start, seg_end)
                local fg = cur and matched_fg or unmatch_fg
                if cur and matched_style then
                    fg = bit.bor(fg, matched_style)
                end
                fp(sx, cy, sub, fg, bg_p)
                sx = sx + cell_len(sub)
            end
            run_start = i
            cur = m
        end
    end
end

--- Paint a scrollable candidate list with selection bar, per-item match
--- highlighting, metadata column, and scrollbar.
---
--- The list is painted starting at (x, y), one item per row, up to
--- `max_visible` rows. When the total item count exceeds `max_visible`,
--- a 1-column scrollbar gutter is reserved on the right side.
---
--- Each item is first painted as a full-width bg fill (selection bar or
--- plain bg), then the text and optional metadata are printed on top.
--- Matched substrings (per `match_byte_set`) are highlighted with
--- `colors.accent_fg` / `colors.bright_fg`.
---
---@param fp function float-print sink (x, y, text, fg, bg)
---@param x integer screen col (left edge of the list area, not including borders)
---@param y integer screen row (top of the list)
---@param width integer total available width (cells)
---@param items table[] list of completion items (string or {text, metadata})
---@param selected integer 1-based index of the selected item (0 = none)
---@param scroll integer 0-based scroll offset into `items`
---@param max_visible integer maximum rows to paint
---@param query string the prefix/word being completed (for match highlighting)
---@param bg integer background color for unselected rows
---@param colors table color keys:
---          cursor_fg, cursor_bg  — selection bar text / bg
---          norm_fg                — unselected item text (when no matches)
---          meta_fg                — metadata text (unselected)
---          bright_fg              — matched-chars fg (unselected)
---          dim_fg                 — unmatched-chars fg (unselected)
---          accent_fg              — matched-chars fg (selected row)
---          track_fg, thumb_fg     — scrollbar track / thumb
local function paint_candidate_list(
    fp,
    x,
    y,
    width,
    items,
    selected,
    scroll,
    max_visible,
    query,
    bg,
    colors
)
    local total = #items
    if total == 0 then
        return
    end
    local n = math.min(total - scroll, max_visible)
    if n <= 0 then
        return
    end
    local needs_sb = total > max_visible
    local list_w = needs_sb and (width - 1) or width

    -- Metadata column: longest text + 2-space gap.
    local max_text = 0
    for i = 1, n do
        local tlen = cell_len(comp_text(items[scroll + i]))
        if tlen > max_text then
            max_text = tlen
        end
    end
    local meta_col = max_text + 2
    local show_meta = meta_col + 4 <= list_w

    local cur_fg = colors.cursor_fg
    local cur_bg = colors.cursor_bg
    local norm_fg = colors.norm_fg
    local meta_fg = colors.meta_fg
    local bright_fg = colors.bright_fg
    local dim_fg = colors.dim_fg
    local accent_fg = colors.accent_fg
    local track_fg = colors.track_fg
    local thumb_fg = colors.thumb_fg

    for i = 1, n do
        local ci = scroll + i
        local row = y + i - 1
        local item = items[ci]
        local text = truncate_cells(comp_text(item), list_w)
        local meta = show_meta and comp_meta(item) or nil
        if ci == selected then
            -- Full-width reverse-video selection bar.
            fp(x, row, string.rep(" ", list_w), cur_fg, cur_bg)
            local mset = match_byte_set(text, query)
            if next(mset) then
                print_highlighted(fp, x, row, text, accent_fg, cur_fg, cur_bg, mset, tb.bold)
            else
                fp(x, row, text, cur_fg, cur_bg)
            end
            if meta and meta_col + cell_len(meta) <= list_w then
                fp(x + meta_col, row, meta, cur_fg, cur_bg)
            end
        else
            local mset = match_byte_set(text, query)
            if next(mset) then
                print_highlighted(fp, x, row, text, bright_fg, dim_fg, bg, mset, tb.bold)
            else
                fp(x, row, text, norm_fg, bg)
            end
            if meta and meta_col + cell_len(meta) <= list_w then
                fp(x + meta_col, row, meta, meta_fg, bg)
            end
        end
    end

    -- Scrollbar: a 1-column gutter on the far right.
    if needs_sb then
        local sb_col = x + width - 1
        local scrollable = math.max(1, total - n)
        local thumb_size = math.max(1, math.floor(n * n / total))
        local thumb_top = math.floor(scroll / scrollable * (n - thumb_size))
        if thumb_top < 0 then
            thumb_top = 0
        elseif thumb_top > n - thumb_size then
            thumb_top = n - thumb_size
        end
        for i = 0, n - 1 do
            local on_thumb = i >= thumb_top and i < thumb_top + thumb_size
            fp(sb_col, y + i, on_thumb and "█" or "│", on_thumb and thumb_fg or track_fg, bg)
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    cell_len = cell_len,
    truncate_cells = truncate_cells,
    comp_text = comp_text,
    comp_meta = comp_meta,
    match_byte_set = match_byte_set,
    print_highlighted = print_highlighted,
    paint_candidate_list = paint_candidate_list,
}
