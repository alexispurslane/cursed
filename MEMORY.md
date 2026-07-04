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

- cursed: -l /tmp/test_xeno failed: module '/tmp/test_xeno' not found:
- error: unexpected closing delimiter `)` — Fix: This is the right fix.
- Let me clean up — I appended a broken probe.
- Let me confirm it was already failing before my change:
- The pre-existing `_diag_hover_visible` lint warning is unrelated and was already failing before this change.
- (no output)
- code actions requires generalized gutter system, save for later, but blocked on that.
- The only lint failure is the pre-existing `_diag_hover_visible` warning, which per project memory is unrelated and pre-existing.

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (6 reads) — The only lint failure is the pre-existing `_diag_hover_visible` warning, which p
