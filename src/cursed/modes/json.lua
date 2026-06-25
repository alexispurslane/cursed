--- JSON major mode (built-in).
---
--- Tree-sitter queries are predicate-free; specificity comes from
--- declaration order + same-node-later-wins.

local JSON_HIGHLIGHT_QUERY = [[
;; Keys (declared FIRST so a bare string value overrides to @string).
(pair key: (_) @keyword)

(string) @string
(number) @number

[
  (null)
  (true)
  (false)
] @constant.builtin

(escape_sequence) @string.escape
(comment) @comment

;; Punctuation
[
  ","
  ":"
] @punctuation.delimiter

[
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket
]]

---@return MajorModeSpec
return {
    name = "json",
    language = "json",
    highlight_query = JSON_HIGHLIGHT_QUERY,
    tab_width = 2,
    expand_tab = true,
    indent_width = 2,
}
