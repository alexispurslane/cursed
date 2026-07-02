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

- (no output)
- Clean build, boots without crashing, all three lanes start.
- Let me trigger a kill via the lua file's `lsp_client` interaction is harder from CLI; instead let me test the **crash/EOF → dead** path by killing the spawned server process mid-run.
- But INIT→READY→didOpen with the server staying alive definitively proves the yyjson swap fixed the crash.
- 5s; previously it died at ~14ms from the malformed-JSON crash)

Let me clean up the leftover test file and kill the stray server.
- ## The bug you saw
The modeline ✝ (dead) was the `lua-language-server` **crashing immediately after `didOpen`**.
- Root cause: the hand-rolled `json_encode` had a broken string escaper — `v:gsub("\\", "\\")` was a no-op (replaced `\` with `\`) and `:gsub('"', "\\")` replaced `"` with a bare `\`.
- c`** — a thin C shim that `#include`s the header and re-exports yyjson's `inline` getters/builders (which have no exported symbol, so LuaJIT FFI can't reach them directly) as real `shim_*` symbols.

## Heavily Read

- src/cursed/lsp_lane.lua (11 reads) — Now the lane handler. Let me find the dispatch switch.
- src/cursed/editor_listeners.lua (4 reads) — No `sync_open` log at all! So `lsp.sync_open` is never called. The mode_enter li
- src/cursed/lsp_client.lua (3 reads) — The server log shows a **JSON parse error**: `invalid escape char ')' in string
