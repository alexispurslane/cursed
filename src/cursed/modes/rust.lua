--- Rust major mode (built-in).
---
--- Tree-sitter queries are predicate-free (#eq?/#match?/#any-of? are
--- not evaluated by the bundled C library); specificity comes from
--- declaration order + the highlighter's same-node-later-wins rule.
---
--- Rust identifiers are lexically ambiguous (a bare `Foo` may be a
--- type, an enum constructor, a const, or a variable). Since we can't
--- predicate on case, we rely on structural position: capture the
--- identifier only where its syntactic role is known (the `name:`/
--- `field:`/`pattern:` fields, or the function of a call). A bare
--- `(identifier) @variable` fallback declared FIRST covers the rest.

local TO = require("cursed.textobject")

local RUST_HIGHLIGHT_QUERY = [[
;; ── Fallback declared FIRST so specific captures override it. ────────
(identifier) @variable

;; ── Comments & attributes ────────────────────────────────────────────
(line_comment) @comment
(block_comment) @comment

(attribute_item) @attribute
(inner_attribute_item) @attribute

;; ── Strings & literals ──────────────────────────────────────────────
(string_literal) @string
(raw_string_literal) @string
(char_literal) @string
(escape_sequence) @string.escape

(integer_literal) @constant.builtin
(float_literal) @constant.builtin
(boolean_literal) @constant.builtin

;; ── Types ───────────────────────────────────────────────────────────
(type_identifier) @type
(primitive_type) @type.builtin

(struct_item       name: (type_identifier) @type)
(enum_item         name: (type_identifier) @type)
(trait_item        name: (type_identifier) @type)
(impl_item         type:  (type_identifier) @type)
(impl_item         trait: (type_identifier) @type)
(type_item         name: (type_identifier) @type)
;; enum variant names are uppercase constructors
(enum_variant      name: (identifier) @constant)

;; generic params: <T, 'a, const N: usize>
(type_parameter name: (type_identifier) @type)
;; lifetime params: 'a
(lifetime) @label

;; ── Constants & statics ──────────────────────────────────────────────
(const_item   name: (identifier) @constant)
(static_item  name: (identifier) @constant)

;; ── Module & use paths ───────────────────────────────────────────────
(crate) @keyword
(use_declaration argument: (scoped_identifier name: (identifier) @namespace))
(mod_item name: (identifier) @namespace)
;; module path segments: `std::collections::HashMap`
(scoped_identifier path: (identifier) @namespace)
(scoped_identifier path: (scoped_identifier name: (identifier) @namespace))
(scoped_type_identifier path: (identifier) @namespace)
(scoped_type_identifier path: (scoped_identifier name: (identifier) @namespace))

;; ── Functions ───────────────────────────────────────────────────────
(function_item       name: (identifier) @function)
(function_signature_item name: (identifier) @function)

;; (call_expression function: (identifier) @function.call)
(call_expression
  function: (identifier) @function.call)
(call_expression
  function: (field_expression
    field: (field_identifier) @function.method.call))
(call_expression
  function: (scoped_identifier
    name: (identifier) @function.call))

(generic_function
  function: (identifier) @function.call)
(generic_function
  function: (scoped_identifier
    name: (identifier) @function.call))
(generic_function
  function: (field_expression
    field: (field_identifier) @function.method.call))

;; macro invocation: `vec![]` / `println!()`
(macro_invocation
  macro: (identifier) @function.macro)
(macro_invocation
  "!" @function.macro)

;; ── Parameters & patterns ────────────────────────────────────────────
(parameter        pattern: (identifier) @variable.parameter)
(self_parameter) @variable.builtin
(closure_parameters (identifier) @variable.parameter)
(let_declaration pattern: (identifier) @variable)

;; struct fields in use: `use foo::Bar;` and `Foo { field: val }`
(field_initializer   field: (field_identifier) @field)
(field_pattern       name:   (field_identifier) @field)
(field_declaration   name:   (field_identifier) @field)
(shorthand_field_initializer (identifier) @field)
(struct_pattern
  type: (scoped_type_identifier
    name: (type_identifier) @constant))

;; ── Keywords ─────────────────────────────────────────────────────────
[
  "as"
  "async"
  "await"
  "break"
  "const"
  "continue"
  "default"
  "dyn"
  "enum"
  "extern"
  "fn"
  "for"
  "gen"
  "if"
  "impl"
  "in"
  "let"
  "loop"
  "match"
  "mod"
  "move"
  "pub"
  "raw"
  "ref"
  "return"
  "static"
  "struct"
  "trait"
  "type"
  "union"
  "unsafe"
  "use"
  "where"
  "while"
  "yield"
] @keyword

"macro_rules!" @keyword
(mutable_specifier) @keyword
(use_list (self) @keyword)
(scoped_use_list (self) @keyword)
(scoped_identifier (self) @keyword)

;; control-flow context
[
  "else"
] @conditional

;; operators & punctuation
[
  "*"
  "&"
  "'"
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

(type_arguments
  "<" @punctuation.bracket
  ">" @punctuation.bracket)
(type_parameters
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

"::" @punctuation.delimiter
":"  @punctuation.delimiter
"."  @punctuation.delimiter
","  @punctuation.delimiter
";"  @punctuation.delimiter
]]

---@return MajorModeSpec
return {
    name = "rust",
    language = "rust",
    highlight_query = RUST_HIGHLIGHT_QUERY,
    tab_width = 4,
    expand_tab = true,
    indent_width = 4,
    textobjects = {
        word = "[^%w_]",
        sexp = TO.sexp({
            { "(", ")" },
            { "[", "]" },
            { "{", "}" },
        }),
    },
}
