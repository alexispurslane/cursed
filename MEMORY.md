# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- okay, maybe we should just manually create selection+motion commands, instead of handling it automatically, my bad
- alright, now, if the mark was already *manually* set, we should extend that selection.
- immediately, and for as long as, the user is in a part of the keychord trie, but has not concluded with a command, we should show what further keys they can press to get to a command if it's a single key or key with...
- we should do alt+q ig
- Let me fix the colors properly and use yellow for the footer hint.
- I realize the approach is getting overly complex.
- Concretely the dedent rule is: on Return, if the line's trailing text matches a closer pattern, re-indent that line one *less* unit than its carried indent, then insert the newline at that dedented indent.
- The structural helper (`_electric_closer_target_indent`) is used in exactly one: the closer-dedent decision on Return.
- we should probably figure out the amount of indentation to insert directly after an electric opener pattern using the tree sitter based target indentation calculation
- ---

## Gotchas & Errors

- Let me verify the key claim empirically — that the structural helper *can't* be used at block-opener completion time because the tree is incomplete then.
- So you **cannot** compute the body indent from the tree *before* inserting the closer.
- That last point is the new finding (you'd previously concluded "can't be used at completion time" — true *before* closer insertion, but **not** after).
- Validation failed for tool "write":
- Validation failed for tool "write": — Fix: OK, I need to stop going in circles.
- The forward-decl approach actually crashes at runtime.
- /opt/homebrew/bin/luajit: ../test_lsp.lua:103: missing declaration for symbol 'printf'
- /opt/homebrew/bin/luajit: ./cursed/lsp_client.lua:380: 'for' limit must be a number — Fix: Drain has a `'for' limit must be a number` error.

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/major_mode.lua (3 reads) — Works. Now task 2 — add `lsp_servers` to major_mode.lua:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/lsp_client.lua (6 reads) — Now task 4 — remove the duplicate `spawn_or_get` in lsp_client.lua. Let me view 
- /Users/alexispurslane/Development/scratch/cursed/src/main.lua (3 reads) — Now task 5 — store `main_kq` + `workspace_dir` on the editor, and shutdown on cl
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (3 reads) — Let me check how the modeline renders segments (esp. empty `format` returns) so
