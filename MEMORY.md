# Project Memory

This file is auto-maintained by the pi-memory extension.
It stores user preferences, key decisions, durable gotchas, and frequently-referenced files
so the agent can pick up context across sessions.

## Key Decisions

- Let me restructure so motion events never add cursors:
- I feel like we should make everything UTF-8 robust (both cursor, rendering, wrap math, and moving around / measuring distances in buffers) before it's too late
- Refactoring all three to use `if/else` instead of goto:

## Gotchas & Errors

- The self-pipe's stated rationale ("select can't detect EVFILT_USER") is false, but that's out of scope to restructure.
- So `select()` never saw the kq_fd become readable and blocked until the 200ms file-load watchdog, after which a band-aid unconditional drain finally picked up the (long-since-ready) reply.
- Could not find the exact text in src/cursed/utf8.lua. The old text must match exactly including all whitespace and newlines.
- 29 passed, 0 failed — Fix: The closure captures `bs, p, w, ll` — all should be ints/arrays.
- But the test is failing with `got=4 want=2`.
- The wrap_test failure is in my TEST's mini-`M()` helper which still has the outdated `wrap_rows` arithmetic that doesn't match the real View — line 47 calls `byte_to_col(0)` on the ZWJ-family string.
- FAIL CJK byte_to_col(4)//中2: got=3 want=4 — Fix: My test asserted `byte_to_col(4)` should be 4, but byte 4 (0-based) is the 2nd byte of the 1st 中 (mid-cluster) → col 1.
- Validation failed for tool "edit":
