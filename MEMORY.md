# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- Let me restructure so motion events never add cursors:

## Gotchas & Errors

- the `tab_width = 2, margin = 72` line is in `@-`'s version), so the check was already failing before I did anything.
- This looks like a broken/partial autotools state, unrelated to my changes (it's a build artifact dir, not tracked by `@-`).
- The self-pipe's stated rationale ("select can't detect EVFILT_USER") is false, but that's out of scope to restructure.
- So `select()` never saw the kq_fd become readable and blocked until the 200ms file-load watchdog, after which a band-aid unconditional drain finally picked up the (long-since-ready) reply.

## Heavily Read

- src/main.lua (11 reads) — Now let me rewrite the mouse handler block. Let me view the full current block o
- src/cursed/editor.lua (4 reads) — Now let me see the render code in detail around the margin/centering:
- src/cursed/view.lua (6 reads) — Let me look at the View.new and fields, and the term module for width:
- src/cursed/commands.lua (4 reads) — Let me verify with a keyboard-driven multi-cursor (avoids mouse timing flakiness
- src/cursed/default_keybindings.lua (3 reads) — Let me look at how Escape is dispatched in the key loop (there are special-case 
- vendor/termbox2/termbox2.h (3 reads) — **Root cause found.** termbox2's SGR/1006 mouse decoder only extracts the `MOTIO
