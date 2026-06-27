# Cursed — Future Work Report

A synthesis of the architectural scout findings and the user's plans/evaluations. Grouped by the original score-sheet dimensions. Each section: the dimension's verdict, then the concrete future work with status and rationale.

---

## 1. Buffer & Text Model

The piece-table-with-mmap'd-orig design is Emacs-grade; multi-cursor + undo-in-selection are ahead of Emacs. The remaining work is around two real frictions: zero-alloc line text access and UTF-8 correctness.

- **Zero-alloc line text** [#1 from user list]. `line_text()` currently allocates a full Lua string per line per render — pathological for huge lines. Goal: get a line of text out of the piece table without allocating.
- **UTF-8 cursor + rendering** [#2] ✅ **DONE.** Cursor motion, wrap math, and rendering now use grapheme-aware display width instead of raw byte offsets; CJK, combining marks, and ZWJ sequences now render and position correctly.
- **Allocless cross-thread buffer sharing** [#24]. The architectural root beneath #1: the highlight lane currently gets a full-text snapshot via `write_text_direct` (O(doc) memcpy per keystroke). Want Buffer/View/Editor in Lua for ergonomics, but Lua values don't cross `lua_State` boundaries. Proposed direction: a buffer arena in C/FFI-shared memory, RWLock'd, pointed-to from Lua wrappers. **This is the one genuinely-open architectural question** — deferred for a dedicated design session.
- **Page-up/down piece-table compaction** [#3]. Piggyback piece coalescing onto page navigation, doing the compaction work where the user already expects a perceptible transition. Addresses the "no compaction pass" gap in the snapshot-undo design.
- **Cursor-disappears-on-wrapped-rows bug** [#0] ✅ **DONE.** Fixed — the caret cell is now painted on wrapped non-first sub-rows (the original guard `csub_col < chunk_start` failed on any wrapped row).

*Rejected as architectural concerns:* mark rings, registers, narrowing, rectangles — all are additive on the clean View/Buffer API, not structural. Multiple-cursors (already implemented, ahead of Emacs) absorbs the rectangle case.

---

## 2. Rendering & Display

Single-window full repaint is pragmatic and correct for ≤80×200; the work is about reducing per-row cost and per-frame waste.

- **Damage tracking: rerender from first cursor down** [#4]. Partial-damage scheme — simpler than a glyph matrix, better than full repaint. Comes *after* UTF-8 and zero-alloc line text, since both change the per-row cost basis being optimized.
- **UTF-8 in wrap math** (part of #2) ✅ **DONE.** Display-width grapheme handling is now threaded through wrap_rows, wrap offsets, and mouse/cursor coordinate conversion; CJK/tabs/combining marks render and click correctly.

*Window splitting* — **intentional non-feature** [#21]: terminal emulator (Ghostty) handles windowing. This is a defensible architectural philosophy, not a deficiency. Remains unmatched vs Emacs in raw capability but is a *choice*.

---

## 3. Input & Keybindings

The trie + chord parser + universal-arg trio is correct Emacs-inspired architecture. The user rejected my "keymaps need to be first-class mutable objects" framing — a keymap is already just a Lua table; the trie-rebuild-from-table path supports everything needed.

- **Convenience functions for `global-set-key` and adding keys to major modes** [#5] ✅ **DONE.** Emacs-style ergonomic wrappers on the `Editor` object, operating over the existing trie-rebuild path (a keymap is already just a Lua table; no `Keymap` class with parent pointers). `editor:global_set_key(chord, action)` binds globally (Emacs `global-set-key`); `editor:define_key(mode, chord, action)` binds in a major mode (Emacs `define-key`) where `mode` is a `MajorMode` object (e.g. `modes.lua`) or a name string resolved against `config.modes`; `editor:define_command(name, fn)` registers a named command (Emacs `defun`-equivalent for the command table) so it's invocable via M-x (spaces→underscores, case-insensitive, mirroring `commands.lookup`) and bindable by string. All three are LIVE: they mutate the base/mode keybinding tables and rebuild the base + active tries immediately (chords validated eagerly so a typo surfaces now, not on first press; `define_key` invalidates the mode's cached `_trie`). The main-loop chord-state reset (`_trie_changed`) already fires on `rebuild_active_trie`, so a live rebind mid-chord is safe. To make these work from init.lua as well as M-:/extensions/listeners, `main.lua` now primes the default keybindings on the editor BEFORE `Config.load()` runs, then applies init.lua's returned `keybindings` table through `global_set_key` — so an imperative `editor:global_set_key(...)` in init.lua is applied for real instead of clobbered by a later trie build. Demotes the "keymaps aren't first-class" concern to a satisfied TODO: the trie-rebuild-from-table path supports everything the `MajorMode:trie()` cache + these helpers need; the bare-name `editor` (init.lua + M-:) and `modes` (init.lua) exposure means no env changes were required.
- **`last-command` / `command-before-this` variable + re-run** [#7] ✅ **DONE.** A `post_command_hook` listener (in `cursed.editor_listeners`) maintains `editor._last_command` / `editor._command_before_this` and records the most recent command-with-universal-args as `editor._last_complex_command`. `repeat` (C-x z) reruns the last command; `repeat-complex-command` reruns the last complex command with its args. Both dispatch via the commands table with args restored (mirrors kmacro replay). The repeat commands themselves are skipped from history so chained `C-x z` repeats the original command.
- **Central event system → pre/post-command hooks** [#6] ✅ **DONE.** Implemented as a traditional hook-list model: `EventSystem` maps `{ event_name = [fns] }`, `emit(name, ...)` calls each `fn(editor, ...)` in registration order with per-handler error isolation. Stored on `editor.event_system` so callbacks can re-enter the hub. Producers wired: `pre_command_hook` / `post_command_hook` (in `process_key`), `ring_buffer_message` (in both IO and HL inbox drains), `mode_enter` / `mode_exit` (replacing the bespoke `on_enter`/`on_exit` call sites in `View`). Default logging consumers registered on the command-hook and ring-buffer events in `cursed.editor_listeners`. The `on_enter`/`on_exit` spec fields are fully retired — see #13.
- **Universal agnostic advice** (does not need the function's permission) [#18] ✅ **DONE.** Implemented in `cursed.advice` as a callable-table wrapper installed into a module slot, behind a **generic fold model with strict-Emacs composition**. `Advice.__call` is a trivial fold that knows NOTHING about which combinators exist: `local composed = self._original; for i=1,#_runners do composed = _runners[i].step(composed) end; return composed(...)`. Each advice is ONE fold-step stored in `_runners` in add-order; folding forward makes the **last-added advice outermost**, matching Emacs `advice-add` exactly (later advice wraps everything before it). There is no grouping by combinator-type and no fixed phase order — just one list of self-describing steps. A combinator (`before`/`around`/`filter_args`/`filter_return`) is a step-CONSTRUCTOR `(fn) -> (next) -> composed_fn` that encapsulates ALL of that combinator's semantics; `Advice.add(module, name, combinator, fn)` calls `combinator(fn)` to build the step and appends it. `add`/`__call` are combinator-agnostic, so a NEW combinator is just a new `Advice.<how>(fn) -> step` function with zero change to either — verified with a `console_log` custom combinator in the tests. Because `require` returns a shared singleton, the wrapping is visible to every caller in the process — genuine transparent stackable advice, not just for commands. Five combinators match Emacs semantics: before/after returns discarded (pcall'd, never break the call); around receives `(next, ...args)` and short-circuits by not calling `next`; filter-args transforms the arg list the next-inner sees; filter-return is multi-value fan-out (better than Emacs's single-value threading — each filter receives ALL returns as varargs, returns whatever becomes the tuple for the next-outer). `Advice.remove(module, name, fn)` drops ALL advices using `fn` (Emacs `advice-remove`-style — identity by `fn`, no combinator needed) and auto-restores the slot to the original function when empty. The cost — `type(advised) == "table"` — is handled by `Advice.callable()` / `Advice.is_advised()`; the four `type()=="function"` command-dispatch sites in `commands.lua` are patched to use `callable()`. Combined with #20, init.lua can now `Advice.add(require("cursed.commands"), "forward_char", Advice.around, ...)` directly.

*Still open (not yet addressed by user plans):* recursive-edit (main loop can't nest), input methods, minor-mode-map layering as a distinct stack. The first two are larger architectural changes; minor-mode layering collapses into "convenience for adding keys to modes" + the event system once those land.

---

## 4. Syntax Highlighting & Tree-Sitter

Architecturally ahead of Emacs (async lane + bucketing + incremental parse). Work is about closing specific constraining edges.

- **Parser timeout on the highlighter lane** [#8]. BLOCKED on a tree-sitter library upgrade: `ts_parser_set_timeout_micros` does NOT exist in the vendored API version (`TREE_SITTER_LANGUAGE_VERSION` 15; confirmed absent in `vendor/tree-sitter-lib/lib/include/tree_sitter/api.h`). The symbol was added in a later tree-sitter release. Still a desired safety net (pathological input stalling the lane; degrade to "this bucket is sparse right now"), but not a small `cdef` anymore — it's gated on bumping the vendored tree-sitter, which is its own scoped task.
- **Overlay abstraction in screen-coordinate space** [#9]. Overlays above highlighting, in screen space not buffer space — sidesteps priority-resolution-vs-tree-sitter tangle. Unblocks flymake/flyspell/prettify-symbols.
- **Shared parse tree between HL lane and main, mutex-guarded** [#11]. Closes the "no parse tree on the main thread" gap — the single biggest TS constraint in the scout report. Key invariant: never modify from main, only read for tree-sitter-based *user* inputs; mutex is cheap because only the lane writes (briefly, while reparsing). This is the clean resolution of the "second tree on main OR sync ring query" dilemma.
- **Tree-sitter-driven textobjects, with pattern fallbacks** [#14]. Pass the current TS parser as a default arg to textobject functions; patterns/sexps ignore it, structural textobjects use it. Clean migration path, no breaking change.
- **Shared buffer arena between threads** — see §1 #24; the architectural root cause of the per-keystroke memcpy.

*Rejected as concerns:* idle refill [#10 — confirmed dead, "not an issue in practice"; aligns with MEMORY "make sure we hl enough on scroll"]. Range-limited parse — design-doc non-goal (boundary corruption); keep as-is. No parse tree on main thread — being closed by #11.

---

## 5. Major Modes & Language Surface

Declarative `MajorModeSpec` is a good base; work is about replacing the bespoke single-callback hookpoint and adding language coverage.

- **Remove `on_enter`/`on_exit` once event system exists** [#13] ✅ **DONE.** The `on_enter`/`on_exit` *fields* are retired from `MajorModeSpec`/`MajorMode`/`MajorModeInstance`; the legacy bridge listener in `main.lua` is gone (centralized logging listeners moved to `cursed.editor_listeners`). The built-in `lua`/`rust` modes dropped their empty stubs. Mode lifecycle is now purely event-driven: `View` emits `mode_enter` / `mode_exit`, and consumers register `editor.event_system:on("mode_enter", ...)` listeners (e.g. from `init.lua`, now that #20 landed). **Per-mode events:** View additionally emits a mode-specific variant — `mode_enter:<name>` / `mode_exit:<name>` (e.g. `mode_enter:lua`) — alongside the generic events, so per-mode handlers register for their own event directly instead of if/else dispatching on the instance name. Plus built-in mode spec files are now unsandboxed (the `require("cursed.modes")` in `cursed.config` is deferred to `Config.load()`, after `_G.editor` exists), so a built-in spec file's top level can register its own `mode_enter:<name>` / `mode_exit:<name>` listeners before returning its `MajorModeSpec` — the same contract `init.lua` and user mode files already had via #20.
- **Markdown grammar/mode** [#12] ✅ **DONE.** Vendored `tree-sitter-grammars/tree-sitter-markdown` (split_parser branch) — flattened into `vendor/tree-sitter-markdown_block/` + `vendor/tree-sitter-markdown-inline/` to match the justfile's `tree-sitter-$lang/src/` convention. Both grammars compile against the vendored tree-sitter v15. Implements the **split-parser design**: the block grammar parses document structure (headings, code blocks, lists, blockquotes) and marks inline content as `inline` nodes; the highlighter pipeline walks those byte ranges, calls `ts_parser_set_included_ranges` on a separate inline parser, parses the inline grammar over exactly those spans, and merges both query capture streams (inline captures stack on top of block captures so bold/italic/code spans layer over heading/list structure). Composite-language support added across the stack: `MajorModeSpec.inline_language` + `inline_highlight_query`; `HlInitLangReq` extended with `inline_language[16]` + `inline_query_len`; `cursed.highlight_lane`'s `per_lang` state owns an optional secondary parser/query and runs the two-pass parse; `cursed.ts` gained `collect_named_ranges` (depth-first tree walk) + `Parser:set_included_ranges` + tree-cursor walker exports. The `text.*` capture vocabulary (title/literal/emphasis/strong/uri/reference) added to `cursed.colorscheme` with slots + styles. `highlighter.lua` (the unused main-thread sync path) was NOT updated — it's a library not wired into the view; the lane is the production path. Queries adapted predicate-free from upstream `highlights.scm`.
- **Queries for C/Python/Go** (from scout report) ✅ **DONE.** `src/cursed/modes/{c,python,go}.lua` each carry a full predicate-free `highlight_query` (same structure as the existing Lua/Rust queries — bare `(identifier) @variable` fallback declared first, role-specific captures overriding).
- **Mode registry for bash/json/toml/yaml** (scout) ✅ **DONE.** `src/cursed/modes/{bash,json,toml,yaml}.lua` each carry a `highlight_query` and are registered in `src/cursed/modes.lua`'s `SPECS` list. Verified empirically: every grammar+query pair (C/Python/Go/Bash/JSON/TOML/YAML/Lua/Rust) compiles cleanly through `ts_query_new` (no bad node/field/capture names that would silently disable highlighting), and the colorscheme's `CAPTURE_CONCEPT` table + dotted-suffix fallback resolves every capture name these queries emit (`@namespace`, `@function.macro`, `@type.builtin`, `@constant.builtin`, …). The report's prior "only Lua and Rust actually highlight" was stale — predating these mode files. Remaining non-gaps: Makefile (intentionally no grammar) and Zig (`src/cursed/modes/zig.lua` notes no bundled tree-sitter-zig grammar yet — vendoring one would be a separate self-contained task).
- **Predicate evaluation in TS queries** (scout). Currently predicate-free; limits nuanced highlighting vs nvim-treesitter. Not flagged by user — deferred.
- **Syntax-aware indent / imenu / xref** — blocked on #11 (shared parse tree on main). Once #11 lands, these become additive.

---

## 6. Concurrency / Async Architecture

Architecturally ahead of Emacs for editor-internal work (true OS parallelism, dedicated lanes, lock-free ring + EVFILT_USER wake). Work is about filling out the async subsystem surface Emacs already has.

- **Central event system first** [#6 ✅ DONE, #23]. The event hub landed (#6): `pre_command_hook` / `post_command_hook` / `ring_buffer_message` / `mode_enter` / `mode_exit` all flow through `editor.event_system`. Everything downstream now depends on it: subprocess management becomes tractable once extensions and main-thread code can announce and observe events uniformly.
- **Subprocess management thread** [#23]. LSP, grep, language tooling all need this. Currently zero subprocess infra (IO lane does its own open/mmap/write, no spawn). Plan: a lane for spawning and managing external processes; easier to build once the event system exists.
- **Timers via `_background_tasks`** [#15]. Turns the ad-hoc deadline machinery (blink, chord, watchdog bolted on separately) into something schedulable. Retires the "no `run-with-timer`" gap without new infrastructure.
- **Subprocess-backed features: occur mode + writable project-wide grep** [#22]. Deferred until subprocess infra exists.

*Intentional non-feature: dynamic grammar loading* [#16]. Grammars statically linked by default — explicitly to avoid the "emacs grammar ABI break on update" pain. Open to distributing precompiled parsers as part of installation and dynamically loading those later; letting users load their own is "their circus" but would at least drive the infra into place. **Deferred, pragmatic.**

*Acknowledged risks (not yet addressed):* native crash in a lane = whole process dies (no subprocess fault isolation); `ring_push`'s false-on-full return goes unchecked by callers; macOS-only kqueue (no eventfd/epoll). No timeline on these.

---

## 7. Extensibility / Programmability

The user corrected my harsh ★★ judgment: bytecode-preloaded modules still run in a dynamic interpreter; anything they define can be overridden from `M-:` / `init.lua` — they're mutable tables, not frozen C binaries. The "behaves like a compiled binary" framing was wrong; the practical extensibility surface is the mutable runtime.

- **Unsandbox mode/init/M-: code** [#20] ✅ **DONE.** `init.lua` and M-: now run with a passthrough env whose reads fall through to `_G` and writes propagate to `_G` — not a sandbox. They can reach the global `editor` (exposed on `_G` by `main.lua`), `require` any module, push background tasks, and register `editor.event_system` listeners. `MajorMode`/`modes` (init.lua) and `editor`/`view`/command shims (M-:) remain as convenience bare names. This is the Emacs-philosophy move (`~/.emacs` is just Lisp against `_G`). Originally only *user* mode files (`~/.config/cursed/modes/*.lua`, loaded via `loadfile`) ran against `_G`; built-in mode specs in `src/cursed/modes/*.lua` were sandboxed because `require("cursed.modes")` ran at `cursed.config` module-load time, before `_G.editor` was set. That is now fixed — the require is deferred to `Config.load()` (see #13) so built-in spec files run their top level after the editor exists too, and can register per-mode event handlers directly.
- **Central event system + universal advice** [#6 ✅ DONE, #18 ✅ DONE]. The composability primitives that make N packages coexist. Both landed: the event hub (#6) and slot-replacement advice (#18). With both, Emacs-style extension ecosystems are feasible — events broadcast lifecycle, advice composes per-function.
- **`last-command` history + rerun** [#7] ✅ DONE — see §3/#7.
- **`on_enter`/`on_exit` cleanup** [#13] ✅ DONE — see §5/#13.
- **Unsandbox init/M-:** [#20] ✅ DONE — see §7/#20. Init.lua can now register `editor.event_system` listeners directly against the global editor.
~ **Fulfill the `textobjects.lua` user-override docs** ✅ **RESOLVED (non-issue).** Major modes now carry their own `textobjects` field (`MajorModeSpec.textobjects`: object name → boundary pattern, via `TO.pattern` / `TO.sexp`), and the active major mode's entries drive `move_word` / `select_range` / the sexp commands. Per-language textobjects are therefore defined alongside the mode they belong to (e.g. the Lua block-keyword sexps, the word-boundary pattern) and overridden the same way any other mode field is — by dropping a user mode file in `~/.config/cursed/modes/<name>.lua` or extending a built-in spec (see #20). There's no need for a separate `~/.config/cursed/textobjects.lua` loader; the stale doc comment in `default_textobjects.lua` is just leftover wording to clean up.

*Rejected as concerns:* "AOT preloaded core is a wall" [#17 — not a real issue; no one replaces core Elisp either, they override]. "Package manager / `package.path` setup" — not in scope currently; user has not flagged it. "Dynamic grammar loading" — see §6 #16.

---

## Cross-cutting / out of dimension

- **#24 allocless cross-thread buffer sharing** (Buffer / Async) — the genuinely-open architectural question; touches every dimension that ever copies buffer text.

---

### Three highest-leverage architectural investments (refined)

These are the items that, once landed, unblock the largest cluster of downstream work:

1. **Central event system [#6]** ✅ **DONE** → unlocks pre/post-command hooks, mode activation/deactivation events, `on_enter`/`on_exit` removal [#13 ✅ DONE], `last-command` history + rerun [#7 ✅ DONE], subprocess thread [#23], ring-buffer-tap-for-extensions, and the substrate on which universal advice [#18 ✅ DONE] composes. The hub, command-hook/`ring_buffer_message`/mode-event producers, and default logging consumers are all in place, centralized in `cursed.editor_listeners`. Unsandboxing [#20 ✅ DONE] lets `init.lua` register listeners and `Advice.add` against the global `editor` / module tables directly.
2. **Shared parse tree between HL lane and main, mutex-guarded [#11]** → unblocks syntax-aware indent, imenu/xref/goto-def, tree-sitter textobjects [#14], and any future structural-editing features.
3. **Allocless cross-thread buffer sharing [#24]** → retires the per-keystroke O(doc) memcpy root cause, indirectly fixes #1 (zero-alloc line text), and aligns the Lua-side Buffer with the cross-lane performance budget the mmap'd-orig already gives you at load time.

Everything else on the list is additive, deferred-but-scoped, or an intentional non-feature.
