--- Lua major mode (built-in).
---
--- Bundles highlight query, indent settings, and word textobject.
--- Tree-sitter queries are predicate-free (#eq?/#match?/#any-of? are
--- not evaluated by the bundled C library); specificity comes from
--- declaration order + the highlighter's same-node-later-wins rule.

local TO = require("cursed.textobject")
local IH = require("cursed.input_hook")

-- This spec file runs AFTER the global `editor` exists (see
-- `cursed.config`), so it can register per-mode event handlers on
-- `editor.event_system` directly. The View emits a mode-specific
-- `mode_enter:lua` / `mode_exit:lua` (plus the generic
-- `mode_enter` / `mode_exit`) for each transition, so a mode hooks its
-- own lifecycle by name without if/else dispatch.
editor.event_system:on("mode_enter:lua", function(_ed, instance, _view)
    -- Per-instance state goes on `instance`; reads delegate to the
    -- template via __index, writes land here.
    instance._entered_at = os.time()
end)

editor.event_system:on("mode_exit:lua", function(_ed, _instance, _view)
    -- Teardown (e.g. shut down an LSP client started on enter).
end)

local LUA_HIGHLIGHT_QUERY = [[
;; Fallback declared FIRST so specific captures override it.
(identifier) @variable

;; Comments & preprocessing
(comment) @comment
(hash_bang_line) @comment

;; Strings & escapes
(string) @string
(escape_sequence) @string.escape

;; Numbers & constants
(number) @number
(nil) @constant.builtin
(true) @boolean
(false) @boolean
(vararg_expression) @constant

;; Keywords
[
  "local"
  "goto"
  "in"
  "return"
] @keyword

[
  "do"
  "end"
] @keyword

[
  "if"
  "then"
  "elseif"
  "else"
] @conditional

[
  "while"
  "repeat"
  "until"
  "for"
] @repeat

"function" @keyword.function

[
  "and"
  "or"
  "not"
] @keyword.operator

(break_statement) @keyword
(label_statement) @label

;; Operators
[
  "+"
  "-"
  "*"
  "/"
  "%"
  "^"
  "#"
  "=="
  "~="
  "<="
  ">="
  "<"
  ">"
  "="
  "&"
  "~"
  "|"
  "<<"
  ">>"
  "//"
  ".."
] @operator

;; Punctuation
[
  ";"
  ":"
  ","
  "."
] @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

;; Tables & fields
(table_constructor
[
  "{"
  "}"
] @constructor)

(field name: (identifier) @field)
(dot_index_expression field: (identifier) @field)
(method_index_expression method: (identifier) @method)

;; Functions
(parameters (identifier) @parameter)

(function_declaration
  name: [
    (identifier) @function
    (dot_index_expression
      field: (identifier) @function)
  ])

(function_declaration
  name: (method_index_expression
    method: (identifier) @method))

(assignment_statement
  (variable_list .
    name: [
      (identifier) @function
      (dot_index_expression
        field: (identifier) @function)
    ])
  (expression_list .
    value: (function_definition)))

(table_constructor
  (field
    name: (identifier) @function
    value: (function_definition)))

(function_call
  name: [
    (identifier) @function.call
    (dot_index_expression
      field: (identifier) @function.call)
    (method_index_expression
      method: (identifier) @method.call)
  ])
]]

---@return MajorModeSpec
return {
    name = "lua",
    language = "lua",
    highlight_query = LUA_HIGHLIGHT_QUERY,
    tab_width = 4,
    expand_tab = true,
    indent_width = 4,
    textobjects = {
        -- Lua word boundary: treat - as a word separator
        word = "[^%w_]",
        -- Sexp delimiters: the bracket pairs PLUS the Lua block
        -- keywords. `function`, `then`, `begin`, `do` all open blocks
        -- closed by the shared `end` keyword; depth-counting across
        -- the whole set lets these nest correctly (function ... then
        -- ... end is two nested sexps sharing one closer keyword).
        -- Word boundaries are enforced by the scan code so `end` does
        -- not match inside `append` / `send` / `endless`.
        sexp = TO.sexp({
            { "(", ")" },
            { "[", "]" },
            { "{", "}" },
            { "function", "end" },
            { "then", "end" },
            { "begin", "end" },
            { "do", "end" },
        }),
    },
    -- Syntax-aware indent (electric Return): when the cursor sits inside
    -- one of these block nodes, Return adds one extra indent level on the
    -- new line. The match is half-open [start, end): a cursor right after
    -- `end` (at the node's end byte) is NOT inside → no extra indent, so
    -- `end<RET>` stays at the current level rather than over-indenting.
    indent_queries = [[
[
  (if_statement)
  (elseif_statement)
  (else_statement)
  (for_statement)
  (while_statement)
  (repeat_statement)
  (function_declaration)
  (function_definition)
  (do_statement)
] @indent
]],
    -- Input hooks (electric pairs). `IH.opener` matches its Lua pattern
    -- as a SUFFIX of the text left of the cursor the moment the user
    -- finishes typing it; on match the closer is auto-inserted. Bracket
    -- openers insert inline (`(|)`); block (keyword) openers insert
    -- `<newline><body-indent><newline><opener-indent><closer>` and
    -- relocate the cursor to the body line — so you never type `end`.
    -- `block=true` AUTO-SPLITS so the same opener also fires on Return
    -- (e.g. `function f() <RET>` pre-places `end`). `word=true` enforces
    -- a leading word boundary so `append`/`send`/`bend` don't trigger `end`.
    -- `IH.closer` matches on Return and snaps the line's indent one unit
    -- less to the opener's level (structural `@indent` query).
    input_hooks = {
        -- Brackets: closer inserted right after the cursor (printable only).
        IH.opener("%(", ")"),
        IH.opener("%[", "]"),
        IH.opener("%{", "}"),
        -- Keyword block openers: closer (`end`) pre-placed below at the
        -- opener's indent, cursor on the indented body line; fires on
        -- both printable and Return.
        IH.opener("then$", "end", { block = true, word = true }),
        IH.opener("do$", "end", { block = true, word = true }),
        IH.opener("function%s*[^%s]*%([^%)]*%)$", "end", { block = true, word = true }),
        -- Closers: on Return, snap the closer line's indent one unit
        -- less and open the next line at that dedented indent.
        IH.closer("end$", { word = true }),
        IH.closer("else$", { word = true }),
        IH.closer("elseif%s+[^%s]+$", { word = true }),
        IH.closer("until%s+[^%s]+$", { word = true }),
        IH.closer("%}$"),
    },
}
