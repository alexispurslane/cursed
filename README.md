# cursed

A terminal text editor, embedded in LuaJIT.

Cursed is an Emacs-philosophy editor whose entire runtime is a single
ahead-of-time-compiled LuaJIT binary. The editor core — piece-table
buffers, multi-cursor editing, an asynchronous tree-sitter highlighter,
Emacs-style keybindings and chord dispatch, an advice/event
extensibility layer, and a major-mode system — is plain Lua running in
the LJS interpreter, bound via FFI to vendored C libraries (LuaJIT,
tree-sitter + a set of language grammars, termbox2, and TRE). The LuaJIT
JIT is used; everything is statically linked; no Lua files ship at
runtime.

> The rockspec blurb still reads "written in Teal" — that is stale.
> Source is plain `.lua` with LDoc type annotations edited under
> [lua-language-server](https://github.com/LuaLS/lua-language-server). The
> binary distribution is pure LuaJIT.

---

## Design philosophy

Cursed is built on a small set of strong opinions.

**1. A live Lisp image, not a frozen binary.**
Exported modules are mutable Lua tables preloaded into the interpreter.
Like `~/.emacs`, your `init.lua` runs against the *live* editor image,
not a sandbox: it can reach the global `editor`, `require` any core
module, push background tasks onto the frame loop, register event
listeners, and `Advice.add` around any function in any module. Nothing is
private to "the binary"; if a module exports it, you can override it
from `M-:` or `init.lua`. The AOT bytecode pipeline is a packaging
mechanism, not a wall.

**2. Real OS concurrency for editor-internal work.**
Each long-running subsystem lives in its own pthread + `lua_State`, and
lanes communicate only with main — never with each other — over
single-producer/single-consumer lock-free ring buffers woken by `kqueue
EVFILT_USER`. This gives true parallelism for file I/O and syntax
highlighting with no mutexes on the hot path and no GC sharing of Lua
tables across threads (flat C arrays cross the boundary instead).

**3. Piece table + mmap'd original buffer; the main lane is the sole
writer.**
On load the IO lane `mmap`s the file page-aligned and hands the pointer
back untouched; the editor builds a piece table over it. Edits land in a
growable "add buffer"; the original buffer is immutable. Because only the
main thread ever mutates text, readers in other lanes see a consistent
document via seqlocks (or, for the highlighter, an explicit snapshot
agreed on per request).

**4. Emacs as the default key contract; terminal emulator as the window
manager.**
Keybindings are Emacs-style (`C-a`, `C-e`, `M-b`, `C-x C-s`, …) parsed by
a chord trie with full prefix chords and universal-argument
(`C-u`) support. Window splitting is an **intentional non-feature**:
splitting panes is the terminal emulator's job (e.g. Ghostty). The
editor's job is fast, correct single-window editing of text.

**5. Tree-sitter ahead of Emacs; async ahead of nvim.**
A dedicated highlight lane holds the parsers, queries, and incremental
parse trees; never blocks the UI; degrades gracefully via parser
timeouts and bounded per-bucket query regions rather than a whole-file
kill switch; and incrementally re-parses edits with `Tree:edit`.

**6. Everything composes through events and advice.**
A central `editor.event_system` hub broadcasts lifecycle (`pre_command_hook`,
`post_command_hook`, `mode_enter` / `mode_exit`, per-mode
`mode_enter:<name>` variants, `ring_buffer_message`). Universal
advice (`:before` / `:after` / `:around` / `:filter_args` /
`:filter_return`) is a generic fold of self-describing steps installed
transparently into a shared module slot — meaning N packages can wrap the
same function without coordinating, exactly like Emacs `advice-add`.

---

## Architecture

### Lanes

```
         ┌──────────────────────────────────┐
         │            Main Lane              │
         │  termbox2, buffer, rendering     │
         │  sole writer of the piece table  │
         │  reads inboxes each frame         │
         └───┬──────────┬──────────┬────────┘
         outbox↓    outbox↓    outbox↓
    ┌───────────┐ ┌─────────┐ ┌─────────┐
    │ Highlight │ │   I/O   │ │(future) │
    │   Lane    │ │  Lane   │ │ lanes   │
    └─────┬─────┘ └────┬────┘ └─────────┘
          │spans         │file replies
          ▼              ▼
        inbox_hl       inbox_io
```

Each lane is a `lua_State` in its own pthread, spawned from `main.c`. The
main lane owns termbox2, the piece table, rendering, and keybinding
dispatch; it is the hub — all communication is main ↔ lane, never lane ↔
lane.

### Frame loop

```
1. select(ttyfd, kqueue_fd, wake_pipe) with a deadline
2. drain kqueue events (inbox_io, inbox_hl, resize)
3. process all buffered termbox events through the chord trie
4. drain ring-buffer inboxes a second time (closes a macOS select race)
5. tick one background task (round-robin)
6. minibuffer on_change, blink timer, scroll-to-cursor
7. render
8. goto 1
```

### Shared memory

All cross-lane memory is C-allocated and passed as raw FFI pointers.
Single-writer regions need no mutex — only seqlocks where a reader can
observe an in-flight write. Lock-free SPSC ring buffers carry typed
messages (`MSG_FILE_LOAD`, `MSG_FILE_LOADED`, `MSG_HL_QUERY`,
`MSG_HL_SPANS`, …) with `ptr` payloads (heap-allocated structs the
receiving lane frees via `wrap_gc`).

See [`docs/plans/core.md`](docs/plans/core.md) for the full shared-state
layout and [`docs/highlight-async-design.md`](docs/highlight-async-design.md)
for the highlight lane's design.

---

## Features

### Text model

- **Piece table over an mmap'd, page-aligned immutable original buffer.**
  Loading a file costs one read-only `mmap`; edits only ever touch a
  growable "add buffer" and the piece vector.
- **Line-addressed piece table** — each logical line owns a vector of
  `(buf_id, off, len)` pieces for O(log n) per-line random access.
- **Multi-cursor editing.** Each cursor carries its own mark, selection,
  and goal column; motions and edits (including region replace via
  `replace_selections`) fan out across all cursors. Alt-click adds a
  cursor; pending cursors commit on a real edit.
- **Snapshot undo/redo** with per-view edit grouping: consecutive
  alphanumeric inserts coalesce; line-joining deletions break groups;
  motions close the active group. Mid-keystroke highlighting is
  incremental and multi-cursor-aware.
- **Soft wrap** (byte-based, screen-width aware — see Roadmap for the
  grapheme-aware refinement).
- **Kill ring** with consecutive-kill merge, **incremental search**
  (`C-s` / `C-r`), **query-replace** (`M-%`), and POSIX regex search
  (vendored [TRE](https://github.com/laurikari/tre), non-backtracking).

### Input & keybindings

- **Chord trie** built from plain Lua tables (`["ctrl-x","ctrl-s"]`).
  Supports arbitrary prefix chords, full-key dispatch, and trie rebuild on
  mode change.
- **Universal argument** (`C-u`) — prefix-repeat and `M-digit` numeric
  arguments passed as varargs to vararg commands; per-command behaviour
  (self-insert repeats N times, motions move N cells, etc.).
- **ESC/Alt disambiguation** with a 50 ms timeout; **mouse** support
  (click-to-position incl. wrapped-row conversion, wheel scroll,
  alt-click multi-cursor).
- **Emacs-style default bindings**, overridable globally from `init.lua`.
  Commands are addressed by name (`"forward_char"`) and resolved from the
  commands table at dispatch, so command names stay stable across binds.

### Syntax highlighting

- **Asynchronous tree-sitter highlighter** on its own pthread + kqueue.
  The lane owns every `TSParser`, `TSQuery`, `QueryCursor`, and parse
  tree; the main thread only declares *intent* (language, query source,
  monotonic view id) and receives flat `struct HlSpan[]` arrays back.
- **Two-layer lane state cache** — `per_lang[language]` keeps the
  reusable parser/query/cursor; `per_lang[lang].docs[view_id]` keeps the
  per-document `old_tree`, last-text, and generation counter. Buffer
  swaps and language swaps both cold-parse safely without disturbing
  unrelated documents.
- **Incremental parsing** via `Tree:edit` + `parse_string(text, old_tree)`
  with generation-based desync detection — when main races a query past
  the lane, the lane falls back to a cold parse.
- **8 KiB byte-aligned bucketing** — fixed-size buckets make viewport
  math trivial and keep query cost flat on huge single-line files. The
  main lane computes viewport buckets every frame and queries absent
  ones, expanding outward in idle ticks.
- **Absolute-byte span responses** with render-time byte→line mapping,
  which is what makes the fire-and-forget, last-wins cache correct: a
  stale span briefly colours the wrong characters for one round trip
  only.
- **Composite-language / split-parser support** (used by Markdown): the
  block grammar parses document structure and emits inline ranges; the
  pipeline then calls `ts_parser_set_included_ranges` on a separate
  inline parser, parses those exact spans, and merges both capture
  streams onto one stack.
- **No whole-file kill switch.** Per-bucket parser timeouts degrade to
  "this bucket is sparse right now", never "this buffer never
  highlights".

### Major modes & language surface

Built-in modes (declarative `MajorModeSpec`: indent settings, language,
`highlight_query`, textobjects):

| Mode       | Grammar        | Highlights | Notes                                    |
|------------|----------------|------------|------------------------------------------|
| base       | —              | —          | Catch-all (`.*`)                         |
| lua        | tree-sitter-lua| ✓          | Per-mode event handlers, block-keyword sexps |
| rust       | tree-sitter-rust| ✓        |                                          |
| c          | tree-sitter-c | ✗          | Grammar compiled in; queries TODO        |
| python     | tree-sitter-python | ✗     | Grammar compiled in; queries TODO        |
| go         | tree-sitter-go| ✗          | Grammar compiled in; queries TODO        |
| markdown   | tree-sitter-markdown (split) | ✓ | Block + inline split-parser pass      |
| bash       | tree-sitter-bash | ✗       | Grammar compiled in; mode TODO           |
| json       | tree-sitter-json | ✗      | Grammar compiled in; mode TODO           |
| toml       | tree-sitter-toml | ✗      | Grammar compiled in; mode TODO           |
| yaml       | tree-sitter-yaml | ✗      | Grammar compiled in; mode TODO           |
| zig        | tree-sitter-zig(?) | ✗    | Grammar compiled in; queries TODO        |
| makefile   | tree-sitter-makefile(?) | ✗ |                                          |

Each mode can register its own `mode_enter:<name>` / `mode_exit:<name>`
event listeners; mode specs are unsandboxed (built-in spec files run their
top level after `_G.editor` exists). Textobjects are defined per-mode
(`MajorModeSpec.textobjects`: word-boundary patterns, paired-delim
sexps, block-keyword sexps) and drive `move_word` / `select_range` /
the sexp commands.

### Extensibility

- **Unsandboxed `init.lua`** at `~/.config/cursed/init.lua` (and user
  mode files at `~/.config/cursed/modes/<name>.lua`) running against the
  live editor. Add or override modes, rebind keys, register listeners,
  install advice.
- **`Advice` module** (`:before`, `:after`, `:around`, `:filter_args`,
  `:filter_return`, plus the ability to add new combinators with zero
  change to core). A callable-table wrapper installed into a shared
  module slot; because `require` returns a singleton, the wrap is visible
  to every caller — transparent stackable advice, not just for commands.
  `Advice.remove` by function identity, auto-restoring the slot when
  empty.
- **Central `EventSystem`** with `pre_command_hook` /
  `post_command_hook`, `mode_enter` / `mode_exit` (+ per-name variants),
  `ring_buffer_message`, and arbitrary user events. Default consumers
  are wired in `cursed.editor_listeners`.
- **`last-command` / `repeat`** (`C-x z`) and **`repeat-complex-command`**
  rerunning the last command-with-universal-args; **kmacro** record/playback
  (`start_kmacro` / `end_kmacro` / `run_kmacro`).
- **Minibuffer** with `M-x`, `find-file`, `switch-to-buffer`, `yes/no/all`
  prompts, command/theme completers, and an `eval` (`M-:`) against `_G`
  with live result display.
- **Configurable keymaps are just Lua tables** — `global-set-key`-style
  conveniences are planned wrappers on top, not a `Keymap` class.

### Rendering & display

- **termbox2** in truecolor (probed; falls back to 256-colour then 8),
  double-buffered.
- **Full-repaint per frame** — pragmatic and correct for current sizes;
  damage tracking and grapheme-aware wrap math are on the roadmap.
- **Modeline** (`path* | L# C# | NN%`), **minibuffer** (prompt + up to 5
  completions + metadata column), **cursor blink** with reset-on-input, and
  **hardware caret hidden** in favour of reverse-video cells.
- **Always-on line numbers** with an `active` slot reserved.

### Theming

- **Base16 scheme loader** at `~/.config/cursed/themes/`. Two shipped
  schemes: `base16-gruvbox-dark.yaml` (tinted-theming) and
  `gruvbox-dark-medium.yaml`, plus a built-in `gruvbox-dark-medium`
  fallback.
- **Truecolor ↔ 256-colour quantization** keyed off the probed output
  mode; the active scheme is exposed globally as
  `require("cursed.colorscheme").active` so the highlighter resolves
  capture names at query time.
- **Concept→slot overrides** (`config.concept_slots = { keyword =
  "base0D", modeline_bg = "base02" }`) honored across startup *and* live
  `load-theme` switches.
- `load-theme` is an `M-x` command sharing the same search dirs at
  runtime.

---

## How it works

1. `main.c` creates a `lua_State`, registers a single `require` hook that
   finds modules by name in a preloaded table, then runs `main.lua`.
2. Every `.lua` under `src/` is ahead-of-time compiled to a bytecode C
   header (`luajit -b`) and statically embedded; `modules.inc` maps
   dotted module names to the bytecode byte arrays. No Lua files ship at
   runtime — but the modules behave exactly like any other Lua value
   once loaded.
3. `main.c` statically links `libluajit.a`, tree-sitter lib + bundled
   grammars, termbox2, and TRE into one standalone binary.
4. At startup `main.lua` initialises termbox2, loads config/themes,
   builds the chord trie, exposes `_G.editor`, opens CLI args through the
   IO lane (creating one view per file, recycling the initial scratch
   view for the first file), and enters the frame loop.

---

## Build

Only a C compiler (`clang`/`gcc`), `make`, and `just` are required —
LuaJIT, tree-sitter, the grammars, termbox2, and TRE are all vendored.

### Prerequisites

- [just](https://github.com/casey/just)
- clang or gcc
- [StyLua](https://github.com/JohnnyMorganz/StyLua) and
  [lua-language-server](https://github.com/LuaLS/lua-language-server) (for `just check`)

### Commands

```bash
just          # build release binary → build/cursed
just debug    # build with debug symbols
just run      # build and run          (just run file.c -- arg)
just check    # fmt-check + lua-language-server
just fmt      # format with stylua
just docs     # generate LDoc docs
just clean    # remove build/
```

### Running

```bash
just run            # open a fresh scratch buffer
just run path/to/file.lua   # open one or more files
```

---

## Configuration

Cursed reads from `$XDG_CONFIG_HOME/cursed/`:

```
~/.config/cursed/
├── init.lua              # unsandboxed entry point; runs against _G.editor
├── modes/                # *.lua → user major modes / overrides
└── themes/               # *.yaml / *.toml base16 schemes
```

`init.lua` returns a config table:

```lua
return {
  colorscheme = "gruvbox-dark-medium",   -- name or absolute path
  concept_slots = { keyword = "base0E" }, -- concept → base-slot overrides
  keybindings = { ["ctrl-x ctrl-c"] = "quit" },  -- global overrides
  modes = {
    mything = MajorMode { name = "mything", tab_width = 2, language = "lua", ... },
  },
  file_patterns = { { "%.th$", modes.lua } },  -- ordered; later wins
}
```

Mode spec files run **after** `_G.editor` exists and can register
per-mode event handlers directly:

```lua
-- src/cursed/modes/lua.lua  (or ~/.config/cursed/modes/lua.lua)
editor.event_system:on("mode_enter:lua", function(_ed, instance, _view)
  instance._entered_at = os.time()
end)
return { name = "lua", language = "lua", tab_width = 4, ...,
         highlight_query = [[ (identifier) @variable ... ]],
         textobjects = { word = TO.pattern("[%w_]+") } }
```

Transparent advice from anywhere in the process:

```lua
local cmds = require("cursed.commands")
local Advice = require("cursed.advice")
Advice.add(cmds, "forward_char", Advice.around, function(next, view, editor, ...)
  editor.status_message = "forwarding"
  return next(view, editor, ...)
end)
```

---

## Project layout

```
src/
├── main.c                       # lane bootstrap, LuaJIT embed, preload hook
├── cursed/
│   ├── main.lua                 # frame loop, key dispatch, inbox drains
│   ├── shared_state.h           # ring buffers, seqlocks, lane kq fds
│   ├── buffer.lua / _ffi.lua    # piece table, undo, search, mmap text model
│   ├── view.lua                 # cursor(s), wrap, selection, hl cache, motions
│   ├── editor.lua               # orchestration, render, minibuffer/isearch/qreplace
│   ├── highlight_lane.lua       # async tree-sitter: per-lang cache, incr parse
│   ├── highlighter.lua          # legacy sync path (library; superseded by lane)
│   ├── io_lane.lua              # async file load/save/insert via mmap
│   ├── ts.lua                   # tree-sitter bindings + lang dispatch
│   ├── keybind.lua              # chord trie, token parsing, universal arg
│   ├── advice.lua               # transparent universal advice (fold of steps)
│   ├── event_system.lua         # central hook-list hub
│   ├── editor_listeners.lua     # default consumers wired to the hub
│   ├── major_mode.lua / modes  # declarative MajorModeSpec + built-in modes
│   ├── commands.lua             # command table (name → fn)
│   ├── default_keybindings.lua  # Emacs-style default binds
│   ├── colorscheme.lua          # base16 loader, truecolor/256 resolution
│   ├── config.lua               # init.lua + user mode file loader
│   ├── minibuffer.lua / completers.lua
│   ├── kill_ring.lua, textobject.lua, default_textobjects.lua
│   ├── universal_arg.lua, advice.lua, find_file.lua
│   ├── kqueue.lua, posix_ffi.lua, termbox2_ffi.lua, tre_ffi.lua
│   ├── treesitter_ffi.lua, tb.lua, gc.lua, log.lua
│   └── modes/*.lua              # base, lua, rust, c, python, go, markdown, …
vendor/                          # luajit, tree-sitter-lib, grammars, termbox2, tre
themes/                          # shipped base16 schemes
docs/                            # design + future-work reports
```

---

## Roadmap

The full architectural survey and per-item status lives in
[`docs/future-work-report.md`](docs/future-work-report.md). Summary:

### High-leverage investments

1. **Allocless cross-thread buffer sharing** — the one genuinely-open
   architectural question. The highlight lane currently receives a
   per-keystroke O(doc) text snapshot; a C/FFI-shared buffer arena
   (RWLock'd, pointed-to from Lua wrappers) would retire that copy and
   indirectly fix zero-alloc line text.
2. **Shared parse tree between highlight lane and main, mutex-guarded** —
   closes the biggest tree-sitter constraint (no parse tree on the main
   thread). Invariant: main never writes — only reads for
   tree-sitter-driven user inputs (indent, imenu, xref, structural
   textobjects). Unblocks a large cluster: syntax-aware indent,
   tree-sitter textobjects, goto-def.
3. **Central event system + universal advice** — ✅ **DONE.** The hub,
   command-hook / `ring_buffer_message` / mode-event producers, and
   default logging consumers are all in place; `init.lua` and `M-:` are
   unsandboxed; advice composes per-function.

### Near-term correctness & performance

- **Zero-alloc line text** — `line_text()` allocates a Lua string per
  line per render; pathological for huge lines. Follows from
  allocless sharing.
- **UTF-8-aware cursor + rendering** — cursor is byte-oriented; breaks
  on CJK/combining marks. Needs a `display_width(byte)` helper threaded
  through wrap math, paint, and mouse-click conversion.
- **Cursor-disappears-on-wrapped-rows bug** — concrete render bug.
- **Damage tracking: rerender from first cursor down** — partial-damage
  scheme, simpler than a glyph matrix.
- **Page-up/down piece-table compaction** — piggyback coalescing onto
  page navigation.

### Language & highlighting surface

- **Highlight queries for C, Python, Go** — grammars compiled in,
  queries missing (only Lua, Rust, Markdown highlight today).
- **Modes for bash, json, toml, yaml** — grammars compiled in, no modes.
- **Tree-sitter-driven textobjects with pattern fallbacks** — pass the
  active parser as a default arg; patterns/sexps ignore it.
- **Predicate evaluation in TS queries** — currently predicate-free;
  limits nuanced highlighting vs nvim-treesitter. Not blocked on a
  library upgrade — a contained ~100–300 line feature against the
  already-cdef'd API.
- **Overlay abstraction in screen-coordinate space** — overlays above
  highlighting, sidestepping priority-vs-tree-sitter tangling; unblocks
  flymake/flyspell/prettify-symbols.

### Async subsystem surface

- **Parser timeout on the highlighter lane** — gated on bumping the
  vendored tree-sitter (`ts_parser_set_timeout_micros` is absent at the
  currently-cdef'd API version). Desired safety net for pathological
  input.
- **Subprocess management thread** — LSP, grep, language tooling all
  need this; the IO lane only does open/mmap/write today. Tractable now
  that the event system exists.
- **Timers via `_background_tasks`** — retire the ad-hoc
  blink/chord/watchdog deadline machinery into something schedulable.
- **Subprocess-backed features: occur mode + writable project-wide grep.**

### Extensibility gaps (larger)

- **Recursive-edit** — the main loop can't nest today.
- **Input methods.**
- **Minor-mode-map layering as a distinct stack** — partly collapses
  into "convenience for adding keys to modes" + the event system.

### Intentional non-features

- **Window splitting** — the terminal emulator handles windowing. A
  defensible architectural choice, not a deficiency.
- **Dynamic grammar loading** — grammars are statically linked to avoid
  the Emacs grammar ABI-break-on-update pain; runtime-loaded parsers
  are a possible later distribution mechanism, deliberately deferred.
- **A `package.path`-style package manager** — not in scope.

### Acknowledged risks (no timeline)

- A native crash in any lane kills the whole process (no subprocess
  fault isolation).
- `ring_push`'s false-on-full return goes unchecked by callers.
- macOS-only kqueue (no eventfd/epoll) — portable to Linux/BSD requires
  an abstraction over the wake primitive.

---

## License

MIT.
