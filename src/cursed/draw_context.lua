--- Headless cell grid for replace-span drawing.
---
--- Replace functions draw into a DrawContext; the renderer stamps the result.
--- No render state, no cursor awareness, no termbox dependency. Pure.
---
--- Coordinates are relative to origin (0, 0). set_cell marks a cell as drawn;
--- all other cells are transparent (left empty). The renderer fills transparent
--- cells with spaces when stamping.

---@class DrawContext
---@field _rows table[] _rows[r] = {{col:integer, ch:string, fg:integer, bg:integer}, ...} sorted by col
---@field _row_max integer[] _row_max[r] = rightmost drawn column on row r, or nil
---@field _rows_used integer highest row index + 1 with at least one drawn cell
---@field _finalized boolean prevent further set_cell after finalize
local DrawContext = {}
DrawContext.__index = DrawContext

--- Create a new DrawContext.
---@return DrawContext
function DrawContext.new()
    return setmetatable({
        _rows = {},
        _row_max = {},
        _rows_used = 0,
        _finalized = false,
    }, DrawContext)
end

--- Mark a cell as drawn. Coordinates relative to origin (0, 0).
--- Only cells passed to set_cell are considered "drawn"; all others
--- are transparent (left as-is when stamped).
---@param row integer 0-based row
---@param col integer 0-based column
---@param ch string single character to draw
---@param fg integer|nil foreground color index (nil defaults to 0)
---@param bg integer|nil background color index (nil defaults to 0)
function DrawContext:set_cell(row, col, ch, fg, bg)
    --assert(not self._finalized, "DrawContext: cannot set_cell after finalize")
    -- Ensure ch is a single character.
    --assert(#ch == 1, ("DrawContext: set_cell expects a single character, got %q"):format(ch))

    local cells = self._rows[row]
    if cells == nil then
        cells = {}
        self._rows[row] = cells
    end
    cells[#cells + 1] = { col = col, ch = ch, fg = fg or 0, bg = bg or 0 }

    -- Track rightmost drawn column per row.
    local cur_max = self._row_max[row]
    if cur_max == nil or col > cur_max then
        self._row_max[row] = col
    end

    -- Track the highest row index we've seen.
    local idx = row + 1
    if idx > self._rows_used then
        self._rows_used = idx
    end
end

--- Return all drawn cells for one row, sorted by column (left to right).
--- Only cells passed to set_cell are included; transparent columns
--- are simply absent from the result.
---@param row_idx integer 0-based row index
---@return {col:integer, ch:string, fg:integer, bg:integer}[]
function DrawContext:row_cells(row_idx)
    local cells = self._rows[row_idx]
    if cells == nil then
        return {}
    end
    -- Sort by column.  set_cell appends, which may not be in col order,
    -- so we sort lazily on first access.
    -- We check if already sorted to avoid resorting every call.
    if not cells._sorted then
        table.sort(cells, function(a, b)
            return a.col < b.col
        end)
        cells._sorted = true
    end
    return cells
end

--- Batch-consecutive helper: stamp a run of cells with identical fg/bg
--- into the row buffer, then print remaining columns as spaces.
---
--- Stamping iterates left-to-right from column 0 up to max_col (exclusive).
--- Consecutive drawn cells that share the same (fg, bg) are batched into a
--- single term:print call; gaps between them are filled with spaces printed
--- one-at-a-time.
---
--- When no cells are drawn on this row, the entire row is filled with spaces
--- using default colors.
---
---@param row_idx integer 0-based row index within the draw context
---@param term table termbox surface; exposes :print(x, y, str, fg, bg)
---@param sx integer screen x origin of this span's left edge
---@param sy integer screen y origin of this span's top row
---@param max_col integer rightmost column to fill (exclusive, typically margin)
function DrawContext:stamp_row(row_idx, term, sx, sy, max_col)
    local cells = self._rows[row_idx]
    if cells == nil or #cells == 0 then
        -- Entire row is transparent: fill with spaces using default colors.
        if max_col > 0 then
            term:print(sx, sy, string.rep(" ", max_col), 0, 0)
        end
        return
    end
    -- Ensure cells are sorted.
    if not cells._sorted then
        table.sort(cells, function(a, b)
            return a.col < b.col
        end)
        cells._sorted = true
    end

    local col = 0
    local ci = 1 -- cursor into cells array
    local nc = #cells

    while col < max_col do
        if ci <= nc and cells[ci].col == col then
            -- Draw cell: batch consecutive cells with same fg/bg.
            local cell = cells[ci]
            local run_fg = cell.fg
            local run_bg = cell.bg
            local run_start = col
            local run_chars = { cell.ch }
            ci = ci + 1
            col = col + 1

            while ci <= nc and col < max_col do
                local next_cell = cells[ci]
                if next_cell.col ~= col then
                    break
                end
                if next_cell.fg ~= run_fg or next_cell.bg ~= run_bg then
                    break
                end
                run_chars[#run_chars + 1] = next_cell.ch
                ci = ci + 1
                col = col + 1
            end

            term:print(sx + run_start, sy, table.concat(run_chars), run_fg, run_bg)
        else
            -- Empty cell: fill with space using default colors.
            -- Batch consecutive empty cells.
            local space_start = col
            while col < max_col and (ci > nc or cells[ci].col > col) do
                col = col + 1
            end
            local nspaces = col - space_start
            if nspaces > 0 then
                term:print(sx + space_start, sy, string.rep(" ", nspaces), 0, 0)
            end
        end
    end
end

--- Finalize and return the footprint.
---
--- After finalize, the DrawContext is immutable (set_cell will not update
--- the footprint).  The returned footprint is used by the wrap algorithm
--- to compute layout.
---
---@return {rows_used: integer, cols_used: integer}
---  rows_used:   total rows occupied (highest drawn row index + 1)
---  cols_used:   rightmost drawn column + 1 on the *last* row, or 0 if
---               the last row has no drawn cells.  The renderer resumes
---               post-span buffer text at this column on the last row.
function DrawContext:finalize()
    self._finalized = true
    local rows_used = self._rows_used
    local last_row = rows_used - 1
    local last_row_max = self._row_max[last_row]
    local cols_used = last_row_max and (last_row_max + 1) or 0
    return { rows_used = rows_used, cols_used = cols_used }
end

return DrawContext
