# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- The convention is clear: vendored as committed plain files in `vendor/tree-sitter-<lang>/src/` (markdown split into two dirs).
- whenever the user moves the cursor, we should keep track of the nearest diagnostic span (bias towards below) and, if the cursor is within that span, display the text of the diagnostic as a popup sort of like the...
- for the generic path, we should decode the json on the lane side, and pass back a pointer to a heap allocated, shared yyjson json object, which is not freed, but which it is the main thread's responsibility to free after...
- macOS users can use Ctrl+click as a Cmd+click substitute (or the user can configure their terminal).
- alright, now let's use mdview for the hover documentation popups from the LSP
- we should collapse all consecutive blank lines to just one
- if a tree sitter parse tree exists for the document, then we should create a simple, globally usable api for finding the smallest tree sitter node surrounding a given position, and ones for walking a tree sitter tree...
- go with alt-' for expand, and we'll use alt-" for collapse in the future.
- Since the AGENTS rule is "Run `just check`.
- , the convention is "end at col 0 of the next line" (half-open across lines).

## Gotchas & Errors

- Actually tmux `send-keys` can't synthesize SGR mouse events.
- For the Ctrl+click test, tmux can't easily synthesize SGR mouse events with Ctrl, but I can verify the logic is sound by checking the mouse handler code path once more and confirming the build is...
- Actually `tmux send-keys -M -t sess` reads a mouse event from the CURRENT terminal's mouse — that won't work non-interactively.
- Actually, the real LSP hover uses CRLF; since I can't easily get a hover to fire non-interactively, let me at least verify `measure` and `render` agree via a tiny in-editor eval with a CRLF markdown...
- That's redundant; if `desc` is the deepest descendant, its children can't both be strictly smaller AND contain the seed (a child containing the seed would BE a deeper descendant, contradicting `desc`...
- Command exited with code 1
- The current shrink collapses to a cursor when it can't descend the tree further, skipping back down through the textobject ladder.
- Let me build and smoke-test to make sure nothing crashes at load:

## Heavily Read

- src/cursed/view.lua (5 reads) — I have everything I need. `self.buffer:line_len(line)` returns the byte length o
- src/cursed/commands.lua (8 reads) — Now there's a subtlety in the widen path: after the ladder is exhausted (`st.ind
