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

## Gotchas & Errors

- total 33995128
- rm: Screenshot 2026-06-27 at 11.01.24 AM.png: No such file or directory
- found: [Screenshot 2026-06-27 at 1.39.50*PM.png] [Screenshot 2026-06-27 at 1.40.43*PM.png] [Screenshot 2026-06-27 at 1.41.42*PM.png] [Screenshot 2026-06-27 at 1.40.28*PM.png]
- I can't view the images, but I'll trust you.
- stylua --check src
- For an empty buffer (0 lines), accessing `line_text(0)` fails since line 0 doesn't exist.
- lua doesn't have `mirror_prefix` set yet — so either they added it and it failed, or there's a real bug.
- That's almost certainly why the mirror "doesn't work" — the popup was rendering but unreadable.

## Heavily Read

- src/main.lua (24 reads) — Now update `process_key` to set/clear `_whichkey_node` + `_whichkey_prefix` inst
- src/cursed/editor.lua (13 reads) — Let me look at the palette box-drawing to mirror it exactly.
- src/cursed/whichkey.lua (4 reads) — Now I understand. The modeline center text uses **auto-detected** color (base06 
- src/cursed/config.lua (8 reads) — `alt-space` is currently bound to `just_one_space` — and since the trie dispatch
