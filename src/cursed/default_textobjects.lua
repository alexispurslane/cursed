--- Default text object definitions for the cursed editor.
---
--- Defined via the builders in cursed.textobject:
---   * `pattern(pat)` — a boundary PATTERN textobject (words, sentences, …)
---   * `sexp(pairs)` — a balanced-pair textobject; `pairs` is a list of
---     {opener, closer} strings, which may be multi-character
---     ({"begin","end"}, {"(",")"}). The sexp commands
---     (forward_sexp, mark_sexp, transpose_sexp, ...) consult the
---     active major mode's `sexp` entry to drive matching.
---   * `ts({ query = "...", capture = "name", lang? = "..." })` —
---     a tree-sitter QUERY textobject. Runs the (cached) query against
---     the view's shared parse tree and treats each capture's byte
---     range as a unit, with the same dir semantics as pattern/sexp.
---     Language-specific; belongs in a MajorMode's `textobjects`, not
---     here (defaults are language-agnostic).
--- Legacy bare pattern strings are also still accepted.
---
--- Used by move_word(n, obj_name), select_range(name, ...), and the
--- mark/kill/copy/transpose commands built on top of them.
---
--- These are the built-in DEFAULTS. Per-language textobjects live on
--- the major mode itself — `MajorModeSpec.textobjects` (object name →
--- boundary pattern, via the same `TO.pattern` / `TO.sexp` builders).
--- The active major mode's entries drive `move_word` / `select_range` /
--- the sexp commands, so a language overrides or adds a textobject by
--- dropping/extending a user mode file in
--- ~/.config/cursed/modes/<name>.lua (see #20 — there is NO standalone
--- ~/.config/cursed/textobjects.lua loader).

local TO = require("cursed.textobject")

return {
    --- Single character — the atomic motion unit. Returns the range
    --- of the character at/in the direction of `dir` from (line,col).
    --- Also serves as the smallest rung on the expand-region ladder.
    ---@param view table
    ---@param line integer
    ---@param col integer
    ---@param dir integer 1=forward, -1=backward
    char = function(view, line, col, dir)
        if dir and dir > 0 then
            local eol = view:content_len(line)
            if col >= eol then
                if line + 1 >= view:line_count() then
                    return nil
                end
                return line + 1, 0, line + 1, 1, 0
            end
            return line, col, line, col + 1, 0
        elseif dir and dir < 0 then
            if col == 0 then
                if line == 0 then
                    return nil
                end
                local prev_eol = view:content_len(line - 1)
                return line - 1, prev_eol + 1, line - 1, prev_eol + 1, 0
            end
            return line, col - 1, line, col, 0
        else
            -- No dir: selection mode (expand-region, mark_char). Return
            -- the character at (line,col) as a range.
            local eol = view:content_len(line)
            if col >= eol then
                return line, eol, line, eol, 0
            end
            return line, col, line, col + 1, 0
        end
    end,

    --- Word boundary: non-word characters (not alphanumeric or underscore).
    --- "foo_bar" is one word; "foo.bar" has a boundary at the dot.
    word = TO.pattern("[^%w_]"),

    --- Bigword boundary: whitespace only (punctuation is part of the word).
    --- "foo.bar" is one bigword; "foo bar" has a boundary at the space.
    bigword = TO.pattern("[^%S]"),

    --- Sentence boundary: sentence-ending punctuation followed by space or newline.
    --- Matches [!.?] then [space/newline]. Won't match periods inside words like "3.14".
    sentence = TO.pattern("[!%.%?][ \n]"),

    --- Subsentence boundary: clause-ending punctuation followed by space or newline.
    --- Matches [;—,:&] then [space/newline].
    subsentence = TO.pattern("[;\xe2\x80\x94,:&][ \n]"),

    --- Paragraph: the block of consecutive non-blank lines containing
    --- `line` (or, if on a blank line, the blank run containing it).
    --- Structural — blank-line runs, not a pattern — so it's a function.
    ---@param view table
    ---@param line integer 0-based line of point
    ---@param col integer 0-based col of point (unused)
    ---@return integer sl
    ---@return integer sc
    ---@return integer el
    ---@return integer ec
    ---@return integer boundary_len
    paragraph = function(view, line, col)
        return view:paragraph_range(line)
    end,

    --- Line motion: move one full line up or down, preserving the
    --- cursor column (clamped to the target line's length). For
    --- expand-region selection, returns the whole line.
    ---@param view table
    ---@param line integer
    ---@param col integer
    ---@param dir integer 1=forward, -1=backward
    line = function(view, line, col, dir)
        if dir and dir > 0 then
            if line + 1 >= view:line_count() then
                return nil
            end
            local target = math.min(col, view:content_len(line + 1))
            return line + 1, target, line + 1, target, 0
        elseif dir and dir < 0 then
            if line == 0 then
                return nil
            end
            local target = math.min(col, view:content_len(line - 1))
            return line - 1, target, line - 1, target, 0
        else
            -- No dir: selection mode. Return the whole current line.
            local eol = view:content_len(line)
            return line, 0, line, eol, 0
        end
    end,

    --- Buffer: the entire buffer from (0,0) to end-of-file. The largest
    --- unit in the expand-region ladder (the top rung). Structural, so
    --- a function returning a concrete range. Useful as a quick
    --- "select all" textobject that composes with mark/kill/copy like
    --- any other (e.g. `mark-buffer` selects it, `kill-buffer` would
    --- cut it).
    ---@param view table
    ---@param line integer 0-based line of point (unused)
    ---@param col integer 0-based col of point (unused)
    ---@return integer sl
    ---@return integer sc
    ---@return integer el
    ---@return integer ec
    ---@return integer boundary_len
    buffer = function(view, line, col)
        local eo = view:eof_pt()
        return 0, 0, eo.line, eo.offset, 0
    end,

    --- Sexp: the innermost balanced-pair expression enclosing point,
    --- for the classic () [] {} set. Major modes may override this
    --- entry with their own `sexp({...})` to add language-specific
    --- delimiters (e.g. Lua's --[[ ]], HTML's <!-- -->, Pascal's
    --- begin/end). Returns nil if point isn't inside a pair.
    sexp = TO.sexp({ { "(", ")" }, { "[", "]" }, { "{", "}" } }),

    --- Alias: "balanced-expression" is the Emacs name for sexp.
    ["balanced-expression"] = TO.sexp({ { "(", ")" }, { "[", "]" }, { "{", "}" } }),
}
