--- Span manager: owns the span lifecycle for a View.
---
--- Combines the former View span methods (add_span, remove_span, query_at,
--- adjust_on_edit) with the overlay manager's frame lifecycle and
--- coordinate mapping — one class for all span types.
---
--- Span types:
---   • properties — inline-rendered attributes (fg, bg, underline, bold,
---     italic); can be ephemeral (spellcheck squiggles, diagnostic underlines).
---     When carrying a `text` field, renders as virtual text (replacement
---     text overlay) instead of the underlying buffer content.
---   • anchor — file-anchored text overlay, painted in flush() after
---     buffer-to-screen resolution. Ephemeral (re-registered each frame).
---   • layer — absolute screen-space overlay (cursor, modeline, popups),
---     painted in flush() at fixed screen coordinates. Ephemeral.
---
--- Frame lifecycle (called by Editor:render in order):
---   1. begin_frame()         — reset layer/anchor staging for this frame
---   2. _render_content uses:
---      - position_cursor(li) — fast-forward cursor to first span on a line
---      - properties_at(li, byte_pos) — advance cursor + collect properties
---   3. finish_frame(term)    — clean off-screen ephemeral, fire render_overlay,
---                              paint staged anchors + layers to terminal

local log = require("cursed.log")
local profile = require("cursed.profile")

local SpanManager = {}
SpanManager.__index = SpanManager

--- Create a span manager for a view.
---@param editor Editor owning editor (for event system, term)
---@param view View owning view
---@return SpanManager
function SpanManager.new(editor, view)
    return setmetatable({
        _editor = editor,
        _view = view,
        _spans = nil,        -- sorted array of all spans (properties, anchor)
        _gen = 0,            -- bumped on every mutation
        _cursor = nil,       -- monotonic cursor for inline frame traversal
        _vcursor = nil,      -- cursor for query_virtual_span_at
        _vcursor_line = nil, -- current line for _vcursor
        _staging = {},       -- per-frame list of layer + anchor spans for flush painting
    }, SpanManager)
end

--- Expose internals for View delegation.
function SpanManager:spans()
    return self._spans
end

function SpanManager:gen()
    return self._gen
end

function SpanManager:set_gen(v)
    self._gen = v
end

-- ============================================================================
-- Frame lifecycle
-- ============================================================================

--- Begin a render frame: reset layer/anchor staging.
--- Properties spans survive across frames (they're inline-rendered and
--- cleaned up by the cursor traversal in _render_content). Off-screen
--- ephemeral properties are cleaned by finish_frame.
function SpanManager:begin_frame()
    self._staging = {}
    self._cursor = nil
    self._vcursor = nil
    self._vcursor_line = nil
end

--- Finish a render frame: clean off-screen ephemeral properties spans,
--- fire the render_overlay event so listeners register new spans, paint
--- staged anchors + layers to the terminal, then clear staging.
---@param term table terminal surface
function SpanManager:finish_frame(term)
    -- Step 1: Remove ephemeral spans from _spans that were NOT caught by
    -- the cursor (spans on lines scrolled out of the viewport). The cursor
    -- already cleaned in-viewport ephemerals during _render_content.
    if self._spans then
        local kept = {}
        for _, s in ipairs(self._spans) do
            if not s.ephemeral then
                kept[#kept + 1] = s
            end
        end
        self._spans = kept
        if #self._spans == 0 then
            self._spans = nil
        end
        self._gen = self._gen + 1
    end

    -- Step 2: Fire render_overlay event so listeners register their
    -- overlays for this frame. Listeners call add_properties_span / add_layer_span
    -- / add_anchor, which add to _spans and/or _staging.
    local es = self._editor.event_system
    if es then
        local n = 0
        local listeners = es._handlers and es._handlers["render_overlay"]
        if listeners then
            n = #listeners
        end
        if profile.enabled then
            log.info("span_manager", "finish_frame", { listeners = n })
        end
        local t0 = profile.now_us()
        es:emit("render_overlay", self._editor)
        profile.span("span_manager", "finish_frame_event", t0, { listeners = n })
    end

    -- Step 3: Paint staged spans.
    -- Phase A: anchor spans (file-anchored, buffer-space). Resolve to
    -- screen via file_to_screen; skip off-screen.
    local t0 = profile.now_us()
    for _, s in ipairs(self._staging) do
        if s.type == "anchor" then
            local sx, sy = self:file_to_screen(s.row_s, s.col_s)
            s:draw(term, sx, sy)
        end
    end
    profile.span("span_manager", "flush_anchor", t0, {
        count = self:_staging_count("anchor"),
    })

    -- Phase B: layer spans (screen-space floating). Paint in registration
    -- order; later wins.
    local t1 = profile.now_us()
    for _, s in ipairs(self._staging) do
        if s.type == "layer" then
            s:draw(term)
        end
    end
    profile.span("span_manager", "flush_layer", t1, {
        count = self:_staging_count("layer"),
    })

    -- Step 4: Clear staging for next frame.
    self._staging = {}
end

--- Count staged spans of a given type.
---@param span_type string
---@return integer
function SpanManager:_staging_count(span_type)
    local n = 0
    for _, s in ipairs(self._staging) do
        if s.type == span_type then
            n = n + 1
        end
    end
    return n
end

-- ============================================================================
-- Inline rendering cursor (properties spans only)
-- ============================================================================

--- Position the frame cursor at the first properties span intersecting
--- the given logical line. Advances monotonically from the previous
--- line's position — O(n) total per frame.
--- Ephemeral properties spans that the cursor passes are removed from
--- _spans (they were rendered in the previous frame).
---@param li integer 0-based logical line index
function SpanManager:position_cursor(li)
    if not self._spans then
        self._cursor = 1
        return
    end
    if not self._cursor then
        self._cursor = 1
    end
    while self._cursor <= #self._spans do
        local s = self._spans[self._cursor]
        if s.type ~= "properties" then
            self._cursor = self._cursor + 1
        elseif s.row_e < li then
            if s.ephemeral then
                table.remove(self._spans, self._cursor)
                self._gen = self._gen + 1
                -- cursor stays at same index (next span shifted in)
            else
                self._cursor = self._cursor + 1
            end
        else
            break
        end
    end
end

--- Advance the frame cursor past properties spans ending at or before
--- (li, byte_pos), removing ephemeral ones. Then collect overlapping
--- properties spans at (li, byte_pos) and return merged properties.
--- Returns nil when no properties span covers this position.
---
--- The returned table has `fg`, `bg`, `underline_color`, `bold`,
--- `italic` keys (and any other custom properties) with later-wins
--- merge order.
---@param li integer 0-based logical line index
---@param byte_pos integer 0-based byte offset
---@return table|nil merged properties, or nil
function SpanManager:properties_at(li, byte_pos)
    if not self._spans then
        return nil
    end

    -- Advance cursor past ended spans, removing ephemeral
    while self._cursor and self._cursor <= #self._spans do
        local s = self._spans[self._cursor]
        if s.type ~= "properties" then
            self._cursor = self._cursor + 1
        elseif s.row_e < li or (s.row_e == li and s.col_e <= byte_pos) then
            if s.ephemeral then
                table.remove(self._spans, self._cursor)
                self._gen = self._gen + 1
            else
                self._cursor = self._cursor + 1
            end
        else
            break
        end
    end

    if not self._cursor or self._cursor > #self._spans then
        return nil
    end

    -- Collect overlapping properties spans from cursor forward
    local result = nil
    local i = self._cursor
    while i <= #self._spans do
        local s = self._spans[i]
        if s.type ~= "properties" then
            i = i + 1
        else
            -- Check if this span covers (li, byte_pos)
            local covers = false
            if s.row_s < li and s.row_e > li then
                covers = true
            elseif s.row_s == li and s.row_e > li then
                covers = byte_pos >= s.col_s
            elseif s.row_s < li and s.row_e == li then
                covers = byte_pos < s.col_e
            elseif s.row_s == li and s.row_e == li then
                covers = byte_pos >= s.col_s and byte_pos < s.col_e
            end

            if covers then
                if not result then
                    result = {}
                end
                -- Later-wins merge: copy non-coordinate fields
                for k, v in pairs(s) do
                    if k ~= "type" and k ~= "col_s" and k ~= "row_s"
                        and k ~= "col_e" and k ~= "row_e" and k ~= "ephemeral" then
                        result[k] = v
                    end
                end
                i = i + 1
            elseif s.row_s > li or (s.row_s == li and s.col_s > byte_pos) then
                -- Past any span that could cover this position
                break
            else
                i = i + 1
            end
        end
    end

    return result
end

-- ============================================================================
-- Overlay registration (called during render_overlay event or core chrome)
-- ============================================================================

--- Register a properties span with attributes.
--- Rendered inline via the span cursor in the NEXT frame (one-frame delay).
--- `attrs` is a table with any combination of `fg`, `bg`, `underline_color`,
--- `bold`, `italic`, etc. The span is ephemeral by default; set
--- `attrs.ephemeral = false` to prevent automatic cleanup.
---@param line integer 0-based logical line index
---@param s_col integer 0-based byte offset of range start (inclusive)
---@param e_col integer 0-based byte offset of range end (exclusive)
---@param attrs table property key-value pairs (fg, bg, underline_color, bold, italic, ...)
function SpanManager:add_properties_span(line, s_col, e_col, attrs)
    if e_col <= s_col then
        return
    end
    local span = {
        type = "properties",
        row_s = line,
        col_s = s_col,
        row_e = line,
        col_e = e_col,
        ephemeral = true,
    }
    -- Copy caller attributes (can override ephemeral)
    for k, v in pairs(attrs) do
        span[k] = v
    end
    self:add(span)
end

--- Register a floating layer span at absolute screen coordinates.
--- Painted in the current frame's flush phase — no delay.
---@param sx integer screen column (0-based)
---@param sy integer screen row (0-based)
---@param text string
---@param fg integer
---@param bg integer
function SpanManager:add_layer_span(sx, sy, text, fg, bg)
    local span = {
        type = "layer",
        sx = sx,
        sy = sy,
        text = text,
        fg = fg,
        bg = bg,
        draw = function(self, term)
            term:print(self.sx, self.sy, self.text, self.fg, self.bg)
        end,
    }
    table.insert(self._staging, span)
end

--- Register a file-anchored anchor span.
--- Resolved to screen and painted in the current frame's flush phase.
--- Stored in both _spans (for ephemeral cleanup) and staging (for painting).
---@param line integer 0-based logical line
---@param col integer 0-based byte offset within the line
---@param text string
---@param fg integer
---@param bg integer
function SpanManager:add_anchor_span(line, col, text, fg, bg)
    local span = {
        type = "anchor",
        row_s = line,
        col_s = col,
        row_e = line,
        col_e = col + 1,
        text = text,
        fg = fg,
        bg = bg,
        ephemeral = true,
        draw = function(self, term, sx, sy)
            if sx ~= nil and sy ~= nil then
                term:print(sx, sy, self.text, self.fg, self.bg)
            end
        end,
    }
    -- Insert directly into _spans (no overlap checking for anchors;
    -- later-wins z-order is intended).
    if not self._spans then
        self._spans = {}
    end
    local idx = self:_insertion_index(span.row_s, span.col_s)
    table.insert(self._spans, idx, span)
    self._gen = self._gen + 1

    -- Also stage for flush painting
    table.insert(self._staging, span)
end

-- ============================================================================
-- Span CRUD (sorted insert, overlap checking, removal, queries)
-- ============================================================================

--- Find the insertion index for a span keyed by (row_s, col_s) into
--- the sorted _spans array. Returns 1-based index.
---@param row_s integer
---@param col_s integer
---@return integer 1-based insertion index
function SpanManager:_insertion_index(row_s, col_s)
    local spans = self._spans
    if not spans or #spans == 0 then
        return 1
    end
    local lo, hi = 1, #spans
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local s = spans[mid]
        if s.row_s == nil then
            hi = mid - 1
        elseif s.row_s < row_s or (s.row_s == row_s and s.col_s <= col_s) then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return lo
end

--- Check whether two spans overlap.
---@param a table
---@param b table
---@return boolean
local function spans_overlap(a, b)
    if a.row_e < b.row_s or b.row_e < a.row_s then
        return false
    end
    if a.row_s == b.row_e and a.row_s == a.row_e then
        return a.col_s < b.col_e and b.col_s < a.col_e
    end
    if a.row_s == b.row_s and a.row_s == a.row_e then
        return a.col_s < b.col_e and b.col_s < a.col_e
    end
    if a.row_e == b.row_s and a.row_e ~= a.row_s then
        return false
    end
    if b.row_e == a.row_s and b.row_e ~= b.row_s then
        return false
    end
    return true
end

--- Add a span to this manager. Overlap rules by type:
---   - "layer": no checking (appended to staging only — call add_layer instead).
---   - "anchor": no checking (post-pass, don't conflict with inline spans).
---   - "properties": properties-properties overlap allowed (later-wins merge).
---@param span table the span to add
function SpanManager:add(span)
    if not self._spans then
        self._spans = {}
    end

    -- Layer and anchor spans: no overlap checking, just append to _spans.
    if span.type == "layer" or span.type == "anchor" then
        table.insert(self._spans, span)
        self._gen = self._gen + 1
        return
    end

    local idx = self:_insertion_index(span.row_s, span.col_s)

    -- Check predecessor
    if idx > 1 then
        local prev = self._spans[idx - 1]
        if spans_overlap(prev, span) then
            if not (prev.type == "properties" and span.type == "properties") then
                log.warn("span_manager", "span overlap rejected: "
                    .. span.type .. " overlaps " .. prev.type, {
                    prev_row_s = prev.row_s,
                    prev_col_s = prev.col_s,
                    span_row_s = span.row_s,
                    span_col_s = span.col_s,
                })
                return
            end
        end
    end

    -- Check successor
    if idx <= #self._spans then
        local next = self._spans[idx]
        if spans_overlap(next, span) then
            if not (next.type == "properties" and span.type == "properties") then
                log.warn("span_manager", "span overlap rejected: "
                    .. span.type .. " overlaps " .. next.type, {
                    next_row_s = next.row_s,
                    next_col_s = next.col_s,
                    span_row_s = span.row_s,
                    span_col_s = span.col_s,
                })
                return
            end
        end
    end

    table.insert(self._spans, span)
    self._gen = self._gen + 1
end

--- Remove a span by table reference equality.
---@param span table the exact span table to remove
function SpanManager:remove(span)
    if not self._spans or #self._spans == 0 then
        return
    end
    for i = 1, #self._spans do
        if self._spans[i] == span then
            table.remove(self._spans, i)
            if #self._spans == 0 then
                self._spans = nil
            end
            self._gen = self._gen + 1
            return
        end
    end
end

--- Query merged properties at a buffer position.
--- Merges all properties spans covering (line, col), later spans win.
---@param line integer 0-based line index
---@param col integer 0-based byte offset
---@return table|nil merged properties, or nil
function SpanManager:query_at(line, col)
    if not self._spans then
        return nil
    end
    local result = nil
    for _, s in ipairs(self._spans) do
        if s.type ~= "properties" then
            goto continue
        end
        if line >= s.row_s and line <= s.row_e then
            local col_inside = true
            if line == s.row_s and col < s.col_s then
                col_inside = false
            end
            if line == s.row_e and col >= s.col_e then
                col_inside = false
            end
            if col_inside then
                if not result then
                    result = {}
                end
                for k, v in pairs(s) do
                    if k ~= "type" and k ~= "col_s" and k ~= "row_s"
                        and k ~= "col_e" and k ~= "row_e" and k ~= "ephemeral" then
                        result[k] = v
                    end
                end
            end
        end
        ::continue::
    end
    return result
end

--- Return the virtual text span (properties span with `text` field)
--- that contains the given buffer position, or nil if none.
--- Uses a monotonic cursor for efficient sequential queries (e.g. cursor
--- movement through a line during rendering). Random-access queries reset
--- the cursor. For stateless one-off queries, use get_virtual_span_at.
---@param li integer 0-based line index
---@param col integer 0-based byte offset
---@return table|nil
function SpanManager:query_virtual_span_at(li, col)
    if not self._spans then
        return nil
    end

    -- Reset cursor on random access (non-monotonic query).
    if not self._vcursor or not self._vcursor_line or self._vcursor_line ~= li then
        self._vcursor = 1
        self._vcursor_line = li
    end

    -- Skip past-ended spans.
    while self._vcursor <= #self._spans do
        local s = self._spans[self._vcursor]
        if s.type ~= "properties" or s.text == nil or s.row_e == nil then
            self._vcursor = self._vcursor + 1
        elseif s.row_e < li then
            self._vcursor = self._vcursor + 1
        elseif s.row_s > li then
            return nil
        else
            break
        end
    end

    -- Search forward for a span covering (li, col).
    local i = self._vcursor
    while i <= #self._spans do
        local s = self._spans[i]
        if s.type == "properties" and s.text ~= nil and s.row_s ~= nil then
            if s.row_s <= li and s.row_e >= li then
                if s.row_s < li and li < s.row_e then
                    return s
                elseif li == s.row_s and li == s.row_e then
                    if col >= s.col_s and col < s.col_e then
                        return s
                    end
                elseif li == s.row_s then
                    if col >= s.col_s then
                        return s
                    end
                elseif li == s.row_e then
                    if col < s.col_e then
                        return s
                    end
                end
            end
            if s.row_s > li then
                return nil
            end
        end
        i = i + 1
    end
    return nil
end

--- Stateless lookup: return the virtual text span containing (li, col),
--- or nil. Does not use or update any monotonic cursor — safe for
--- one-off queries from motion commands, snap logic, etc.
---@param li integer 0-based line index
---@param col integer 0-based byte offset
---@return table|nil
function SpanManager:get_virtual_span_at(li, col)
    if not self._spans then
        return nil
    end
    for _, s in ipairs(self._spans) do
        if s.type == "properties" and s.text ~= nil and s.row_s ~= nil then
            if s.row_s <= li and s.row_e >= li then
                if s.row_s < li and li < s.row_e then
                    return s
                elseif li == s.row_s and li == s.row_e then
                    if col >= s.col_s and col < s.col_e then
                        return s
                    end
                elseif li == s.row_s then
                    if col >= s.col_s then
                        return s
                    end
                elseif li == s.row_e then
                    if col < s.col_e then
                        return s
                    end
                end
            end
        end
    end
    return nil
end

--- Return all properties spans that have a `text` field and intersect
--- the given logical line. These are virtual-text spans: the byte range
--- is rendered with the replacement text instead of buffer content.
---@param li integer 0-based line index
---@return table[] virtual text spans on this line
function SpanManager:virtual_spans_for_line(li)
    if not self._spans then
        return {}
    end
    local result = {}
    for _, s in ipairs(self._spans) do
        if s.type == "properties" and s.text ~= nil and li >= s.row_s and li <= s.row_e then
            result[#result + 1] = s
        end
    end
    return result
end

--- Adjust span positions after buffer edits.
---@param edits table[] from batch_edit's hl_edits
function SpanManager:adjust_on_edit(edits)
    if not self._spans or #self._spans == 0 then
        return
    end

    for _, e in ipairs(edits) do
        local sl, sc = e.sl, e.sc
        local rl, rc = e.rl, e.rc
        local kind = e.kind
        local el, ec = e.el, e.ec

        local is_insert = kind == "insert" or kind == "insert_relocate"
        local is_delete = kind == "delete"
        local is_replace = kind == "replace"

        local delta_lines = rl - sl
        local delta_cols
        if delta_lines == 0 then
            delta_cols = rc - sc
        end

        local del_lines = 0
        local del_cols = 0
        if el then
            del_lines = el - sl
            del_cols = ec - sc
        end
        if is_insert then
            del_lines = 0
            del_cols = 0
        end

        local new_spans = {}
        local i = 1
        while i <= #self._spans do
            local s = self._spans[i]

            -- Layer spans have no buffer coordinates; skip entirely.
            if s.type == "layer" then
                table.insert(new_spans, s)
                i = i + 1
                goto continue_edit
            end

            -- Ephemeral spans are rebuilt fresh each frame. Skip adjustment.
            if s.ephemeral then
                table.insert(new_spans, s)
                i = i + 1
                goto continue_edit
            end

            -- Two-pass adjustment: delete first, then insert.
            -- Split so replace edits (delete-then-insert composite) apply
            -- both adjustments rather than only one via the old elseif chain.
            local dropped = false

            -- Pass 1: delete adjustment (for delete and replace)
            -- Delete region is half-open [sl,sc) to [el,ec).
            -- A span starting at (row_s, col_s) is inside if it lies
            -- at or after (sl,sc) AND strictly before (el,ec).
            if del_lines > 0 and sl <= s.row_s then
                local after_start = s.row_s > sl or (s.row_s == sl and s.col_s >= sc)
                local before_end = s.row_s < el or (s.row_s == el and s.col_s < ec)
                if after_start and before_end then
                    dropped = true
                elseif after_start then
                    -- Span is on or after the end line (or after el);
                    -- shift rows and reposition columns for spans
                    -- that rode the end line (content appended at sc).
                    local on_end = s.row_s == el
                    local on_end_e = s.row_e == el
                    s.row_s = s.row_s - del_lines
                    s.row_e = s.row_e - del_lines
                    if on_end then
                        s.col_s = s.col_s - ec + sc
                    end
                    if on_end_e then
                        s.col_e = s.col_e - ec + sc
                    end
                end
                -- else: span sits on sl before sc — outside the region, no
                -- change.
            end
            if not dropped and del_lines == 0 and del_cols > 0 then
                if sl == s.row_s and sc <= s.col_s then
                    if sl == s.row_e then
                        s.col_s = math.max(s.col_s - del_cols, 0)
                        s.col_e = math.max(s.col_e - del_cols, 0)
                    elseif sl == s.row_s then
                        s.col_s = math.max(s.col_s - del_cols, 0)
                    end
                    if sl == s.row_e and sl ~= s.row_s then
                        s.col_e = math.max(s.col_e - del_cols, 0)
                    end
                end
            end

            -- Pass 2: insert adjustment (for insert and replace)
            -- Text is inserted at (sl,sc), cursor lands at (rl,rc).
            -- Only spans starting at or after the insert point shift.
            -- Spans on the insert line that shift get column-adjusted:
            -- content from (sl,sc) onward lands at (rl,rc).
            if not dropped and (is_insert or is_replace) then
                if delta_lines > 0 and (s.row_s > sl or (s.row_s == sl and s.col_s >= sc)) then
                    local on_line = s.row_s == sl
                    local on_line_e = s.row_e == sl
                    s.row_s = s.row_s + delta_lines
                    s.row_e = s.row_e + delta_lines
                    if on_line then
                        s.col_s = s.col_s - sc + rc
                    end
                    if on_line_e then
                        s.col_e = s.col_e - sc + rc
                    end
                elseif delta_lines == 0 and sl == s.row_s and sc <= s.col_s then
                    s.col_s = s.col_s + delta_cols
                    if sl == s.row_e then
                        s.col_e = s.col_e + delta_cols
                    end
                elseif delta_lines == 0 and sl == s.row_s and sc > s.col_s then
                    if sc < s.col_e and sl == s.row_e then
                        s.col_e = s.col_e + delta_cols
                    end
                end
            end

            i = i + 1
            if dropped or s.row_s > s.row_e
                or (s.row_s == s.row_e and s.col_s >= s.col_e) then
                -- collapsed; drop
            else
                new_spans[#new_spans + 1] = s
            end

            ::continue_edit::
        end

        self._spans = new_spans
        if #self._spans == 0 then
            self._spans = nil
        end
        self._gen = self._gen + 1
    end
end

-- ============================================================================
-- Coordinate mapping (buffer ↔ screen)
-- ============================================================================

--- Resolve the view for coordinate queries.
---@return table|nil
function SpanManager:_v()
    return self._view
end

--- Buffer-area geometry.
---@return {text_x: integer, max_y: integer, w: integer, h: integer}|nil
function SpanManager:_geom()
    local view = self._view
    if not view or not view.file_loaded then
        return nil
    end
    local w = self._editor.term:width()
    local h = self._editor.term:height()
    local footer = self._editor:footer_rows()
    local _, text_x = view:text_geometry(w)
    return {
        text_x = text_x,
        max_y = h - footer - 1,
        w = w,
        h = h,
    }
end

--- Map a buffer position to the screen cell it renders at this frame.
---@param line integer 0-based logical line index
---@param col integer 0-based byte offset within the line
---@return integer|nil sx
---@return integer|nil sy
function SpanManager:file_to_screen(line, col)
    local view = self._view
    if not view then
        return nil
    end
    local g = self:_geom()
    if not g then
        return nil
    end
    if line < 0 or line >= view:line_count() then
        return nil
    end
    local sub_row, sub_col = view:wrap_sub_position(line, col)
    local sy = view:viewport_row_for_line(line, sub_row)
    if sy == nil or sy < 0 or sy > g.max_y then
        return nil
    end
    return g.text_x + sub_col, sy
end

--- Map a screen cell to the buffer position under it.
---@param sx integer screen column (0-based)
---@param sy integer screen row (0-based)
---@return integer|nil line
---@return integer|nil col
function SpanManager:screen_to_file(sx, sy)
    local view = self._view
    if not view then
        return nil
    end
    local g = self:_geom()
    if not g then
        return nil
    end
    if sy < 0 or sy > g.max_y then
        return nil
    end
    local li, sub_row = view:viewport_line_at_row(sy)
    local line = math.min(li, view:line_count() - 1)
    if line < 0 then
        line = 0
    end
    local col
    if sx >= g.text_x then
        local sub_col = sx - g.text_x
        local byte_off = view:wrap_byte_offset(line, sub_row, sub_col)
        col = math.min(byte_off, view:content_len(line))
    else
        col = 0
    end
    return line, col
end

return SpanManager
