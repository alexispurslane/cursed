# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- alright, now, if the mark was already *manually* set, we should extend that selection.
- immediately, and for as long as, the user is in a part of the keychord trie, but has not concluded with a command, we should show what further keys they can press to get to a command if it's a single key or key with...
- we should do alt+q ig
- Let me fix the colors properly and use yellow for the footer hint.
- I realize the approach is getting overly complex.
- Concretely the dedent rule is: on Return, if the line's trailing text matches a closer pattern, re-indent that line one *less* unit than its carried indent, then insert the newline at that dedented indent.
- The structural helper (`_electric_closer_target_indent`) is used in exactly one: the closer-dedent decision on Return.
- we should probably figure out the amount of indentation to insert directly after an electric opener pattern using the tree sitter based target indentation calculation
- ---
- Deadlines are in the future but the loop still iterates ~1540/sec — so `select` returns early every iteration (a ready fd).

## Gotchas & Errors

- The forward-decl approach actually crashes at runtime.
- /opt/homebrew/bin/luajit: ../test_lsp.lua:103: missing declaration for symbol 'printf'
- /opt/homebrew/bin/luajit: ./cursed/lsp_client.lua:380: 'for' limit must be a number — Fix: Drain has a `'for' limit must be a number` error.
- vendored LuaJIT already built
- lua:576`) rejected the immutable Lua string — `"cannot convert 'string' to 'char *'"`.
- (no output)
- Clean build, boots without crashing, all three lanes start.
- Let me trigger a kill via the lua file's `lsp_client` interaction is harder from CLI; instead let me test the **crash/EOF → dead** path by killing the spawned server process mid-run.

## Heavily Read

- src/cursed/lsp_client.lua (5 reads) — Now rewrite the main facade's registry + handshake handling to be status-keyed. 
- src/main.lua (4 reads) — Found it — `docs/plans/core.md` already specifies `outbox_lsp`/`inbox_lsp`; the 
- src/cursed/lsp_lane.lua (12 reads) — Let me look at the exact sections I need to edit in the lane.
