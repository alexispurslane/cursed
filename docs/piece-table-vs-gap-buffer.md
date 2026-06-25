# Piece Table vs Gap Buffer: A LuaJIT-Centric Comparison

## 1. Data Structure Fundamentals

### Gap Buffer

A gap buffer is a single contiguous `char[]` with a "hole" (the gap) positioned at the cursor. Insertion fills the gap from the left; deletion expands it. Moving the cursor means `memmove`-ing text across the gap.

```
[ H e l l o . . . . . W o r l d ]
              ^gap       ^gap_end
```

**Invariants:**
- `buf[0..gap_start)` = text before cursor
- `buf[gap_start..gap_end)` = unused space
- `buf[gap_end..len)` = text after cursor

### Piece Table

A piece table stores the original file in an immutable **original buffer** and all inserts in an append-only **add buffer**. A *piece descriptor list* (flat array, linked list, or balanced tree) maps ordered `(buffer_id, offset, length)` triples into the logical document.

```
Original buffer: "Hello World"        (immutable, can be mmap'd)
Add buffer:      "beautiful "         (append-only)

Piece descriptors:
  [orig, 0, 6] [add, 0, 10] [orig, 6, 5]
  => "Hello " + "beautiful " + "World"
```

**Invariants:**
- Original buffer never mutated after load
- Add buffer is append-only
- Pieces reference slices of buffers; logical text = concatenation of pieces

---

## 2. Algorithmic Complexity

| Operation                        | Gap Buffer                     | Piece Table (flat list)       | Piece Table (balanced tree) |
|----------------------------------|--------------------------------|-------------------------------|-----------------------------|
| Insert at cursor                 | O(1) amortized                | O(P) to find point + O(P) shift or O(log P) insert | O(log P)             |
| Insert far from cursor           | O(distance) gap move + O(1)   | Same as above                 | O(log P)                    |
| Delete at cursor                 | O(1)                          | O(P) find + O(1) split        | O(log P)                    |
| Random char access (offset i)    | O(1)                          | O(P) linear walk              | O(log P)                    |
| Sequential scan (all text)       | O(N) — single memcpy range    | O(N + P) — N chars + P boundaries | O(N + log P)            |
| Line-number ↔ offset             | O(N) or auxiliary cache       | Augmented tree: O(log P)      | O(log P)                    |
| Undo one step                    | O(op) explicit inverse stack  | O(1) snapshot swap            | O(1) snapshot swap          |
| Multi-cursor support             | Awkward (≥2 gaps or constant moves) | Natural: each cursor is a point in piece space | Natural           |

*P = number of pieces, N = document length. In practice P ≈ number of non-contiguous edits.*

### Key Takeaway

The gap buffer is algorithmically *faster* for the hot path (insert/delete at cursor, random access, sequential scan) but *slower* when the cursor teleports (O(N)) or for undo (explicit inverse operations). The piece table's complexity is independent of N but scales with P — the number of pieces — which grows with edit count.

---

## 3. Performance Properties in Detail

### 3.1 Cache Locality

| Structure      | Sequential Read  | Random Access   | Write Locality  |
|----------------|------------------|-----------------|-----------------|
| Gap Buffer     | **Excellent** — single contiguous span (skip gap via two memcpy) | **Excellent** — O(1) index | Excellent — writes are to the same cache line |
| Piece Table    | **Moderate** — must jump between buffers at each piece boundary; prefetcher defeated | **Poor** (flat) / **Moderate** (tree) | Good — add buffer is append-only |

The gap buffer's primary performance advantage is **cache friendliness**. Modern CPU prefetchers handle the single-array access pattern near-perfectly. The piece table's piece boundaries cause cache misses. Benchmarks from the Core Dumped gap-buffer-vs-rope study show gap buffers are ~7× faster for regex search over 1 GB of text, precisely because of this locality.

### 3.2 Gap-Move Cost (Gap Buffer's Achilles Heel)

Moving the cursor across distance D costs O(D) via `memmove`. On a 1 GB file, jumping from top to bottom and typing costs 1 GB of copying. This is the dominant argument against gap buffers for large-file editing.

**Mitigation:** Circular gap buffers (as described in the Flexichain paper by Strandh et al.) reduce worst-case `memmove` by ~2× but don't eliminate it. Delayed gap movement (move only on next edit) is also common.

### 3.3 Piece Proliferation (Piece Table's Achilles Heel)

Each non-contiguous insert creates 1–3 new pieces. After heavy editing, P can reach thousands. This degrades:
- **Random access** (O(P) with flat list)
- **Sequential scan** (overhead per boundary)
- **Memory** (each piece descriptor is ~16–24 bytes)

**Mitigation:** VS Code uses a red-black tree for O(log P) access, plus line-count augmentation. Vis editor uses a flat linked list with a "last edited piece" cache that coalesces consecutive appends. Periodic "rebuilding" (flattening all pieces into a single buffer) resets P to 1.

### 3.4 Memory

| Structure      | Overhead                                               | For 10 MB file, 10 KB typed          |
|----------------|--------------------------------------------------------|---------------------------------------|
| Gap Buffer     | One buffer ≈ N + gap (typically 1.5×–2× N)            | ~15–20 MB allocated                   |
| Piece Table    | Original buffer (N) + add buffer (typed text) + piece descriptors | ~10 MB original + 10 KB add + ~160 bytes pieces |

The piece table wins for memory efficiency: the original buffer can be mmap'd (zero-copy from disk, shared with OS page cache) and the add buffer is tiny. The gap buffer always allocates N + gap_size, and doubling-resize temporarily holds 2× old size.

---

## 4. LuaJIT Implementation Analysis

This is the core of the comparison. LuaJIT's FFI changes the calculus significantly.

### 4.1 Gap Buffer in LuaJIT

A gap buffer maps **trivially** to FFI:

```lua
local ffi = require("ffi")

ffi.cdef[[
typedef struct {
    uint8_t *buf;
    size_t   cap;       -- total allocated
    size_t   gap_start; -- first byte of gap
    size_t   gap_end;   -- one-past last byte of gap
    size_t   len;       -- logical text length (cap - (gap_end - gap_start))
} GapBuffer;
]]

local gb_t = ffi.typeof("GapBuffer")
local uint8_ptr_t = ffi.typeof("uint8_t *")

--- Create a gap buffer with initial capacity.
---@param init_cap number initial capacity in bytes
---@return GapBuffer
local function gb_new(init_cap)
    local gb = gb_t()
    gb.cap = init_cap
    gb.gap_start = 0
    gb.gap_end = init_cap
    gb.len = 0
    gb.buf = ffi.C.malloc(init_cap)
    return ffi.gc(gb, function(self)
        ffi.C.free(self.buf)
    end)
end
```

**Implementation notes:**

1. **The buffer is a single `malloc`'d block** — `ffi.C.malloc` + `ffi.gc(_, ffi.C.free)` gives RAII. The JIT compiles `gb.buf[i]` reads/writes to the same machine code a C compiler would emit. No Lua table overhead at all.

2. **Gap movement is `ffi.copy`** (which lowers to `memmove`). This is a single FFI call, JIT-compiled as an intrinsic. Cost is proportional to distance, same as C.

3. **No struct-of-arrays problem.** The `GapBuffer` struct is 40 bytes (5 × `size_t` on x64) — well within the 128-byte JIT fast-path limit. Field access (`gb.gap_start`) compiles to a base+offset load.

4. **Resize uses `ffi.C.realloc`** — but you must be careful: `realloc` may free the old pointer, so the `ffi.gc` finalizer would double-free. The safe pattern is:
   ```lua
   local function gb_grow(gb, min_cap)
       local new_cap = gb.cap
       while new_cap < min_cap do new_cap = new_cap * 2 end
       -- Remove old finalizer, realloc, re-assign
       ffi.gc(gb, nil)
       local new_buf = ffi.C.realloc(gb.buf, new_cap)
       gb.buf = new_buf
       gb.cap = new_cap
       ffi.gc(gb, function(self) ffi.C.free(self.buf) end)
   end
   ```

5. **Character iteration for search/render** is a tight `for i = 0, gb.gap_start - 1 do ... end` + `for i = gb.gap_end, gb.cap - 1 do ... end` loop. The JIT fuses these into SIMD-friendly sequential accesses — comparable to C.

**Estimated lines of code for a minimal but correct implementation:** ~150–200 lines.

### 4.2 Piece Table in LuaJIT

A piece table has more moving parts. There are several implementation strategies in LuaJIT:

#### Strategy A: Pure Lua Tables

```lua
---@class Piece
---@field buf_id integer 0 = original, 1 = add
---@field offset integer byte offset into buffer
---@field length integer byte count

---@class PieceTable
---@field orig string original file content
---@field add string[] append-only chunks
---@field pieces Piece[] ordered piece descriptors
```

**Problems:**
- Each `Piece` is a Lua table: ~80 bytes overhead per table on x64 (hash part + GC header). With P = 5000 pieces, that's ~400 KB of overhead for the descriptors alone.
- `string.sub(orig, offset + 1, offset + length)` creates a new Lua string per piece per scan — garbage pressure.
- Sequential scan iterates a Lua table of tables — the JIT can optimize this somewhat, but it's stillboxed floats and table lookups, not raw pointer arithmetic.

**Verdict:** Simple to write, but performance is poor for non-trivial documents. Not recommended.

#### Strategy B: FFI Struct Arrays (Recommended)

```lua
ffi.cdef[[
typedef struct {
    uint8_t  buf_id;  // 0 = original, 1+ = add buffer index
    uint32_t offset;
    uint32_t length;
} PieceDescriptor;

typedef struct {
    uint8_t *orig_buf;
    size_t   orig_len;

    uint8_t **add_bufs;     // array of add buffer pointers
    size_t   add_count;
    size_t   add_cap;

    PieceDescriptor *pieces; // flat array of pieces
    size_t   piece_count;
    size_t   piece_cap;
} PieceTable;
]]
```

**Implementation notes:**

1. **Piece descriptors are a flat FFI array** — `PieceDescriptor` is 12 bytes (1 + 4 + 4, padded to 12 or 16 depending on alignment). A flat `pieces[i]` access compiles to a base + `i*16` offset load under the JIT. **Verify alignment:** if you pack to 9 bytes, struct copies become slow (the JIT falls off the fast path for non-power-of-2-aligned structs). Pad explicitly:

   ```c
   typedef struct {
       uint32_t buf_id;   // 0 = original, 1+ = add buffer index
       uint32_t offset;
       uint32_t length;
   } PieceDescriptor;  // 12 bytes, padded to 12 naturally
   ```

   Or even better, use `uint32_t` for `buf_id` to avoid any packing surprises. **12 bytes, 3 aligned uint32s — JIT-friendly.**

2. **Inserting into the piece array is O(P)** — you must `memmove` the tail. This is the same cost as inserting into a C array. For P ≤ ~10,000 pieces (a *lot* of non-contiguous edits), this is typically < 160 KB of `memmove`, which takes microseconds.

3. **If you need O(log P) inserts, you need a tree.** VS Code's approach (red-black tree) is possible in LuaJIT FFI, but significantly more complex. A practical middle ground is a **B-tree** or **sorted array with binary search + periodic compaction**. The vis editor deliberately chose the flat linked list, reasoning that O(P) is fine for typical edit counts.

4. **Add buffers need management.** A simple approach: a single growable `ffi.new("uint8_t[?]", cap)` that doubles on overflow. More sophisticated: slab-allocated add buffers per "edit session" (for undo granularity).

5. **The `add_bufs` pointer array** is an FFI array of pointers. You must keep a Lua-side reference to each `add_buf` FFI cdata object, otherwise the GC will free them while the `add_bufs` array still points to their memory. **This is a critical LuaJIT FFI gotcha:** the GC does not follow pointers inside cdata. Your `PieceTable` struct must either:
   - Keep the cdata refs in a companion Lua table: `pt._add_buf_refs[1] = the_cdata_obj`
   - Or allocate all add buffers via `ffi.C.malloc` and manage them manually with `ffi.gc` finalizers

   The **recommended pattern** is explicit `malloc` + `ffi.gc` per buffer:

   ```lua
   local function pt_add_buffer(pt, data, len)
       local buf = ffi.C.malloc(len)
       ffi.copy(buf, data, len)
       -- Store the malloc'd pointer in the add_bufs array
       pt.add_bufs[pt.add_count] = buf
       pt.add_count = pt.add_count + 1
       -- NO ffi.gc on the raw pointer inside the array —
       -- instead, attach a finalizer to the whole PieceTable
   end
   ```

   And the `PieceTable` finalizer walks `add_bufs` and frees each one, plus frees `orig_buf`, `add_bufs` array, and `pieces` array.

6. **`ffi.gc` RAII for the whole PieceTable:**

   ```lua
   local function pt_free(pt)
       ffi.C.free(pt.orig_buf)
       for i = 0, pt.add_count - 1 do
           ffi.C.free(pt.add_bufs[i])
       end
       ffi.C.free(pt.add_bufs)
       ffi.C.free(pt.pieces)
   end

   local function pt_new(orig_data, orig_len)
       local pt = pt_t()
       -- ... initialize fields ...
       return ffi.gc(pt, pt_free)
   end
   ```

   **Caveat:** `pt_free` must not be called if any Lua-side references to sub-cdata (e.g., someone extracted a `pt.pieces[i]` reference) still exist. In practice, the piece table is an opaque object — external code should never hold references into its internals.

7. **Sequential scan for search/render.** This is the piece table's weakest point in LuaJIT. You must iterate pieces and for each piece, iterate its bytes:

   ```lua
   local function pt_scan(pt, callback)
       for i = 0, pt.piece_count - 1 do
           local p = pt.pieces[i]
           local buf = p.buf_id == 0 and pt.orig_buf or pt.add_bufs[p.buf_id - 1]
           for j = 0, p.length - 1 do
               callback(buf[p.offset + j])
           end
       end
   end
   ```

   The JIT can optimize the inner loop (sequential byte access), but the outer loop adds overhead at each piece boundary. With P = 1000 pieces, you have 1000 loop transitions per full scan. This is measurable but usually not dominant vs. the total O(N) work for large files.

**Estimated lines of code for a minimal but correct implementation:** ~350–500 lines.

#### Strategy C: FFI for Buffers + Lua Tables for Piece List

Keep the original/add buffers as `ffi.C.malloc`'d byte arrays, but store piece descriptors in a plain Lua table of Lua tables. This avoids the `memmove` cost for inserting into the piece array but pays the Lua-table overhead per piece.

**Verdict:** A reasonable compromise for small-to-medium documents. The Lua table insert is O(P) due to the internal array shift, but the constant factor is lower than `memmove` for small P. However, the per-piece memory overhead (80 bytes vs. 12 bytes) and the GC pressure from thousands of short-lived tables make this unattractive for serious use.

### 4.3 JIT Compilation Considerations

| Concern                          | Gap Buffer                                              | Piece Table                                              |
|----------------------------------|---------------------------------------------------------|----------------------------------------------------------|
| Struct size for JIT fast-path    | 40 bytes — well within 128-byte limit                   | ~56 bytes — within limit                                 |
| Inner loop type                  | Simple `for i = a, b do buf[i] end` — JIT-friendly     | Nested: piece loop + byte loop — JIT-friendly per piece  |
| FFI struct writes in loops        | `gb.gap_start = gb.gap_start + 1` — compiled           | `pt.piece_count = pt.piece_count + 1` — compiled         |
| `memmove` calls                  | Frequent (gap moves) but single FFI intrinsic call     | Frequent (piece array shifts) but simpler, smaller moves  |
| Allocation pressure              | Rare (only on resize, ~log N times)                     | Moderate (add buffer growth, piece array growth)         |
| Short-lived FFI allocations      | None                                                    | Minimal if using flat arrays; high if using Lua tables    |
| GC pressure                      | Very low — one GB object, one malloc'd buffer          | Low-moderate — one PT object, few malloc'd buffers        |
| `ffi.gc` finalizer count         | 1                                                       | 1 (centralized) recommended                              |

**Critical warning from the LuaJIT docs:** The JIT compiler does **not** currently compile:
- Vector operations
- Non-default initialization of VLA/VLS or large C types (> 128 bytes or > 16 array elements)
- Bitfield initializations
- Calls to C functions with aggregates passed/returned by value

This means:
- **Do not pass `PieceDescriptor` structs by value to C functions.** Keep all logic in Lua.
- **Do not use FFI arrays with > 16 elements in initializers.** Allocate with `ffi.new("Type[?]", count)` and fill manually.
- **Avoid `ffi.new("Type", ...)` inside hot loops.** Pre-allocate outside. Each `ffi.new` is a heap allocation + potential GC pressure.

### 4.4 The `ffi.gc` RAII Pattern in Depth

Mike Pall explicitly designed `ffi.gc` for this use case. The pattern is:

```lua
local pt_type = ffi.typeof("PieceTable")

local function pt_new()
    local pt = pt_type()
    pt.orig_buf = ffi.C.malloc(DEFAULT_ORIG_CAP)
    pt.add_bufs = ffi.C.malloc(ffi.sizeof("uint8_t *") * DEFAULT_ADD_CAP)
    pt.pieces = ffi.C.malloc(ffi.sizeof("PieceDescriptor") * DEFAULT_PIECE_CAP)
    -- ... zero-initialize fields ...
    return ffi.gc(pt, pt_destroy)
end

local function pt_destroy(pt)
    -- Called by GC when pt becomes unreachable.
    -- Walk all sub-allocations and free them.
    if pt.orig_buf ~= nil then ffi.C.free(pt.orig_buf) end
    if pt.add_bufs ~= nil then
        for i = 0, pt.add_count - 1 do
            if pt.add_bufs[i] ~= nil then ffi.C.free(pt.add_bufs[i]) end
        end
        ffi.C.free(pt.add_bufs)
    end
    if pt.pieces ~= nil then ffi.C.free(pt.pieces) end
end
```

**GOTCHA: The GC can collect `pt` while a function still holds a `pt.pieces[i]` intermediate reference in a local.** This is the well-known "early finalization" problem (documented by Andy Wingo). The fix: always keep the owning object alive in a Lua local:

```lua
local function pt_char_at(pt, pos)
    -- WRONG: local p = pt.pieces[0] ... pt = nil ... use p  =>  GC may free pt.bu
    -- RIGHT: use pt directly, don't extract sub-cdata into long-lived locals
end
```

In practice, for a text buffer, you're unlikely to hit this because the piece table is a long-lived global object. But for short-lived piece table snapshots (undo), be careful.

---

## 5. Implementation Complexity Scorecard

| Aspect                            | Gap Buffer          | Piece Table (flat)      | Piece Table (tree)       |
|-----------------------------------|---------------------|--------------------------|--------------------------|
| Core insert/delete               | ~50 lines           | ~120 lines               | ~250 lines               |
| Gap/piece management             | ~30 lines           | ~80 lines                | ~200 lines (tree rotate) |
| Resize/realloc                   | ~30 lines           | ~60 lines (multiple bufs)| ~60 lines               |
| Undo/redo                        | ~80 lines (inverse ops + stack) | ~40 lines (snapshot swap) | ~40 lines          |
| Cursor/movement                  | ~20 lines           | ~30 lines (find piece)   | ~50 lines (tree walk)    |
| Sequential scan / render         | ~15 lines           | ~40 lines                | ~40 lines                |
| Search (regex integration)       | ~20 lines (memcpy to temp, then pcre2) | ~60 lines (stitch pieces) | ~60 lines          |
| Save to file                     | ~15 lines (memcpy gap-free region) | ~40 lines (walk pieces) | ~40 lines          |
| **Total (minimal, correct)**     | **~150–200 lines**  | **~350–500 lines**       | **~700–1000 lines**      |
| Correctness difficulty            | Low                 | Medium                    | High                     |
| Edge-case surface                 | Gap overflow, resize | Buffer refs, piece split, piece overflow | Tree invariants, rebalance |

### Specific LuaJIT Complexity Concerns

1. **Gap Buffer:** The only tricky part is the realloc dance (removing and re-adding `ffi.gc`). Everything else is straightforward pointer arithmetic. **A first-time implementer can get this right in a day.**

2. **Piece Table (flat):** The piece-splitting logic (insert in middle of piece → 3 new pieces, delete → split + remove) is fiddly. Buffer lifetime management requires discipline (always malloc/free, never let Lua GC see sub-pointers). **Expect 2–3 days including undo.**

3. **Piece Table (tree):** A balanced tree (red-black or AVL) implemented entirely in FFI is equivalent to writing it in C but without C's type system to help. Every tree rotation must correctly update augmented data (subtree char count, line count). **Expect 1–2 weeks for a correct, tested implementation.**

---

## 6. Performance Summary for LuaJIT

### Microbenchmarks (estimated, based on LuaJIT FFI performance characteristics)

All numbers are approximate for a 10 MB file, 1000 pieces in piece table, on x64:

| Operation                      | Gap Buffer            | Piece Table (flat)      | Piece Table (tree)       |
|--------------------------------|-----------------------|--------------------------|--------------------------|
| Insert at cursor (1 char)      | ~5 ns (array write)  | ~50 ns (find + memmove)  | ~80 ns (tree walk + ins)  |
| Insert far from cursor         | ~N/B ns (memmove)    | ~50 ns + O(P) shift      | ~80 ns + O(log P)        |
| Delete at cursor               | ~5 ns                 | ~50 ns                   | ~80 ns                   |
| Random char access             | ~3 ns (array index)  | ~P×3 ns (linear walk)   | ~log(P)×5 ns             |
| Sequential scan (full file)    | ~N/2 GB/s             | ~(N+P)/2 GB/s            | ~(N+P)/2 GB/s            |
| Regex search (full file)       | ~N/2 GB/s (contiguous) | ~N/3 GB/s (stitching)  | ~N/3 GB/s                |
| Undo one step                  | ~100–500 ns (inverse) | ~20 ns (snapshot swap)   | ~20 ns                   |

*Where B = memory bandwidth (~10 GB/s typical), N = file size, P = piece count.*

### What This Means in Practice

**For files < 1 MB (most source code):** The gap buffer wins on every metric that matters. Sequential scan speed, insert latency, and implementation simplicity all favor it. The O(N) gap-move is sub-millisecond for N < 1M. The piece table's advantages (O(1) undo, large-file independence) don't matter at this scale.

**For files 1–100 MB:** The piece table's independence from file size becomes important. A 50 MB gap-move is noticeable (~5 ms). But the piece table's sequential scan speed is 30–50% slower due to piece boundaries. **Choose based on your access pattern** — if you search more than you jump-and-edit, the gap buffer may still win.

**For files > 100 MB:** The piece table (or rope) is the only practical choice. Gap buffers become impractical for jump-and-edit workflows. The piece table's ability to mmap the original buffer is a major advantage — the OS handles paging, and you never copy the file into the Lua heap.

**For undo-heavy workflows:** The piece table's structural undo (snapshot the piece list — a few KB of descriptors) is dramatically simpler and more reliable than the gap buffer's inverse-operation stack. If multi-level undo is a core feature, the piece table saves significant implementation and debugging time.

---

## 7. Recommendation

### For the Cursed Project (LuaJIT Editor)

Given the project's constraints (LuaJIT, `just lint` must pass, fully annotated, immutable patterns preferred):

**Start with a piece table using flat FFI arrays:**

1. **It matches the architecture.** The project's AGENTS.md specifies "immutable patterns preferred" and "discriminated-union-style tables for state variants." The piece table's immutable original buffer + append-only add buffer is naturally immutable. The gap buffer's in-place mutation is philosophically at odds with this.

2. **Undo is structurally free.** The project's state management pattern (pure reducer functions, discriminated-union state) synergizes with structural undo. A piece table snapshot is just a `(pieces_array_ref, piece_count)` pair — swap it in and you've undone. No inverse operations to write, test, or get wrong.

3. **Large files are first-class.** mmap'd original buffer means you can open a 500 MB log file instantly. The gap buffer would need to allocate 500+ MB on load.

4. **Implementation is feasible.** A flat-array piece table (no tree) is ~350–500 lines of annotated LuaJIT. The `ffi.gc` finalizer pattern keeps memory safe. The flat array means O(P) inserts, but P is small for typical editing sessions (< 10,000 for aggressive non-contiguous editing). If P becomes a problem, compaction (flatten all pieces into a new buffer, reset to P = 1) is a 50-line function.

5. **The performance gap for small files is acceptable.** You pay ~10× per insert relative to a gap buffer (~50 ns vs. ~5 ns), but both are well below human perception (~100 ms). The sequential scan slowdown (30–50%) only matters for regex on large files, and can be mitigated by materializing contiguous spans for the regex engine.

**If and only if** you know the target is exclusively small files (< 1 MB) with Emacs-style localized editing, consider a gap buffer for its simplicity. But for a general-purpose editor, the piece table is the better foundation.
