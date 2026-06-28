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
- Concretely the dedent rule is: on Return, if the line's trailing text matches a closer pattern, re-indent that line one *less* unit than its carried indent, then insert the newline at that dedented indent.
- The structural helper (`_electric_closer_target_indent`) is used in exactly one: the closer-dedent decision on Return.
- we should probably figure out the amount of indentation to insert directly after an electric opener pattern using the tree sitter based target indentation calculation

## Gotchas & Errors

- Confirmed: incomplete `if x then` parses as `(chunk (ERROR (identifier)))` — **no `if_statement` node exists**, so query-based indent can't fire for a freshly-typed opener.
- === Vendored files ===
- rg: main.c: IO error for operation on main.c: No such file or directory (os error 2)
- The cost is that users can shoot themselves in the foot, but the reward is that nothing is blocked.
- === initial ===
- Let me verify the key claim empirically — that the structural helper *can't* be used at block-opener completion time because the tree is incomplete then.
- So you **cannot** compute the body indent from the tree *before* inserting the closer.
- That last point is the new finding (you'd previously concluded "can't be used at completion time" — true *before* closer insertion, but **not** after).

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/view.lua (8 reads) — Let me understand the tree availability at printable time. Let me look at `hl_tr
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/ts.lua (4 reads) — Let me write a quick repro to empirically test whether an incomplete `if x then`
