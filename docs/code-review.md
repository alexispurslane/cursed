# Code Review — cursed editor

**Date:** 2026-07-06
**Scope:** All ~42,000 lines of non-vendor source (41,317 Lua + 1,142 C + 660 C headers)
**Method:** 5 subagent scouts using `deepseek/deepseek-v4-flash`, plus `scc` and `lua-language-server` automated analysis
**Aggregate score:** 4.6/10

---

## Overview by subsystem

| Area | Score | Lines | Key weaknesses |
|------|:-----:|:-----:|----------------|
| C Core (main.c, shared_state.h, buffer.h, FFI bindings) | **6.5/10** | ~3,500 | ABI fixed, struct-tearing fixed, thread functions consolidated |
| Core Editor (editor.lua, view.lua, buffer.lua, commands.lua, main.lua) | **5.5/10** | ~18,000 | Drain functions consolidated, run_replace stale-closure fixed, 750-line render() still monolithic |
| LSP & Threading (lsp_*.lua, proc_*.lua, highlight_lane.lua, io_lane.lua, editor_listeners.lua) | **5/10** | ~5,200 | read_buf leak fixed, waitpid logging added, applyEdit relay added, 500-line closures still open |
| UI & Input (minibuffer.lua, completion_menu.lua, whichkey.lua, overlay.lua, completers.lua, etc.) | **4/10** | ~8,000 | Completion rendering extracted, nil-comparison crash fixed, ~180 lines duplicate code removed |
| Infrastructure (utf8.lua, ts.lua, advice.lua, shared.lua, config.lua, clipboard.lua, etc.) | **6/10** | ~7,500 | Error logging added to advice, nil deref fixed in clipboard, shutdown push fixed, ownership documented |

---

## How to read this document

Each issue has a unique number (prefixed by the severity letter: C = Critical, H = High, M = Medium, L = Low, X = Cosmetic) followed by the severity label:

> **C01 [CRITICAL]** `struct LspResponse` — C header and FFI incompatible
> `shared_state.h:474` / `shared_ffi.lua:183`
>
> The C header describes `result_len` + trailing JSON bytes. The FFI describes
> `yyjson_doc*` + `yyjson_val*` pointers. Every field from offset 8 onward differs.
>
> **Impact:** No runtime crash because no C code creates LspResponse, but the C header
> is a dangerous mis-specification for anyone refactoring.
>
> **Fix:** Update `shared_state.h` to match FFI layout, or add a prominent warning
> that FFI is authoritative.

---

# Critical Issues

### C01 [CRITICAL] `struct LspResponse` — **FIXED** — C header and FFI are incompatible
**Files:** `shared_state.h:474` / `shared_ffi.lua:183`

**C header layout:**
```
offset 0:  uint32_t client_id
offset 4:  uint32_t id
offset 8:  uint32_t result_len      ← NOT in FFI
offset 12: uint8_t  error_present
offset 13: uint8_t  _pad[3]
offset 16: (end) → followed by result_len bytes of JSON
total: 16 bytes
```

**FFI layout (what actually runs):**
```
offset 0:  uint32_t client_id
offset 4:  uint32_t id
offset 8:  uint8_t  error_present   ← different field!
offset 9:  uint8_t  _pad[3]
offset 12: void    *doc             ← different!
offset 20: void    *val             ← different!
total: 26 bytes → padded to 32
```

**Impact:** C header is a dangerously misleading specification. Anyone refactoring `shared_state.h` will think the layout is one thing when it's another.

**Fix:** Update `shared_state.h` to match FFI declaration, or add a bold warning that FFI is authoritative.

---

### C02 [CRITICAL] `ring_pop` reads `entries[]` without atomic load — **FIXED** — struct-tearing UB
**File:** `shared_state.h:288`

```c
*msg = rb->entries[tail & (RING_CAP - 1)];
```

`struct Msg` is 16 bytes. The `entries` array is NOT `_Atomic`. The C standard does not guarantee that a non-atomic struct assignment is atomic — a compiler could emit two 8-byte mov instructions, and the reader could tear between them.

**Impact:** On x86-64 TSO this practically works. On ARM64, this is genuine UB with observable data corruption.

**Fix:** Use `_Atomic struct Msg` or `atomic_load_explicit` on entries.

---

### C03 [CRITICAL] `_teardown_dead()` leaks `read_buf` — **FIXED** — 64KB per LSP server crash/exit
**File:** `lsp_lane.lua:269`

`ffi.C.free(client.read_buf)` only appears in `kill_client()` (line 607), NOT in `_teardown_dead()`. The common code path for server exit (EOF in `drain()`) calls `_teardown_dead()` → leaks 64KB every time.

**Impact:** Cumulative heap leak over a long editing session with multiple LSP server starts/stops.

**Fix:** Add `ffi.C.free(self.read_buf); self.read_buf = nil` to `_teardown_dead()`.

---

### C04 [CRITICAL] `overlay.lua:file_to_screen()` — nil comparison crash — **FIXED**
**File:** `overlay.lua:~120`

```lua
local sy = view:viewport_row_for_line(line, sub_row)
if sy < 0 or sy > g.max_y then  -- sy can be nil!
```

`viewport_row_for_line` can return `nil` if the sub_row is outside the viewport. In Lua, `nil < number` raises "attempt to compare nil with number".

**Impact:** Guaranteed crash when an overlay (e.g., LSP diagnostic squiggle) targets a sub_row outside the visible viewport.

**Fix:** Add `if sy == nil then return nil end` before the comparison.

---

### C05 [CRITICAL] `shared_tree_publish` eviction — `victim_gen` starts at 0 — **FIXED**
**File:** `shared_state.h:312`

```c
uint32_t victim_gen = 0;
```

If a tree is published with `gen == 0` (e.g., the initial cold parse for a view), its gen matches the sentinel and it's always chosen for eviction before any positive-gen tree.

**Impact:** The first parse tree for a newly opened view is preferentially evicted, forcing a re-parse on the next render cycle.

**Fix:** Initialize `victim_gen = UINT32_MAX` so any valid gen beats it.

---

### C06 [CRITICAL] `find_executable` never checks X_OK — **FIXED**
**File:** `lsp_lane.lua:432-441`

```lua
local f = io.open(candidate, "r")  -- just checks readable!
```

`io.open(candidate, "r")` succeeds for ANY readable file — directories, symlinks to nowhere, non-executable scripts. This will match files that cannot actually be exec'd, causing `execvp` to fail with EACCES.

**Impact:** A non-executable file found before the real executable on PATH will cause the LSP server to silently fail to start.

**Fix:** Use `ffi.C.access(candidate, X_OK)` instead.

---

# High Issues

### H07 [HIGH] `shared.lua` pushes `MSG_SHUTDOWN` to `outbox_io` twice — **FIXED** — one should go to a different inbox
**File:** `shared.lua:62-68`

```lua
self:push(self._ptr.outbox_io, { type = shared_ffi.MSG_SHUTDOWN })
self:push(self._ptr.outbox_io, { type = shared_ffi.MSG_SHUTDOWN })  -- DUPLICATE
self:push(self._ptr.outbox_hl, { type = shared_ffi.MSG_SHUTDOWN })
```

Two consecutive pushes to `outbox_io`; the IO lane's inbox never receives a shutdown. Likely copy-paste error from when there was only one lane.

**Impact:** IO lane thread may not terminate cleanly on shutdown.

**Fix:** Route the second push to the correct inbox (e.g., `inbox_io` for the IO lane's own inbox).

---

### H08 [HIGH] Missing tree-sitter parser symbols in `vendor.h` — **FIXED**
**File:** `vendor.h:10-20`

`tree_sitter_markdown`, `tree_sitter_markdown_inline`, `tree_sitter_tsx`, and `tree_sitter_typescript` are referenced in `treesitter_ffi.lua` but never declared in `vendor.h`. With linker garbage collection (`--gc-sections`), these symbols could be stripped.

**Impact:** Potential runtime crash when loading markdown, TSX, or TypeScript files.

**Fix:** Add `extern TSLanguage *tree_sitter_*` declarations for all 4 missing parsers.

---

### H09 [HIGH] 750-line monolithic `Editor:render()` function
**File:** `editor.lua:2287-3037`

Single function handling: clamp, clear, gutter-paint, syntax-highlight, selection-overlay, cursor-overlay, indent-guide, pending-drop, modeline, eval-result, minibuffer chrome, and overlay flush — with nested function definitions (`paint_run`, `fp`, `focus_dim`) re-created every frame.

**Impact:** Impossible to understand, test, or modify safely. Performance instrumentation interspersed with rendering logic.

**Fix:** Factor into 5-7 separate methods (e.g., `render_background`, `render_gutter`, `render_content`, `render_modeline`, `render_overlays`).

---

### H10 [HIGH] `commands.lua` is ~60% copy-paste (4,765 lines)
**File:** `commands.lua`

~16 select-variant commands each repeat:
```lua
editor._extend = true
view:_begin_shift_select()
```
followed by a call to the corresponding motion. Forward/backward motion pairs differ only by sign. Could be ~10 metaprogrammatic definitions.

**Impact:** Massive maintenance burden, high risk of inconsistency when adding new commands.

**Fix:** Use a decorator/wrapper for `_select` variants; generate forward/backward pairs from a single motion primitive.

---

### H11 [HIGH] `main.lua` event loop is 850+ lines with 4 duplicated drain functions — **FIXED**
**File:** `main.lua:900-1759`

`drain_inbox`, `drain_hl_inbox`, `drain_lsp_inbox`, `drain_proc_inbox` share the identical `while msg ~= nil do editor.event_system:emit(...) end` loop structure. Message-type dispatch could be a single generic drain function with a routing table.

**Impact:** ~150 lines of duplication. Any bug in drain logic must be fixed in 4 places.

**Fix:** Replace with a single generic dispatcher in `main.lua`.

---

### H12 [HIGH] `editor_listeners.lua` — ~500 lines of event-handler closures
**File:** `editor_listeners.lua`

Diagnostic squiggle overlay (~90 lines), hover popup (~190 lines), code action gutter markers — all defined as inline closures within `register_all`. Debug logging closures `on_message`/`on_exit` are defined but never used (dead code from old callback-based LSP API).

**Impact:** Monolithic, untestable. Dead closures create confusion for maintainers.

**Fix:** Extract each handler to a named module-level function. Remove dead closures.

---

### H13 [HIGH] Massive rendering duplication: `minibuffer.lua` × `completion_menu.lua` — **FIXED**
**Files:** `minibuffer.lua`, `completion_menu.lua`

Both files independently reimplement:
- `cell_len` (3-4 lines each)
- `truncate_cells` (different implementations, same concept)
- `match_byte_set` (30+ lines, exact duplicate)
- `print_highlighted` (35+ lines, exact duplicate)
- Completion list painting (~100 lines each)
- Scrollbar rendering, selection-bar, match highlighting, metadata-column layout

**Impact:** ~300 lines of exact duplicate rendering logic. Any bug fix or improvement must be replicated in both.

**Fix:** Extract shared completion rendering into a single `completion_render.lua` or fold into overlay manager.

---

### H14 [HIGH] Four lane thread functions are copy-paste in C — **FIXED**
**File:** `main.c:105-198`

`io_lane_thread`, `highlight_lane_thread`, `lsp_lane_thread`, `proc_lane_thread` are 20-line functions differing only in the module name string. Plus 5× repetitive error cleanup cascades in `main()` (~200 lines).

**Impact:** ~300 lines of unnecessary duplication. Adding a 6th lane requires copy-pasting the same boilerplate.

**Fix:** Single `lane_thread(void *arg)` function with the module name as a parameter. Use `goto cleanup` for error handling.

---

### H15 [HIGH] `advice.lua` silently swallows errors in `before`/`after` combinators — **FIXED**
**File:** `advice.lua:109-128`

```lua
pcall(fn, unpack({ ... }))  -- error discarded
return next(...)
```

`pcall` discards the error return. Compare to `:filter-args` and `:filter-return`, which DO log errors. Same issue in `:after` combinator (line 128).

**Impact:** Debugging failures in advised functions becomes extremely difficult — errors vanish silently.

**Fix:** Log via `log.error` before discarding.

---

### H16 [HIGH] `clipboard.detect_backend()` nil dereference — **FIXED**
**File:** `clipboard.lua:22`

```lua
local uname = io.popen("uname -s 2>/dev/null"):read("*l") or ""
```

`io.popen()` returns nil on failure (no shell, no `uname`, EMFILE). `:read("*l")` dereferences nil.

**Impact:** Crash on systems without `uname` in PATH or in low-fd situations, during `require("cursed.clipboard")`.

**Fix:** Guard with `local f = io.popen(...); local uname = f and f:read("*l") or ""`.

---

### H17 [HIGH] `reap_if_done` silently masks all waitpid errors — **FIXED**
**File:** `proc_lane.lua:166-172`

```lua
if rv < 0 then
    -- ECHILD (already reaped?) — treat as exited 0
    proc.reported = true
    send_exit(proc, KIND_EXITED, 0)
    return
end
```

ECHILD, EINTR, EINVAL all produce `KIND_EXITED, 0` with no logging.

**Impact:** Could mask real errors (e.g., the child was already reaped by a different code path).

**Fix:** Log the errno at WARN level before treating as clean exit.

---

### H18 [HIGH] `run_replace` uses stale `view` closure across minibuffer yields — **FIXED**
**File:** `commands.lua:4620-4680`

`run_replace` captures `view` at invocation time, but `read_from_minibuffer` yields to the event loop. If the user switches buffers between the query and replacement prompts, the replacement runs on the stale buffer.

**Impact:** Replacement text goes to the wrong buffer.

**Fix:** Re-resolve `editor:current_view()` inside `on_submit`.

---

### H19 [HIGH] `SharedState:pop()` returns raw `ptr` cdata with no ownership semantics — **FIXED**
**File:** `shared.lua:42-55`

```lua
return {
    type = raw.type,
    arg = raw.arg,
    ptr = raw.ptr,  -- cdata pointer to malloc'd memory, no GC finalizer
}
```

Caller receives a raw `void*` cdata. No ownership info, no size, no GC finalizer. If C freed `raw.ptr` during `ring_pop`, this is a use-after-free. If it didn't, it's a memory leak because no `wrap_gc` is attached.

**Impact:** Entire `Msg.ptr` protocol relies on callers knowing the expected lifetime — no runtime safety.

**Fix:** Attach a GC finalizer, or document ownership contract per message type in a centralized table.

---

### H20 [HIGH] `process_key` function is ~287 lines and uses `goto`
**File:** `editor.lua:~610-897`

Handles: read-char interception, completion-menu dispatch, M-digit accumulation, universal-arg state machine, printable handling, trie navigation, and command dispatch. Uses a `goto feed_trie` label.

**Impact:** Control-flow over-complexity. Hard to reason about, easy to introduce bugs.

**Fix:** Split into separate functions: `process_read_char`, `process_completion`, `process_universal_arg`, `process_printable`, `process_trie_dispatch`.

---

### H21 [HIGH] `completers.lua` is a 1,352-line grab-bag
**File:** `completers.lua`

Mixes LSP completion (async bridging), symbol navigation (document + workspace), command completion, file completion, buffer-words completion, dabbrev, and mode dispatch resolver. The LSP completers alone are ~600 lines of tangled async orchestration.

**Impact:** Hard to navigate, test, or modify individual completers. All share the same module-level state.

**Fix:** Split into `completers/lsp.lua`, `completers/file.lua`, `completers/buffer.lua`, etc.

---

### H22 [HIGH] No `workspace/applyEdit` inbound handler — **FIXED**
**File:** `lsp_lane.lua` (inbound dispatch)

The client supports `workspace/executeCommand` via `request_execute_command`, but there is no inbound request handler for `workspace/applyEdit`. If the server sends `applyEdit` back, it will be logged and silently dropped.

**Impact:** Server-initiated buffer mutations silently lost.

**Fix:** Implement an inbound handler for `workspace/applyEdit`.

---

# Medium Issues

### M23 [MEDIUM] Comment-to-code ratio ~1:1 across 42K LOC
~10,699 comment lines in Lua source. ~828 LDoc annotations. Many comments explain *what* instead of *why*.

**Examples:**
- 4-line comment on a 1-line nil assignment (`editor._extend = false`)
- `advice.lua`: ~150 comment lines for ~190 code lines
- `config.lua`: 110-line module docblock
- `lsp_client.lua`: 30-44 line docstrings per function (e.g., `apply_handshake`: 84 LoC + 44 doc lines)
- `completers.lua:completers.lsp()`: 120 lines of docstring

**Fix:** Delete docstrings that repeat the function signature. Keep only *why* comments. Move design prose to `docs/`.

---

### M24 [MEDIUM] `debug.getinfo` called on every keystroke — **FIXED**
**File:** `editor.lua:~855`

```lua
local info = debug.getinfo(act, "u")
```

Called on EVERY command dispatch in the per-keystroke hot path to check if the action is vararg. `debug.getinfo` is a reflective call with non-trivial overhead.

**Fix:** Cache `isvararg`/`nparams` at command registration time.

---

### M25 [MEDIUM] `advice.__call` creates N new closures per invocation — no cache — **FIXED**
**File:** `advice.lua:85-89`

```lua
function Advice.__call(self, ...)
    local composed = self._original
    for i = 1, #self._runners do
        composed = self._runners[i].step(composed)
    end
    return composed(...)
end
```

Every advised call creates N closures (one per fold step), calls them, discards them. For hot paths like `forward_char` or `insert_char`, this is non-trivial allocation.

**Fix:** Cache the composed function, invalidate on `_runners` change.

---

### M26 [MEDIUM] `utf8.lua` Extended_Pictographic: linear 25-clause `or` chain — **FIXED**
**File:** `utf8.lua:295-318`

```lua
if cp >= 0x00A9 and cp <= 0x00AE
or cp >= 0x203C and cp <= 0x2049
-- ... 23 more clauses
```

Evaluated for every codepoint. Should use a binary-searched range table like the WIDTH0/WIDTH2 `in_table` approach already used in the same file. The codebase already has the pattern — just not applied here.

---

### M27 [MEDIUM] LSP capabilities sent as empty `{}`
**File:** `lsp_lane.lua:593`

`capabilities = {}`. The server doesn't know about `textDocumentSync`, `completionItem.commitCharactersSupport`, `offsetEncoding`, etc. The server falls back to defaults (UTF-16 position encoding, no sync).

**Impact:** Functional but suboptimal. UTF-16 offsets mean multi-byte character positions may be calculated differently than the editor expects.

**Fix:** Advertise client capabilities properly (at minimum: `offsetEncoding = "utf-8"`, `textDocumentSync.kind = Full`).

---

### M28 [MEDIUM] `M.store_diagnostics` version ambiguity
**File:** `lsp_client.lua:~1247`

```lua
version = (ver ~= 0 and ver or nil)
```

Stores `nil` for version 0. LSP spec says document version is a non-negative integer. Main sends version 0 in `didOpen`. If the server publishes diagnostics with version 0, version-gating becomes a no-op.

**Fix:** Use `version` directly, comparing against `nil` rather than `0`.

---

### M29 [MEDIUM] `spawn_or_get` — dead code from old callback API
**File:** `lsp_client.lua:333-358`

```lua
function M.spawn_or_get(_main_kqueue, servers, workspace_dir, _on_message, _on_exit)
    ...
    return { _placeholder = true, client_id = id }
end
```

NUses parameters named `_on_message`/`_on_exit` (unused). Calling convention (`_on_message, _on_exit` as positional params) doesn't match how `register_all` works now. Entire function is never called.

**Impact:** Dead code that could confuse maintainers.

**Fix:** Delete.

---

### M30 [MEDIUM] Dead closures `on_message`/`on_exit` in `editor_listeners.lua`
**File:** `editor_listeners.lua:490-498`

```lua
local on_message = function(msg) log.debug("event", "lsp message", { ... }) end
local on_exit = function(code) log.info("event", "lsp exited", { ... }) end
```

Defined, then `cid` is obtained, then these closures are NEVER used. Ghosts of the old callback-based `spawn_or_get` API. Just log calls that never fire.

**Fix:** Delete.

---

### M31 [MEDIUM] `utf8.lua` `LV_lo`/`LV_hi` mislabeled — **FIXED**
**File:** `utf8.lua:280-281`

```lua
local LV_lo, LV_hi = 0xA960, 0xA97F -- Hangul Jamo Extended-A (L)
```

This range is Hangul Jamo Extended-A, which are **L** (leading jamo) types, not LV. The function correctly classifies it as `"L"`, but the variable name is dangerous for future maintainers.

**Fix:** Rename to `L_EXT_A_lo`/`L_EXT_A_hi`.

---

### M32 [MEDIUM] ~16 mode files duplicate `tab_width=4, expand_tab=true, indent_width=4` — **FIXED**
**Files:** `modes/c.lua`, `go.lua`, `html.lua`, `json.lua`, `makefile.lua`, `python.lua`, `toml.lua`, `tsx.lua`, `typescript.lua`, `yaml.lua`, `zig.lua`

11 files each repeat:
```lua
    tab_width = 4,
    expand_tab = true,
    indent_width = 4,
```
Only `markdown.lua` (tab_width=2) differs.

**Impact:** 33 lines of identical data. Any default change requires editing all 11 files.

**Fix:** Have `MajorMode.new` inherit these from `base.lua` when not specified.

---

### M33 [MEDIUM] `log.lua` fallback filename uses `os.time()` — collision risk
**File:** `log.lua:170`

```lua
local fallback = "/tmp/cursed-" .. tostring(os.time()) .. ".log"
```

`os.time()` has 1-second resolution. Two processes in the same second collide. Also vulnerable to wall-clock changes (NTP, DST).

**Fix:** Use PID (`ffi.C.getpid()`) or a random suffix.

---

### M34 [MEDIUM] `reap_if_done` — KILL_SENT and terminal EXIT may race
**File:** `proc_lane.lua:290` / `proc_lane.lua:147`

When `kill()` sends a signal, `handle_kill` pushes `KILL_SENT` immediately, then `reap_if_done` will later push `SIGNALED`/`EXITED`. But pipe EOF could fire on a different kqueue iteration and push `SIGNALED` BEFORE `KILL_SENT`. Main-thread listeners expecting `KILL_SENT` first will see reversed ordering.

**Impact:** Confusing event order for process lifecycle consumers.

**Fix:** Queue `KILL_SENT` and defer `SIGNALED` until `KILL_SENT` has been consumed, or document the ordering.

---

### M35 [MEDIUM] `sync_open` / `sync_change` don't validate `buf:write_text_direct` return
**File:** `lsp_client.lua` (sync_open / sync_change callers)

`buf:write_text_direct()` returns `(ptr, len)`. If the buffer is closed or empty, this could return `(nil, 0)`. The lane side (`handle_doc_sync`) has `if d.text_ptr ~= nil then ... end`, but the main-side enqueueing doesn't validate before sending.

**Impact:** Could send a nil content to the LSP server on empty/closed buffers.

**Fix:** Add nil guard before enqueueing.

---

### M36 [MEDIUM] `store_diagnostics` gutter version-gating duplicated
**File:** `editor_listeners.lua:701-703, 717-719`

```lua
if cached.version ~= nil and buf.lsp_version ~= nil and cached.version ~= buf.lsp_version then
    return nil
end
```

Same 3-line guard repeated in both diagnostic and code-action gutter sign functions.

**Fix:** Extract to a shared helper on the `lsp` module.

---

### M37 [MEDIUM] `send_handshake` / `send_missing` are near-identical
**File:** `lsp_lane.lua:95-128`

Both allocate `LspHandshake`, fill fields, and push. `send_missing` is just `send_handshake` with no client object.

**Fix:** Merge into a single function that optionally handles the NULL-exe_name dance.

---

### M38 [MEDIUM] `relay_response` / `relay_notification` are near-identical
**File:** `lsp_lane.lua:170-260`

Both decode a `yyjson_doc`, malloc a C struct, copy fields, and push to the inbox. Only the struct type (`LspResponse` vs `LspNotification`) and JSON key navigated differ.

**Fix:** Single `relay_payload(client, body_text, struct_type, value_key)` helper.

---

### M39 [MEDIUM] `Buffer:line_len()` iterates ALL pieces of the line every time
**File:** `buffer.lua:189-213`

For lines with many pieces (e.g., after heavy editing), this is O(pieces). Called by many operations (view text rendering, wrap calculation, cursor clamping).

**Fix:** Cache total length on the Line struct, invalidate on piece append.

---

### M40 [MEDIUM] `string.rep(" ", w)` for background fills — allocates per sub-row per frame — **FIXED**
**File:** `editor.lua` (render path)

```lua
term:print(0, row, string.rep(" ", w), empty_bg, empty_bg)
term:print(block_x, row, string.rep(" ", block_w), row_bg, row_bg)
```

For a 100-row viewport, that's 100 string allocations per frame (60fps = 6000 allocations/sec).

**Fix:** Use a cached `wide_space` buffer.

---

### M41 [MEDIUM] `_paint_underline_profiled` — profiled clone of `_paint_underline`
**File:** `overlay.lua`

A 55-line profiled clone of a 45-line function. The profiled version adds timing instrumentation around `wrap_sub_position`, `viewport_row_for_line`, and the squiggle cell loop.

**Impact:** Double maintenance surface. Adding a feature to one requires manually duplicating to the other.

**Fix:** Conditional instrumentation inside the single function, gated at entry.

---

### M42 [MEDIUM] `completers.buffer_words` O(total_buffer_chars) per debounce — **FIXED**
**File:** `completers.lua`

On every keystroke (debounced 120ms), re-scans ALL buffers for `%w_+` tokens. For many large open files, causes periodic latency spikes.

**Fix:** Cache per-buffer token lists, invalidate only on buffer edits.

---

### M43 [MEDIUM] `fzy.lua:score()` builds per-call lowercase arrays — O(2n) per candidate — **FIXED**
**File:** `fzy.lua`

For every candidate, constructs `lneedle` and `lhaystack` tables via loop, and runs `has_match` as a pre-filter (another full iteration). For a 50k-file project, every keystroke creates 50k lowercase byte arrays, each iterated twice.

**Fix:** Precompute lowercase during index build, or generate on the fly.

---

### M44 [MEDIUM] `file_index.lua:walk_with_fts()` O(n log n) sort after each walk — **FIXED**
**File:** `file_index.lua`

File list is fully sorted after every `fts` traversal. For 100k files, this is 100k×log(100k) comparisons on every TTL expiration.

**Fix:** Sort only when new files are added, or use an insertion-sorted list.

---

### M45 [MEDIUM] `event_system.lua` has no reentrancy guard — infinite recursion possible
**File:** `event_system.lua:86-100`

The doc explicitly acknowledges: `emit("X")` from an `"X"` handler causes infinite recursion. No depth counter or reentrant flag.

**Fix:** Add a simple recursion-depth counter.

---

### M46 [MEDIUM] `config.lua:255-263` requires `_G.editor` before `Config.load()`
**File:** `config.lua`

```lua
-- require("cursed.modes") runs here during Config.load()
```

The design note says this is intentional (for the `editor` global). Creates a hidden ordering dependency: `_G.editor` must be set before `Config.load()` is called.

**Fix:** Pass `editor` as an explicit parameter to `Config.load()`.

---

### M47 [MEDIUM] `clipboard.set_if_different` reads full clipboard on every write attempt — **FIXED**
**File:** `clipboard.lua:111-116`

```lua
function clipboard.set_if_different(text)
    local current = clipboard.paste()
    if current == text then return true end
    return clipboard.copy(text)
end
```

Reads the entire clipboard (O(N) depending on OS clipboard tool). Doesn't handle `paste()` returning `nil` (no backend).

**Fix:** Drop the dedup check, or cache the last-written value in memory.

---

### M48 [MEDIUM] `running` flag — Lua reads without atomic semantics
**Files:** `shared_ffi.lua:40`, `shared.lua:82`

C header: `_Atomic bool running;` → FFI: `bool running;`. Lua code reads `self._ptr.running` as a plain memory access. LuaJIT FFI bypasses C's type system — on aarch64, could observe a stale cached value.

**Impact:** Works on x86-64 (strong ordering). Latent correctness issue on non-x86.

**Fix:** Add a C helper `shared_state_running(struct SharedState *ss)` using `atomic_load_explicit`, call it from Lua.

---

### M49 [MEDIUM] `SharedState.shared_tree` omitted from FFI struct
**File:** `shared_ffi.lua:26-41`

The FFI declaration of `struct SharedState` ends at `running` and omits `struct SharedTree shared_tree`. `ffi.sizeof("struct SharedState")` returns the wrong value in Lua. Currently no Lua code uses this sizeof, but it's a latent trap.

**Fix:** Add the full `shared_tree` field to the FFI struct declaration.

---

# Low Issues

### L50 [LOW] Four lane main loops copy-pasted across Lua lane files
**Files:** `io_lane.lua`, `proc_lane.lua`, `lsp_lane.lua`, `highlight_lane.lua`

Each contains the same ~30-line loop pattern:
```lua
while ss:running() do
    local events, n = kq:wait(-1)
    -- dispatch EVFILT_USER → pop outbox
    -- dispatch EVFILT_READ → drain fd
end
```
Message dispatch switch and `xpcall` error handling also duplicated verbatim.

**Fix:** A shared `Lane.run(kq, outbox, handlers)` wrapper.

---

### L51 [LOW] No reentrancy guard in event_system
**File:** `event_system.lua:86-100`

`emit("X")` from within a handler registered for `"X"` causes infinite recursion. The doc acknowledges this.

**Fix:** Add a recursion-depth counter.

---

### L52 [LOW] `ring_push` fires `kevent()` syscall on every push — batching missing
**File:** `shared_state.h:276-281`

Every `ring_push` fires a `kevent()` with `NOTE_TRIGGER` to wake the consumer. For batch operations (bulk highlight result delivery), only one wake is needed per batch.

**Fix:** Add a batch-push API that defers the kevent.

---

### L53 [LOW] `RING_CAP` hardcoded as literal `1024` in FFI
**File:** `shared_ffi.lua:18`

```lua
struct Msg entries[1024];  -- hardcoded literal
```

C header: `#define RING_CAP 1024`. If the C constant changes, the FFI silently diverges.

**Fix:** Generate this value or add a prominent comment warning.

---

### L54 [LOW] `shared_state_alloc` redundant zero-init for head/tail
**File:** `shared_state.h:190-200`

16 lines of `atomic_store_explicit(&ss->inbox_io.head, 0, ...)`. `calloc` already zeroes the entire struct; these are redundant.

**Fix:** Remove — `calloc` guarantees zero initialization.

---

### L55 [LOW] `_Atomic` qualifier stripped in FFI `head`/`tail` fields
**Files:** `shared_state.h:135` / `shared_ffi.lua:12`

C: `_Atomic uint32_t head; _Atomic uint32_t tail;`. FFI: `uint32_t head; uint32_t tail;`. LuaJIT `ffi.cdef` doesn't support `_Atomic`. Works because only C functions access these fields.

**Fix:** Acceptable, but document the mismatch.

---

### L56 [LOW] `View:invalidate_wrap_cache()` may leave stale `_wrap_graph_cache` references
**File:** `view.lua:2547`

Clears `_wrap_rows = nil`, `_wrap_cum = nil` but not `_wrap_graph_cache` or `_vp_row_cache`. Cache generation counters (`_wrap_gen`, `_graph_gen`) should catch staleness, but mismatch risk exists.

**Fix:** Clear all dependent caches in a single invalidation.

---

### L57 [LOW] `completers.lua:workspace_symbols()` drops first keystroke if server connecting
**File:** `completers.lua:~1148`

```lua
if cid == nil then return {} end
```

Short-circuits before `state.last_query` update. If the first keystroke arrives while `cid` is still nil (server connecting), the server is never queried for that first char — discovered only on the NEXT keystroke.

**Impact:** UX issue: first character of workspace symbol search is silently ignored during connection.

**Fix:** Store the pending query and send when `cid` becomes available.

---

### L58 [LOW] `overlay.lua:screen_to_file()` silently maps off-screen clicks to line 0
**File:** `overlay.lua:~160`

`math.min(li, view:line_count() - 1)` at line 156 clamps to valid range, but `li` could be negative (scrolled above buffer start). Silently maps off-screen clicks to line 0.

**Impact:** Off-screen overlay clicks silently accepted instead of returning nil.

**Fix:** Add a guard for `li < 0`.

---

### L59 [LOW] `minibuffer.lua:activate()` calls `on_change` with 1 arg instead of 2
**File:** `minibuffer.lua:425`

```lua
if opts.initial and #opts.initial > 0 and self.on_change then
    self.on_change(opts.initial)  -- 1 arg, no comp_index
end
```

But `_fire_on_change` passes `(text, self._comp_index)`. Inconsistent interface.

**Fix:** Use `self:_fire_on_change(opts.initial)` instead.

---

### L60 [LOW] `mdview.lua:120` uses `false` as cache sentinel for "not found"
**File:** `mdview.lua:120`

```lua
hl_cache[lang] = resolved or false
```

Then `if hl_cache[lang] ~= nil` on line 123 — `false` passes nil check. The intent is to return nil for not-found languages.

**Fix:** Use a different sentinel or check `== nil` instead of `~= nil`.

---

### L61 [LOW] `file_index.lua:159` hardcodes `FTS_SKIP` as literal `4`
**File:** `file_index.lua:159`

```lua
c.fts_set(ftsp, ent, 4)  -- FTS_SKIP
```

Breaks on systems where `FTS_SKIP` has a different value.

**Fix:** `local FTS_SKIP = pffi.FTS_SKIP` or a defined constant.

---

### L62 [LOW] `file_index.lua:58-73` `is_ignored_dir` skips all dotfiles — undocumented
**File:** `file_index.lua`

`name:byte(1) == 0x2E` skips ALL dotfiles, including `.cursed` config directories inside the workspace.

**Fix:** Document or make configurable.

---

### L63 [LOW] `lua_close(main_L)` before worker thread joins
**File:** `main.c:453`

```lua
lua_close(main_L);       -- main state freed
-- ... then cancel + join workers
```

Architecture ensures workers only use their own lua_States, so this is safe — but fragile against future refactoring where a worker might hold a reference to main's state.

**Fix:** Move `lua_close(main_L)` AFTER all thread joins.

---

### L64 [LOW] `utf8.lua` WIDTH0 table encoded as flat integer list — non-obvious format
**File:** `utf8.lua:156-262`

```lua
local WIDTH0 = { 0x0300, 0x036F, 0x0483, 0x0489, ... }
-- binary-search the sorted (lo,hi) pairs
```

Flat list where each pair is two sequential entries. The `in_table` function handles this, but the encoding is non-obvious. A `{ {lo,hi}, ... }` structure would be self-documenting but more allocation-heavy.

**Fix:** Document the flat-pair encoding in the table definition, or keep as-is with a prominent comment.

---

### L65 [LOW] `input_hook.lua:match_suffix` O(n×m) scan for long lines
**File:** `input_hook.lua:240`

`string.find(left, pat, 1)` in a loop finds the last occurrence that ends at `#left`. For long lines with many matches, this iterates ALL matches.

**Fix:** Use a reverse find or iterate from the end.

---

### L66 [LOW] Empty LSP capabilities — no client features advertised
**File:** `lsp_lane.lua:593`

Already noted in M27. Listed separately because the impact is lower (servers fall back to defaults).

**Fix:** See M27.

---

### L67 [LOW] `shared_tree_acquire` writes `*out_gen` before NULL check
**File:** `shared_state.h:343`

```lua
if (out_gen) *out_gen = 0;
if (!ss || view_id == 0) return NULL;  -- writes happen before NULL check!
```

If `ss` is NULL and `out_gen` is non-NULL, we write through `out_gen` before returning NULL. Harmless (the write to `*out_gen` happens either way), but atypical ordering.

**Fix:** Move `if (!ss || view_id == 0) return NULL;` before the `out_gen` write.

---

### L68 [LOW] `key_state` / `key_node` mutated in-place AND returned from `process_key`
**File:** `editor.lua:~610-897`

The function returns `key_state, key_node` but also mutates them in-place (tables passed by reference). Redundant return values.

**Fix:** Either mutate in-place without returning, or return new values without mutating.

---

# Cosmetic Issues

### X69 [COSMETIC] `View:p()` — one-character method name is cryptic
**File:** `view.lua:262`

Returns the primary cursor. `View:primary()` or `View:cursor()` would be clearer.

---

### X70 [COSMETIC] `editor.lua:82-96` — `blend` function shadowing and confusing `tb_` local
**File:** `editor.lua`

Parameter named `factor` but comment says "0 = color unchanged, 255 = fully target". Local `tb_` to avoid shadowing module-level `tb` is confusing.

---

### X71 [COSMETIC] `buffer.lua:215-240` — `filepath()` and `set_filepath()` use different naming convention
**File:** `buffer.lua`

Rest of the Lua API uses snake_case. These should be `get_filepath`/`set_filepath` or `filepath`/`set_filepath`.

---

### X72 [COSMETIC] `view.lua:420` — `close_edit_for_motion` takes view as param but uses `view.editor`
**File:** `view.lua`

Module-level function that takes `view` as a parameter but accesses `view.editor` internally — inconsistent with the method style of the rest of the View API.

---

### X73 [COSMETIC] Template section comments 100 dashes long in `commands.lua`
**File:** `commands.lua`

```lua
----------------------------------------------------------------------------------------------------
-- Motion commands
----------------------------------------------------------------------------------------------------
```
~30 such section dividers, each 100 dashes. Visually excessive.

---

### X74 [COSMETIC] `buffer.lua:436-500` — `build_lines_from_orig()` last-line handling misleading
**File:** `buffer.lua`

The comment "Last line" is misleading when the file ends with `\n` — it allocates a newline-only line (correct in context of piece-table model, but confusing).

---

### X75 [COSMETIC] `editor.lua:1-100` — 5 helper locals at module scope only used by render
**File:** `editor.lua`

`ui`, `blend`, `match_byte_set`, `cell_len`, `truncate_cells` are module-level helper functions only used by `render()` and modeline math. Should be local to `render_modeline` or a `render_util` sub-module.

---

### X76 [COSMETIC] `editor.lua:125-285` — modeline segment system comment-to-code ratio ~4:1
**File:** `editor.lua`

~160 lines of config + helper functions + comments for a system that could be a simple `string.format` call in 20 lines. The extensibility is nice but the verbosity is extreme.

---

### X77 [COSMETIC] `editor.lua:397-465` — `Editor.new()` has 50 fields explicitly nil-initialized
**File:** `editor.lua`

Good practice (prevents `__index` lookup) but visual noise. Grouping with blank-line separators would improve navigability.

---

### X78 [COSMETIC] `-- but termbox x/y are CELL columns` — orphaned comment fragment
**File:** `editor.lua:99`

Appears to be the tail end of a removed comment block.

---

### X79 [COSMETIC] `-- (no output)` debug artifact comment
**File:** `view.lua:~2720`

Looks like a stub or debug artifact left in the code.

---

### X80 [COSMETIC] Empty if-body in render — vestigial cursor gating
**File:** `editor.lua:~2935`

```lua
if not (mb and mb.active) then
    -- Cursor (only in main view when minibuffer is inactive)
    -- The visible caret is drawn as a reverse-video cell in the
    -- per-chunk loop above ...
end
```

Empty conditional with only a comment. Actual cursor rendering is inline in the per-sub-row loop above. The conditional was intended to gate additional cursor logic but is now vestigial.

---

### X81 [COSMETIC] `COMPLETION_TRIGGER_INVOKED` and `CODE_ACTION_TRIGGER_INVOKED` both valued `1`
**File:** `lsp_client.lua:431, 514`

Separate local constants with the same value, each used exactly once.

---

### X82 [COSMETIC] `setup_lane_globals` trailing blank lines
**File:** `main.c:63-65`

Stray empty/whitespace lines after `lua_setglobal`.

---

### X83 [COSMETIC] `gc.lua` (27 lines) not worth a separate module
**File:** `gc.lua`

Entire module is `ffi.gc` with a rename and a 5-line comment.

---

### X84 [COSMETIC] `bench.lua` and `profile.lua` could be one module
**Files:** `bench.lua`, `profile.lua`

`profile.lua` is a 55-line env-var gate around `bench.lua`. Two modules + two `require` paths when one would suffice.

---

### X85 [COSMETIC] `universal_arg.lua` 0-line module doc over-verbose
**File:** `universal_arg.lua`

24 lines of description for a 103-line module.

---

### X86 [COSMETIC] `whichkey.lua:describe_action()` returns `"(command)"` for functions — useless UX
**File:** `whichkey.lua:98`

Function actions show `"(command)"` instead of anything descriptive. Could show `fn` or the function address.

---

### X87 [COSMETIC] `default_keybindings.lua:123` — comment repeats info from line 92
**File:** `default_keybindings.lua`

Line 123: `-- ctrl-x ctrl-c` quits the editor. Line 92 already explains the keyboard_quit vs quit distinction.

---

# Automated analysis results

## `scc` (lines of code counter)

| Metric | Value |
|--------|------:|
| Lua files | 73 |
| Lua lines (total) | 41,317 |
| Lua code | 28,045 |
| Lua comments | 10,699 |
| Lua blanks | 2,573 |
| Lua complexity | 6,429 |
| C + headers | 1,142 lines |
| Estimated organic dev time | 13.74 months |
| Estimated people required | 6.45 |

## `lua-language-server` (linter)

**53 warnings total**, of which **50 are in vendored LuaJIT** and only **3 in project source**:
- `examples/picker.lua:340,341` — field injection into View without `---@class`
- `src/cursed/editor_listeners.lua:308` — undefined field `_diag_hover_visible`
- `test_lsp.lua:25,26,78,88,145` — undefined fields on `lsp` module (test file referencing internal API)

The clean lint result confirms that the *surface* of the code (syntax, type annotations, call sites) is well-formed — the problems are deeper (logic, correctness, architecture).

---

# Index

| ID | Severity | Title | File(s) |
|----|:--------:|-------|---------|
| C01 | CRITICAL | `struct LspResponse` — C header and FFI incompatible | `shared_state.h:474` / `shared_ffi.lua:183` |
| C02 | CRITICAL | `ring_pop` reads `entries[]` without atomic load — struct-tearing UB | `shared_state.h:288` |
| C03 | CRITICAL | `_teardown_dead()` leaks `read_buf` — 64KB per server crash/exit | `lsp_lane.lua:269` |
| C04 | CRITICAL | `overlay.lua:file_to_screen()` — nil comparison crash | `overlay.lua:~120` |
| C05 | CRITICAL | `shared_tree_publish` eviction — `victim_gen` starts at 0 | `shared_state.h:312` |
| C06 | CRITICAL | `find_executable` never checks X_OK | `lsp_lane.lua:432-441` |
| H07 | HIGH | `shared.lua` pushes `MSG_SHUTDOWN` to `outbox_io` twice | `shared.lua:62-68` |
| H08 | HIGH | Missing tree-sitter parser symbols in `vendor.h` | `vendor.h:10-20` |
| H09 | HIGH | 750-line monolithic `Editor:render()` function | `editor.lua:2287-3037` |
| H10 | HIGH | `commands.lua` is ~60% copy-paste (4,765 lines) | `commands.lua` |
| H11 | HIGH | `main.lua` event loop is 850+ lines with 4 duplicated drain functions | `main.lua:900-1759` |
| H12 | HIGH | `editor_listeners.lua` — ~500 lines of event-handler closures | `editor_listeners.lua` |
| H13 | HIGH | Massive rendering duplication: minibuffer × completion_menu | `minibuffer.lua`, `completion_menu.lua` |
| H14 | HIGH | Four lane thread functions are copy-paste in C | `main.c:105-198` |
| H15 | HIGH | `advice.lua` silently swallows errors in before/after | `advice.lua:109-128` |
| H16 | HIGH | `clipboard.detect_backend()` nil dereference | `clipboard.lua:22` |
| H17 | HIGH | `reap_if_done` silently masks all waitpid errors | `proc_lane.lua:166-172` |
| H18 | HIGH | `run_replace` uses stale view closure across yields | `commands.lua:4620-4680` |
| H19 | HIGH | `SharedState:pop()` returns raw ptr cdata with no ownership | `shared.lua:42-55` |
| H20 | HIGH | `process_key` function is ~287 lines and uses goto | `editor.lua:~610-897` |
| H21 | HIGH | `completers.lua` is a 1,352-line grab-bag | `completers.lua` |
| H22 | HIGH | No `workspace/applyEdit` inbound handler | `lsp_lane.lua` |
| M23 | MEDIUM | Comment-to-code ratio ~1:1 across 42K LOC | (many files) |
| M24 | MEDIUM | `debug.getinfo` called on every keystroke — **FIXED** | `editor.lua:~855` |
| M25 | MEDIUM | `advice.__call` creates N new closures per invocation — no cache — **FIXED** | `advice.lua:85-89` |
| M26 | MEDIUM | `utf8.lua` Extended_Pictographic: linear 25-clause or chain — **FIXED** | `utf8.lua:295-318` |
| M27 | MEDIUM | LSP capabilities sent as empty `{}` | `lsp_lane.lua:593` |
| M28 | MEDIUM | `M.store_diagnostics` version ambiguity | `lsp_client.lua:~1247` |
| M29 | MEDIUM | `spawn_or_get` — dead code | `lsp_client.lua:333-358` |
| M30 | MEDIUM | Dead closures on_message/on_exit | `editor_listeners.lua:490-498` |
| M31 | MEDIUM | `utf8.lua` LV_lo/LV_hi mislabeled | `utf8.lua:280-281` |
| M32 | MEDIUM | ~16 mode files duplicate same tab_width/expand_tab/indent_width — **FIXED** | `modes/*.lua` |
| M33 | MEDIUM | `log.lua` fallback filename uses os.time() — collision risk | `log.lua:170` |
| M34 | MEDIUM | KILL_SENT and terminal EXIT may race (out of order) | `proc_lane.lua:290,147` |
| M35 | MEDIUM | sync_open/sync_change don't validate write_text_direct return | `lsp_client.lua` |
| M36 | MEDIUM | Gutter version-gating duplicated | `editor_listeners.lua:701-719` |
| M37 | MEDIUM | send_handshake / send_missing near-identical | `lsp_lane.lua:95-128` |
| M38 | MEDIUM | relay_response / relay_notification near-identical | `lsp_lane.lua:170-260` |
| M39 | MEDIUM | `Buffer:line_len()` iterates all pieces every time | `buffer.lua:189-213` |
| M40 | MEDIUM | `string.rep(" ", w)` allocates per sub-row per frame — **FIXED** | `editor.lua` (render path) |
| M41 | MEDIUM | `_paint_underline_profiled` — profiled clone | `overlay.lua` |
| M42 | MEDIUM | `completers.buffer_words` O(total_chars) per debounce — **FIXED** | `completers.lua` |
| M43 | MEDIUM | `fzy.lua:score()` builds per-call lowercase arrays — O(2n) per candidate — **FIXED** | `fzy.lua` |
| M44 | MEDIUM | `walk_with_fts()` O(n log n) sort after each walk — **FIXED** | `file_index.lua` |
| M45 | MEDIUM | `event_system.lua` no reentrancy guard | `event_system.lua:86-100` |
| M46 | MEDIUM | `config.lua` requires `_G.editor` before `Config.load()` | `config.lua:255-263` |
| M47 | MEDIUM | `clipboard.set_if_different` reads full clipboard on every write — **FIXED** | `clipboard.lua:111-116` |
| M48 | MEDIUM | `running` flag — Lua reads without atomic semantics | `shared_ffi.lua:40`, `shared.lua:82` |
| M49 | MEDIUM | `SharedState.shared_tree` omitted from FFI struct | `shared_ffi.lua:26-41` |
| L50 | LOW | Four lane main loops copy-pasted across Lua lane files | `*_lane.lua` |
| L51 | LOW | No reentrancy guard in event_system | `event_system.lua:86-100` |
| L52 | LOW | `ring_push` fires kevent() syscall on every push | `shared_state.h:276-281` |
| L53 | LOW | `RING_CAP` hardcoded as literal `1024` in FFI | `shared_ffi.lua:18` |
| L54 | LOW | `shared_state_alloc` redundant zero-init for head/tail | `shared_state.h:190-200` |
| L55 | LOW | `_Atomic` qualifier stripped in FFI head/tail fields | `shared_state.h:135` / `shared_ffi.lua:12` |
| L56 | LOW | `View:invalidate_wrap_cache()` may leave stale references | `view.lua:2547` |
| L57 | LOW | `workspace_symbols()` drops first keystroke if server connecting | `completers.lua:~1148` |
| L58 | LOW | `screen_to_file()` silently maps off-screen clicks to line 0 | `overlay.lua:~160` |
| L59 | LOW | `minibuffer.lua:activate()` calls on_change with 1 arg instead of 2 | `minibuffer.lua:425` |
| L60 | LOW | `mdview.lua` uses false as cache sentinel | `mdview.lua:120` |
| L61 | LOW | `file_index.lua` hardcodes FTS_SKIP as literal 4 | `file_index.lua:159` |
| L62 | LOW | `is_ignored_dir` skips all dotfiles — undocumented | `file_index.lua:58-73` |
| L63 | LOW | `lua_close(main_L)` before worker thread joins | `main.c:453` |
| L64 | LOW | `utf8.lua` WIDTH0 table encoded as flat list — non-obvious | `utf8.lua:156-262` |
| L65 | LOW | `match_suffix` O(n×m) scan for long lines | `input_hook.lua:240` |
| L66 | LOW | Empty LSP capabilities | `lsp_lane.lua:593` |
| L67 | LOW | `shared_tree_acquire` writes out_gen before NULL check | `shared_state.h:343` |
| L68 | LOW | `key_state`/`key_node` mutated in-place AND returned | `editor.lua:~610-897` |
| X69 | COSMETIC | `View:p()` — one-character method name | `view.lua:262` |
| X70 | COSMETIC | `blend` function shadowing and confusing tb_ local | `editor.lua:82-96` |
| X71 | COSMETIC | filepath()/set_filepath() naming convention mismatch | `buffer.lua:215-240` |
| X72 | COSMETIC | close_edit_for_motion inconsistent method style | `view.lua:420` |
| X73 | COSMETIC | Template section comments 100 dashes long | `commands.lua` |
| X74 | COSMETIC | build_lines_from_orig() last-line handling misleading | `buffer.lua:436-500` |
| X75 | COSMETIC | 5 helper locals at module scope only used by render | `editor.lua:1-100` |
| X76 | COSMETIC | Modeline segment system comment-to-code ratio ~4:1 | `editor.lua:125-285` |
| X77 | COSMETIC | Editor.new() 50 fields nil-initialized — visual noise | `editor.lua:397-465` |
| X78 | COSMETIC | Orphaned comment fragment | `editor.lua:99` |
| X79 | COSMETIC | `-- (no output)` debug artifact | `view.lua:~2720` |
| X80 | COSMETIC | Empty if-body in render — vestigial | `editor.lua:~2935` |
| X81 | COSMETIC | COMPLETION_TRIGGER_INVOKED and CODE_ACTION_TRIGGER_INVOKED both 1 | `lsp_client.lua:431,514` |
| X82 | COSMETIC | setup_lane_globals trailing blank lines | `main.c:63-65` |
| X83 | COSMETIC | `gc.lua` 27 lines not worth separate module | `gc.lua` |
| X84 | COSMETIC | bench.lua and profile.lua could be one module | `bench.lua`, `profile.lua` |
| X85 | COSMETIC | universal_arg.lua module doc over-verbose | `universal_arg.lua` |
| X86 | COSMETIC | describe_action returns "(command)" for functions — useless | `whichkey.lua:98` |
| X87 | COSMETIC | default_keybindings.lua comment repeats info | `default_keybindings.lua:123` |

---

*Generated by pi subagent code review, 2026-07-06. 5 scout agents reviewing ~42,000 lines across 73 Lua files + 5 C/C header files.*
