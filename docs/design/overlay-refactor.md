# Overlay Refactor Design

## Spans

A span decorates a contiguous range of buffer text.

```lua
{ col_s, row_s, col_e, row_e, type, ... }
```

Four span types:

| Type | Mechanism | Overlap | Budget |
|------|-----------|---------|--------|
| `properties` | Inline during render | Allowed (later wins) | Styling + arbitrary metadata |
| `replace` | Token-stream, headless DrawContext | Forbidden (error) | Virtual text, inlays, diffs |
| `layer` | Post-pass overlay in screen-space | Forbidden (error) | HUD, minimap, status |
| `anchor` | Post-pass overlay in buffer-space | Forbidden (error) | Inline decorations that float |

Properties spans carry `{bold, italic, fg, bg, ...}` plus arbitrary keys.
Replace spans carry `{text?}` or `{fn?}` (mutually exclusive).
Layer/anchor spans carry a `draw` function that receives absolute screen coordinates
during the post-processing pass.

## DrawContext

The DrawContext is a headless cell grid. Replace functions draw into it; the
renderer stamps the result. No render state, no cursor awareness. Pure.

```
---@class DrawContext
---@field set_cell   fun(row: integer, col: integer, ch: string, fg?: integer, bg?: integer, ...)
---@field finalize   fun(): { rows_used: integer, cols_used: integer }
---@field row_cells  fun(row_idx: integer): {col:integer, ch:string, fg:integer, bg:integer}[]
---@field stamp_row  fun(row_idx: integer, term: Term, sx: integer, sy: integer, max_col: integer)
```

- Coordinates are relative to origin `(0, 0)`.
- `set_cell` marks a cell as drawn. All other cells are transparent.
- `finalize()` returns the footprint: `rows_used` (total rows occupied) and
  `cols_used` (rightmost drawn column + 1 on the *last* row).
- `row_cells(r)` returns the drawn cells for row `r` as an array of
  `{col, ch, fg, bg}` records. Only drawn cells are present; transparent
  columns are simply absent from the array.
- `stamp_row(r, term, sx, sy, max_col)` writes row `r` directly to a termbox
  surface at screen position `(sx, sy)`, filling undrawn columns with blanks
  up to `max_col` (the margin). This is the fast-path for the renderer.

### Stamp behavior

The DrawContext is stamped at the replace span's screen position. It covers the
full width of every row (column 0 to margin). Transparency handles integration:
undrawn cells are skipped, preserving whatever the renderer already placed there
(preceding buffer text or blanks).

The replace function receives `cols_skipped` — the number of columns already
drawn on the span's starting row. Row 0 columns `[0, cols_skipped)` are a
forbidden zone; the function must leave them transparent. Rows 1+ have no
restriction — full width from column 0.

## Rendering pipeline

Every frame:

1. **Build visual token stream** per logical line. Walk buffer text and sorted
   replace-span list. Emit `TEXT[a,b]` and `REPLACE[span]` tokens. REPLACE
   tokens carry the span (with its `fn`), not the DrawContext — `fn` is called
   during wrapping when `cols_skipped` is known. Token stream is contiguous,
   no gaps.

2. **Wrap.** Greedily consume the token stream at the margin width.
   - TEXT tokens use existing word-break logic (`utf8.compute_wrap` semantics).
   - REPLACE tokens: call `fn(cols_skipped)` → DrawContext. Emit one segment
     per replace row into the corresponding ScreenRow. Recompute `fn(0)` if
     the span doesn't fit on the current row.
   - Output: cached `ScreenRow[]` per logical line.

3. **Render.** Walk ScreenRows.
   - Text segments: apply properties spans, write cells via termbox.
   - Replace segments: stamp the DrawContext row.
   - Cursor: post-pass overlay.

4. **Post-pass.** Render layer and anchor spans.

### Token stream

```lua
---@class LineToken
---@field type       '"text"'|'"replace"'
---@field buf_start  integer   0-based byte offset within the logical line
---@field buf_end    integer   0-based byte offset (exclusive, past-end)
---@field text       string|nil   raw text (TEXT only)
---@field widths     integer[]|nil  display widths per grapheme (TEXT only)
---@field span       table|nil   the replace span (REPLACE only)
```

Token construction per line (called during `View:_build_tokens(li)`):

1. Get the stripped line text and grapheme skeleton (`byte_starts`, `widths`).
2. Intersect the View's sorted replace-span list with this line's byte range.
3. Walk the line, alternating TEXT and REPLACE tokens. TEXT tokens slice the
   line text and carry pre-extracted `widths` per grapheme so the wrap
   algorithm doesn't re-parse.

### Wrap algorithm

```lua
---@class WrapState
---@field row_buf integer   buf_start of the first thing on the current screen row
---@field col     integer   display column cursor within the current screen row
---@field last_space_byte integer|nil  byte offset of last space/TAB on current row

function View:_wrap_line(li)
    local tokens = self:_build_tokens(li)
    local ww = self.wrap_width or 0

    if ww <= 0 then
        return self:_build_unwrapped_rows(li, tokens)  -- single row, no splitting
    end

    local rows = {}       -- ScreenRow[]
    local row_segs = {}   -- segments accumulating on the current screen row
    local ws = { row_buf = 0, col = 0, last_space_byte = nil }

    for _, tok in ipairs(tokens) do
        if tok.type == "text" then
            _wrap_text_token(tok, ww, ws, rows, row_segs)
        else  -- replace
            -- Call the replace function with the current column as cols_skipped.
            local dc = tok.span.fn(ws.col)
            local rows_used, cols_used = dc:finalize()

            -- If the replace starts mid-row and can't fit (overflows margin,
            -- or has multiple rows and would look weird split), push it to
            -- its own row and recompute at col 0.
            if ws.col > 0 and (ws.col + cols_used > ww or rows_used > 1) then
                _flush_row(rows, row_segs, ws.row_buf)
                row_segs = {}
                ws.row_buf = tok.buf_start
                ws.col = 0
                ws.last_space_byte = nil
                dc = tok.span.fn(0)
                rows_used, cols_used = dc:finalize()
            end

            -- Emit one segment per replace row.
            for r = 0, rows_used - 1 do
                if r > 0 then
                    _flush_row(rows, row_segs, ws.row_buf)
                    row_segs = {}
                    ws.row_buf = tok.buf_start
                    ws.col = 0
                end
                table.insert(row_segs, {
                    type      = "replace",
                    buf_start = tok.buf_start,
                    buf_end   = tok.buf_end,
                    draw_ctx  = dc,
                    row_idx   = r,
                })
            end
            ws.col = cols_used
            ws.last_space_byte = nil
        end
    end

    _flush_row(rows, row_segs, ws.row_buf)
    return rows
end
```

**Text-token wrapping** (`_wrap_text_token`) reuses the word-boundary logic from
`utf8.compute_wrap`: walk grapheme widths, track the last space/TAB position,
and when overflow is imminent, backtrack to split there. The difference is
that the output is `RowSegment` records placed into the accumulating
`row_segs` array rather than per-grapheme `sub_rows`/`sub_cols` arrays.

### ScreenRow and RowSegment types

```lua
---@class RowSegment
---@field type       '"text"'|'"replace"'
---@field buf_start  integer   0-based byte offset in the logical line
---@field buf_end    integer   0-based byte offset (exclusive)
---@field text       string|nil   text to render (TEXT only)
---@field col        integer|nil   0-based display column start within the row (TEXT only)
---@field widths     integer[]|nil  display widths per grapheme (TEXT only, for byte↔col mapping)
---@field draw_ctx   DrawContext|nil  (REPLACE only)
---@field row_idx    integer|nil     0-based row within the DrawContext (REPLACE only)

---@class ScreenRow
---@field li         integer       logical line index
---@field sub_row    integer       0-based sub-row index within li
---@field buf_start  integer       0-based byte offset where this screen row starts
---@field buf_end    integer       0-based byte offset where this screen row ends (exclusive)
---@field segments   RowSegment[]
---@field width      integer       total display width of this row
```

### Performance: dual index

`wrap_sub_position(li, byte_offset)` is the hottest query in the system —
the cursor overlay calls it once per visible sub-row (~25× per frame), and
on a 192KB single-line file the existing O(log N) binary search drops this
from ~4ms to sub-millisecond (see view.lua:3020–3025).

ScreenRows alone are O(sub_row_count) for this query (walking rows to find
the byte range). To preserve O(log N), the `_wrap_graph_cache` is **retained**
as a secondary index built alongside ScreenRows:

```lua
-- _screen_rows_cache[li+1] = ScreenRow[]      -- primary: what to render
-- _wrap_graph_cache[li+1] = {                 -- secondary: O(log N) lookup
--     sub_rows, sub_cols, total_rows,           -- per-grapheme positional
--     sub_first, sub_last                       -- grapheme range per sub-row
-- }
```

Both are built in a single pass during `_screen_rows(li)`. The grapheme
skeleton (`_graph`) is always retained — it is the foundation for
`byte_to_col`, `col_to_byte`, `advance_grapheme`, and tab expansion,
independent of wrapping.

### Fast path: no replace spans

`wrap_rows(li)` is called in a tight loop during scroll positioning
(`_extend_wrap_to`) to build the cumulative screen-row table. Building full
ScreenRows (with token streams, replace function calls) just to get a count
would regress scroll performance on large files.

When the View has **no replace spans**, the existing fast path is used:
`_graph` → `compute_wrap` → `total_rows`. Only when replace spans exist on
a line is `_screen_rows(li)` triggered. The row count is cached separately
as `_screen_row_counts[li+1] = integer`, computed during token-stream build.

### Wrap cache

The `_screen_rows_cache[li+1] = {rows = ScreenRow[], counts = integer[]}`
stores both the ScreenRows and per-sub-row widths. Invalidation follows
the same pattern as `_wrap_graph_cache`: keyed on `(_graph_gen, wrap_width)`,
cleared by `_graph_apply_edits` for edited lines, fully rebuilt on
-generation or width change.

Cursor positioning (forward):

```lua
--- Map a buffer position to screen coordinates.
---@return integer sub_row  0-based sub-row within li
---@return integer col      0-based display column within that sub-row
function View:wrap_sub_position(li, byte_offset)
    if no replace spans on this line then
        -- Fast path: O(log N) binary search on _wrap_graph_cache
        return existing implementation
    end
    -- Slow path: walk ScreenRow segments
    ...
end
```

Cursor positioning (reverse):

```lua
--- Map screen coordinates back to a buffer position.
--- Used by mouse clicks and vertical cursor movement (C-n/C-p).
---@return integer byte_offset  0-based byte offset within li
function View:wrap_byte_offset(li, sub_row, sub_col)
    if no replace spans on this line then
        -- Fast path: O(1) via _wrap_graph_cache sub_first/sub_last
        return existing implementation
    end
    -- Slow path: walk the ScreenRow's segments
    -- For TEXT segments, use widths to resolve sub_col → byte offset.
    -- For REPLACE segments, map any sub_col inside the segment to buf_start (clamp).
end
```

Visual line bounds:

```lua
--- Byte range of visual line (sub_row) within logical line li.
--- Used by move_start_of_visual_line / move_end_of_visual_line.
---@return integer buf_start 0-based byte offset
---@return integer buf_end   0-based byte offset (exclusive)
function View:visual_line_bounds(li, sub_row)
    local rows = self:_screen_rows(li)
    local row = rows[sub_row + 1]
    return row.buf_start, row.buf_end
end
```

Grapheme-run enumeration for rendering:

```lua
--- Return the segments for a given (li, sub_row).
--- Replaces the current `sub_row_runs`.
---@return RowSegment[]
---@return integer row_width
function View:screen_row_segments(li, sub_row)
    local rows = self:_screen_rows(li)
    if not rows or sub_row >= #rows then return {}, 0 end
    local row = rows[sub_row + 1]
    return row.segments, row.width
end
```

### Renderer integration

The render loop in `Editor:_render_content` changes from:

```
for each sub_row: runs, row_w = view:sub_row_runs(li, sub_row)
                  paint each run
```

to per-segment iteration:

```
segments, row_w = view:screen_row_segments(li, sub_row)
for each segment:
    if TEXT:
        -- Compute byte range for this segment only (not whole row).
        -- Request highlight_segments for this range.
        -- Paint text with properties spans via adapted _paint_run.
        -- Check selection/isearch overlap against this segment's range.
    if REPLACE:
        draw_ctx:stamp_row(row_idx, term, text_x, row, margin)
        -- Skip highlight/selection/isearch for this segment.
```

Key differences from the current single-chunk approach:
- `chunk_start`/`chunk_end` and `highlight_segments` are computed **per
  TEXT segment**, not once for the whole row. This avoids querying
  highlighting for replaced byte ranges.
- Selection and isearch painting iterates segments, skipping REPLACE
  segments entirely. Selection ranges that span a replace segment are
  split: the TEXT portions on each side are painted, the middle is skipped.
- `_paint_run` is adapted to accept a `RowSegment` (with `text`, `col`,
  `widths`) instead of a raw grapheme run.

### Cursor post-pass

Cursor rendering moves out of the per-sub-row loop into a separate pass
that queries `wrap_sub_position` for each cursor and draws the cursor block.

Cursor character extraction (for non-whole-line cursors):

```
for each cursor:
    sub_row, col = view:wrap_sub_position(c.line, c.col)
    if sub_row matches current screen row:
        -- Find the TEXT segment containing c.col+1
        for each TEXT segment on this row:
            if c.col+1 >= seg.buf_start and c.col+1 <= seg.buf_end then
                local offset = c.col - seg.buf_start
                ch = grapheme_at_display_offset(seg.text, seg.widths, offset)
                ov:put_float(text_x + col, row, ch, cursor_fg, cursor_bg)
                break
            end
        -- If no TEXT segment found (cursor clamped to replace boundary),
        -- default to space character.
```

The `_subrow_cursor` cache (view.lua:91) is removed — `screen_row_segments`
returns pre-built segments from the cache, so the shared forward-walk
optimization is unnecessary.

### Post-pass overlays

Layer and anchor spans are collected during the render loop and painted
after all buffer content. This replaces the existing `overlay.lua`
`put_file`/`put_float` mechanism (which becomes the layer/anchor queue).

### _graph retention

The `_graph(li)` cache (byte_starts, widths, prefix) and `_graph_cache`
are **retained unchanged**. They are the foundation for byte↔column mapping
and are independent of wrapping/replace spans. Only `_wrap_graph_cache`
is replaced by `_screen_rows_cache`.

### Integration with existing wrap infrastructure

| Old API | New API | Notes |
|---------|---------|-------|
| `_wrap_graph(li)` → `sub_rows, sub_cols, total_rows, sub_first, sub_last` | `_screen_rows(li)` → `ScreenRow[]` | Primary output; `_wrap_graph_cache` retained as O(log N) secondary index |
| `wrap_rows(li)` → `total_rows` | Fast path: existing compute_wrap. Only builds ScreenRows when replace spans exist on line | Cached as `_screen_row_counts[li+1]` |
| `sub_row_runs(li, sub_row)` → runs, row_w | `screen_row_segments(li, sub_row)` → segments, row_w | Renderer calls this instead |
| `wrap_sub_position(li, b)` → sub_row, col | Same signature, fast path unchanged | Slow path (replace spans present) walks Segment widths |
| `wrap_byte_offset(li, sub_row, sub_col)` → byte_offset | Same signature, fast path unchanged | Slow path walks Segment widths in reverse |
| `_wrap_graph` sub_first/sub_last (visual line bounds) | `visual_line_bounds(li, sub_row)` → buf_start, buf_end | New dedicated API; reads from ScreenRow.buf_start/buf_end |
| `_wrap_graph_cache` | `_screen_rows_cache` + retained `_wrap_graph_cache` | Dual cache: ScreenRows for rendering, sub_rows/sub_cols for O(log N) lookup |
| `_subrow_cursor` cache | Removed | `screen_row_segments` returns pre-built data; forward-walk sharing unnecessary |

## Replace function contract

```
---@param cols_skipped integer   -- columns already occupied on row 0
---@param dc          DrawContext -- the draw target
---@return nil (footprint retrieved from dc:finalize())
```

No access to render state, cursor, or termbox. Callable headlessly.

## Span lifecycle

- Spans live on the **View** (not the buffer). They are a visual layer through
  which the buffer is viewed.
- Buffer insertions/deletions adjust span positions (same mechanism as
  `hl_spans`).
- A span whose range collapses to zero width is deleted.
- Span mutations lodge a 0ms background task, forcing a re-render on the next
  event-loop turn.
- The span cursor is reset on every re-render.

## Properties spans as metadata

Properties spans double as a spatial key-value store, Emacs text-properties
style. The View exposes query helpers:

```
View:query_at(pos)      → merged properties table at buffer position
View:query_range(a,b)   → iterator of (range, properties)
```

Lookup is O(log n) via the span list. This will eventually absorb `hl_spans`
(highlighting, spelling squiggles, etc.).

## State access

For diagnostic/debug use, the View may expose a read-only snapshot of Editor and
View state via metatable wrappers (shallow `__newindex` block). Replace
functions do not receive or use these.
