--- Default text object definitions for the cursed editor.
---
--- Defined via the builders in cursed.textobject:
---   * `pattern(pat)` — a boundary PATTERN textobject (words, sentences, …)
---   * `sexp(pairs)` — a balanced-pair textobject; `pairs` is a list of
---     {opener, closer} strings, which may be multi-character
---     ({"begin","end"}, {"(",")"}). The sexp commands
---     (forward_sexp, mark_sexp, transpose_sexp, ...) consult the
---     active major mode's `sexp` entry to drive matching.
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

    --- Sexp: the innermost balanced-pair expression enclosing point,
    --- for the classic () [] {} set. Major modes may override this
    --- entry with their own `sexp({...})` to add language-specific
    --- delimiters (e.g. Lua's --[[ ]], HTML's <!-- -->, Pascal's
    --- begin/end). Returns nil if point isn't inside a pair.
    sexp = TO.sexp({ { "(", ")" }, { "[", "]" }, { "{", "}" } }),

    --- Alias: "balanced-expression" is the Emacs name for sexp.
    ["balanced-expression"] = TO.sexp({ { "(", ")" }, { "[", "]" }, { "{", "}" } }),
}
