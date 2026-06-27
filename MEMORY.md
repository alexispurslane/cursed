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
- Line-anchored scroll model: scroll position is {top_li, top_sub_row}, NOT absolute screen row. Going by absolute screen row forces building the wrap-cache prefix to position anywhere → 240ms hitch on jump-to-EOF. Whole-file / page / goto-line jumps should position by LINE NUMBER and only compute wrap rows viewport-locally (~50 lines). Absolute screen-row math (line_to_screen_row / total_screen_rows / screen_row_to_line binary search) is only needed for incremental vertical motion (C-n/C-p) which can be made viewport-relative. This is the chosen direction (over approximate-jump and bg-build approaches).

## Gotchas & Errors

- But the wrap cache is a forward cumulative structure — you can't build the end without the prefix (cumulative sum depends on everything before).
- **Build backward from EOF for the viewport**: can't, cumulative needs prefix.
- `loop_iter` elapsed INCLUDES the blocking select() wait for the next key — a 535ms loop_iter with render_total=6ms is just idle, NOT a stall. Don't read loop_iter alone as a perf signal; check render_total + named spans.
- `clamp_anchor_to_eof` "whole doc fits" branch bug: when the anchor is near EOF, walking forward finds few rows below (filled <= text_rows) but that does NOT mean the whole doc fits — it just means the anchor is too low. Pull UP instead of pinning to (0,0). Only pin to 0 when the anchor is already at line 0.
- `scroll_to_cursor` must NOT compute `viewport_row_for_line(far_line)` for far jumps — that walks the whole prefix (the thing we're avoiding). Use a jump fast-path: if |cursor.line - scroll_li| > 2*text_rows, re-anchor directly (near EOF → anchor_so_line_at_row(cursor, margin) backward walk O(viewport); else anchor_to_line(cursor) O(1)).
- `move_line` (C-n/C-p visual-row motion) must walk from the CURSOR's own (line, sub), NOT from the viewport anchor. I first wrote it viewport-relative (`viewport_row_for_line(cursor) + n; viewport_line_at_row(target)`) — that breaks after the viewport is paged away from the cursor (wheel/C-v): the cursor sits above the anchor, `viewport_row_for_line` returns negative, and `move_line`'s `target_screen < 0` guard fires → clamps the cursor to (0,0) "start of document" instead of moving it. Fix: added `View:walk_sub_rows(li, sub, delta)` that walks `delta` wrap-rows from the cursor's position independent of the anchor. Visual-row motion is anchor-independent by definition.
- `C-v`/`M-v` (page down/up) do NOT move the cursor by design (scroll_page = scroll viewport only, like wheel). So after paging, `C-l` recenter recenters to the UNMOVED cursor at its original line — expected, not a bug.
- Recenter near EOF appears to "not move" — pre-existing clamp behavior: `cursor - middle` exceeds max_scroll so it clamps back. Unchanged by the anchor refactor.

## Heavily Read

- /Users/alexispurslane/Development/scratch/cursed/src/cursed/view.lua (35 reads) — Now let me revert each region. First the annotations + init fields:
- /Users/alexispurslane/Development/scratch/cursed/src/cursed/editor.lua (8 reads) — Now the render row loop and hl viewport math in editor.lua:
