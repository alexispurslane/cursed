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
-- bare strings, write `pattern("[^%w_]")` or `sexp({{"(",")"},...})`.
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

return M
