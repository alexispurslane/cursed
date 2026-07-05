# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now
- I want to do fuzzy file finding within a directory for this editor project, but I don't want it to depend on an external program like fzf.

## Key Decisions

- , the convention is "end at col 0 of the next line" (half-open across lines).
- Actually, the simplest robust fix: in the C cleanup, when the main return code indicates a headless exit, use `pthread_cancel` instead of `pthread_join` for the lanes.
- But the convention is `forward_<name>_select` (select is a suffix).
- This will, in the future, allow using tree-sitter based text objects as well.
- )` tree-sitter-query textobject builder (updated from the old "will, in the future, allow using tree-sitter based text objects" promise — now delivered), with the lazy query compilation, fresh-snapshot-per-call RAII...
- The command may use tree-sitter as a fallback rather than LSP.
- for instance, we should probably add ctrl-c s and ctrl-c k for starting and killing the lsp, and maybe ctrl-c ctrl-r for restarting it.
- alright, now, we should make LSP notifications and responses come back as events on the event bus, instead of having to have this whole separate "mint callback, store it, call it" thing.
- we should also have an input_hook that completes tags
- Could mitigate by keeping the array for O(1) prefix access and only using BIT for update paths, rebuilding the array from BIT when convenient.

## Gotchas & Errors

- stylua --check src
- vendor/luajit/src/luajit: /tmp/vp_test.lua:33: attempt to call method 'line_count' (a nil value)
- The "indented split" failure was my test's wrong cursor column (I passed 11 instead of 10).
- A fixed-string block opener can't express `</tag>` where the tag name varies.
- Let me add a debug log inside the render loop to inspect `total_sub` and the cached cursor state right before the broken render:
- (no output)
- Running under lldb...
- Lua tables can't have `nil` values — `{ p, nil }` creates a table with **one** element, so `path_argv[1]` is left **uninitialized garbage** instead of NULL.

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/find_file.lua (3 reads) — Now add the fuzzy completer to `find_file.lua`:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/posix_ffi.lua (5 reads) — The `FTSENT` struct layout on macOS is completely different from what I declared
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/completers.lua (3 reads) — Now add the export to `completers.lua`. Let me find the right spot:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/commands.lua (4 reads) — Got it — fuzzy find-file is a separate command, existing substring matching stay
