# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now
- I want to do fuzzy file finding within a directory for this editor project, but I don't want it to depend on an external program like fzf.

## Key Decisions

- for instance, we should probably add ctrl-c s and ctrl-c k for starting and killing the lsp, and maybe ctrl-c ctrl-r for restarting it.
- alright, now, we should make LSP notifications and responses come back as events on the event bus, instead of having to have this whole separate "mint callback, store it, call it" thing.
- we should also have an input_hook that completes tags
- Could mitigate by keeping the array for O(1) prefix access and only using BIT for update paths, rebuilding the array from BIT when convenient.
- when the user is in the minibuffer crafting a search, we should only find the first instance, jumping there so they can see it; only when they hit enter should the search be turned into candidate cursors at every match.
- add_cursor_candidate doesn't seem to only activate the candidates within the region --- it seems to always do all of them
- In `ring_pop`, the original code was:
- Let me use Python for this C refactor.
- we should open the buffers that aren't open, at least temporarily, to do those edits.
- lsp_rename` right after the `find_word_*` helpers so it can use `find_word_at` as an upvalue.

## Gotchas & Errors

- Lua tables can't have `nil` values — `{ p, nil }` creates a table with **one** element, so `path_argv[1]` is left **uninitialized garbage** instead of NULL.
- Initializing ...                                                                                >=================== 01/69                                                        — Fix: The primary fix: after `on_submit` populates candidates, the primary cursor now jumps to the first pending cursor.
- Without this, the cursor could be at a position that doesn't match any candidate, making `_promote_candidate_at_primary` fail silently.
- error: unexpected argument '--no-color' found
- lua:55: kqueue: add_fd(15) on kq=0 failed (rc=-1 errno=9)
- lua:276: table index is nil
- /bin/bash: line 26: luajit: command not found
- Command aborted

## Heavily Read

- src/cursed/editor_listeners.lua (14 reads) — Now I have everything I need. Let me check whether `editor.status_message` is se
- src/cursed/editor.lua (14 reads) — There's already an `Editor:apply_workspace_edit` method. Let me read it fully.
- src/cursed/commands.lua (11 reads) — All checks pass. Now let me also handle the `commands.lua` code-action caller — 
- src/cursed/lsp_client.lua (4 reads) — The LSP binding currently happens on `mode_enter` for the *focused* view. For au
- src/cursed/view.lua (6 reads) — The lint errors are `inject-field` warnings — I need to declare the new fields o
- src/main.lua (3 reads) — Let me read the full load-handling structure to see both branches:
