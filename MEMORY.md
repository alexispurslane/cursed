# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- alright, now let's use mdview for the hover documentation popups from the LSP
- we should collapse all consecutive blank lines to just one
- if a tree sitter parse tree exists for the document, then we should create a simple, globally usable api for finding the smallest tree sitter node surrounding a given position, and ones for walking a tree sitter tree...
- go with alt-' for expand, and we'll use alt-" for collapse in the future.
- Since the AGENTS rule is "Run `just check`.
- , the convention is "end at col 0 of the next line" (half-open across lines).
- Actually, the simplest robust fix: in the C cleanup, when the main return code indicates a headless exit, use `pthread_cancel` instead of `pthread_join` for the lanes.
- But the convention is `forward_<name>_select` (select is a suffix).
- This will, in the future, allow using tree-sitter based text objects as well.
- )` tree-sitter-query textobject builder (updated from the old "will, in the future, allow using tree-sitter based text objects" promise — now delivered), with the lazy query compilation, fresh-snapshot-per-call RAII...

## Gotchas & Errors

- Actually, the real LSP hover uses CRLF; since I can't easily get a hover to fire non-interactively, let me at least verify `measure` and `render` agree via a tiny in-editor eval with a CRLF markdown...
- That's redundant; if `desc` is the deepest descendant, its children can't both be strictly smaller AND contain the seed (a child containing the seed would BE a deeper descendant, contradicting `desc`...
- Command exited with code 1
- The current shrink collapses to a cursor when it can't descend the tree further, skipping back down through the textobject ladder.
- Let me build and smoke-test to make sure nothing crashes at load:
- lua: (command line):2: module 'cursed.colorscheme' not found:
- /bin/bash: -c: line 4: syntax error near unexpected token `('
- cursed: -l /tmp/test_xeno failed: module '/tmp/test_xeno' not found:
