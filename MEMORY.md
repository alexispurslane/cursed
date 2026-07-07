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

- lua:55: kqueue: add_fd(15) on kq=0 failed (rc=-1 errno=9)
- lua:276: table index is nil
- /bin/bash: line 26: luajit: command not found
- Command aborted
- Good idea in principle — but I can't actually launch subagents from here.
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/modes/lua.lua. The old text must match exactly including all whitespace and newlines.
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/modes/rust.lua. The old text must match exactly including all whitespace and newlines.
- (no output)

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/lsp_client.lua (4 reads) — Now update the stale comment in `lsp_client.lua` that references the old `{}`:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/lsp_lane.lua (7 reads) — let's mark M38 as not going to do; let's remove send_missing, and just call send
- /Users/alexispurslane/Development/scratch/cursed/docs/code-review.md (14 reads) — look at H10 and *pitch* me how you'd factor commands.lua out without significant
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/shared_ffi.lua (3 reads) — I think you caused an issue from one of the earlier edits this jj revision:
- /Users/alexispurslane/Development/scratch/cursed/src/shared_state.h (5 reads) — Good — I can see the exact C layout. Let me fix both at once. First, add the C h
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/proc_lane.lua (6 reads) — Let me trace through the actual control flow carefully.
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/commands.lua (17 reads) — The deletion accidentally ate `scroll_up` and `beginning_of_buffer`. Let me fix:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/default_textobjects.lua (4 reads) — Let me do this in order. First, the textobject definitions:
