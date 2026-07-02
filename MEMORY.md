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

- ## The bug you saw
- Root cause: the hand-rolled `json_encode` had a broken string escaper — `v:gsub("\\", "\\")` was a no-op (replaced `\` with `\`) and `:gsub('"', "\\")` replaced `"` with a bare `\`.
- c`** — a thin C shim that `#include`s the header and re-exports yyjson's `inline` getters/builders (which have no exported symbol, so LuaJIT FFI can't reach them directly) as real `shim_*` symbols.
- Could not find edits[0] in src/cursed/commands.lua. The oldText must match exactly including all whitespace and newlines.
- cursed: failed to initialize terminal: cursed.tb: tb_init failed (code -4) — Fix: So when the user ran in their terminal, it should be too, unless...
- log` cannot be opened, so we'll get logs one way or another.
- === render item counts (chronological) === — Fix: Let me actually look at the damage-tracking / repaint logic, because for a ghost to *persist* (not just flicker for 4ms), the old box's cells must not be getting repainted frame-to-frame.
- Could not find the exact text in /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua. The old text must match exactly including all whitespace and newlines. — Fix: Let me re-apply the `_tick` fix there.

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (9 reads) — Found the root cause. In `tick_background_tasks`, when a deadline task fires, `d
