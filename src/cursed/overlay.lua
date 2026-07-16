--- Overlay manager: the screen-coordinate-space drawing layer above highlighting.
---
--- Internally represents overlays as anchor spans (buffer-anchored) and
--- layer spans (screen-space floating), stored in `_ephemeral_spans` for
--- this frame. Anchor spans are also inserted directly into the view's
--- `_spans` list (bypassing add_span's overlap rejection since ephemeral
--- overlays use later-wins z-order). Both types carry a `draw` function
--- that the flush method calls with resolved coordinates.
---
--- Two overlay kinds:
---   • anchor — attached to a buffer (line, byte-col); rendered at the
---     screen cell that position maps to THIS FRAME, and skipped when the
---     anchor is scrolled out of view. Use for diagnostics (flymake),
---     spell-check squiggles (flyspell), match-hints: they follow the text
---     as you scroll. Corresponds to put_file / put_underline.
---   • layer — absolute screen (sx, sy); painted regardless of scroll.
---     Use for popups, tooltips, the modeline, the minibuffer.
---     Corresponds to put_float.
---
--- Coordinate maps (the reusable substrate, callable any time):
---   file_to_screen(line, col) -> sx, sy | nil   (nil = scrolled out)
---   screen_to_file(sx, sy)     -> line, col | nil (nil = outside buffer area)
--- `col` is a 0-based BYTE offset within the line — the buffer's native
--- addressing, matching what the mouse click handler produces, so an
--- extension can round-trip a click → buffer edit → anchored overlay.
---
--- Lifecycle (driven by Editor:render):
---   1. begin_frame(view) — remove previous frame's anchor spans from view,
---      clear _ephemeral_spans, snapshot the view.
---   2. core chrome + extensions register overlays (put_file / put_float).
---   3. emit_render() — fires the `render_overlay` event so extensions
---      register overlays for this frame (the extension hook).
---   4. flush() — paints anchor spans first (resolved via file_to_screen,
---      skips off-screen), then layer spans in registration order, before
---      term:present().
---
--- The `render_overlay` event is THE extension hook: a listener does
--- `editor.overlays:put_file(...)` / `:put_float(...)` for the current frame.
--- Overlays never persist across frames (begin_frame clears the queues).
---
--- Z-order within a frame: anchors paint over the buffer text; layers
--- paint over anchors, in registration order (later overdraws earlier).
--- Core chrome (modeline/minibuffer) registers before emit_render, so an
--- extension's floating popup paints above the modeline — the expected
--- "extension UI on top" layering.

---@class OverlayManager
---@field _editor Editor owning editor
---@field _term Term backing terminal surface
---@field _view table|nil frame snapshot, set by begin_frame
---@field _ephemeral_spans table[] spans added this frame (cleared in begin_frame)
---@field _file table[] file-anchored queue: {line, col, text, fg, bg} (kept for backward compat, cleared in begin_frame)
---@field _float table[] floating queue: {sx, sy, text, fg, bg} (kept for backward compat, cleared in begin_frame)
---@field _underline table[] file-anchored squiggle queue: {line, s_col, e_col, rgb} (kept for backward compat, cleared in begin_frame)
local OverlayManager = {}
OverlayManager.__index = OverlayManager

local log = require("cursed.log")
local profile = require("cursed.profile")

--- Create the overlay manager. Stored on the editor as `editor.overlays`.
---@param editor Editor owning editor (for term + footer_rows + current_view)
---@return OverlayManager
local function new(editor)
    return setmetatable({
        _editor = editor,
        _term = editor.term,
        _view = nil, -- frame snapshot, set by begin_frame
        _ephemeral_spans = {}, -- spans added this frame
        _file = {}, -- file-anchored queue (kept for backward compat)
        _float = {}, -- floating queue (kept for backward compat)
        _underline = {}, -- file-anchored squiggles (kept for backward compat)
    }, OverlayManager)
end

--- Resolve the view a coordinate query should use: the frame's
--- snapshot during render, else the focused view (for queries from
--- event handlers / M-: outside the render pass).
---@return table|nil view
function OverlayManager:_v()
    return self._view or self._editor:current_view()
end

--- Buffer-area geometry for the current view + terminal size.
--- `text_x` is the first text column (after the gutter / centered block);
--- `max_y` is the last buffer row before the footer (modeline + minibuffer).
--- Returns nil when there is no loaded view to map against.
---@return {text_x: integer, max_y: integer, w: integer, h: integer}|nil
function OverlayManager:_geom()
    local view = self:_v()
    if not view or not view.file_loaded then
        return nil
    end
    local w = self._term:width()
    local h = self._term:height()
    local footer = self._editor:footer_rows()
    local _, text_x = view:text_geometry(w)
    return { text_x = text_x, max_y = h - footer - 1, w = w, h = h }
end

--- Map a buffer position to the screen cell it renders at this frame.
--- `col` is a 0-based byte offset within the line. Returns (sx, sy), or
--- nil when the position is scrolled out of the visible buffer area, the
--- line is past the document, or there is no loaded view.
---
--- Resolves wrap + scroll + centered-text-geometry exactly as the renderer
--- paints (via View:line_to_screen_row + wrap_sub_position + text_geometry),
--- so an anchored overlay never drifts from the glyph it sits on.
---@param line integer 0-based logical line index
---@param col integer 0-based byte offset within the line
---@return integer|nil sx
---@return integer|nil sy
function OverlayManager:file_to_screen(line, col)
    local view = self:_v()
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

--- Map a screen cell to the buffer position under it. `col` in the result
--- is a 0-based byte offset. Returns nil when `sy` is in the footer/modeline
--- region or above the viewport; a click in the gutter snaps to col 0.
--- Mirrors the mouse click→buffer mapping so overlays + clicks agree.
---@param sx integer screen column (0-based)
---@param sy integer screen row (0-based)
---@return integer|nil line
---@return integer|nil col
function OverlayManager:screen_to_file(sx, sy)
    local view = self:_v()
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
        -- Gutter or left of the centered block: col 0.
        col = 0
    end
    return line, col
end

--- Begin a render frame: remove previous frame's ephemeral spans from the
--- old view, clear the queues, and snapshot the new view. Called by
--- Editor:render before any painting. `view` may be nil (e.g. the initial
--- "Loading…" frame) — anchor overlays then resolve to nil and layer
--- overlays still paint.
---@param view table|nil the view being rendered this frame
function OverlayManager:begin_frame(view)
    -- Remove previous frame's anchor spans from the old view so they don't
    -- accumulate in the view's _spans list across frames.
    if self._view then
        for _, s in ipairs(self._ephemeral_spans) do
            if s.type == "anchor" then
                self._view:remove_span(s)
            end
        end
    end
    self._view = view
    self._ephemeral_spans = {}
    self._file = {}
    self._float = {}
    self._underline = {}
end

--- Register a file-anchored overlay. Creates an anchor span that is
--- resolved to screen at flush; if the anchor is scrolled off-screen
--- this frame, nothing is painted.
---@param line integer 0-based logical line
---@param col integer 0-based byte offset within the line
---@param text string
---@param fg integer
---@param bg integer
function OverlayManager:put_file(line, col, text, fg, bg)
    local span = {
        type = "anchor",
        row_s = line,
        col_s = col,
        row_e = line,
        col_e = col + 1,
        text = text,
        fg = fg,
        bg = bg,
        draw = function(self, term, sx, sy)
            if sx ~= nil and sy ~= nil then
                term:print(sx, sy, self.text, self.fg, self.bg)
            end
        end,
    }
    -- Insert directly into view._spans (bypassing add_span's overlap
    -- rejection) since ephemeral anchor spans may overlap; later-wins
    -- z-order is the intended behavior.
    local view = self._view
    if view then
        if not view._spans then
            view._spans = {}
        end
        local idx = view:_span_insertion_index(span.row_s, span.col_s)
        table.insert(view._spans, idx, span)
        view._span_gen = (view._span_gen or 0) + 1
        view._span_cursor = nil
    end
    table.insert(self._ephemeral_spans, span)
end

--- Register a floating overlay at absolute screen (sx, sy).
--- Creates a layer span that paints at the given screen coordinates.
---@param sx integer screen column (0-based)
---@param sy integer screen row (0-based)
---@param text string
---@param fg integer
---@param bg integer
function OverlayManager:put_float(sx, sy, text, fg, bg)
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
    table.insert(self._ephemeral_spans, span)
end

--- Register a file-anchored squiggly underline spanning the byte range
--- [s_col, e_col) on `line`. Creates an anchor span whose draw function
--- receives resolved per-sub-row screen-cell ranges from `_resolve_underline`.
--- Ranges that span wrap sub-rows are segmented per sub-row; off-screen
--- anchors are skipped.
---
--- `rgb` is a 0xRRGGBB truecolor int for the squiggle (use a resolved
--- `diagnostic_error`/`_warn`/`_info`/`_hint` color).
---@param line integer 0-based logical line index
---@param s_col integer 0-based byte offset of the range start (inclusive)
---@param e_col integer 0-based byte offset of the range end (exclusive)
---@param rgb integer 0xRRGGBB squiggle color
function OverlayManager:put_underline(line, s_col, e_col, rgb)
    if e_col <= s_col then
        return
    end
    local span = {
        type = "anchor",
        row_s = line,
        col_s = s_col,
        row_e = line,
        col_e = e_col,
        rgb = rgb,
        draw = function(self, term, ranges)
            for _, r in ipairs(ranges) do
                local sx_start, sx_end, sy = r[1], r[2], r[3]
                for col = sx_start, sx_end - 1 do
                    term:squiggle_cell(col, sy, self.rgb)
                end
            end
        end,
    }
    -- Insert directly into view._spans (same rationale as put_file).
    local view = self._view
    if view then
        if not view._spans then
            view._spans = {}
        end
        local idx = view:_span_insertion_index(span.row_s, span.col_s)
        table.insert(view._spans, idx, span)
        view._span_gen = (view._span_gen or 0) + 1
        view._span_cursor = nil
    end
    table.insert(self._ephemeral_spans, span)
end

--- Fire the `render_overlay` event so extensions register overlays for
--- this frame. The editor hub delivers the editor to each listener.
function OverlayManager:emit_render()
    local es = self._editor.event_system
    if es then
        local n = 0
        local listeners = es._handlers and es._handlers["render_overlay"]
        if listeners then
            n = #listeners
        end
        -- Per-frame trace; gated on profiling so production runs don't
        -- write+flush a JSON line every frame.
        if profile.enabled then
            log.info("overlay", "emit_render", { listeners = n })
        end
        local t0 = profile.now_us()
        es:emit("render_overlay", self._editor)
        profile.span("overlay", "emit_render", t0, { listeners = n })
    end
end

--- Paint all registered overlays for this frame.
---
--- Phase 1: anchor spans (buffer-space, file-anchored). These paint over
---   the buffer text but under floating overlays. Each anchor span is either:
---   • a text overlay — resolved to screen via file_to_screen, then drawn
---   • an underline — resolved via _resolve_underline to per-sub-row ranges,
---     then squiggled cell-by-cell
---   Off-screen anchors are skipped (file_to_screen returns nil).
---
--- Phase 2: layer spans (screen-space, floating). These paint over
---   everything at their absolute screen coordinates, in registration
---   order (later overdraws earlier).
---
--- Clears _ephemeral_spans (begin_frame removes old anchors from view._spans).
--- Old queue fields (_file, _float, _underline) are also cleared for
--- backward compatibility but are no longer used for painting.
function OverlayManager:flush()
    local term = self._term
    local n_all = #self._ephemeral_spans
    local n_anchor = 0
    local n_underline = 0
    local n_layer = 0
    for _, s in ipairs(self._ephemeral_spans) do
        if s.type == "anchor" then
            n_anchor = n_anchor + 1
            if s.rgb ~= nil then
                n_underline = n_underline + 1
            end
        elseif s.type == "layer" then
            n_layer = n_layer + 1
        end
    end
    local flush_t0 = profile.now_us()

    -- Phase 1: anchor spans (file-anchored, buffer-space).
    local t_anchor = profile.now_us()
    for _, s in ipairs(self._ephemeral_spans) do
        if s.type == "anchor" then
            if s.rgb ~= nil then
                -- Underline: resolve to per-sub-row screen ranges and draw.
                local ranges = self:_resolve_underline(s)
                s:draw(term, ranges)
            else
                -- Text overlay: resolve buffer→screen.
                local sx, sy = self:file_to_screen(s.row_s, s.col_s)
                s:draw(term, sx, sy)
            end
        end
    end
    profile.span("overlay", "flush_anchor", t_anchor, {
        count = n_anchor,
        underline = n_underline,
    })

    -- Phase 2: layer spans (floating, screen-space).
    local t_layer = profile.now_us()
    for _, s in ipairs(self._ephemeral_spans) do
        if s.type == "layer" then
            s:draw(term)
        end
    end
    profile.span("overlay", "flush_layer", t_layer, { count = n_layer })

    self._ephemeral_spans = {}
    self._file = {}
    self._float = {}
    self._underline = {}
    profile.span("overlay", "flush", flush_t0, {
        anchor = n_anchor,
        underline = n_underline,
        layer = n_layer,
        total = n_all,
    })
end

--- Resolve an underline anchor span to per-sub-row screen-cell ranges.
--- Segments the underline across wrap sub-rows, skips lines past the
--- document and cells outside the buffer area. Uses the frame's snapshot
--- view and geometry so the squiggle tracks the glyph it sits under.
---@param u table anchor span with row_s, col_s, col_e, rgb
---@return {integer, integer, integer}[] {sx_start, sx_end, sy} entries
function OverlayManager:_resolve_underline(u)
    local view = self._view
    local g = self:_geom()
    if not view or not g then
        return {}
    end
    local line = u.row_s
    if line < 0 or line >= view:line_count() then
        return {}
    end
    local s_sub, s_scol = view:wrap_sub_position(line, u.col_s)
    local e_sub, e_scol = view:wrap_sub_position(line, u.col_e)
    local row_w = view.wrap_width or g.w
    local results = {}
    for sub = s_sub, e_sub do
        local col_lo = (sub == s_sub) and s_scol or 0
        local col_hi = (sub == e_sub) and e_scol or row_w
        if col_hi > col_lo then
            local sy = view:viewport_row_for_line(line, sub)
            if sy >= 0 and sy <= g.max_y then
                table.insert(results, { g.text_x + col_lo, g.text_x + col_hi, sy })
            end
        end
    end
    return results
end

OverlayManager.new = new
return OverlayManager
