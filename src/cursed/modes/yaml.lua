--- YAML major mode (built-in).
---
--- Tree-sitter queries are predicate-free; specificity comes from
--- declaration order + same-node-later-wins. The YAML grammar's public
--- node names come from the upstream queries/highlights.scm.

local YAML_HIGHLIGHT_QUERY = [[
;; Scalars
[
  (double_quote_scalar)
  (single_quote_scalar)
  (block_scalar)
  (string_scalar)
] @string

[
  (integer_scalar)
  (float_scalar)
] @number

(boolean_scalar) @boolean
(null_scalar) @constant.builtin

(comment) @comment

;; Anchors & aliases
[
  (anchor_name)
  (alias_name)
] @label

(tag) @type

;; Directives
[
  (yaml_directive)
  (tag_directive)
  (reserved_directive)
] @attribute

;; Keys (declared AFTER the @string fallback so a key node overrides).
(block_mapping_pair
  key: (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @field))

(block_mapping_pair
  key: (flow_node
    (plain_scalar
      (string_scalar) @field)))

(flow_mapping
  (_
    key: (flow_node
      [
        (double_quote_scalar)
        (single_quote_scalar)
      ] @field)))

(flow_mapping
  (_
    key: (flow_node
      (plain_scalar
        (string_scalar) @field))))

;; Punctuation
[
  ","
  "-"
  ":"
  ">"
  "?"
  "|"
] @punctuation.delimiter

[
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  "*"
  "&"
  "---"
  "..."
] @punctuation.delimiter
]]

---@return MajorModeSpec
return {
    name = "yaml",
    language = "yaml",
    highlight_query = YAML_HIGHLIGHT_QUERY,
    tab_width = 2,
    expand_tab = true,
    indent_width = 2,
}
