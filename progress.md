# Scout Progress — Rendering & Viewport Layer

## Status: COMPLETE

Wrote findings to `/tmp/cursed-scout-render.md` (~13KB).

## Key findings (highly compressed):

1. **Render = full repaint every frame.** `Editor:render()` (editor.lua:1296) clears the whole buffer then walks visible rows painting each via `term:print` (= `tb_set_cell` per char), then `term:present()`. No dirty rect / damage tracking. Double-buffering is termbox2-internal only.

2. **Viewport/scroll:** scroll_y is screen-row offset. `scroll_to_cursor` (view.lua:3942) has a guard to skip when cursor unchanged; `scroll_viewport` / `scroll_page` (view.lua:3993/4050) move viewport without caret for wheel/paging (memory: avoids caret-stuck). `recenter` cycles middle/top/bottom.

3. **Soft wrap = byte-based, NOT grapheme-aware.** `wrap_rows = ceil(byte_len / wrap_width)`, `wrap_byte_offset` = `sub_row*wrap_width + sub_col`. No tab/wide-char/combining handling. No hard-wrap / auto-fill mode. Neither `truncate-lines` nor `word-wrap` toggles exist.

4. **Multi-view / split: data exists, render doesn't.** `Editor.views[]` + `active_view` + `add_view`/`close_view`/`focused_view` all exist (editor.lua:132, 291-336, 1251). But `Editor:render()` only paints `current_view` over the whole viewport — no window rects, no dividers, no `other-window`. No C-x 2/3/1/o keybindings anywhere. `buffer-view-split.md` explicitly scopes rendering to single-view even after the Buffer/View/Editor refactor.

5. **Cursor:** logical line + byte col stored per-cursor (view.lua:25-35). Display sub-row computed via `wrap_sub_position` only at the cursor's line, painted as reverse-video cell gated on blink. Hardware caret always hidden. Multi-cursor supported.

6. **Frame loop:** `select(ttyfd, kq, wake_pipe)` with deadline = min(background-tasks-now, chord-100ms, blink, load-watchdog). When idle with no tasks: blocks indefinitely until blink timer fires. Render fires every loop iteration unconditionally (main.lua:1153).

7. **No idle refill.** Memory confirmed removed; `view.lua:1079` comment says *no separate off-screen idle prefiller*. `View:_hl_tick` does per-render viewport±margin bucket fills instead.

8. **Status/modeline/minibuffer:** one modeline row with `path* | L# C# | NN%` (editor.lua:1607-1638). Footer = modeline + minibuffer rows + completion rows. Minibuffer in footer area with prompt, completions (max 5), metadata column. Eval result in minibuffer row when inactive.

9. **Resize:** resizefd registered on kqueue (main.lua:784-786) but `event_resize` is NOT dispatched as an event in main.lua — grep finds nothing. Render just re-reads `term:width/height` each frame so it "works" but no explicit on-resize hook.

10. **Colorscheme:** all UI concepts (line_number, modeline_fg, cursor_bg, selection_bg, drop_bg, minibuffer_*) live in one CONCEPT_SLOTS table (colorscheme.lua:90-106); `ui(name)` resolver at editor.lua:28-39. `line_number_active` exists but appears unused — display-line-numbers is always-on with no toggle and no current-line highlight.

## Judge vs Emacs

- **Fundamental bones: GOOD** for single-window editing (piece table, async highlight lane, multi-cursor, isearch, kill ring, chord dispatch, truecolor).
- **Biggest gap: single-view render** — any window-split work starts at `editor.lua:1296` and needs a layout-driven fan-out (per-view rects, divider paint, mouse routing). View math is already window-agnostic.
- **Second gap: byte-based wrap math** — would mis-cursor on CJK/tabs. Fix = a `display_width(byte)` helper threaded through wrap_sub_position/paint/mouse.
- **Missing Emacs features:** arbitrary window splitting (C-x 2/3/1/o), dedicated windows, follow-mode, hl-line-mode, EOF/continuation glyphs, truncate-lines/word-wrap toggles, display-line-numbers toggle. All need new code; the data layer is closer to ready than the render layer.
- **Image display: N/A** (terminal-only, termbox2 has no image API).
- **Not a blocker now but worth noting:** full repaint per frame — fine for current sizes; would matter for many splits or huge terminals.

## Files most likely needing changes for split-window work
- `src/cursed/editor.lua:1296-1760` (render body); add a layout/rects layer above.
- `src/cursed/editor.lua:291-336` (view management; add split/close-other-window ops).
- `src/cursed/view.lua:2020-2210` (wrap math; possibly accept a rect clamp for clipped painting).
- `src/cursed/default_keybindings.lua` (add C-x 2/3/1/o chord bindings).
- New module (e.g. `window.lua`) for layout manager.
