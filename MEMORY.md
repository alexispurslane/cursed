# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now
- I want to do fuzzy file finding within a directory for this editor project, but I don't want it to depend on an external program like fzf.

## Key Decisions

- Could mitigate by keeping the array for O(1) prefix access and only using BIT for update paths, rebuilding the array from BIT when convenient.
- when the user is in the minibuffer crafting a search, we should only find the first instance, jumping there so they can see it; only when they hit enter should the search be turned into candidate cursors at every match.
- add_cursor_candidate doesn't seem to only activate the candidates within the region --- it seems to always do all of them
- In `ring_pop`, the original code was:
- Let me use Python for this C refactor.
- we should open the buffers that aren't open, at least temporarily, to do those edits.
- lsp_rename` right after the `find_word_*` helpers so it can use `find_word_at` as an upvalue.
- lsp_version then
- Merge into a single function that optionally handles the NULL-exe_name case.
- we have a fair amount of LSP capabilities at this point, we should probably advertise all of them

## Gotchas & Errors

- /bin/bash: line 26: luajit: command not found
- Command aborted
- Good idea in principle — but I can't actually launch subagents from here.
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/modes/lua.lua. The old text must match exactly including all whitespace and newlines.
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/modes/rust.lua. The old text must match exactly including all whitespace and newlines.
- (no output)
- Validation failed for tool "edit": — Fix: Let me fix this in two separate calls — first fix `_paint_run`, then fix its call site:
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua. The old text must match exactly including all whitespace and newlines.

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor_listeners.lua (5 reads) — Let me start by reading the file to understand the current structure.
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (23 reads) — Let me trace how each consumer activates/deactivates to find the right push/remo
- /Users/alexispurslane/Development/scratch/cursed/src/main.lua (5 reads) — It's in `main.lua`, not `editor.lua`. Let me read it:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/keybind.lua (3 reads) — The `Trie.build()` and `Trie:lookup()` already exist and work. What's missing is
