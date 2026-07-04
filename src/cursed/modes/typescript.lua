--- TypeScript major mode (built-in).
---
--- Specificity comes from declaration order + the highlighter's
--- same-node-later-wins rule: a broad `(identifier) @variable` fallback
--- is declared FIRST so specific captures override it. We ALSO use the
--- text predicates the editor implements over the C library (#match?,
--- #any-of?) — evaluated by `QueryCursor:filtered_matches` — to pin
--- ambiguous bare identifiers by their casing/screening (capitalized
--- → type, SCREAMING_SNAKE → constant, well-known globals → builtin).
--- Structural captures still handle the role-known positions (a
--- `type_identifier`, the `name:` of a `function_declaration`, the
--- function of a `call_expression`, …).
---
--- The TS grammar ships TWO languages: `typescript` (this spec) and
--- `tsx` (cursed.modes.tsx, which extends this spec + adds JSX
--- captures). They share node types for everything outside JSX, so the
--- highlight query below is reused verbatim by tsx.

local TO = require("cursed.textobject")
local IH = require("cursed.input_hook")
local completers = require("cursed.completers")

-- Shared by cursed.modes.tsx (which appends JSX captures).
local TYPESCRIPT_HIGHLIGHT_QUERY = [[
;; Fallback declared FIRST so specific captures override it.
(identifier) @variable

;; Predicate-gated identifier roles (bare names disambiguated by
;; casing / known-builtin screening). Each is gated, so it only wins
;; its node when the predicate passes; otherwise the @variable fallback
;; above remains in effect.
;;   * Capitalized → a type / class / enum-variant reference
((identifier) @type
  (#match? @type "^[A-Z]"))
;;   * ALL_CAPS_SCREAMING → a constant
((identifier) @constant
  (#match? @constant "^[A-Z][A-Z0-9_]*$"))
;;   * well-known global objects (constructors / namespaces)
((identifier) @type.builtin
  (#any-of? @type.builtin
    "Array" "Boolean" "Date" "Error" "JSON" "Map" "Math" "Number"
    "Object" "Promise" "RegExp" "Set" "String" "Symbol" "WeakMap" "WeakSet"
    "console" "window" "document" "globalThis" "process" "Buffer" "NaN"
    "Infinity" "undefined"))

;; Comments & shebang
(comment) @comment
(hash_bang_line) @comment

;; Strings, templates & regex
(string) @string
(string_fragment) @string
(template_string) @string
(template_type) @type
(escape_sequence) @string.escape
(regex) @string
(regex_pattern) @string
(regex_flags) @keyword

;; Numbers & literals
(number) @number
[
  (true)
  (false)
  (null)
] @constant.builtin
(undefined) @constant.builtin

(this) @variable.builtin
(super) @keyword

;; Types
(type_identifier) @type
(predefined_type) @type.builtin

;; Decorators
(decorator) @attribute
(decorator (identifier) @function)

;; Functions: declaration name + call sites
(function_declaration      name: (identifier) @function)
(function_signature        name: (identifier) @function)
(generator_function_declaration name: (identifier) @function)
(method_definition         name: (property_identifier) @function)
(method_signature         name: (property_identifier) @function)

(call_expression
  function: (identifier) @function.call)
(call_expression
  function: (member_expression
    property: (property_identifier) @function.method.call))
(call_expression
  function: (new_expression
    constructor: (identifier) @constructor))

(new_expression constructor: (identifier) @constructor)

;; arrow functions: `const f = (x) => x` — the bound name is a function
(variable_declarator
  name: (identifier) @function
  value: (arrow_function))
(variable_declarator
  name: (identifier) @function
  value: (function_expression))

;; Types & classes
(class_declaration       name: (type_identifier) @type)
(abstract_class_declaration name: (type_identifier) @type)
(interface_declaration   name: (type_identifier) @type)
(enum_declaration        name: (identifier) @type)
(type_alias_declaration  name: (type_identifier) @type)
(internal_module        name: (identifier) @namespace)

;; enum members are constants
(enum_body (property_identifier) @constant)

;; Parameters & fields
(required_parameter (identifier) @variable.parameter)
(optional_parameter (identifier) @variable.parameter)
(public_field_definition name: (property_identifier) @field)
(public_field_definition name: (private_property_identifier) @field)

;; property access: `obj.prop` / `obj["prop"]`
(member_expression property: (property_identifier) @field)
(subscript_expression index: (string (string_fragment) @field))

;; Imports
(import_statement (import_clause (identifier) @namespace))
(named_imports (import_specifier name: (identifier) @namespace))

;; Punctuation — generics / type args
(type_arguments
  "<" @punctuation.bracket
  ">" @punctuation.bracket)
(type_parameters
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  ";"
  ":"
  ","
  "."
  "?"
  "=>"
] @punctuation.delimiter

;; Operators
[
  "+"
  "-"
  "*"
  "/"
  "%"
  "**"
  "++"
  "--"
  "="
  "+="
  "-="
  "*="
  "/="
  "%="
  "**="
  "<<"
  ">>"
  ">>>"
  "<<="
  ">>="
  ">>>="
  "=="
  "==="
  "!="
  "!=="
  "<"
  ">"
  "<="
  ">="
  "&&"
  "||"
  "??"
  "&"
  "|"
  "^"
  "~"
  "!"
  "..."
  "?."
] @operator

;; Keywords
[
  "as"
  "async"
  "await"
  "break"
  "case"
  "catch"
  "class"
  "const"
  "continue"
  "default"
  "delete"
  "do"
  "else"
  "export"
  "extends"
  "finally"
  "for"
  "from"
  "function"
  "get"
  "if"
  "import"
  "in"
  "instanceof"
  "let"
  "new"
  "of"
  "return"
  "set"
  "switch"
  "throw"
  "try"
  "typeof"
  "var"
  "void"
  "while"
  "yield"
  "abstract"
  "declare"
  "enum"
  "implements"
  "interface"
  "keyof"
  "namespace"
  "private"
  "protected"
  "public"
  "readonly"
  "satisfies"
  "static"
  "type"
] @keyword
]]

---@return MajorModeSpec
return {
    name = "typescript",
    language = "typescript",
    -- First-wins list of LSP executables to spawn when a view activates
    -- the typescript mode. Entries may be bare strings OR candidate
    -- tables carrying extra argv / env (see cursed.lsp_client.normalize).
    -- `typescript-language-server` wraps tsserver; it speaks JSON-RPC on
    -- stdio via the `--stdio` flag.
    lsp_servers = {
        { bin = "typescript-language-server", args = { "--stdio" } },
    },
    -- In-buffer completion source: the general-purpose LSP completer.
    completer = completers.lsp,
    highlight_query = TYPESCRIPT_HIGHLIGHT_QUERY,
    tab_width = 2,
    expand_tab = true,
    indent_width = 2,
    textobjects = {
        word = "[^%w_$]",
        -- Sexp delimiters: the bracket pairs. TS blocks are brace-bodied;
        -- there's no shared keyword closer like Lua's `end`, so only the
        -- three bracket pairs participate in depth counting.
        sexp = TO.sexp({
            { "(", ")" },
            { "[", "]" },
            { "{", "}" },
        }),
    },
    -- Syntax-aware indent (electric Return): when the cursor sits inside
    -- one of these block nodes, Return adds one extra indent level on
    -- the new line. The match is half-open [start, end).
    indent_queries = [[
[
  (function_declaration)
  (function_signature)
  (generator_function_declaration)
  (method_definition)
  (method_signature)
  (arrow_function)
  (function_expression)
  (class_declaration)
  (abstract_class_declaration)
  (interface_declaration)
  (enum_declaration)
  (enum_body)
  (type_alias_declaration)
  (internal_module)
  (object)
  (object_pattern)
  (array)
  (array_pattern)
  (statement_block)
  (switch_statement)
  (switch_case)
  (switch_default)
  (for_statement)
  (for_in_statement)
  (while_statement)
  (do_statement)
  (if_statement)
  (else_clause)
  (try_statement)
  (catch_clause)
  (finally_clause)
  (with_statement)
  (labeled_statement)
] @indent
]],
    -- Tree-sitter document outline (goto_symbol fallback when no LSP is
    -- bound to the buffer).
    symbol_queries = [[
[
  (function_declaration)
  (function_signature)
  (generator_function_declaration)
  (class_declaration)
  (abstract_class_declaration)
  (interface_declaration)
  (enum_declaration)
  (type_alias_declaration)
  (method_definition)
  (method_signature)
  (abstract_method_signature)
  (namespace)
] @symbol
]],
    -- Input hooks (electric pairs). Brackets auto-insert an inline
    -- closer (`(|)`); `}` dedents one indent level on Return via the
    -- structural `@indent` query.
    input_hooks = {
        IH.opener("%(", ")"),
        IH.opener("%[", "]"),
        IH.opener("%{", "}"),
        IH.closer("%}$"),
    },
}
