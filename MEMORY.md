# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Preferences

- please make it work for words and sentences now

## Key Decisions

- alright, let's make word and sentence motions work manually I guess....
- okay, maybe we should just manually create selection+motion commands, instead of handling it automatically, my bad
- alright, now, if the mark was already *manually* set, we should extend that selection.
- immediately, and for as long as, the user is in a part of the keychord trie, but has not concluded with a command, we should show what further keys they can press to get to a command if it's a single key or key with...
- we should do alt+q ig
- Let me fix the colors properly and use yellow for the footer hint.
- I realize the approach is getting overly complex.

## Gotchas & Errors

- stylua --check src
- For an empty buffer (0 lines), accessing `line_text(0)` fails since line 0 doesn't exist.
- lua doesn't have `mirror_prefix` set yet — so either they added it and it failed, or there's a real bug.
- That's almost certainly why the mirror "doesn't work" — the popup was rendering but unreadable.
- (no output)
- md` starts cleanly (the tb_init failure is just because there's no TTY).
- Could not find the exact text in src/cursed/major_mode.lua. The old text must match exactly including all whitespace and newlines. — Fix: alright, now here's how we fix the gap: we implement electric pairs, using defined pairs for the mode!
- Confirmed: incomplete `if x then` parses as `(chunk (ERROR (identifier)))` — **no `if_statement` node exists**, so query-based indent can't fire for a freshly-typed opener.

## Heavily Read

- src/cursed/shared.lua (3 reads) — Now the `SharedState` Lua methods. Let me view the end of shared.lua to place th
- src/cursed/view.lua (8 reads) — Now task 5: add `View:hl_tree()` and release on close. Let me find a good spot t
