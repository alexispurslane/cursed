# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- we should collapse all consecutive blank lines to just one
- if a tree sitter parse tree exists for the document, then we should create a simple, globally usable api for finding the smallest tree sitter node surrounding a given position, and ones for walking a tree sitter tree...
- go with alt-' for expand, and we'll use alt-" for collapse in the future.
- Since the AGENTS rule is "Run `just check`.
- , the convention is "end at col 0 of the next line" (half-open across lines).
- Actually, the simplest robust fix: in the C cleanup, when the main return code indicates a headless exit, use `pthread_cancel` instead of `pthread_join` for the lanes.
- But the convention is `forward_<name>_select` (select is a suffix).
- This will, in the future, allow using tree-sitter based text objects as well.
- )` tree-sitter-query textobject builder (updated from the old "will, in the future, allow using tree-sitter based text objects" promise — now delivered), with the lazy query compilation, fresh-snapshot-per-call RAII...
- The command may use tree-sitter as a fallback rather than LSP.

## Gotchas & Errors

- (no output)
- code actions requires generalized gutter system, save for later, but blocked on that.
- The only lint failure is the pre-existing `_diag_hover_visible` warning, which per project memory is unrelated and pre-existing.
- ts`, which resolves tree-sitter C symbols at load time — those only exist linked into the real `cursed` binary, so headless `luajit` can't load it.
- )` — `(stream, bytes)` where stream is `"stdout"`/`"stderr"`, or `(kind, code)` where kind is `"exited"`/`"signaled"`/`"failed"`/`"kill_sent"`.
- Command aborted
- === Pane ===
- usage: cursed [-e EXPR | -l MODULE]... [FILE...]

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/examples/picker.lua (4 reads) — Now let me verify the file looks correct and run `just check`:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/view.lua (4 reads) — the first time I type something in the input area, a new line is added between t
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/buffer.lua (3 reads) — now, let's see if we can play with the text nature of the buffer more: how about
