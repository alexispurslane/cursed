--- Python major mode (built-in).
---
--- Tree-sitter queries are predicate-free (#eq?/#match?/#any-of? are
--- not evaluated by the bundled C library); specificity comes from
--- declaration order + the highlighter's same-node-later-wins rule.
--- A bare `(identifier) @variable` fallback declared FIRST covers
--- bare names; functions/types are captured at their definition or
--- call site where the role is known.

local PYTHON_HIGHLIGHT_QUERY = [[
;; Fallback declared FIRST so specific captures override it.
(identifier) @variable

;; Comments & strings
(comment) @comment
(string) @string
(escape_sequence) @string.escape

;; Literals
[
  (integer)
  (float)
] @number

[
  (none)
  (true)
  (false)
] @constant.builtin

;; Decorators
(decorator) @attribute
(decorator (identifier) @function)

;; Functions: declaration name + call sites
(function_definition name: (identifier) @function)
(call function: (identifier) @function.call)
(call
  function: (attribute attribute: (identifier) @function.call))

;; Types
(type (identifier) @type)
(generic_type (identifier) @type)

;; Attributes / fields
(attribute attribute: (identifier) @field)

;; Operators
[
  "-"
  "-="
  "!="
  "*"
  "**"
  "**="
  "*="
  "/"
  "//"
  "//="
  "/="
  "&"
  "&="
  "%"
  "%="
  "^"
  "^="
  "+"
  "->"
  "+="
  "<"
  "<<"
  "<<="
  "<="
  "<>"
  "="
  ":="
  "=="
  ">"
  ">="
  ">>"
  ">>="
  "|"
  "|="
  "~"
  "@="
] @operator

[
  "and"
  "in"
  "is"
  "not"
  "or"
] @keyword.operator

;; Keywords
[
  "as"
  "assert"
  "async"
  "await"
  "break"
  "class"
  "continue"
  "def"
  "del"
  "elif"
  "else"
  "except"
  "exec"
  "finally"
  "for"
  "from"
  "global"
  "if"
  "import"
  "lambda"
  "nonlocal"
  "pass"
  "print"
  "raise"
  "return"
  "try"
  "while"
  "with"
  "yield"
  "match"
  "case"
] @keyword
]]

---@return MajorModeSpec
return {
    name = "python",
    language = "python",
    highlight_query = PYTHON_HIGHLIGHT_QUERY,
    tab_width = 4,
    expand_tab = true,
    indent_width = 4,
}
