# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- Let me restructure so motion events never add cursors:
- I feel like we should make everything UTF-8 robust (both cursor, rendering, wrap math, and moving around / measuring distances in buffers) before it's too late
- Refactoring all three to use `if/else` instead of goto:
- )` advances the screen column by byte count, not display width
- Use it instead of re-stripping from `buf:line_text`.
- I'll add a dedicated `selection_fg` UI concept at a brighter slot (base06) and use it for selection text.
- we should also always have a 1-col margin to the left of the line numbers and 2-col to the right (instead of one on the right)

## Gotchas & Errors

- 29 passed, 0 failed — Fix: The closure captures `bs, p, w, ll` — all should be ints/arrays.
- But the test is failing with `got=4 want=2`.
- The wrap_test failure is in my TEST's mini-`M()` helper which still has the outdated `wrap_rows` arithmetic that doesn't match the real View — line 47 calls `byte_to_col(0)` on the ZWJ-family string.
- FAIL CJK byte_to_col(4)//中2: got=3 want=4 — Fix: My test asserted `byte_to_col(4)` should be 4, but byte 4 (0-based) is the 2nd byte of the 1st 中 (mid-cluster) → col 1.
- Validation failed for tool "edit":
- Could not find edits[0] in src/cursed/utf8.lua. The oldText must match exactly including all whitespace and newlines.
- Command aborted
- The caret also uses `cursor_fg` (base00 on the bright cursor_bg base05, which is correct), so I can't just bump `cursor_fg`.

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/main.lua (5 reads) — Good — that's the key design call. Let me confirm the editor's field setup and t
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (28 reads) — Now I understand the architecture. The key insight from the report and these pat
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/view.lua (6 reads) — Let me read the View geometry helpers and the editor's local helpers (`cell_len`
