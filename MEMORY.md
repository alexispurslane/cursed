# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- go with alt-' for expand, and we'll use alt-" for collapse in the future.
- Since the AGENTS rule is "Run `just check`.
- , the convention is "end at col 0 of the next line" (half-open across lines).
- Actually, the simplest robust fix: in the C cleanup, when the main return code indicates a headless exit, use `pthread_cancel` instead of `pthread_join` for the lanes.
- But the convention is `forward_<name>_select` (select is a suffix).
- This will, in the future, allow using tree-sitter based text objects as well.
- )` tree-sitter-query textobject builder (updated from the old "will, in the future, allow using tree-sitter based text objects" promise — now delivered), with the lazy query compilation, fresh-snapshot-per-call RAII...
- The command may use tree-sitter as a fallback rather than LSP.
- for instance, we should probably add ctrl-c s and ctrl-c k for starting and killing the lsp, and maybe ctrl-c ctrl-r for restarting it.
- alright, now, we should make LSP notifications and responses come back as events on the event bus, instead of having to have this whole separate "mint callback, store it, call it" thing.

## Gotchas & Errors

- code actions requires generalized gutter system, save for later, but blocked on that.
- The only lint failure is the pre-existing `_diag_hover_visible` warning, which per project memory is unrelated and pre-existing.
- ts`, which resolves tree-sitter C symbols at load time — those only exist linked into the real `cursed` binary, so headless `luajit` can't load it.
- )` — `(stream, bytes)` where stream is `"stdout"`/`"stderr"`, or `(kind, code)` where kind is `"exited"`/`"signaled"`/`"failed"`/`"kill_sent"`.
- Command aborted
- === Pane ===
- usage: cursed [-e EXPR | -l MODULE]... [FILE...]
- The listener surfaces the spawn settle as a status message: `"language server ready (X)"` / `"not on PATH (X)"` / `"failed to start (X)"` / `"stopped (X)"`.

## Heavily Read

- src/cursed/lsp_client.lua (18 reads) — Now I'll implement. Starting with `lsp_client.lua`:
- src/cursed/commands.lua (16 reads) — Let me look at the symbol-finder command pattern using `palette` (lines 1783, 18
- src/cursed/editor.lua (5 reads) — Now the `Editor:apply_workspace_edit`. Let me find a good insertion point and ex
- src/cursed/completers.lua (12 reads) — `filter_symbols` is a local defined lexically after my new `static_list`, so it'
- src/cursed/default_keybindings.lua (3 reads) — Let me look at the symbol-finder command pattern using `palette` (lines 1783, 18
- src/main.lua (4 reads) — Checking definitively:
- src/cursed/editor_listeners.lua (8 reads) — Let me look at how LSP is currently spawned by mode_enter, so I can wire start/k
- src/cursed/lsp_lane.lua (5 reads) — Let me also clean up the stale doc references in `lsp_lane.lua` / `shared_ffi.lu
