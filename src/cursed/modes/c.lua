--- C major mode (built-in).
---
--- Tree-sitter queries are predicate-free (#eq?/#match?/#any-of? are
--- not evaluated by the bundled C library); specificity comes from
--- declaration order + the highlighter's same-node-later-wins rule.
--- C identifiers are lexically ambiguous, so we capture the
--- identifier only where its role is known (type_identifier,
--- field_identifier, the function of a call, a function declarator)
--- and let a bare `(identifier) @variable` fallback declared FIRST
--- cover the rest.

local C_HIGHLIGHT_QUERY = [[
;; Fallback declared FIRST so specific captures override it.
(identifier) @variable

;; Comments
(comment) @comment

;; Preprocessor
(preproc_directive) @keyword.import
"#define" @keyword.import
"#elif" @keyword.import
"#else" @keyword.import
"#endif" @keyword.import
"#if" @keyword.import
"#ifdef" @keyword.import
"#ifndef" @keyword.import
"#include" @keyword.import

;; Strings & literals
(string_literal) @string
(system_lib_string) @string
(number_literal) @number
(char_literal) @number
(null) @constant.builtin

;; Types
(type_identifier) @type
(primitive_type) @type
(sized_type_specifier) @type
"enum" @keyword
"struct" @keyword
"typedef" @keyword
"union" @keyword

;; Functions
(function_declarator declarator: (identifier) @function)
(call_expression function: (identifier) @function.call)
(call_expression
  function: (field_expression field: (field_identifier) @function.call))
(function_definition declarator: (function_declarator declarator: (identifier) @function))

;; Fields & labels
(field_identifier) @field
(statement_identifier) @label

;; Operators
[
  "--"
  "-"
  "-="
  "->"
  "="
  "!="
  "*"
  "&"
  "&&"
  "+"
  "++"
  "+="
  "<"
  "=="
  ">"
  "||"
] @operator

;; Punctuation
[
  "."
  ";"
  ","
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

;; Keywords
[
  "break"
  "case"
  "const"
  "continue"
  "default"
  "do"
  "else"
  "extern"
  "for"
  "if"
  "inline"
  "return"
  "sizeof"
  "static"
  "switch"
  "volatile"
  "while"
] @keyword
]]

---@return MajorModeSpec
return {
    name = "c",
    language = "c",
    highlight_query = C_HIGHLIGHT_QUERY,
    tab_width = 4,
    expand_tab = true,
    indent_width = 4,
}
