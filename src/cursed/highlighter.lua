--- Syntax highlighter built on the bundled tree-sitter grammars.
---
--- A Highlighter owns a TSParser + a TSQuery. Given a buffer's full text
--- and its per-line byte offsets, it runs the query and resolves
--- overlapping captures into non-overlapping per-line spans suitable for
--- the renderer:
---
---     local hl = Highlighter.new("lua", LUA_QUERY_SOURCE)
---     local line_spans = hl:highlight(text, line_starts)
---     -- line_spans[li + 1] = { {cs = 0, ce = 5, fg = 0x0002}, ... }
---     -- (cs/ce are byte offsets within line li, excluding its trailing \n)
---
--- Integration points:
---   * The query source is provided BY THE MAJOR MODE (its
---     `highlight_query` field), NOT by this module. Built-in mode files
---     live in `cursed/modes/<lang>.lua`.
---   * Queries are predicate-free: the tree-sitter C library does NOT
---     evaluate text predicates (#eq?, #match?, #any-of?), so queries
---     must avoid them. Specificity comes from declaration order + the
---     highlighter's same-node-later-wins rule (declare broad fallbacks
---     like `(identifier) @variable` FIRST).
---
--- Capture resolution (the stack algorithm):
---   captures() yields captures ordered by start byte (ties → smaller
---   pattern index first). For overlapping captures, the LAST-pushed
---   (innermost / later-declared) wins for its own byte range, exactly
---   like tree-sitter-cli's default highlighter. Nested ranges (e.g. an
---   escape_sequence inside a string) resume the outer color when the
---   inner capture ends.
---
--- The theme (capture name → 8-color attr) lives here — it's
--- language-agnostic and the renderer-facing concern, so it stays
--- centralized rather than duplicated per mode.

local ts = require("cursed.ts")
local ColorScheme = require("cursed.colorscheme")
local log = require("cursed.log")

----------------------------------------------------------------------------------------------------
-- Theme: capture name → termbox fg attribute.
--
-- The actual colors live in the active ColorScheme (loaded in main.lua
-- from a base16 scheme file, or the built-in gruvbox fallback).
-- The scheme resolves standard tree-sitter capture names through two
-- layers:
--   1. CAPTURE_CONCEPT — collapses the ~50 standard TS capture names
--      onto our ~25 canonical concepts (conditional/repeat/keyword.return
--      → keyword.control; function.call/method.call → distinct
--      concepts; etc.). Captures not in the table fall through via
--      dotted-suffix stripping, then to `variable`.
--   2. CONCEPT_SLOTS — maps each concept to a base16 color slot
--      (base00–0F). Style bits (bold/italic) are OR'd on top.
--
-- The output fg is a 0xRRGGBB truecolor int when the terminal supports
-- it; otherwise a pre-quantized 256-color index. nil → terminal default
-- (use `variable`/base08 as the catch-all, handled inside the scheme).
----------------------------------------------------------------------------------------------------

--- Resolve a capture name to a termbox fg attr, or nil for default.
--- Delegates to the active ColorScheme (set in main.lua at startup).
---@param name string
---@return integer|nil
local function resolve_fg(name)
    local scheme = ColorScheme.active
    if scheme == nil then
        return nil
    end
    return scheme:resolve_capture(name)
end

----------------------------------------------------------------------------------------------------
-- Highlighter
----------------------------------------------------------------------------------------------------

---@class Highlighter
---@field language string
---@field parser any ts.Parser
---@field query any ts.Query
---@field _query_src string|false|nil source string cached for change detection
local Highlighter = {}
Highlighter.__index = Highlighter

--- Create a highlighter for a tree-sitter language.
--- The query source is supplied by the caller (the MajorMode's
--- `highlight_query` field) — this module ships no built-in queries.
---@param language string grammar name (must be a bundled grammar)
---@param query_source string predicate-free tree-sitter query source
---@return Highlighter|nil
---@return string|nil errmsg
function Highlighter.new(language, query_source)
    if query_source == nil then
        return nil,
            ("cursed.highlighter: no query source provided for language %q"):format(language)
    end
    local lang_ptr, err = ts.lang_get(language)
    if not lang_ptr then
        return nil, err
    end
    local parser, perr = ts.Parser.new(lang_ptr)
    if not parser then
        return nil, perr
    end
    local query, qerr = ts.Query.new(lang_ptr, query_source)
    if not query then
        return nil, qerr
    end
    return setmetatable({
        language = language,
        parser = parser,
        query = query,
    }, Highlighter),
        nil
end

----------------------------------------------------------------------------------------------------
-- Stack algorithm: convert the capture stream into non-overlapping
-- (start_byte, end_byte, fg) global segments.
--
--   stack: open captures (LIFO because grammar-node ranges nest).
--   pos:   byte offset up to which the current color has been emitted.
--   The active color at any point is the top of the stack.
--   Later-emitted captures (more specific / declared later in the
--   query) win for their range; when they close, the outer color
--   resumes.
----------------------------------------------------------------------------------------------------

local function build_segments(self, root)
    local cursor, cerr = ts.QueryCursor.new()
    if not cursor then
        return nil, cerr
    end
    cursor:exec(self.query, root)

    -- Node-text slicer for predicate evaluation: this synchronous
    -- highlighter path parses a Lua string, so slicing is a plain
    -- string.sub. (The async lane slices a char* buffer instead.)
    local text = self._text_for_pred
    local function get_text_fn(sb, eb)
        if text == nil then
            return ""
        end
        return string.sub(text, sb + 1, eb)
    end

    local stack = {} ---@type {eb: integer, fg: integer|nil, node: any}[]
    local segs = {} ---@type {cs: integer, ce: integer, fg: integer|nil}[]
    local pos = 0
    local _, last_vbyte = ts.node_byte_range(root)

    local function current_fg()
        local top = stack[#stack]
        return top and top.fg or nil
    end

    local function emit(up_to)
        if up_to <= pos then
            return
        end
        local fg = current_fg()
        if fg ~= nil then
            segs[#segs + 1] = { cs = pos, ce = up_to, fg = fg }
        end
        pos = up_to
    end

    for cap in cursor:filtered_captures(get_text_fn) do
        local cs = cap.start_byte
        local ce = cap.end_byte
        if cs < ce then
            -- Close any open captures that end at or before this one starts.
            while #stack > 0 and stack[#stack].eb <= cs do
                emit(stack[#stack].eb)
                stack[#stack] = nil
            end
            -- Advance to this capture's start under the (possibly new) top.
            emit(cs)
            if pos < cs then
                pos = cs
            end
            local fg = resolve_fg(cap.name)
            -- Same-node captures: the capture declared LATER in the query
            -- (emitted later by next_capture, since it orders ties by
            -- ascending pattern index) wins for this node — replace the
            -- top's color instead of stacking, so e.g. @function.call
            -- overrides the @variable fallback on the same identifier.
            local top = stack[#stack]
            if top ~= nil and top.eb == ce and ts.node_eq(top.node, cap.node) then
                top.fg = fg
            else
                stack[#stack + 1] = { eb = ce, fg = fg, node = cap.node }
            end
        end
    end

    -- Flush all remaining open captures.
    while #stack > 0 do
        emit(stack[#stack].eb)
        stack[#stack] = nil
    end
    -- Clamp/strip any segments that wandered past the document end.
    if last_vbyte then
        for i = #segs, 1, -1 do
            if segs[i].ce > last_vbyte then
                segs[i].ce = last_vbyte
            end
            if segs[i].cs >= last_vbyte or segs[i].ce <= segs[i].cs then
                table.remove(segs, i)
            end
        end
    end
    return segs, nil
end

----------------------------------------------------------------------------------------------------
-- Map global segments to per-line spans.
--
-- line_starts is 1-indexed: line_starts[li + 1] = byte offset of the
-- start of logical line li, and line_starts[#line_starts] = total bytes.
-- The trailing \n of a line is the last byte of its [start, next) range;
-- spans are clamped to exclude it (the renderer paints content only).
----------------------------------------------------------------------------------------------------

local function line_content_end(line_starts, li, count)
    -- byte offset of the first byte NOT in this line's content (excludes \n)
    local next_start = line_starts[li + 2]
    if next_start == nil then
        return line_starts[count + 1]
    end
    return next_start - 1
end

local function build_line_spans(segs, line_starts)
    local count = #line_starts - 1
    if count <= 0 or segs == nil then
        return {}
    end
    local lines = {} ---@type table<integer, {cs: integer, ce: integer, fg: integer}[]>

    -- Pass over segments in increasing start order; keep a running line
    -- cursor since both are monotonic.
    local li = 0
    for _, seg in ipairs(segs) do
        local gs, ge, fg = seg.cs, seg.ce, seg.fg
        if gs >= line_starts[count + 1] then
            break
        end
        -- Advance line cursor to the line containing gs.
        while li < count and line_starts[li + 2] <= gs do
            li = li + 1
        end
        local s = gs
        while li < count and s < ge do
            local lstart = line_starts[li + 1]
            local lend = line_content_end(line_starts, li, count)
            local seg_end = math.min(ge, lend)
            if s < seg_end then
                local cs = s - lstart
                local ce = seg_end - lstart
                if ce > cs then
                    local row = lines[li + 1]
                    if row == nil then
                        row = {}
                        lines[li + 1] = row
                    end
                    row[#row + 1] = { cs = cs, ce = ce, fg = fg }
                end
            end
            if ge <= lend then
                break
            end
            li = li + 1
            -- Skip the \n that separates this line from the next.
            s = lend + 1
        end
    end
    return lines
end

----------------------------------------------------------------------------------------------------
-- Public: highlight a full document
----------------------------------------------------------------------------------------------------

--- Parse `text` and return per-line highlight spans.
---@param text string full document text
---@param line_starts integer[] 1-indexed line start byte offsets + total
---@return table|nil line_spans (line-index+1 → {cs,ce,fg}[]) or nil on failure
function Highlighter:highlight(text, line_starts)
    local tree, terr = self.parser:parse_string(text, nil)
    if not tree then
        log.error("highlighter", "parse failed", { language = self.language, error = terr or "?" })
        return nil
    end
    self._text_for_pred = text
    local root = tree:root()
    local segs, serr = build_segments(self, root)
    self._text_for_pred = nil
    if not segs then
        log.error("highlighter", "query failed", { language = self.language, error = serr or "?" })
        return nil
    end
    local spans = build_line_spans(segs, line_starts)
    -- tree + cursor are GC-managed; let them drop.
    return spans
end

return Highlighter
