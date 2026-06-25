--- TOML major mode (built-in).
---
--- Tree-sitter queries are predicate-free; specificity comes from
--- declaration order + same-node-later-wins.

local TOML_HIGHLIGHT_QUERY = [==[
;; Keys & properties
(bare_key) @keyword
(quoted_key) @string
(pair (bare_key)) @field
(pair (dotted_key (bare_key) @field))

;; Literals
(boolean) @boolean
[
  (integer)
  (float)
] @number

[
  (offset_date_time)
  (local_date_time)
  (local_date)
  (local_time)
] @string

;; Strings & comments
(string) @string
(escape_sequence) @string.escape
(comment) @comment

;; Punctuation & operators
[
  "."
  ","
] @punctuation.delimiter

"=" @operator

[
  "["
  "]"
  "[["
  "]]"
  "{"
  "}"
] @punctuation.bracket
]==]

---@return MajorModeSpec
return {
    name = "toml",
    language = "toml",
    highlight_query = TOML_HIGHLIGHT_QUERY,
    tab_width = 2,
    expand_tab = true,
    indent_width = 2,
}
