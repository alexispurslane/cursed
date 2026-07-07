# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now
- I want to do fuzzy file finding within a directory for this editor project, but I don't want it to depend on an external program like fzf.

## Key Decisions

- But the convention is `forward_<name>_select` (select is a suffix).
- This will, in the future, allow using tree-sitter based text objects as well.
- )` tree-sitter-query textobject builder (updated from the old "will, in the future, allow using tree-sitter based text objects" promise — now delivered), with the lazy query compilation, fresh-snapshot-per-call RAII...
- The command may use tree-sitter as a fallback rather than LSP.
- for instance, we should probably add ctrl-c s and ctrl-c k for starting and killing the lsp, and maybe ctrl-c ctrl-r for restarting it.
- alright, now, we should make LSP notifications and responses come back as events on the event bus, instead of having to have this whole separate "mint callback, store it, call it" thing.
- we should also have an input_hook that completes tags
- Could mitigate by keeping the array for O(1) prefix access and only using BIT for update paths, rebuilding the array from BIT when convenient.
- when the user is in the minibuffer crafting a search, we should only find the first instance, jumping there so they can see it; only when they hit enter should the search be turned into candidate cursors at every match.
- add_cursor_candidate doesn't seem to only activate the candidates within the region --- it seems to always do all of them

## Gotchas & Errors

- A fixed-string block opener can't express `</tag>` where the tag name varies.
- Let me add a debug log inside the render loop to inspect `total_sub` and the cached cursor state right before the broken render:
- (no output)
- Running under lldb...
- Lua tables can't have `nil` values — `{ p, nil }` creates a table with **one** element, so `path_argv[1]` is left **uninitialized garbage** instead of NULL.
- Initializing ...                                                                                >=================== 01/69                                                        — Fix: The primary fix: after `on_submit` populates candidates, the primary cursor now jumps to the first pending cursor.
- Without this, the cursor could be at a position that doesn't match any candidate, making `_promote_candidate_at_primary` fail silently.
- error: unexpected argument '--no-color' found
