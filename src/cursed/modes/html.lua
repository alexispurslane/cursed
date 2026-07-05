--- HTML major mode (built-in).
---
--- Vendors the tree-sitter-html grammar (ABI 14 → compatible with the
--- bundled lib's min-compatible 13). The highlight query is the upstream
--- highlights.scm (predicate-free) plus small enrichments for entities,
--- the attribute `=` punctuation, and the doctype token. Tree-sitter
--- queries are predicate-free here; specificity comes from declaration
--- order + the same-node-later-wins rule.
---
--- This registration ALSO lets `markdown` mode inject the `html` grammar
--- into `html_block` regions — the lane resolves injected grammars from
--- every registered MajorMode that carries `language` + `highlight_query`,
--- so simply registering this mode makes markdown HTML blocks highlight
--- for free. (The reverse — HTML injecting CSS / JavaScript into
--- `<script>`/`<style>` elements — is intentionally NOT wired: we don't
--- vendor a `css` or `javascript` grammar, and an injection_query
--- referencing unknown grammars would warn-fail in the lane every parse.
--- The raw text inside those elements still falls through to `@text`.)

local TO = require("cursed.textobject")
local IH = require("cursed.input_hook")

-- HTML5 void elements — never have (and must not get) a closing tag.
-- Source: HTML Living Standard §void-elements.
local VOID_ELEMENTS = {
    area = true,
    base = true,
    br = true,
    col = true,
    embed = true,
    hr = true,
    img = true,
    input = true,
    link = true,
    meta = true,
    param = true,
    source = true,
    track = true,
    wbr = true,
}

-- Tag-completion input hook.
--
-- On typing `>` that closes a START tag, auto-insert the matching close
-- tag after the cursor (so `<div>` becomes `<div>|</div>` with the cursor
-- ready to type the element's content). Declines (no-op) for:
--   * closing tags    `</div>`   — the char after `<` is `/`, not a
--                                 letter, so the tag-name capture fails.
--   * self-closing     `<br/>`   — the char before the final `>` is `/`.
--   * void elements    `<img>`   — `img` is in VOID_ELEMENTS.
--   * comments / doctype `<!-- … -->` / `<!doctype>` — char after `<` is
--                                 `!`, not a letter.
--   * anything without a `<tagname…` prefix on the same line — e.g. a
--     bare `>` in prose (`a > b`) has no preceding `<`, so the capture
--     fails to match. (Raw `<`/`>` in text content is invalid HTML
--     anyway — it must be `&lt;`/`&gt;` — so we don't worry about
--     angle brackets appearing outside tags.)
--
-- Shared by both HTML input hooks — the `>`-printable inline completer
-- and the Return block opener — so the decline rules stay in one place.
local function extract_close_tag(left)
    -- Self-closing `<tag/>`? char before the final `>` is `/`.
    if left:match("/>%s*$") then
        return nil
    end
    local tag = left:match("<([%a][%w-]*)[^<>]*>$")
    if tag == nil or VOID_ELEMENTS[tag:lower()] then
        return nil
    end
    return "</" .. tag .. ">"
end

-- Tag-completion input hook (printable trigger).
--
-- On typing `>` that closes a START tag, auto-insert the matching close
-- tag after the cursor (so `<div>` becomes `<div>|</div>` with the cursor
-- ready to type the element's content). Decline rules live in
-- `extract_close_tag` (shared with the Return block opener below).
--
-- Multi-cursor: each cursor is checked independently. Declined cursors
-- return a no-op edit (sl==rl, sc==rc → `insert_translator` returns nil,
-- leaving that cursor untouched); accepted cursors get their `</tag>`.
-- `batch_edit` iterates ALL of the view's cursors, so we key the
-- per-cursor closer string by the cursor object and skip anything not
-- in the accepted set (cursors that matched a different hook, or that
-- this hook declined) via the no-op return.
--
-- Limitation: the tag-name + attribute scan is a single-line Lua
-- pattern, not a tree-sitter query. Cross-line start tags, and `>`
-- inside a quoted attribute value, fall back to no-completion (safe —
-- no spurious `</tag>` is inserted). Wiring this to the parse tree
-- (like `IH.closer`'s structural dedent) would handle those edge cases
-- but the regex covers the overwhelming majority of real HTML editing.
local function make_tag_complete_fn()
    return function(view, cursors)
        if #cursors == 0 then
            return {}
        end
        local buf = view.buffer
        local closer_for = {}
        for _, c in ipairs(cursors) do
            local left = buf:line_text(c.line):sub(1, c.col)
            local closer = extract_close_tag(left)
            if closer ~= nil then
                closer_for[c] = closer
            end
        end
        if next(closer_for) == nil then
            return {}
        end
        local handled = {}
        view:batch_edit(false, function(c)
            local closer = closer_for[c]
            if closer == nil then
                -- Declined: no-op insert (K=0, rc=col) so the
                -- translator returns nil and this cursor is untouched.
                local sl, sc = c.line, c.col
                return sl, sc, sl, sc, "insert"
            end
            handled[#handled + 1] = c
            local sl, sc = c.line, c.col
            local rl, rc = buf:insert_char(c.line, c.col, closer)
            -- `insert_relocate` keeps the cursor at (c.line, c.col) —
            -- i.e. BETWEEN the `>` and the freshly-inserted `</tag>` —
            -- ready for the user to type the element's content.
            return sl, sc, rl, rc, "insert_relocate", c.line, c.col
        end)
        return handled
    end
end

-- Upstream highlights.scm + enrichments.
-- Declared in roughly specificity order; later captures on the same
-- node win, so the bare `(!doctype)` `doctype` constant overrides any
-- fallback. Brackets are listed LAST so they read as structural chrome
-- rather than competing with tag-name colour, but a tag's `tag_name`
-- capture is on a distinct child node so ordering between them is moot.
local HTML_HIGHLIGHT_QUERY = [[
;; Tag names — both open and close (erroneous close gets its own color).
(tag_name) @tag
(erroneous_end_tag_name) @tag.error

;; Attribute name = value pair.
(attribute_name) @attribute
(attribute_value) @string

;; The doctype token (`<!doctype html>`) reads as a constant.
(doctype) @constant

;; Comments & entities.
(comment) @comment
(entity) @string.escape

;; Generic text node (prose between tags) reads as default-fg prose.
(text) @text

;; Punctuation.
"=" @punctuation.delimiter

[
  "<"
  ">"
  "</"
  "/>"
  "<!"
] @punctuation.bracket
]]

---@return MajorModeSpec
return {
    name = "html",
    language = "html",
    highlight_query = HTML_HIGHLIGHT_QUERY,
    tab_width = 2,
    expand_tab = true,
    indent_width = 2,
    textobjects = {
        -- Word boundary: any char that is NOT a word char or
        -- hyphen is a separator, so tag names like `div` and
        -- hyphenated values like `item-1` / `class-A` (and
        -- aria-* / data-* attributes) read as single words even
        -- inside `<div class=\"item-1\">`.
        word = "[^%w%-]",
        -- HTML sexp pairs: only the real bracket pairs (parens are
        -- rare in attribute values but appear in inline styles / SVG
        -- transforms). Angle-bracket tag matching is NOT a balanced
        -- pair (every `<...>` is self-terminated) so it's omitted — the
        -- `tag` ts textobject below covers element-boundary motion.
        sexp = TO.sexp({
            { "(", ")" },
            { "[", "]" },
            { "{", "}" },
        }),
        -- Tree-sitter `tag` textobject: the enclosing element. Used by
        -- mark-tag / move-to-next-tag / kill-tag. `lang` is omitted so
        -- the builder resolves the active mode's grammar ("html")
        -- lazily at call time. `element` covers the whole `<tag>...</tag>`
        -- node; `self_closing_tag` covers `<tag/>`. self_closing is
        -- nested INSIDE an `element` wrapper in the grammar, so listing
        -- both and taking the first/last match (per the
        -- smallest-enclosing scan) lands on the right unit.
        tag = TO.ts({
            query = [[ [
  (element)
  (self_closing_tag)
] @capture ]],
        }),
    },
    -- Syntax-aware indent (electric Return): when the cursor sits
    -- inside an `element`'s CONTENT (between start_tag and end_tag),
    -- Return adds one extra indent level on the new line. Half-open
    -- [start, end): a cursor right after `</tag>` is NOT inside, so a
    -- close tag at line end doesn't over-indent.
    indent_queries = [[
[
  (element)
] @indent
]],
    -- Tree-sitter document outline (goto_symbol fallback when no LSP is
    -- bound to the buffer). Captures `start_tag` nodes; the completer
    -- shows the tag's first source line as the label (e.g.
    -- `<body class="main">`), giving a tag-level outline.
    symbol_queries = [[
[
  (start_tag)
] @symbol
]],
    -- Input hooks (electric pairs + tag completion + tag block opener).
    --
    -- Bracket openers pair as usual (`()`/`[]`/`{}`) for inline styles,
    -- SVG transforms, and the rare parens in attribute values. Angle
    -- brackets are NOT paired via `IH.opener`: pairing `<` → `>` would
    -- pre-place a `>` that the user then has to skip past, and the
    -- editor has no skip-over-closer logic — so the user typing `>` to
    -- close the tag would insert a SECOND `>`, breaking the
    -- tag-completion hook's suffix match. Instead, angle-bracket tags
    -- are completed as a whole: see `make_tag_complete_fn` above.
    --
    -- Quote pairing is omitted: a `"` typed at the end of prose would
    -- pair against itself, which is more annoying than helpful for an
    -- authoring language where quotes are mostly attribute delimiters.
    -- (Same convention as the lua mode.)
    --
    -- Two tag hooks, composed:
    --   1. `>`-printable  — typing `>` after `<div` inserts `</div>`
    --      inline (`<div>|</div>`), for fast single-line authoring.
    --   2. Return block opener — hitting Enter right after a start tag
    --      splits into three lines (opener / indented body / closer),
    --      like the lua mode's `function f() <RET>` pre-places `end`.
    --      In SPLIT MODE: if the `>`-printable hook already inline-
    --      placed `</div>` right after the cursor, the block opener
    --      reuses it as line 3 instead of inserting a second one — so
    --      the common flow `<div><RET>` (where `>` already completed
    --      the inline closer) produces a clean 3-line block, not
    --      `<div>\n  \n</div></div>`.
    --
    -- Hook dispatch is last-declared-first (`_input_hooks_composite`
    -- reverses the list), so the more-specific tag hooks are listed
    -- LAST to be checked first: the Return block opener before any
    -- future return-trigger hook, and the `>`-printable completer
    -- before any future `>`-printable hook.
    input_hooks = {
        IH.opener("%(", ")"),
        IH.opener("%[", "]"),
        IH.opener("%{", "}"),
        IH.hook(">", "printable", make_tag_complete_fn()),
        IH.dynamic_block_opener("<[%a][%w-]*[^<>]*>$", extract_close_tag),
    },
}
