--- Bash major mode (built-in).
---
--- Tree-sitter queries are predicate-free; specificity comes from
--- declaration order + same-node-later-wins.

local BASH_HIGHLIGHT_QUERY = [[
;; Comments & strings
(comment) @comment
[
  (string)
  (raw_string)
  (heredoc_body)
  (heredoc_start)
] @string

;; Variables & properties
(variable_name) @field
(subscript index: (word) @field)
(expansion) @variable

;; Commands & functions (declared AFTER @field/@variable fallbacks are
;; not needed here since command_name / word are disjoint node types).
(command_name) @function
(function_definition name: (word) @function)
(file_descriptor) @number

;; Operators
[
  "$"
  "&&"
  ">"
  ">>"
  "<"
  "|"
] @operator

;; Punctuation
[
  "("
  ")"
  "{"
  "}"
  "["
  "]"
] @punctuation.bracket

;; Keywords
[
  "case"
  "do"
  "done"
  "elif"
  "else"
  "esac"
  "export"
  "fi"
  "for"
  "function"
  "if"
  "in"
  "select"
  "then"
  "unset"
  "until"
  "while"
] @keyword
]]

---@return MajorModeSpec
return {
    name = "bash",
    language = "bash",
    highlight_query = BASH_HIGHLIGHT_QUERY,
    tab_width = 4,
    expand_tab = true,
    indent_width = 4,
}
