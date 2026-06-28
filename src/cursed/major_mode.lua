--- Major mode for the cursed editor.
---
--- A major mode bundles keybindings, text objects, and indent settings.
--- Modes are instantiated in ~/.config/cursed/init.lua using MajorMode.new{...}
--- and mapped to filename patterns in the file_patterns array.
---
--- When a mode is activated in a view, an instance is created via
--- MajorMode:instantiate(). The instance delegates to the template
--- (prototype pattern) so per-view state lives on the instance while
--- the template's fields are shared.
---
--- Mode lifecycle is driven by events on the editor's central event hub:
--- View emits `mode_enter` / `mode_exit` (carrying the instance + view)
--- when activating/deactivating a mode, AND a mode-specific variant —
--- `mode_enter:<name>` / `mode_exit:<name>` (e.g. `mode_enter:lua`) —
--- so per-mode handlers register for their own event directly instead
--- of if/else dispatching on the instance name. The generic events
--- remain for cross-cutting consumers (logging every transition, …).
---
--- Mode spec files are UNSANDBOXED: a spec file's top level runs after
--- the global `editor` exists, so it can register its own per-mode
--- listeners before returning its MajorModeSpec —
--- `editor.event_system:on("mode_enter:<name>", function(ed, instance, view) ... end)`.
--- (See `cursed.config` for the load-order guarantee.) Code that wants
--- to react to mode transitions (LSP boot, per-instance state,
--- statistics, …) should register a listener on `editor.event_system`
--- rather than declare callbacks on the spec.
---
--- A mode may declare a `language` (a bundled tree-sitter grammar name)
--- to enable syntax highlighting. The View builds a Highlighter from the
--- highest-precedence mode that carries one. An optional `highlight_query`
--- overrides the built-in default query for the language.
---
--- Syntax-aware indent: a mode may declare `indent_queries` — a
--- predicate-free tree-sitter query whose `@indent` captures mark nodes
--- that should add ONE extra indent level on the new line when Return is
--- pressed inside them (e.g. an `if_statement` body). The View queries
--- the shared parse tree around the cursor for the smallest matching
--- node and, if the cursor sits inside one, appends an indent unit on
--- top of the carried line indent. Falls back to indent-carry-only when
--- no tree is available yet (before the first highlight response lands).
---
--- Input hooks: a mode may declare `input_hooks` — a flat list of hook
--- specs (built via the `cursed.input_hook` higher-order builders,
--- `IH`). Each hook has a Lua `pattern` matched as a SUFFIX of the text
--- left of the cursor; the moment the user finishes typing it (the
--- `printable` trigger) or hits Return (the `return` trigger), the hook's
--- `fn(view, cursors)` runs. Two predefined builders cover the classic
--- electric-pair behaviour dropped in by `major_mode`s:
---   * `IH.opener(pattern, closer, {block?, word?})` — on a `printable`
---     trigger (and, when `block=true`, ALSO on `return`) auto-insert the
---     closer; brackets insert inline (`(|)`), block openers insert
---     `<newline><body-indent><newline><opener-indent><closer>` and
---     relocate to the body line (closer pre-placed at the opener's
---     indent), then tree-sitter-fix the body indent. `word=true`
---     requires a leading word boundary so `append`/`send`/`bend` don't
---     fire `end`. Block openers AUTO-SPLIT into two hook entries (one
---     per trigger) sharing one fn.
---   * `IH.closer(pattern, {word?})` — on `return`, snap the line's indent
---     one unit LESS (structural opener level via the `@indent` query)
---     and create the new line at that dedented indent; declines when no
---     parse tree is available or the line is not over-indented.
--- Modes that need bespoke behaviour write `IH.hook(pattern, trigger, fn,
---   {word?})` directly. Hooks run their own `batch_edit`; the View's
--- `_run_input_hooks(trigger)` does the suffix-scan dispatch.

local keybind = require("cursed.keybind")

---@class MajorMode
---@field name string human-readable name (e.g. "lua", "python")
---@field keybindings table<string, string|function> chord → command name or function
---@field textobjects table<string, string> object name → boundary pattern
---@field tab_width integer visual width of a tab stop (default 8)
---@field expand_tab boolean if true, Tab key inserts spaces instead of \t (default false)
---@field indent_width integer number of columns for auto-indent (default = tab_width)
---@field margin integer|nil max text render width; overrides the global config margin when set (centers the gutter+text column when the window is wider)
---@field language string|nil bundled tree-sitter grammar name (enables highlighting)
---@field highlight_query string|nil override query source for the grammar
---@field injection_query string|nil injections query (walks the block tree for content regions to inject another grammar into — markdown: inline nodes, fenced code blocks, metadata blocks)
---@field extra_injected_grammars table<string,string>|nil grammar name → query source, for grammars the injection_query references that have no MajorMode of their own (e.g. markdown_inline, referenced by markdown's injection query)
---@field indent_queries string|nil predicate-free tree-sitter query source; `@indent`-captured nodes add one indent level on Return when the cursor is inside them
---@field input_hooks table|nil flat list of input-hook specs (build with cursed.input_hook); matched as a suffix of left-of-cursor text and dispatched by View:_run_input_hooks
---@field _trie table? lazily-built keybind trie for this mode's keybindings
local MajorMode = {}
MajorMode.__index = MajorMode

---@class MajorModeSpec
---@field name string
---@field keybindings? table<string, string|function>
---@field textobjects? table<string, string>
---@field tab_width? integer
---@field expand_tab? boolean
---@field indent_width? integer
---@field margin? integer
---@field language? string
---@field highlight_query? string
---@field injection_query? string
---@field extra_injected_grammars? table<string,string>
---@field indent_queries? string
---@field input_hooks? table

--- Create a major mode template from a config spec table.
--- Use :instantiate() to create per-view instances.
---@param spec MajorModeSpec
---@return MajorMode
function MajorMode.new(spec)
    local tw = spec.tab_width or 8
    return setmetatable({
        name = spec.name,
        keybindings = spec.keybindings or {},
        textobjects = spec.textobjects or {},
        tab_width = tw,
        expand_tab = spec.expand_tab or false,
        indent_width = spec.indent_width or tw,
        margin = spec.margin,
        language = spec.language,
        highlight_query = spec.highlight_query,
        injection_query = spec.injection_query,
        extra_injected_grammars = spec.extra_injected_grammars,
        indent_queries = spec.indent_queries,
        input_hooks = spec.input_hooks,
        _trie = nil,
    }, MajorMode)
end

--- Create a per-view instance of this mode (prototype delegation).
--- The instance delegates reads to the template; writes (e.g. setting
--- per-instance state from a `mode_enter` listener) go on the instance
--- itself.
---@return MajorModeInstance
function MajorMode:instantiate()
    ---@type MajorModeInstance
    return setmetatable({ _base = self }, { __index = self })
end

--- Get (or lazily build) the keybind trie for this mode's keybindings.
--- Only includes the mode-specific bindings (no defaults merged).
---@return table
function MajorMode:trie()
    if self._trie == nil then
        self._trie = keybind.Trie.build(self.keybindings)
    end
    return self._trie
end

--- An instance of a MajorMode bound to a specific view.
--- Created via MajorMode:instantiate(). Delegates reads to the
--- template mode via __index; writes go on the instance.
---@class MajorModeInstance
---@field _base MajorMode reference to the template mode
---@field name string (inherited)
---@field keybindings table<string, string|function> (inherited)
---@field textobjects table<string, string> (inherited)
---@field tab_width integer (inherited)
---@field expand_tab boolean (inherited)
---@field indent_width integer (inherited)
---@field margin integer|nil (inherited)
---@field language string|nil (inherited)
---@field highlight_query string|nil (inherited)
---@field injection_query string|nil (inherited)
---@field extra_injected_grammars table<string,string>|nil (inherited)
---@field indent_queries string|nil (inherited)
---@field input_hooks table|nil (inherited)

return MajorMode
