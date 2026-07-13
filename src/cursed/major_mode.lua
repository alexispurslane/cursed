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
---@field expand_tab boolean if true, Tab key inserts spaces instead of \t (default true)
---@field indent_width integer number of columns for auto-indent (default = tab_width)
---@field margin integer|nil max text render width; overrides the global config margin when set (centers the gutter+text column when the window is wider)
---@field language string|nil bundled tree-sitter grammar name (enables highlighting)
---@field highlight_query string|nil override query source for the grammar
---@field injection_query string|nil injections query (walks the block tree for content regions to inject another grammar into — markdown: inline nodes, fenced code blocks, metadata blocks)
---@field extra_injected_grammars table<string,string>|nil grammar name → query source, for grammars the injection_query references that have no MajorMode of their own (e.g. markdown_inline, referenced by markdown's injection query)
---@field indent_queries string|nil predicate-free tree-sitter query source; `@indent`-captured nodes add one indent level on Return when the cursor is inside them
---@field symbol_queries string|nil predicate-free tree-sitter query source; `@symbol`-captured nodes feed the tree-sitter document outline (the goto_symbol fallback when no LSP is bound to the buffer)
---@field input_hooks table|nil flat list of input-hook specs (build with cursed.input_hook); matched as a suffix of left-of-cursor text and dispatched by View:_run_input_hooks
---@field lsp_servers (string|table)[]|nil first-wins list of EITHER bare executable-name strings OR candidate tables `{ bin = "name", args = {"--stdio"}, env = { VAR = "value" } }`, spawned as a language server subprocess when a view activates this mode (managed centrally by the editor)
---@field spellcheck_captures "all"|true|false|string[]|nil scope for spellchecking: "all"/true = whole text; false = skip; nil = "all" for prose modes / `{comment,string,...}` for code modes; a list = TS capture names to check
---@field completer function|nil factory `fun(editor): fun(ctx): table` producing this mode's in-buffer completion source (e.g. `completers.lsp`). The editor's `mode_dispatch` resolver instantiates it lazily + caches it; falls back to `buffer_words` when nil.
---@field printable fun(view, editor, ch): boolean?|nil per-mode printable-char handler; nil → fall back to the global `__printable`. Return truthy to feed the trie (command-letter/vim-style apps); return false/nil when handled (filter/insert apps). Enables non-file-backed "TUI app" buffers whose list items are buffer lines and whose selected row is the cursor's line.
---@field multi_currency boolean when false, multi-cursor commands (select_next_match, add_cursor, select_all_matches, drop_cursor) and mouse Alt-click no-op in views running this mode. Default true. App/list buffers set false.
---@field on_enter fun(view, editor, instance)|nil convenience that auto-wires a `mode_enter:<name>` listener (idempotently, per editor) calling `on_enter(view, editor, instance)`. Lets a mode seed its own buffer with lines / attach per-view state. Equivalent to registering the listener by hand in the spec file (the existing pattern) — sugar only.
---@field on_exit fun(view, editor, instance)|nil convenience that auto-wires a `mode_exit:<name>` listener calling `on_exit(view, editor, instance)`.
---@field no_gutter boolean|nil drop the whole gutter (line numbers + sign columns + separators) for views in this mode. Display toggle only — the buffer text is still the substrate.
---@field no_line_numbers boolean|nil keep the gutter frame but blank the line numbers. `no_gutter` implies this.
---@field wrap boolean|nil default true; when false, wrap at window width only (skip margin narrowing). Display toggle only.
---@field whole_line_cursor boolean|nil the cursor paints the entire sub-row width in `cursor_bg` instead of a single cell — the "selected row" highlight for list apps. Display toggle only.
---@field _trie table? lazily-built keybind trie for this mode's keybindings
---@field _listener_editors table|nil set of editors this template has already registered on_enter/on_exit listeners against (idempotent per-editor auto-wiring)
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
---@field symbol_queries? string
---@field input_hooks? table
---@field lsp_servers? (string|table)[] first-wins list of LSP executables (strings or `{bin,args,env}` tables) to try when this mode activates
---@field spellcheck_captures? "all"|true|false|string[] scope for spellchecking (nil → mode-aware default)
---@field completer? function factory `fun(editor): fun(ctx): table` for this mode's in-buffer completion source (resolved at runtime by the editor's `mode_dispatch`)
---@field printable? fun(view, editor, ch): boolean? per-mode printable-char handler (nil → global `__printable`)
---@field multi_currency? boolean false → multi-currency commands no-op in this mode (default true)
---@field on_enter? fun(view, editor, instance) auto-wired mode_enter:<name> listener
---@field on_exit? fun(view, editor, instance) auto-wired mode_exit:<name> listener
---@field no_gutter? boolean drop the whole gutter
---@field no_line_numbers? boolean keep gutter frame, blank line numbers
---@field wrap? boolean default true; false → skip margin narrowing (wrap at window width only)
---@field whole_line_cursor? boolean cursor paints the whole row in cursor_bg

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
		expand_tab = spec.expand_tab ~= false, -- true by default
		indent_width = spec.indent_width or tw,
		margin = spec.margin,
		language = spec.language,
		highlight_query = spec.highlight_query,
		injection_query = spec.injection_query,
		extra_injected_grammars = spec.extra_injected_grammars,
		indent_queries = spec.indent_queries,
		symbol_queries = spec.symbol_queries,
		input_hooks = spec.input_hooks,
		lsp_servers = spec.lsp_servers,
		spellcheck_captures = spec.spellcheck_captures,
		completer = spec.completer,
		printable = spec.printable,
		multi_currency = spec.multi_currency, -- nil defaults to "enabled" via view:multi_currency_enabled()
		on_enter = spec.on_enter,
		on_exit = spec.on_exit,
		no_gutter = spec.no_gutter,
		no_line_numbers = spec.no_line_numbers,
		wrap = spec.wrap ~= false, -- default true
		whole_line_cursor = spec.whole_line_cursor,
		_trie = nil,
		_listener_editors = nil,
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

--- Idempotently register `on_enter` / `on_exit` as `mode_enter:<name>` /
--- `mode_exit:<name>` listeners on `editor.event_system`, once per editor.
--- Called from `View:_emit_mode_event` BEFORE the emit so the listener
--- is in place to catch the very first activation. No-op when the
--- template declares neither hook.
---@param editor Editor owning editor (must have an event_system)
function MajorMode:_ensure_listeners(editor)
	if self.on_enter == nil and self.on_exit == nil then
		return
	end
	if self._listener_editers == nil then
		self._listener_editers = {}
	end
	if self._listener_editers[editor] then
		return
	end
	self._listener_editers[editor] = true
	local es = editor.event_system
	if es == nil then
		return
	end
	local name = self.name
	if self.on_enter then
		es:on("mode_enter:" .. name, function(ed, inst, view)
			inst.on_enter(view, ed, inst)
		end)
	end
	if self.on_exit then
		es:on("mode_exit:" .. name, function(ed, inst, view)
			inst.on_exit(view, ed, inst)
		end)
	end
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
---@field symbol_queries string|nil (inherited)
---@field input_hooks table|nil (inherited)
---@field lsp_servers (string|table)[]|nil (inherited from template)
---@field completer function|nil (inherited from template)
---@field printable fun(view, editor, ch): boolean?|nil (inherited)
---@field multi_currency boolean|nil (inherited)
---@field on_enter fun(view, editor, instance)|nil (inherited)
---@field on_exit fun(view, editor, instance)|nil (inherited)
---@field no_gutter boolean|nil (inherited)
---@field no_line_numbers boolean|nil (inherited)
---@field wrap boolean|nil (inherited)
---@field whole_line_cursor boolean|nil (inherited)

return MajorMode
