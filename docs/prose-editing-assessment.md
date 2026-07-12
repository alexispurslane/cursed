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

**Problem:** There is no way to reflow a paragraph to a target width, and no automatic
line breaking as you type.

**This is the single biggest gap.** Without it, every line break must be managed
manually. Editing an earlier word in a paragraph leaves ragged right edges that
must be fixed by hand.

**Missing features:**

- **`fill-paragraph`** (M-q in Emacs) — reformat the current paragraph to `fill-column`.
  Handles bullet lists, numbered lists, blockquotes, hanging indents, and
  paragraph-separating blank lines.
- **`fill-region`** — apply fill to a marked region.
- **`auto-fill-mode`** — while enabled, pressing space when the cursor is past
  `fill-column` automatically inserts a line break at a word boundary. This is
  what makes prose typing feel natural.
- **`fill-column`** — an editable variable (typically 72 for prose, 80 for code).
- **`set-fill-column` / `set-fill-prefix`** — interactive setting.
- **`unfill-paragraph`** — join a paragraph back into one long line (useful before
  pasting into web forms or reflowing at a different width).

**Implementation sketch for `fill-paragraph`:**

```
1. Detect paragraph boundaries (blank-line-delimited, like the existing
   `paragraph` textobject).
2. Collect all non-blank lines in the paragraph.
3. Join them into a single string (splitting at the old line breaks).
4. Re-wrap at `fill-column` using word-boundary-aware splitting
   (the existing `_wrap_graph` logic can be reused here, just applied
   to text formatting rather than display).
5. Replace the paragraph region in the buffer.
6. Single undo group.
```

**Implementation sketch for `auto-fill-mode`:**

```
1. After every printable char insertion, check if cursor column > fill-column.
2. If so, run a mini fill-backward: find the last space before fill-column
   on the current line, replace it with a newline.
3. Best-effort: don't reflow the whole paragraph, just break the current line.
```

---

#### 2. Visual-Line-Aware Home / End

**Problem:** `ctrl-a` / `ctrl-e` (`move-line-start` / `move-line-end`) operate on
**logical** lines, not **visual** sub-rows. When soft wrap is active, pressing
home jumps to column 0 of the logical line (often far off-screen left of the
current visual row), not the start of the current visual row.

**Missing features:**

- **`move-beginning-of-visual-line`** — jump to column 0 of the current visual
  sub-row. If already at the start of a wrapped sub-row, jump to the start of
  the logical line (Emacs does this double-tap behavior).
- **`move-end-of-visual-line`** — jump to the last column of the current visual
  sub-row. If already there, jump to end of logical line.
- **`kill-visual-line`** — kill from point to end of the current visual sub-row,
  not the logical line.

**Likely home for these:** map `ctrl-a` / `ctrl-e` to visual-line-aware variants
when `visual-line-mode` is active (see next gap), or always. Emacs uses
`C-a` / `C-e` for logical lines by default and `C-a` / `C-e` for visual lines
when `visual-line-mode` is on.

---

#### 3. Visual Line Mode Toggle

**Problem:** There is no mode that makes all movement and editing commands operate
on display lines (visual sub-rows) rather than logical lines. This means many
commands misbehave at wrap boundaries.

**Features Emacs's `visual-line-mode` provides:**

- `C-a` / `C-e` → visual line start/end (rather than logical)
- `C-k` (kill-line) → kill to end of visual line
- `C-n` / `C-p` → visual line navigation (already done in cursed)
- Truncation toggle to switch between wrap and truncate display
- The cursor wraps at visual line boundaries when moving between lines

**Cursed already has** `forward_visual_line` / `backward_visual_line` and the
wrap infrastructure (`wrap_width`, `_wrap_graph`, `sub_row_runs`). What's missing
is the unified toggle + remapping of home/end/kill-line when visual mode is active.

---

#### 4. Word Count

**Problem:** No command to count words, characters, lines, or sentences.

A world-class prose editor provides a `word-count` command (or `wc`-like
functionality) accessible from M-x or a keybinding. Emacs has `M-x word-count`
and `M-x count-words` (C-x = shows point stats; M-x count-words-region).

**Implementation would be trivial:**

```lua
-- Parse the buffer (or region) into word/sentence/char counts.
-- For prose, words are whitespace-delimited tokens.
-- For markdown, optionally skip front-matter/headings/formatting syntax.
```

---

### Priority: Important (notable daily friction)

#### 5. Transpose Operations

**Note:** The drag commands (`alt-left` / `alt-right`, which move the active
selection) are **already implemented** and partially fill this role. Drag is
arguably more discoverable and visual.

**However,** single-character transpose (`ctrl-t`) is a reflex for typo fixes:

- `transpose-chars` (ctrl-t) — swap the two characters on either side of point
- `transpose-words` — swap the word before point with the word after point
- `transpose-sentences` — swap sentences

Cursed's drag commands cover the word and sentence cases (select + drag), but
the single-keystroke char transpose is a different muscle-memory use case.

---

#### 6. Spell-Check-on-Save

**Problem:** No automatic verification on save. A user can save a file with
misspellings and never know.

**Feature:** A `before-save-hook` equivalent or a `flyspell-check-on-save`
flag that re-checks the buffer and surfaces a warning (or a count) when
misspellings remain.

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

| # | Feature | Priority | Effort | Notes |
| --- | --- | --- | --- | --- |
| 1 | Fill-paragraph (M-q) | **Critical** | Medium | Reuse textobject + wrap infra |
| 2 | Auto-fill-mode | **Critical** | Medium | Post-insertion hook |
| 3 | Visual-line home/end | **Critical** | Small | Command definition + rebind |
| 4 | Visual-line-mode toggle | **Important** | Small | Binds + truncation toggle |
| 5 | Word count | **Important** | Trivial | ~30 lines of Lua |
| 6 | Spell-check-on-save | **Important** | Small | Before-save hook |
| 7 | Transpose-chars | **Important** | Trivial | ~10 lines |
| 8 | Abbrev expansion | Nice-to-have | Medium | Table + post-self-insert hook |
| 9 | Thesaurus | Nice-to-have | Medium | Pipe to `dict`/WordNet |
| 10 | Hyphenation | Nice-to-have | Large | Dictionary + wrap-graph hook |
| 11 | Markdown preview | Nice-to-have | Large | Uses existing mdview |
| 12 | Sentence-end config | Nice-to-have | Small | Config var + textobject param |
| 13 | Auto-capitalization | Nice-to-have | Small | Post-self-insert hook |

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
