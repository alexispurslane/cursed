--- Text-object builders.
--
-- Each builder returns a plain Lua closure of the signature
--   fn(view, line, col, dir) -> (sl, sc, el, ec, boundary_len) | nil
-- used by View:select_range / View:move_word and the mark/kill/copy/
-- transpose commands built on top of them. `dir` is optional:
--   nil/0 = at-point / select (next forward when between units),
--   >0    = forward-adjacent (for forward motion),
--   <0    = backward-adjacent (for backward motion).
-- It selects which adjacent unit to return when point sits BETWEEN
-- units (on a boundary char for patterns, between pairs for sexp);
-- when point is inside a unit/pair, dir is ignored.
--
-- This module is the user-facing way to declare text objects in a
-- textobjects table (default_textobjects.lua, ~/.config/cursed/
-- textobjects.lua, or a MajorMode's `textobjects` field): instead of
-- bare strings, write `pattern("[^%w_]")`, `sexp({{"(",")"},...})`,
-- or `ts({ query = "...", capture = "name" })`.
-- Builders capture their spec at construction time and consult `view`
-- lazily at call time, so this module does NOT require cursed.view
-- (avoiding a circular require: view loads this file's consumers,
-- not this module).

local M = {}

--- Build a boundary PATTERN text-object.
--
-- `pat` is a Lua pattern matching a unit's BOUNDARY (the separator
-- between units, e.g. "[^%w_]" for words, "[!%.%?][ \n]" for
-- sentences). The returned function finds the previous and next
-- boundary around point and returns the half-open range
-- [after-prev-boundary's-gap, current-boundary's-non-ws-prefix-end)
-- plus `boundary_len` = the boundary's trailing-whitespace length
-- (how many chars a forward motion should skip to land at the next
-- unit). This single formula covers word/bigword/sentence/subsentence.
-- `dir` selects which adjacent unit to return when point sits ON a
-- boundary (the no-man's-land between units): nil/>0 -> the next unit
-- forward, <0 -> the previous unit backward, 0 -> nil (containing-only).
-- When point is inside a unit, dir is ignored and that unit is returned.
---@param pat string boundary pattern
---@return function fn
function M.pattern(pat)
    local function fn(view, line, col, dir)
        return view:_pattern_range(pat, line, col, dir)
    end
    return fn
end

--- Build a balanced-pair (sexp) text-object.
--
-- `pairs` is a list of `{opener, closer}` delimiter strings. Each
-- pair may use distinct multi-character open/close delimiters (e.g.
-- {"begin","end"}, {"<!--","-->"}, {"(",")"}). The returned function
-- finds the innermost pair enclosing point (including the delimiters)
-- and returns its half-open range [opener, closer_end) with
-- `boundary_len = 0` (forward motion lands right after the closer).
-- When point is BETWEEN pairs, `dir` selects which adjacent pair to
-- return: nil/0 or >0 -> the next pair forward (so mark_sexp selects
-- it and forward_sexp steps into it); <0 -> the previous pair backward
-- (so backward_sexp steps back into it). Returns all-nil only at the
-- true end/start of document. The sexp commands (mark/kill/copy/
-- transpose/forward/backward/down/up) consume this range only — they
-- no longer touch the matching primitives or recover the pair set.
---@param pairs table list of {opener:string, closer:string}
---@return function fn
function M.sexp(pairs)
    local function fn(view, line, col, dir)
        return view:_sexp_range(line, col, pairs, dir)
    end
    return fn
end

--- Build a tree-sitter QUERY text-object.
--
-- `spec` is a table:
--   query   string  tree-sitter query source. One or more patterns,
--                   each with a capture named `capture` (default
--                   "@capture"). The captured node's byte range is the
--                   textobject unit, exactly like a pattern/sexp unit.
--   capture string  capture name to select (default "capture").
--   lang    string?  bundled grammar name to compile the query against.
--                   When omitted, the active major mode's tree-sitter
--                   language is used (resolved lazily at call time via
--                   view:ts_language()).
--
-- The returned function runs the (cached, compiled) query against the
-- view's shared parse tree (view:hl_tree(), a fresh RAII snapshot per
-- call — NEVER caches the TSNode/Tree across calls, since TSNode embeds
-- a TSTree* that dangles once the RAII Tree is GC'd; re-resolve by
-- byte range every call, exactly like expand-region's tree path).
--
-- dir semantics mirror pattern()/sexp():
--   nil/0 or >0 -> the first unit whose start is at/after point
--                  (forward motion / mark picks the upcoming unit);
--   <0          -> the last unit whose start is strictly before point
--                  (backward motion).
-- When point is INSIDE a unit, that unit is returned and dir is ignored
-- (so `select_range` / mark selects the containing unit).
--
-- Returns all-nil when no parse tree is available (e.g. before the
-- first highlight response lands), the language is unknown, the query
-- failed to compile, or no capture matches around point. Callers fall
-- back to other textobjects; `boundary_len` is always 0 (a tree-sitter
-- node has no trailing-gap concept — forward motion lands at the node's
-- end byte).
--
-- This composes with every command built on textobjects: mark,
-- move_word, kill, copy, transpose, and the expand-region ladder (a
-- `ts` entry is a plain function, so `_textobject_fn` returns it
-- unchanged).
--
-- Example (a Lua "statement" textobject):
--   statement = TO.ts({
--       query = [[ (statement) @capture ]],
--       capture = "capture",
--   })
--
--@param spec table { query = string, capture? = string, lang? = string }
--@return function fn
function M.ts(spec)
    local capture_name = spec.capture or "capture"
    local query_src = spec.query
    local fixed_lang = spec.lang
    -- Compiled-query cache: keyed by language NAME (the pointer is
    -- process-stable per bundled grammar, but rebuilding the Query is
    -- cheap and avoids holding a ref that outlives a mode switch).
    -- `nil` sentinel = "tried and failed" (don't re-compile every call).
    local compiled = nil
    local compiled_lang = nil

    -- Return the compiled ts.Query for this view's language, or nil.
    -- Lazily compiles + caches on first use (and on language change).
    local function get_query(view)
        local lang = fixed_lang or view:ts_language()
        if lang == nil then
            return nil
        end
        if compiled ~= nil and compiled_lang == lang then
            return compiled ~= false and compiled or nil
        end
        compiled_lang = lang
        local ts = require("cursed.ts")
        local lang_ptr, lerr = ts.lang_get(lang)
        if not lang_ptr then
            return nil
        end
        local query, qerr = ts.Query.new(lang_ptr, query_src)
        if not query then
            compiled = false
            return nil
        end
        compiled = query
        return query
    end

    -- Collect the byte spans of every `capture_name` capture under
    -- `root`, in document order. Returns a list of {sb, eb} (half-open,
    -- excluding zero-width nodes). `get_text_fn` is a no-op string
    -- grabber: the textobject query has no text predicates, but the
    -- filtered_matches iterator requires one.
    local function collect_spans(root, view, ts)
        local query = get_query(view)
        if query == nil then
            return nil
        end
        local cursor = ts.QueryCursor.new()
        cursor:exec(query, root)
        -- No text predicates in a textobject query; pass a placeholder.
        local spans = {}
        for match in
            cursor:filtered_matches(function()
                return ""
            end)
        do
            for _, cap in ipairs(match.captures) do
                if cap.name == capture_name then
                    local sb = tonumber(ts.node_start_byte(cap.node))
                    local eb = tonumber(ts.node_end_byte(cap.node))
                    if eb > sb then
                        spans[#spans + 1] = { sb = sb, eb = eb }
                    end
                end
            end
        end
        table.sort(spans, function(a, b)
            return a.sb < b.sb
        end)
        return spans
    end

    local function fn(view, line, col, dir)
        local ts = require("cursed.ts")
        local tree = view:hl_tree()
        if tree == nil then
            return nil, nil, nil, nil, nil
        end
        local root = tree:root()
        if ts.node_is_null(root) then
            return nil, nil, nil, nil, nil
        end
        local spans = collect_spans(root, view, ts)
        if spans == nil or #spans == 0 then
            return nil, nil, nil, nil, nil
        end
        -- Point as a full-document byte offset (0-based). Use the
        -- view's line/col->byte mapper (handles tab/UTF-8 width, matches
        -- expand-region's coord space).
        local here = view:line_col_byte_offset(line, col)
        -- Find the unit CONTAINING point (start <= here < end), the
        -- last unit strictly before point, and the first unit at/after.
        local containing
        local prev_unit
        local next_unit
        for _, s in ipairs(spans) do
            if s.eb <= here then
                prev_unit = s
            elseif s.sb <= here and here < s.eb then
                containing = s
                break
            else -- s.sb > here
                next_unit = s
                break
            end
        end
        local unit
        if containing ~= nil then
            unit = containing
        elseif dir == nil or (dir and dir >= 0) then
            unit = next_unit
        else
            unit = prev_unit
        end
        if unit == nil then
            return nil, nil, nil, nil, nil
        end
        local sl, sc = view:byte_to_line_col(unit.sb)
        local el, ec = view:byte_to_line_col(unit.eb)
        return sl, sc, el, ec, 0
    end
    return fn
end

return M
