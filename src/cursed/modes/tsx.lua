--- TSX major mode (built-in).
---
--- Extends `cursed.modes.typescript`: reuses its entire highlight query
--- (the tsx grammar is a superset of the typescript grammar outside
--- JSX) and appends JSX-specific captures. Everything else — LSP
--- server, completer, indent settings, electric pairs, textobjects,
--- indent_queries — is inherited unchanged.

local TS_SPEC = require("cursed.modes.typescript")

-- JSX captures appended to the base TypeScript query. The tsx grammar
-- adds these node types (absent in the plain typescript grammar):
-- jsx_element, jsx_opening_element, jsx_closing_element,
-- jsx_self_closing_element, jsx_attribute, jsx_text, jsx_expression.
local JSX_QUERY = [[

;; ── JSX (superset nodes, tsx grammar only) ────────────────────────
(jsx_text) @text

;; tag name: `<Foo>`, `<Foo.Bar>`, `<foo:bar>`
(jsx_opening_element      name: (identifier) @tag)
(jsx_opening_element      name: (member_expression property: (property_identifier) @tag))
(jsx_opening_element      name: (jsx_namespace_name) @tag)
(jsx_closing_element      name: (identifier) @tag)
(jsx_closing_element      name: (member_expression property: (property_identifier) @tag))
(jsx_closing_element      name: (jsx_namespace_name) @tag)
(jsx_self_closing_element name: (identifier) @tag)
(jsx_self_closing_element name: (member_expression property: (property_identifier) @tag))
(jsx_self_closing_element name: (jsx_namespace_name) @tag)

;; attribute key: `href`, `className`, …
(jsx_attribute (property_identifier) @attribute)
]]

---@return MajorModeSpec
local spec = {}
for k, v in pairs(TS_SPEC) do
    spec[k] = v
end
spec.name = "tsx"
spec.language = "tsx"
spec.highlight_query = TS_SPEC.highlight_query .. JSX_QUERY
return spec
