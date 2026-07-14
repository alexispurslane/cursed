# Prose Editing Feature Assessment

A gap analysis of the cursed editor's prose editing capabilities, identifying what's
already present and what would be needed for a world-class prose editing experience.

---

## Current Prose Feature Inventory (Already Present)

### Navigation & Movement

| Command | Binding | Notes |
| --- | --- | --- |
| forward-word / backward-word | alt-f / alt-b | |
| forward-bigword / backward-bigword | ctrl-x M-f / ctrl-x M-b | Whitespace-delimited words |
| forward-sentence / backward-sentence | alt-e / alt-a | Sentence-ending `[!.?][ \n]` pattern |
| forward-subsentence / backward-subsentence | alt-s / alt-S | Clause-ending punctuation |
| forward-paragraph / backward-paragraph | alt-{ / alt-} | Blank-line-delimited paragraphs |
| forward-visual-line / backward-visual-line | ctrl-n / ctrl-p | Respects soft wrap sub-rows |
| beginning-of-buffer / end-of-buffer | alt-< / alt-> | |
| page up / page down | ctrl-v / alt-v (+ pagedown/pageup) | |
| goto-line | alt-g g / alt-g alt-g | |

### Selection & Text Objects

| Feature | Binding | Notes |
| --- | --- | --- |
| mark-word | alt-@ | |
| mark-paragraph | alt-h | |
| mark-whole-buffer | ctrl-x h | |
| mark-sexp | ctrl-x s m | |
| expand-region / shrink-region | alt-' / alt-" | Progressive semantic selection: char → word → bigword → sexp → line → defun → buffer; then ascends tree-sitter parse tree |
| set-mark | ctrl-space | |
| swap-mark-and-cursor | ctrl-x ctrl-x | |
| Text objects | | char, word, bigword, sentence, subsentence, paragraph, line, sexp, buffer (all composable with mark/kill/copy/drag) |
| Auto-generated textobject commands | | `mark_<name>` / `forward_<name>` / `backward_<name>` / `forward_<name>_select` / `backward_<name>_select` auto-registered for every textobject on mode entry or parse-tree landing |

### Kill, Yank & Copy

| Command | Binding | Notes |
| --- | --- | --- |
| kill-line | ctrl-k | |
| kill-word | alt-backspace | Backward kill word (Emacs M-backspace) |
| kill-word-forward | alt-d | |
| kill-sentence | alt-k | |
| backward-kill-sentence | ctrl-x delete | |
| kill-paragraph | ctrl-x alt-p | |
| kill-whole-line | ctrl-x ctrl-k | |
| kill-region | ctrl-w | Emacs-faithful |
| yank | ctrl-y | |
| yank-pop | alt-y | |
| copy-region | alt-w | |
| copy-sentence | ctrl-x alt-w | |
| copy-sexp | ctrl-x s w | |
| Kill ring | | Full kill ring with yank-pop cycle |

### Case & Whitespace

| Command | Binding | Notes |
| --- | --- | --- |
| upcase-word / downcase-word / capitalize-word | alt-u / alt-l / alt-c | |
| upcase-region / downcase-region | ctrl-x ctrl-u / ctrl-x ctrl-l | |
| snake_case_region / kebab-case-region | ctrl-x _ / ctrl-x - | |
| camelcase-region / title-case-region | ctrl-x c / ctrl-x t | |
| remove-spaces-region | ctrl-x space | |
| delete-horizontal-space | alt-\ | |
| just-one-space | alt-space | |
| delete-blank-lines | ctrl-x ctrl-o | |
| delete-indentation | alt-^ | Join lines |
| quoted-insert | ctrl-q | |
| zap-to-char / zap-up-to-char | alt-z / alt-Z | Kill up to a character |

### Spell Checking

| Feature | Status |
| --- | --- |
| Backend | Enchant-2 (via `enchant-2 -a` pipe) |
| Squiggle overlays | ✅ Red underlines via overlay system |
| Context-aware | ✅ Tree-sitter capture masking: prose = whole line, code = comments/strings only |
| flyspell-correct | ✅ Opens completion menu with suggestions, advances to next misspelling |
| autocorrect-word | ✅ Replaces with top suggestion |
| flyspell-buffer | ✅ Re-checks whole buffer |
| add-to-dict | ✅ Persistent user dictionary |
| ignore-word | ✅ Session-only dismissal |
| Per-buffer store | ✅ Version-stamped against buffer mutation counter, never paints stale offsets |
| Visible-window scoping | ✅ Only checks/renders visible lines |

### Search & Replace

| Feature | Binding | Notes |
| --- | --- | --- |
| isearch-forward / isearch-backward | ctrl-s / ctrl-r | Incremental search |
| query-replace | alt-% | With y/n/! navigation |
| query-replace-regexp | ctrl-M-% (via M-x) | Capture group support: `\1`..`\9` expansion |
| Search candidate navigation | | From isearch or query-replace |

### Word Wrap & Display

| Feature | Status |
| --- | --- |
| Soft word wrap | ✅ `_wrap_graph` pre-computes wrap points at word boundaries |
| Sub-row rendering | ✅ `wrap_rows` / `sub_row_runs` / `wrap_byte_offset` consume the wrap graph |
| Visual line navigation | ✅ forward/backward-visual-line (ctrl-n/p and arrow keys) |
| Margin config | ✅ Per-mode `margin` field + global config; markdown = 72 |
| no_wrap toggle | ✅ View/mode field for per-buffer truncation |
| Wrap cache | ✅ Generation-counter validated, O(log N) position lookup via binary search on `byte_starts` |

### LSP / Code Intelligence (for technical prose)

| Feature | Status |
| --- | --- |
| Completion | ✅ In-buffer popup with dabbrev + LSP sources |
| Diagnostics | ✅ Squiggle overlays, gutter signs, hover popups, navigation |
| Hover docs | ✅ Debounced popup with markdown rendering |
| Code actions | ✅ (ctrl-c a) |
| Rename | ✅ (ctrl-c r) |
| Format | ✅ (alt-i) |
| Document symbols | ✅ Tree-sitter fallback when no LSP |
| Workspace symbols | ✅ (alt-g w) |
| Definition | ✅ (alt-.) |

### Multiple Cursors

All of the above commands (navigation, selection, kill, yank, case, search) are
multiple-cursor aware. Cursors can be added via:

| Command | Binding |
| --- | --- |
| select-next-match | ctrl-x ctrl-n |
| select-prev-match | ctrl-x ctrl-p |
| select-all-matches | ctrl-x a |
| split-selection-into-lines | ctrl-x S |
| add-cursor-here | alt-; |
| add-cursor-at-candidate | alt-, |
| add-cursor-up / add-cursor-down | alt-up / alt-down |

### Undo / Redo

| Feature | Notes |
| --- | --- |
| Snapshot-based | Piece table snapshots — perfect restoration, no inverse-command complexity |
| Undo / Redo stacks | Undo pops to redo stack; modifications push more undo snapshots |
| undo-in-selection / redo-in-selection | Best-effort within region, even with multiple cursors |

---

## Gaps vs. a World-Class Prose Editor

### Priority: Critical (dealbreaker for daily prose use)

#### 1. Auto-Fill / Fill-Paragraph

**Status: ✅ DONE** — Implemented in `src/cursed/commands.lua` (fill_paragraph,
fill_region, unfill_paragraph, toggle_auto_fill) and `src/cursed/modes/auto_fill.lua`
(auto-fill major mode).

**Implemented features:**

| Feature | Status | Binding | Notes |
| --- | --- | --- | --- |
| **`fill-paragraph`** (M-q) | ✅ | `alt-q` | Selects paragraph via textobject, joins lines, collapses whitespace, re-wraps at `view.margin` or 72 |
| **`fill-region`** | ✅ | M-x `fill_region` | Same logic as fill-paragraph but operates on active selection |
| **`auto-fill-mode`** | ✅ | M-x `toggle_auto_fill` | Minor mode (`is_minor = true`); not shown in modeline, doesn't clobber margin; listens on `post_command_hook` after `__printable`, breaks at last space before fill width |
| **`fill-column`** | ✅ | `view.margin` / `view._auto_fill_margin` | Dedicated `_auto_fill_margin` field survives mode-setup overwrites |
| **`set-fill-column`** | ✅ | `ctrl-x f` (`set_margin`) | Accepts universal arg or prompts interactively |
| **`set-fill-prefix`** | ❌ Not implemented | — | — |
| **`unfill-paragraph`** | ✅ | M-x `unfill_paragraph` | Joins paragraph into single line, collapses whitespace |

**Implementation notes:**

- `fill-paragraph` and `fill-region` reuse the paragraph textobject and `utf8.wrap_string`
  for word-boundary-aware reflow.
- `auto-fill` mode deactivates visual wrap (sets `wrap = false`) since auto-fill
  handles line breaking by inserting actual newlines — visual wrap would fight it.
- On entering auto-fill mode, if no margin is configured anywhere, the user is
  prompted via minibuffer for a fill margin value.
- The `post_command_hook` listener is registered once globally and filters by
  `__printable` command and focused view, so only the active auto-fill buffer
  gets auto-filled.
- Now uses `is_minor = true` in the mode spec — auto-fill is a **minor mode**,
  skipped for modeline naming and doesn't override margin/display settings from
  the underlying major mode (e.g. markdown).

---

#### 2. Visual-Line-Aware Home / End

**Status: ✅ DONE** — `ctrl-a` and `ctrl-e` are bound to
`move_beginning_of_visual_line` and `move_end_of_visual_line` in default
keybindings (soft wrap always-active semantics, not a mode toggle).
`move_beginning_of_visual_line` jumps to column 0 of the current visual sub-row;
`move_end_of_visual_line` jumps to the last grapheme of the current visual
sub-row. Both fall back to logical line start/end when wrap is inactive.

**Implemented:**

| Feature | Status | Binding | Notes |
| --- | --- | --- | --- |
| **`move-beginning-of-visual-line`** | ✅ | `ctrl-a` | Falls back to logical line start when wrap is off |
| **`move-end-of-visual-line`** | ✅ | `ctrl-e` | Falls back to logical line end when wrap is off |
| **`kill-visual-line`** | ✅ | `ctrl-k` (when `visual-movement` mode active) | Kills from point to end of current visual sub-row |

---

#### 3. Visual Line Mode Toggle

**Status: ✅ DONE** — Implemented as a per-buffer major mode
`visual-movement` (toggle via `M-x toggle_visual_movement`).

**Architecture:**

- Default keybindings for `ctrl-n`/`ctrl-p`/`ctrl-a`/`ctrl-e` now use
  **logical** line commands (`forward_line`, `backward_line`, `move_line_start`,
  `move_line_end`).
- When `visual-movement` mode is activated, the mode overrides these bindings
  to their visual-line counterparts:
  `forward_visual_line` / `backward_visual_line` / `move_beginning_of_visual_line`
  / `move_end_of_visual_line`.
- `ctrl-k` is also overridden to `kill_visual_line` when the mode is active.
- Arrow keys (`up`/`down`/`home`/`end`) remain on their own bindings and are
  unaffected by the toggle.

**Implemented:**

| Feature | Status | Notes |
| --- | --- | --- |
| `ctrl-n` → visual line down | ✅ | Mode overrides to `forward_visual_line` |
| `ctrl-p` → visual line up | ✅ | Mode overrides to `backward_visual_line` |
| `ctrl-a` → visual line start | ✅ | Mode overrides to `move_beginning_of_visual_line` |
| `ctrl-e` → visual line end | ✅ | Mode overrides to `move_end_of_visual_line` |
| `ctrl-k` → kill to visual line end | ✅ | Mode overrides to `kill_visual_line` |
| Toggle command | ✅ | `M-x toggle_visual_movement` |
| Truncation toggle | ❌ Not implemented | Wrap state is independent |

**Source files:**

- `src/cursed/modes/visual_movement.lua` — mode definition and keybinding overrides
- `src/cursed/commands.lua` — `kill_visual_line`, `forward_line`/`backward_line`,
  `toggle_visual_movement`
- `src/cursed/view.lua` — `View:forward_line()` / `View:backward_line()`
- `src/cursed/default_keybindings.lua` — default logical-line bindings

---

#### 4. Word Count

**Status: ✅ DONE** — Implemented as `cursed.word_count` utility module + `word-count`
commands + `word-count-mode` minor mode.

**Features:**

| Feature | Status | Binding | Notes |
| --- | --- | --- | --- |
| **`word-count`** | ✅ | M-x `word_count` | One-shot count in modeline: "245w 12s 3¶ 1§ ~1pg ~1m" |
| **`word-count-mode`** | ✅ | M-x `toggle_word_count_mode` | Minor mode; live updates after every edit via `post_command_hook` |
| **`set-word-goal`** | ✅ | M-x `set_word_goal` | Set total word target (C-u N or minibuffer prompt) |
| **`set-word-goal-increment`** | ✅ | M-x `set_word_goal_increment` | Set "write N more" target from current count |
| Goal progress display | ✅ | Shown in modeline segment | "245→1000 (24%)" or "+45→+200 (22%)" |
| Modeline segment | ✅ | Appended when mode active | Shows stats + goals, removed on deactivation |
| Selection-aware | ✅ | Counts region when selection is active | Whole buffer when no selection |

**Statistics tracked:**

- **Words** — whitespace-delimited tokens
- **Sentences** — `[.!?][ \n]` convention (same as sentence textobject)
- **Paragraphs** — blank-line-delimited runs
- **Sections** — markdown `#` heading detection
- **Estimated pages** — words ÷ 250, rounded up
- **Reading time** — words ÷ 200 wpm, rounded up

**Source files:**

- `src/cursed/word_count.lua` — counting and formatting logic
- `src/cursed/commands.lua` — `word_count`, `set_word_goal`, `set_word_goal_increment`, `toggle_word_count_mode`
- `src/cursed/modes/word_count.lua` — minor mode with modeline segment + `post_command_hook` listener

---

### Priority: Important (notable daily friction)

#### 5. Transpose Operations

**Status: ✅ DONE** — `transpose-chars` (ctrl-t) implemented in
`src/cursed/commands.lua` and bound in `src/cursed/default_keybindings.lua`.
Multi-cursor aware, UTF-8 safe.

**Implemented features:**

| Feature | Status | Binding | Notes |
| --- | --- | --- | --- |
| **`transpose-chars`** | ✅ | `ctrl-t` | Swaps two chars on either side of point; at EOL swaps two chars before point; multi-cursor aware; UTF-8 safe via `prev_char_start` |
| **`transpose-words`** | ❌ Not implemented | — | Covered by drag (select + alt-left/alt-right) |
| **`transpose-sentences`** | ❌ Not implemented | — | Covered by drag (select + alt-left/alt-right) |

Cursed's drag commands (`alt-left` / `alt-right`) already cover the word and
sentence transpose cases with a more discoverable and visual approach (select +
drag), but the single-keystroke char transpose addresses the different
muscle-memory reflex for quick typo fixes.

**Source files:**

- `src/cursed/commands.lua` — `transpose_chars` command implementation
- `src/cursed/default_keybindings.lua` — `ctrl-t` keyboard binding

---

#### 6. Spell-Check-on-Save

**Status: ✅ DONE** — Implemented via `before_save` event emitted from
`editor:save()`, with a handler registered in `src/cursed/spell.lua` that
queries the spell store and shows a `status_message` warning when misspellings
remain.

**Implemented features:**

| Feature | Status | Notes |
| --- | --- | --- |
| `before_save` event | ✅ | Emitted from `Editor:save()` before the async write |
| `spell-check-on-save` warning | ✅ | Surfaces "spell: N misspelling[s] remaining" in status bar on save; no config flag needed — always active when spell backend is initialized |

**Source files:**

- `src/cursed/editor.lua` — emits `before_save` event in `Editor:save()`
- `src/cursed/spell.lua` — registers handler that warns about remaining misspellings
- `src/cursed/spell/commands.lua` — `flyspell_correct`, `autocorrect_word`, etc.

---

### Priority: Nice-to-Have (polish / workflow)

#### 7. Abbreviation Expansion (Abbrev Mode)

**Problem:** No way to define automatic expansions as you type. Common prose
use cases:

- Typo corrections (e.g., "teh" → "the", "adn" → "and")
- Personal shorthand expansions (e.g., "sig" → "- Alexis Purslane")
- Common phrase expansion (e.g., "brb" → "be right back")

Emacs's `abbrev-mode` also provides `dabbrev-expand` for dynamic completion
of the word at point based on text in the buffer, but dabbrev is already handled
by the in-buffer completion system.

**Missing specifically:** table-driven static abbreviation expansion on
word-ending delimiters (space/punctuation).

---

#### 8. Thesaurus / Word Lookup

**Problem:** No built-in thesaurus or definition lookup.

A world-class prose editor should integrate with a word API or local thesaurus
database (e.g., WordNet, `dict` protocol, or a simple synonym file).

---

#### 9. Hyphenation

**Problem:** No automatic hyphenation at line breaks.

For justified text or narrow columns, hyphenation at syllable boundaries
produces significantly tighter word wrap. Requires a hyphenation dictionary
(same format used by TeX / LibreOffice / hunspell).

**Not trivial** to implement without a hyphenation dictionary, but the
`_wrap_graph` infrastructure would be the right place to plug it in.

---

#### 10. Markdown Live Preview / Outline Folding

**Problem:** No integrated preview or structure folding.

Cursed has `mdview.lua` (a demo overlay that renders markdown to styled
termbox output), but it's not integrated as an interactive mode:

- No toggle-preview command (shows rendered version in-place or in a split)
- No heading folding (toggle visibility of section content)
- No integrated table-of-contents navigation

Tree-sitter's structured parse tree makes all of these straightforward to
implement.

---

#### 11. Sentence-End Customization

**Problem:** The sentence textobject uses a hard-coded pattern
(`[!.?][ \n]`) that isn't configurable per-mode or per-user.

This means abbreviations like "Mr. Smith went home" are parsed as a sentence
boundary after "Mr.", which breaks `kill-sentence`, `forward-sentence`,
`mark-sentence`, etc.

Emacs provides `sentence-end` (a configurable regexp) and `sentence-end-double-space`
(a flag requiring two spaces after a period to end a sentence).

---

#### 12. Auto-Capitalization

**Problem:** No automatic sentence-initial capitalization while typing.

When `auto-fill-mode` is active, Emacs automatically capitalizes the first
letter after sentence-ending punctuation. This is a small touch that makes
a noticeable difference for prose entry speed.

---

## Ranking Summary

| # | Feature | Priority | Effort | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | Fill-paragraph (M-q) | **Critical** | Medium | ✅ **Done** | `commands.fill_paragraph`, bound to `alt-q` |
| 2 | Auto-fill-mode | **Critical** | Medium | ✅ **Done** | `modes/auto_fill.lua`, toggle via `toggle_auto_fill` |
| 3 | Visual-line home/end | **Critical** | Small | ✅ **Done** | `ctrl-a`/`ctrl-e` bound to visual-line variants when `visual-movement` mode is active; logical by default |
| 4 | Visual-line-mode toggle | **Important** | Small | ✅ **Done** | `modes/visual_movement.lua`, `toggle_visual_movement` command |
| 5 | Word count | **Important** | Trivial | ✅ **Done** | `cursed/word_count.lua` + `word-count` minor mode with goal tracking |
| 6 | Spell-check-on-save | **Important** | Small | ✅ **Done** | `before_save` event + handler in spell.lua |
| 7 | Transpose-chars | **Important** | Trivial | ✅ **Done** | `transpose_chars` command + ctrl-t binding |
| 8 | Abbrev expansion | Nice-to-have | Medium | ❌ | Table + post-self-insert hook |
| 9 | Thesaurus | Nice-to-have | Medium | ❌ | Pipe to `dict`/WordNet |
| 10 | Hyphenation | Nice-to-have | Large | ❌ | Dictionary + wrap-graph hook |
| 11 | Markdown preview | Nice-to-have | Large | ❌ | Uses existing mdview |
| 12 | Sentence-end config | Nice-to-have | Small | ❌ | Config var + textobject param |
| 13 | Auto-capitalization | Nice-to-have | Small | ❌ | Post-self-insert hook |

## What Makes This Editor Uniquely Suited for Prose

Several existing architectural strengths make cursed an unusually good base for
these additions — significantly better than most terminal editors:

- **The `_wrap_graph` / `wrap_width` infrastructure** already handles word-boundary
  detection at arbitrary widths. Fill-paragraph is essentially `_wrap_graph`
  applied to buffer text instead of display.
- **The piece-table buffer architecture** makes inserting/deleting line breaks
  during fill a cheap operation (it's just altering the table).
- **The overlay system** already paints squiggles, diagnostic lines, and hover
  popups — the spell-check UI is just one overlay consumer among many.
- **The event bus** (`event_system.lua` with `on()`/`emit()`) makes it trivial
  to add before-save hooks, post-insert hooks, and other prose plumbing without
  touching core render or command code.
- **Tree-sitter awareness** means fill-paragraph can skip code blocks, front
  matter, and YAML/TOML metadata automatically.
- **The Advising system** (`advice.lua`) lets users or modes wrap existing
  commands to add visual-line awareness, auto-fill, or any other prose
  behavior without forking the command source.
- **Multiple cursors compose with every command**, so filling a paragraph with
  cursors on every line works naturally.

---

*Generated from codebase audit — 2026-07-12*
