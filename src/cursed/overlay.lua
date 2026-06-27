--- Overlay manager: the screen-coordinate-space drawing layer above highlighting.
---
--- Two overlay kinds:
---   • file-anchored — attached to a buffer (line, byte-col); rendered at the
---     screen cell that position maps to THIS FRAME, and skipped when the
---     anchor is scrolled out of view. Use for diagnostics (flymake),
---     spell-check squiggles (flyspell), match-hints: they follow the text
---     as you scroll, freed from priority-resolution-vs-tree-sitter tangles.
---   • floating — absolute screen (sx, sy); painted regardless of scroll.
---     Use for popups, tooltips, the modeline, the minibuffer.
---
--- Coordinate maps (the reusable substrate, callable any time):
---   file_to_screen(line, col) -> sx, sy | nil   (nil = scrolled out)
---   screen_to_file(sx, sy)     -> line, col | nil (nil = outside buffer area)
--- `col` is a 0-based BYTE offset within the line — the buffer's native
--- addressing, matching what the mouse click handler produces, so an
--- extension can round-trip a click → buffer edit → anchored overlay.
---
--- Lifecycle (driven by Editor:render):
---   1. begin_frame(view) — snapshot the view, clear the queues.
---   2. core chrome + extensions register overlays (put_file / put_float).
---   3. emit_render() — fires the `render_overlay` event so extensions
---      register overlays for this frame (the extension hook).
---   4. flush() — paints file-anchored (resolved via file_to_screen, skips
---      off-screen) then floats in registration order, before term:present().
---
--- The `render_overlay` event is THE extension hook: a listener does
--- `editor.overlays:put_file(...)` / `:put_float(...)` for the current frame.
--- Overlays never persist across frames (begin_frame clears the queues).
---
--- Z-order within a frame: file-anchored paint over the buffer text; floats
--- paint over file-anchored, in registration order (later overdraws earlier).
--- Core chrome (modeline/minibuffer) registers before emit_render, so an
--- extension's floating popup paints above the modeline — the expected
--- "extension UI on top" layering.

---@class OverlayManager
---@field _editor Editor owning editor
---@field _term Term backing terminal surface
---@field _view table|nil frame snapshot, set by begin_frame
---@field _file table[] file-anchored queue: {line, col, text, fg, bg}
---@field _float table[] floating queue: {sx, sy, text, fg, bg}
local OverlayManager = {}
OverlayManager.__index = OverlayManager

--- Create the overlay manager. Stored on the editor as `editor.overlays`.
---@param editor Editor owning editor (for term + footer_rows + current_view)
---@return OverlayManager
local function new(editor)
    return setmetatable({
        _editor = editor,
        _term = editor.term,
        _view = nil, -- frame snapshot, set by begin_frame
        _file = {}, -- file-anchored queue: {line, col, text, fg, bg}
        _float = {}, -- floating queue: {sx, sy, text, fg, bg}
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
    if sy < 0 or sy > g.max_y then
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

--- Begin a render frame: snapshot the view + clear the queues.
--- Called by Editor:render before any painting. `view` may be nil
--- (e.g. the initial "Loading…" frame) — file-anchored overlays then
--- resolve to nil and float overlays still paint.
---@param view table|nil the view being rendered this frame
function OverlayManager:begin_frame(view)
    self._view = view
    self._file = {}
    self._float = {}
end

--- Register a file-anchored overlay. Resolved to screen at flush; if the
--- anchor is scrolled off-screen this frame, nothing is painted.
---@param line integer 0-based logical line
---@param col integer 0-based byte offset within the line
---@param text string
---@param fg integer
---@param bg integer
function OverlayManager:put_file(line, col, text, fg, bg)
    self._file[#self._file + 1] = { line = line, col = col, text = text, fg = fg, bg = bg }
end

--- Register a floating overlay at absolute screen (sx, sy).
---@param sx integer screen column (0-based)
---@param sy integer screen row (0-based)
---@param text string
---@param fg integer
---@param bg integer
function OverlayManager:put_float(sx, sy, text, fg, bg)
    self._float[#self._float + 1] = { sx = sx, sy = sy, text = text, fg = fg, bg = bg }
end

--- Fire the `render_overlay` event so extensions register overlays for
--- this frame. The editor hub delivers the editor to each listener.
function OverlayManager:emit_render()
    local es = self._editor.event_system
    if es then
        es:emit("render_overlay", self._editor)
    end
end

--- Paint all registered overlays: file-anchored first (resolved via
--- file_to_screen, off-screen anchors skipped) so they sit on the buffer
--- text, then floats in registration order so later registrations overdraw
--- earlier ones. Clears the queues.
function OverlayManager:flush()
    local term = self._term
    for _, o in ipairs(self._file) do
        local sx, sy = self:file_to_screen(o.line, o.col)
        if sx ~= nil and sy ~= nil then
            term:print(sx, sy, o.text, o.fg, o.bg)
        end
    end
    for _, o in ipairs(self._float) do
        term:print(o.sx, o.sy, o.text, o.fg, o.bg)
    end
    self._file = {}
    self._float = {}
end

OverlayManager.new = new
return OverlayManager
