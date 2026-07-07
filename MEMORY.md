# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now
- I want to do fuzzy file finding within a directory for this editor project, but I don't want it to depend on an external program like fzf.

## Key Decisions

- we should also have an input_hook that completes tags
- Could mitigate by keeping the array for O(1) prefix access and only using BIT for update paths, rebuilding the array from BIT when convenient.
- when the user is in the minibuffer crafting a search, we should only find the first instance, jumping there so they can see it; only when they hit enter should the search be turned into candidate cursors at every match.
- add_cursor_candidate doesn't seem to only activate the candidates within the region --- it seems to always do all of them
- In `ring_pop`, the original code was:
- Let me use Python for this C refactor.
- we should open the buffers that aren't open, at least temporarily, to do those edits.
- lsp_rename` right after the `find_word_*` helpers so it can use `find_word_at` as an upvalue.
- lsp_version then
- Merge into a single function that optionally handles the NULL-exe_name case.

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

- /Users/alexispurslane/Development/scratch/cursed/docs/code-review.md (11 reads) — nope, mark what you've done so far off in @docs/code-review.md
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (6 reads) — M39 is more involved than it looks — the piece mutation surface is large, and th
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/commands.lua (7 reads) — Now I have a clear picture. Let me check what function contains the `debug.getin
- /Users/alexispurslane/Development/scratch/cursed/src/main.lua (4 reads) — Now I understand both call sites. Let me read the main.lua dispatch for complete
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/advice.lua (3 reads) — Good. The doc comment at line 31 still describes the old behavior. Let me update
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/buffer.lua (10 reads) — Found it at line 237. Let me read it:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/utf8.lua (8 reads) — Three quick perf wins done (M24, M25, M40). M39 was a skip (too invasive for the
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/completers.lua (3 reads) — Now the cache logic in `completers.buffer_words`:
