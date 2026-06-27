# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- Let me restructure so motion events never add cursors:
- I feel like we should make everything UTF-8 robust (both cursor, rendering, wrap math, and moving around / measuring distances in buffers) before it's too late
- Refactoring all three to use `if/else` instead of goto:
- )` advances the screen column by byte count, not display width

This needs a full rewrite to use display-column addressing via the grapheme cache.
- Use it instead of re-stripping from `buf:line_text`.

## Gotchas & Errors

- So `select()` never saw the kq_fd become readable and blocked until the 200ms file-load watchdog, after which a band-aid unconditional drain finally picked up the (long-since-ready) reply.
- Could not find the exact text in src/cursed/utf8.lua. The old text must match exactly including all whitespace and newlines.
- 29 passed, 0 failed — Fix: The closure captures `bs, p, w, ll` — all should be ints/arrays.
- But the test is failing with `got=4 want=2`.
- The wrap_test failure is in my TEST's mini-`M()` helper which still has the outdated `wrap_rows` arithmetic that doesn't match the real View — line 47 calls `byte_to_col(0)` on the ZWJ-family string.
- FAIL CJK byte_to_col(4)//中2: got=3 want=4 — Fix: My test asserted `byte_to_col(4)` should be 4, but byte 4 (0-based) is the 2nd byte of the 1st 中 (mid-cluster) → col 1.
- Validation failed for tool "edit":
- Could not find edits[0] in src/cursed/utf8.lua. The oldText must match exactly including all whitespace and newlines.

## Heavily Read

- src/cursed/view.lua (30 reads) — `move_char` advances by bytes — rewrite it on graphemes using `advance_grapheme`
- src/cursed/editor.lua (12 reads) — `term:print(text_x + painted, row, chunk:sub(...), fg, bg)` — this uses byte off
- src/main.lua (3 reads) — That's the read-char path. Let me find the actual printable-key → insert_char di
- vendor/termbox2/termbox2.h (6 reads) — Patching termbox2 to store full grapheme clusters per cell. Let me study the cel
- src/cursed/utf8.lua (5 reads) — Now there's a width mismatch I must address: our renderer computed the ZWJ famil
