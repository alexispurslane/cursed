--- Which-key: live chord-completion hint popup.
---
--- While the user is partway through a key chord (a prefix has matched
--- but no command has dispatched yet), the editor sets
--- `editor._whichkey_node` to the current trie node and
--- `editor._whichkey_prefix` to the chord-so-far. This module paints
--- the available next keys as a bottom-aligned floating overlay
--- (registered via the `render_overlay` event) just above the modeline.
---
--- Visual style mirrors the M-x palette: a rounded box (╭─╮ / ╰─╯) with
--- an accent border (minibuffer_prompt + bold) over the modeline
--- CENTER segment's bg color, so it reads as a detached continuation
--- of the modeline. Entries are packed into aligned columns (a key
--- column + a label column, each padded to the widest member across
--- ALL available keys so columns line up across rows and pages). The
--- block sits flush against the bottom of the buffer region.
---
--- Paging: when the available keys overflow the popup's capacity,
--- Page Up / Page Down page the hint instead of feeding the trie
--- (those keys are otherwise undefined mid-prefix). The page index
--- lives on `editor._whichkey_page`, reset to 0 whenever the prefix
--- node changes. Pure rendering otherwise — it only reads editor state
--- the key machinery sets and never mutates it (except try_page).

local bit = require("bit")
local ColorScheme = require("cursed.colorscheme")
local tb = require("cursed.tb")
local keybind = require("cursed.keybind")

----------------------------------------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------------------------------------

-- Max CONTENT rows (excluding the two border rows). Keeps the hint
-- from eating the whole buffer even when a prefix has dozens of bindings.
local MAX_ROWS = 6

-- Max label cell width; command names longer than this are truncated
-- with an ellipsis so one long label can't blow out the column width.
local LABEL_CAP = 18

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

--- Resolve a UI concept color from the active scheme (0xRRGGBB, style OR'd)
--- or fall back to termbox default when no scheme is loaded.
---@param name string concept name
---@return integer
local function ui(name)
    local scheme = ColorScheme.active
    if scheme == nil then
        return tb.color_default
    end
    return scheme:color(name)
end

--- Relative luminance of a truecolor attr (style bits stripped).
--- Mirrors the helper in editor.lua (kept local since it's tiny).
---@param color integer termbox attr (0xRRGGBB [+ style bits])
---@return number
local function luminance(color)
    local c = bit.band(color, 0xFFFFFF)
    local r = bit.band(bit.rshift(c, 16), 0xFF) / 255
    local g = bit.band(bit.rshift(c, 8), 0xFF) / 255
    local b = bit.band(c, 0xFF) / 255
    return 0.299 * r + 0.587 * g + 0.114 * b
end

--- Auto-pick a readable text color for a given resolved bg, exactly as
--- the modeline center segment does: bright (base06) on a dark bg,
--- black (base00) on a light bg. Falls back to modeline_fg when no
--- scheme is loaded. This makes the which-key popup match the
--- modeline's legibility instead of the raw (often dark-on-dark)
--- modeline_fg concept.
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

--- Cell-width of a string (counts UTF-8 codepoints; chrome is 1 cell each).
---@param s string
---@return integer
local function cell_len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- Humanize a command name into a short label for the hint popup.
--- "save_buffer" → "Save Buffer"; "find-file" → "Find File".
---@param cmd string command name
---@return string
local function describe_command(cmd)
    local t = {}
    for word in cmd:gmatch("[^_/]+") do
        t[#t + 1] = word:sub(1, 1):upper() .. word:sub(2):lower()
    end
    if #t == 0 then
        return cmd
    end
    return table.concat(t, " ")
end

--- Describe the action bound at a trie child node for the hint label.
--- Interior nodes (no action) get "more commands"; strings get the
--- humanized command name; functions get "(command)".
---@param action string|function|nil
---@return string
local function describe_action(action)
    if action == nil then
        return "more commands"
    end
    if type(action) == "string" then
        return describe_command(action)
    end
    return "(command)"
end

--- Collect advisory child-key labels for the hint popup, sorted by
--- display key for a stable left→right / top→bottom order.
---@param node keybind.Trie current trie position
---@return table[] entries {key = display, label = string}
local function collect_entries(node)
    local entries = {}
    for tok, child in pairs(node.children) do
        entries[#entries + 1] = {
            key = keybind.format_token(tok),
            label = describe_action(child.action),
        }
    end
    table.sort(entries, function(a, b)
        return a.key < b.key
    end)
    return entries
end

--- Truncate `s` to at most `max` display cells, appending "…" when cut.
---@param s string
---@param max integer max cells
---@return string
local function truncate_cells(s, max)
    if cell_len(s) <= max then
        return s
    end
    if max <= 1 then
        return "…"
    end
    local out, n = {}, 0
    for seq in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
        if n >= max - 1 then
            break
        end
        out[#out + 1] = seq
        n = n + 1
    end
    return table.concat(out) .. "…"
end

----------------------------------------------------------------------------------------------------
-- Layout model
----------------------------------------------------------------------------------------------------

---@class whichkey.Layout
---@field entries table[] all available entries (sorted)
---@field rows table[][] current page's rows of entries
---@field key_col integer key column cell width
---@field label_col integer label column cell width
---@field cell_w integer full cell width (incl. padding)
---@field per_row integer entries per row
---@field page integer current 0-based page index
---@field page_count integer total pages
---@field box_y_top integer top border screen row
---@field box_y_bot integer bottom border screen row (just above the modeline)
---@field content_y_first integer top content row (just below the top border)
---@field footer_y integer|nil footer hint row (just above the bottom border, nil when single-page)
---@field content_w integer usable content width (terminal − 2 border cols)
---@field w integer terminal width

--- Compute the full layout model for the current which-key state.
--- Column widths are derived from ALL entries (not just the current
--- page) so columns stay aligned across pages. Returns nil when
--- there's nothing to show or no room to show it (need ≥ 2 rows for
--- the two borders plus ≥ 1 content row).
---@param editor Editor
---@return whichkey.Layout|nil
local function compute_layout(editor)
    local node = editor._whichkey_node
    if node == nil or next(node.children) == nil then
        return nil
    end
    local term = editor.term
    local w = term:width()
    local h = term:height()
    local footer = editor:footer_rows()
    local modeline_y = h - footer
    local box_y_bot = modeline_y - 1 -- bottom border sits just above modeline
    -- Need ≥ 2 rows for the two borders plus ≥ 1 content row.
    if box_y_bot < 2 then
        return nil
    end
    local rows_avail = math.min(MAX_ROWS, box_y_bot - 1)

    local entries = collect_entries(node)
    if #entries == 0 then
        return nil
    end

    -- Usable content width: full terminal minus the two border columns.
    local content_w = w - 2
    if content_w < 1 then
        return nil
    end

    -- Column widths across ALL entries (stable across pages).
    local key_col = 0
    local label_col = 0
    for _, e in ipairs(entries) do
        local kw = cell_len(e.key)
        local lw = math.min(cell_len(e.label), LABEL_CAP)
        if kw > key_col then
            key_col = kw
        end
        if lw > label_col then
            label_col = lw
        end
    end

    -- Shrink the label column so at least one entry fits per content row.
    local min_cell = 1 + key_col + 2 + 2 -- leading + key + gap + trailing, no label
    if min_cell > content_w then
        -- Terminal too narrow even for the bare key: clip the key column.
        key_col = math.max(0, content_w - 5)
        min_cell = 1 + key_col + 2 + 2
    end
    label_col = math.min(label_col, content_w - min_cell)
    if label_col < 0 then
        label_col = 0
    end
    local cell_w = 1 + key_col + 2 + label_col + 2

    local per_row = math.max(1, math.floor(content_w / cell_w))
    -- Footer hint row is reserved ONLY when the hint would actually
    -- page (entries overflow the box). It costs one content row to
    -- explain "PgUp / PgDn scroll", so we never show it on a single
    -- page where there's nothing to scroll.
    local capacity_full = per_row * rows_avail
    local footer = #entries > capacity_full
    local content_rows = footer and (rows_avail - 1) or rows_avail
    if content_rows < 1 then
        return nil
    end
    local capacity = per_row * content_rows
    local page_count = math.max(1, math.ceil(#entries / capacity))

    local page = editor._whichkey_page or 0
    if page >= page_count then
        page = page_count - 1
    end
    if page < 0 then
        page = 0
    end
    if page ~= (editor._whichkey_page or 0) then
        editor._whichkey_page = page
    end

    -- Current page slice.
    local start = page * capacity
    local slice_n = math.min(#entries, start + capacity) - start
    local slice = {}
    for i = 1, slice_n do
        slice[i] = entries[start + i]
    end

    -- Pack the slice into rows of `per_row`.
    local rows = {}
    for i = 1, #slice, per_row do
        local r = {}
        for j = i, math.min(i + per_row - 1, #slice) do
            r[#r + 1] = slice[j]
        end
        rows[#rows + 1] = r
    end

    -- Bottom-align the box (bottom border fixed; top border above content).
    local n_rows = #rows
    -- content rows + optional footer row sit between the two borders.
    local footer_y = footer and (box_y_bot - 1) or nil
    local last_content_y = footer and (footer_y - 1) or (box_y_bot - 1)
    local content_y_first = last_content_y - (n_rows - 1)
    local box_y_top = content_y_first - 1

    return {
        entries = entries,
        rows = rows,
        key_col = key_col,
        label_col = label_col,
        cell_w = cell_w,
        per_row = per_row,
        page = page,
        page_count = page_count,
        box_y_top = box_y_top,
        box_y_bot = box_y_bot,
        content_y_first = content_y_first,
        footer_y = footer_y,
        content_w = content_w,
        w = w,
    }
end

----------------------------------------------------------------------------------------------------
-- Paint
----------------------------------------------------------------------------------------------------

--- Paint one entry cell at (x, y) with aligned key/label columns.
---@param ov OverlayManager
---@param x integer
---@param y integer
---@param e table entry {key, label}
---@param key_col integer
---@param label_col integer
---@param bg integer
---@param key_fg integer
---@param label_fg integer
local function paint_cell(ov, x, y, e, key_col, label_col, bg, key_fg, label_fg)
    local key = e.key
    local label = e.label
    if label_col == 0 then
        label = ""
    else
        label = truncate_cells(label, label_col)
    end
    ov:put_float(x, y, " ", key_fg, bg) -- leading pad
    local kx = x + 1
    ov:put_float(kx, y, key .. string.rep(" ", key_col - cell_len(key)), key_fg, bg)
    local gx = kx + key_col
    ov:put_float(gx, y, "  ", label_fg, bg) -- key→label gap
    local lx = gx + 2
    if label_col > 0 then
        ov:put_float(lx, y, label .. string.rep(" ", label_col - cell_len(label)), label_fg, bg)
    end
    local tx = lx + label_col
    ov:put_float(tx, y, "  ", label_fg, bg) -- trailing pad
end

--- Paint the popup from a computed layout: rounded top/bottom borders
--- over the modeline center bg, then the content rows inside.
---@param ov OverlayManager
---@param lay whichkey.Layout
local function paint_popup(ov, lay)
    -- Colors: bg = modeline center segment color; text color auto-
    -- detected from that bg's luminance (matching the modeline's
    -- own legibility, NOT the raw modeline_fg which is dark-on-dark
    -- on dark schemes like catppuccin-mocha). Border + keys get bold
    -- so the intent of each chord key reads as a header.
    local bg = ui("modeline_bg")
    local text_fg = auto_text_color(bg)
    local border_fg = bit.bor(text_fg, tb.bold)
    local key_fg = bit.bor(text_fg, tb.bold)
    local label_fg = text_fg

    local n_rows = #lay.rows

    -- Fill the whole box (borders + content + footer) with modeline_bg
    -- so it paints over the buffer cleanly as a solid chrome strip.
    for r = lay.box_y_top, lay.box_y_bot do
        ov:put_float(0, r, string.rep(" ", lay.w), label_fg, bg)
    end

    -- Top border: ╭─...─╮
    ov:put_float(0, lay.box_y_top, "╭" .. string.rep("─", lay.w - 2) .. "╮", border_fg, bg)
    -- Bottom border: ╰─...─╯
    ov:put_float(0, lay.box_y_bot, "╰" .. string.rep("─", lay.w - 2) .. "╯", border_fg, bg)

    -- Content rows: inset by 1 (inside the borders).
    for r = 1, n_rows do
        local y = lay.content_y_first + (r - 1)
        local x = 1
        for _, e in ipairs(lay.rows[r]) do
            paint_cell(ov, x, y, e, lay.key_col, lay.label_col, bg, key_fg, label_fg)
            x = x + lay.cell_w
        end
    end

    -- Footer hint + page indicator (only when paging is actually
    -- needed). The footer row sits just above the bottom border and
    -- tells the user which keys scroll the hint pages. The help hint
    -- is yellow (base0A) so it stands out as an instruction.
    if lay.page_count > 1 and lay.footer_y ~= nil then
        local scheme = ColorScheme.active
        local yellow = scheme and scheme:slot_color(0x0A) or ui("minibuffer_metadata")
        local hint = "PgUp / PgDn  scroll pages"
        ov:put_float(1, lay.footer_y, hint, yellow, bg)
        local ind = string.format("(%d/%d)", lay.page + 1, lay.page_count)
        local ix = lay.w - 1 - cell_len(ind)
        ov:put_float(ix, lay.footer_y, ind, label_fg, bg)
    end
end

----------------------------------------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------------------------------------

local WhichKey = {}

--- Register the which-key render listener on the editor's event hub.
--- Paints nothing when `editor._whichkey_node` is nil (no active prefix).
---@param editor Editor
function WhichKey.setup(editor)
    local es = editor.event_system
    es:on("render_overlay", function(ed)
        local ov = ed.overlays
        if ov == nil then
            return
        end
        local lay = compute_layout(ed)
        if lay == nil then
            return
        end
        paint_popup(ov, lay)
    end)
end

--- Input hook: while a prefix is held and the hint popup overflows,
--- Page Up / Page Down page the popup instead of feeding the trie
--- (those keys are otherwise undefined mid-prefix). Returns true when
--- the key was consumed (caller skips trie dispatch); false otherwise.
---@param editor Editor
---@param token string key token from event_to_token
---@return boolean handled
function WhichKey.try_page(editor, token)
    if token ~= "pagedown" and token ~= "pageup" then
        return false
    end
    local lay = compute_layout(editor)
    if lay == nil or lay.page_count <= 1 then
        return false
    end
    local cur = editor._whichkey_page or 0
    if token == "pagedown" then
        if cur + 1 < lay.page_count then
            editor._whichkey_page = cur + 1
        end
        -- At the last page: consume (no-op) so paging doesn't flash
        -- "undefined chord".
        return true
    else
        if cur > 0 then
            editor._whichkey_page = cur - 1
        end
        return true
    end
end

return WhichKey
