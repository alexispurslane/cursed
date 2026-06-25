--- Go major mode (built-in). Go uses real tabs.
---
--- Tree-sitter queries are predicate-free (#eq?/#match?/#any-of? are
--- not evaluated by the bundled C library); specificity comes from
--- declaration order + the highlighter's same-node-later-wins rule.

local GO_HIGHLIGHT_QUERY = [[
;; Fallback declared FIRST so specific captures override it.
(identifier) @variable

;; Comments
(comment) @comment

;; Strings & literals
(interpreted_string_literal) @string
(raw_string_literal) @string
(rune_literal) @string
(escape_sequence) @string.escape

[
  (int_literal)
  (float_literal)
  (imaginary_literal)
] @number

[
  (true)
  (false)
  (nil)
  (iota)
] @constant.builtin

;; Types
(type_identifier) @type
(qualified_type name: (type_identifier) @type)

;; Functions: declarations + calls
(function_declaration name: (identifier) @function)
(method_declaration name: (field_identifier) @function)
(call_expression function: (identifier) @function.call)
(call_expression
  function: (selector_expression field: (field_identifier) @function.call))

;; Fields
(field_identifier) @field

;; Operators
[
  "--"
  "-"
  "-="
  ":="
  "!"
  "!="
  "..."
  "*"
  "*="
  "/"
  "/="
  "&"
  "&&"
  "&="
  "%"
  "%="
  "^"
  "^="
  "+"
  "++"
  "+="
  "<-"
  "<"
  "<<"
  "<<="
  "<="
  "="
  "=="
  ">"
  ">="
  ">>"
  ">>="
  "|"
  "|="
  "||"
  "~"
] @operator

;; Keywords
[
  "break"
  "case"
  "chan"
  "const"
  "continue"
  "default"
  "defer"
  "else"
  "fallthrough"
  "for"
  "func"
  "go"
  "goto"
  "if"
  "import"
  "interface"
  "map"
  "package"
  "range"
  "return"
  "select"
  "struct"
  "switch"
  "type"
  "var"
] @keyword

;; Punctuation
[
  "."
  ","
  ";"
  ":"
] @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket
]]

---@return MajorModeSpec
return {
    name = "go",
    language = "go",
    highlight_query = GO_HIGHLIGHT_QUERY,
    tab_width = 4,
    expand_tab = false,
    indent_width = 4,
}
