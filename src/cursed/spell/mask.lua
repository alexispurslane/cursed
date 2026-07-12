--- Context-masked line text for spellchecking.
---
--- `enchant-2 -a` checks every whitespace-separated token on the line
--- it receives. For prose modes that's exactly what we want; for code
--- modes it would flag every identifier. So before sending a line to
--- the spell pipe, we build "masked" text: same bytes layout (so the
--- byte offsets aspell reports map 1:1 back to the buffer), but every
--- byte OUTSIDE the checkable scope is replaced with a space.
---
--- Scope selection:
---   • prose mode (mode.spellcheck_captures == "all" or nil, and
---     mode has no tree-sitter language): identity — whole line.
---   • code mode with `spellcheck_captures`: the list of TS capture
---     names to check (default {comment, string, ...} when a mode
---     declares a language but no captures). Outside those captures'
---     byte ranges → spaces.
---   • mode explicitly sets `spellcheck_captures = false`: skip entirely
---     (return nil — nothing to check on this line).

local M = {}

local log = require("cursed.log")

--- Default capture set for code modes that declare a language but no
--- explicit spellcheck_captures: comments + (block) strings.
local DEFAULT_CODE_CAPTURES = { "comment", "string", "block_string", "block_comment" }

--- Resolve the checkable captures for the active mode stack.
--- Returns:
---   "all"   — check every byte on every line (prose).
---   nil     — skip this buffer entirely (mode opted out via false).
---   {list}  — TS capture names to check (code).
---
--- Scope values: "all" (prose—check whole line), nil (skip entirely),
--- or a list of TS capture names to check.
---@alias SpellScope "all"|string[]|nil

--- Decide the scope for a view (cached per render-frame, cheap to query).
--- Exposed for the driver so it knows whether to even try checking.
---@param view table
---@return SpellScope
local function resolve_scope(view)
    if view == nil or view._major_modes == nil or #view._major_modes == 0 then
        return "all"
    end
    -- Walk top-to-bottom; first mode to declare spellcheck_captures wins.
    for i = #view._major_modes, 1, -1 do
        ---@type any
        local m = view._major_modes[i]
        local cap = m.spellcheck_captures
        if cap ~= nil then
            if cap == false then
                return nil
            elseif cap == "all" or cap == true then
                return "all"
            else
                return cap
            end
        end
    end
    -- No mode declared spellcheck_captures. If any mode declares a
    -- tree-sitter language, default to the code capture set; otherwise
    -- treat as prose (whole text).
    for i = #view._major_modes, 1, -1 do
        ---@type any
        local m = view._major_modes[i]
        if m.language ~= nil or m.highlight_query ~= nil then
            return DEFAULT_CODE_CAPTURES
        end
    end
    return "all"
end

--- Build the capture byte-range set for the whole visible window.
--- Returns a table keyed by line → list of {s_byte, e_byte} covering
--- every byte the spellcheck should consider. Bytes outside any range
--- get masked to spaces.
---
--- Walks the tree-sitter parse tree via the same ts API
--- `completers.ts_document_symbols` uses (View:hl_tree + ts.QueryCursor).
---@param view table
---@param captures string[] capture names to collect
---@param top_li integer first 0-based visible line
---@param bottom_li integer last 0-based visible line
---@return table|nil  map[line] = {{s_byte,e_byte},...} (absolute byte offsets), or nil on no tree
local function capture_ranges(view, captures, top_li, bottom_li)
    local ts = require("cursed.ts")
    local tree = view:hl_tree()
    if tree == nil then
        return nil
    end
    local root = tree:root()
    if ts.node_is_null(root) then
        return nil
    end
    -- Compile a capture query. The mode's highlight_query already
    -- contains the capture bindings we care about; reuse a minimal
    -- source that matches any node with those capture names. Since
    -- the highlight query may use predicates/equality that the
    -- QueryCursor can't handle standalone, we instead walk the tree's
    -- named nodes and match by capture name through the compiled
    -- highlight query if available; otherwise fall back to a node-type
    -- heuristic: comment- and string-named nodes count.
    --
    -- Simplest robust path: walk named nodes depth-first, collect ranges
    -- whose node_type matches (comment, string, block_comment, ...).
    -- This avoids recompiling arbitrary highlight queries with predicates.
    local type_set = {}
    for _, name in ipairs(captures) do
        -- capture names like "string" / "comment" usually mirror node
        -- types; accept both the exact capture name and common variants.
        type_set[name] = true
        if name == "string" then
            type_set["string_content"] = true
            type_set["string_literal"] = true
        elseif name == "comment" then
            type_set["comment"] = true
        elseif name == "block_comment" then
            type_set["block_comment"] = true
        elseif name == "block_string" then
            type_set["string_content"] = true
        end
    end

    local line_starts = nil
    -- line_starts is needed to convert absolute byte offsets to line +
    -- 0-based byte col. Lazy-build via view:_hl_line_starts (1-indexed).
    local function ensure_starts()
        if line_starts ~= nil then
            return
        end
        line_starts = view:_hl_line_starts()
        if line_starts == nil then
            line_starts = { [1] = 0 }
        end
    end

    -- Convert absolute byte offset → 0-based (line, byte_col).
    ---@param abs integer
    ---@return integer|nil line 0-based
    ---@return integer col 0-based byte offset within line
    local function abs_to_line(abs)
        ensure_starts()
        if line_starts == nil then
            return nil, 0
        end
        -- Binary search for the largest start <= abs.
        local lo, hi = 1, #line_starts
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            local start_mid = line_starts[mid] -- may be nil (diagnostics know)
            if start_mid ~= nil and start_mid <= abs then
                lo = mid
            else
                hi = mid - 1
            end
        end
        local ls_abs = line_starts[lo] -- may be nil
        if ls_abs == nil then
            return nil, 0
        end
        local line = lo - 1 -- 0-based
        return line, abs - ls_abs
    end

    local ranges_by_line = {}

    -- Recursive descent over named nodes.
    local function walk(node)
        if node == nil or ts.node_is_null(node) then
            return
        end
        local nt = ts.node_type(node)
        if type_set[nt] then
            local sb = ts.node_start_byte(node)
            local eb = ts.node_end_byte(node)
            local li, sc = abs_to_line(sb)
            if li and li >= top_li and li <= bottom_li then
                local _, ec = abs_to_line(eb)
                local list = ranges_by_line[li]
                if list == nil then
                    list = {}
                    ranges_by_line[li] = list
                end
                list[#list + 1] = { s_col = sc, e_col = ec }
            end
        end
        -- Recurse into named children only (unnamed punctuation/keywords
        -- can't be a comment/string root).
        local child = ts.node_named_child(node, 0)
        local i = 0
        while child ~= nil and not ts.node_is_null(child) do
            walk(child)
            i = i + 1
            child = ts.node_named_child(node, i)
        end
    end

    walk(root)
    return ranges_by_line
end

--- Decide the scope for a view (cached per render-frame, cheap to query).
--- Exposed for the driver so it knows whether to even try checking.
---@param view table
---@return SpellScope
function M.scope(view)
    return resolve_scope(view)
end

--- Build masked line text for one buffer line at `line`, preserving
--- byte offsets so aspell's reported offsets map back to the buffer
--- 1:1.
---
--- Returns (masked_text, s_col, e_col) where s_col/e_col bound the
--- checkable region on the line, or nil if nothing to check.
---
--- `ranges` is the per-line table from capture_ranges (may be nil when
--- scope == "all" — whole line checkable).
---@param _view table unused (mode scope resolved upstream)
---@param line integer 0-based
---@param line_text string buffer line text (without trailing newline if from line_text)
---@param scope SpellScope
---@param ranges table|nil per-line ranges from capture_ranges
---@return string|nil masked
---@return integer s_col 0-based byte col of first checkable byte
---@return integer e_col 0-based byte col one past last checkable byte
function M.mask_line(_view, line, line_text, scope, ranges)
    if scope == nil then
        return nil, 0, 0
    end
    if scope == "all" then
        if #line_text == 0 then
            return nil, 0, 0
        end
        return line_text, 0, #line_text
    end
    -- Capture-scoped: collect checkable ranges for this line.
    local line_ranges = ranges and ranges[line]
    if line_ranges == nil or #line_ranges == 0 then
        return nil, 0, 0
    end
    -- Build a byte-identical-length string with non-checkable bytes
    -- replaced by spaces. UTF-8 content bytes are multibyte but the
    -- line_text is a Lua byte-string; replacing through byte indices
    -- is safe as long as we operate on byte offsets (which we do).
    local n = #line_text
    local out = {}
    for i = 1, n do
        out[i] = " "
    end
    local lo, hi = n, 0
    for _, r in ipairs(line_ranges) do
        ---@type integer
        local rs = r.s_col
        ---@type integer
        local re = r.e_col
        local s = rs + 1
        local e = math.min(re, n)
        if e >= s then
            for i = s, e do
                out[i] = line_text:byte(i)
            end
            if s < lo then
                lo = s
            end
            if e > hi then
                hi = e
            end
        end
    end
    if hi < lo then
        return nil, 0, 0
    end
    local masked = string.char(table.unpack(out))
    return masked, lo - 1, hi
end

--- Run capture_ranges once for the visible window; return (scope, ranges).
--- `ranges` is nil when scope == "all" (caller doesn't need ranges) or
--- when no parse tree is available (caller falls back to skipping this
--- cycle for code buffers).
---@param view table
---@param top_li integer
---@param bottom_li integer
---@return SpellScope scope
---@return table|nil ranges
function M.build_ranges(view, top_li, bottom_li)
    local scope = resolve_scope(view)
    if scope == nil or scope == "all" then
        return scope, nil
    end
    local ok, ranges = pcall(capture_ranges, view, scope, top_li, bottom_li)
    if not ok then
        log.warn("spell_mask", "capture_ranges_error", { error = tostring(ranges) })
        return scope, nil
    end
    return scope, ranges
end

return M
