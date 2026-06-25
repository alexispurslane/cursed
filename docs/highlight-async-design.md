# Async Tree-Sitter Highlighter — Design

Reference doc for implementation. Final shape agreed 2026-06-20.

## Goals

- Highlighting never blocks the UI (parse runs off-main-thread).
- No whole-doc kill switch (`MAX_HL_BYTES` is deleted).
- Graceful degradation on huge files and pathological inputs (long minified
  lines, deep nesting): parser timeout + bounded query regions.
- Fast typing latency via incremental parse.
- Lazy fill: highlight what's on screen, expand coverage in idle time.

## Non-goals (deferred, possibly never needed)

- Range-limited *parse* via `ts_parser_set_included_ranges`. Causes visible
  boundary corruption (unclosed string literals swallowing the queried
  region). Only revisit if incremental parse + timeout proves insufficient
  for some real file.

---

## Architecture: three lanes

    main lane (UI thread, today)     ──outbox_hl──▶   highlight lane (new pthread + lua_State)
            ◀──inbox_hl──

The highlight lane mirrors `io_lane.lua` exactly in shape:

- Own pthread + own `lua_State` (spawned from `main.c::create_lane_state` +
  a new `highlight_lane_thread`, twin of `io_lane_thread`).
- Blocks on its own kqueue fd (`hl_kq_fd`) waiting for `EVFILT_USER` wakes
  triggered by `ring_push` to `outbox_hl`.
- Loads `cursed.highlight_lane` bytecode via the same `find_module` +
  `preload_modules` mechanism used for `cursed.io_lane`.

### Ownership: the lane owns the parser (and the query, and the trees)

`TSParser`, `TSQuery`, and the `old_tree` live **entirely inside the
highlight lane's lua_State**. Tree-sitter parser objects are not thread-safe;
sharing them across the ring would race. Consequence: the View no longer
holds a `Highlighter`. The View only records *intent* — it remembers which
language + query string it wants, and which monotonic view id the request is
for — and sends those as plain strings/ints in messages. The lane never
reaches into the main lane's object graph (no access to `MajorMode`
instances, no `init.lua`); strings in, spans out.

### Two-layer lane state cache (so swaps don't trash everything)

The lane must NOT discard its `TSParser`/`TSQuery` every time the user
switches buffers. State is split into two layers:

```
per_lang[language] = {            -- reusable across any document of that language
    lang_ptr,                     --   built once, kept forever
    parser,                       --   (TSParser; thread-local, safe to reuse)
    query,                        --   (TSQuery; built from the query source string)
    cursor,                       --   (TSQueryCursor; reused across all queries — fixes a current bug where one is allocated per build_segments call)
    docs = { [view_id] = {        -- per (language, document)
        old_tree,                 -- the parse tree from last successful parse
        last_text,                -- the byte buffer old_tree points into (TSNode retains input)
        gen,                      -- expected gen of the next incoming edit
    } },
}
```

Switching language A→B→A: `per_lang[A]` (parser, query, cursor) is still
there; only `per_lang[A].docs[view_id]` may have been dropped depending on
whether that document was edited under a different view id in the meantime.

**Important corollary — `old_tree` is invalid across documents, not just
languages.** A tree points into a specific byte buffer; switching buffers
(same language, different text) is the more common case than language
swaps and the more dangerous one if missed. So requests carry both a
language string AND a monotonic view id; the lane treats a `view_id` it
hasn't seen before (or whose `gen` doesn't match expected) as a fresh
document: drop `old_tree`, cold parse. Both layers of dispatch — language
lookup AND per-document lookup — key off the request fields.

On `MSG_HL_INITIALIZE_LANGUAGE` (see below) for an already-known language
whose query source string has changed, the lane drops the existing
`per_lang[lang]` entry entirely (including all its `docs`) and rebuilds —
A `TSQuery` is not mutable.

The `Highlighter` class in `cursed/highlighter.lua` is repurposed: its
`build_segments` + `build_line_spans` + `resolve_fg` logic moves into the
lane (it already takes `(text, line_starts)` and returns per-line spans —
we rework it to return absolute-byte spans; see "Span format"). The View
side shrinks to: cache map + request dispatch.

---

## SharedState additions (`shared_state.h`, `shared_ffi.lua`, `shared.lua`)

Add a third ring pair + kq fd, mirroring the IO pair:

```c
struct SharedState {
    struct RingBuf outbox_io;
    struct RingBuf inbox_io;
    struct RingBuf outbox_hl;   /* main → highlight */
    struct RingBuf inbox_hl;    /* highlight → main */
    int main_kq_fd;
    int io_kq_fd;
    int hl_kq_fd;               /* highlight lane's own kqueue */
    _Atomic bool running;
};
```

`shared_state_alloc` wires `outbox_hl.consumer_kq_fd = hl_kq_fd`,
`outbox_hl.wake_ident = <fresh ident>`, symmetric for `inbox_hl`.

`main.c` creates `hl_L` via `create_lane_state()`, runs
`highlight_lane_thread`, pthread_joins it on exit. The main lane's central
kqueue (in `main.lua` ~line 565) gains an EVFILT_USER filter for
`inbox_hl.wake_ident` so a response arriving on the ring wakes the main
render loop.

Message type constants added to `shared_ffi.lua`:

```
MSG_HL_INITIALIZE_LANGUAGE = 8  /* main → hl: ptr = struct HlInitLangReq* */
MSG_HL_QUERY              = 9  /* main → hl: ptr = struct HlQueryReq* (carries view_id, lang, bucket, edit, text) */
MSG_HL_SPANS              = 10 /* hl → main: ptr = struct HlSpans* */
MSG_SHUTDOWN              = 5  /* reused */
```

`MSG_HL_INITIALIZE_LANGUAGE` (not `SET_LANGUAGE`) — we're not setting
some global current language; we're asking the lane to initialize (or
replace) a parser+query for the given (language, query_source) so that
subsequent `MSG_HL_QUERY` messages with that language string will work.
It's idempotent setup, not global state mutation. Sent by the main lane
the first time it sees a major mode carrying a `language` +
`highlight_query`, and again if the query source string for that language
changes (e.g. user config).

Note: the lane does NOT use the message to track "current document" or
"current view" — every `MSG_HL_QUERY` carries its own `(language,
view_id)` and the lane dispatches off that. `INITIALIZE_LANGUAGE` only
ensures the parser+query exist; it precedes the use of the parser+query,
it doesn't select a "current" one.

### Request payloads

All payloads are heap-allocated structs passed via `ptr`; the *receiving*
lane frees them (`wrap_gc` with `ffi.C.free` as dtor — same pattern as
`SaveRequest` in `io_lane.lua`).

`MSG_HL_INITIALIZE_LANGUAGE` — `struct HlInitLangReq` holding language name
+ query source string. Cleanest as one allocation: fixed header followed by
the variable-length query source bytes:

```c
struct HlInitLangReq {
    char     language[16];   /* grammar name: "lua", "c", ... */
    uint32_t query_len;       /* length of query source that follows */
    /* followed by query_len bytes of query source (NOT null-terminated) */
};
```
(See "Language name → parser dispatch" below for how the lane resolves
the grammar name to a `TSLanguage`.)

`MSG_HL_QUERY` — always `ptr` to a single `HlQueryReq`, regardless of
whether it's a viewport query or an edit query. The struct carries the
dispatch key `(language, view_id)`, the target bucket, the edit (or not),
and the text pointer/len:

```c
struct HlQueryReq {
    char     language[16];   /* dispatch key #1 — per_lang lookup */
    uint32_t view_id;        /* dispatch key #2 — per_lang[lang].docs lookup */
    uint32_t bucket_idx;
    uint32_t gen;            /* generation counter for desync detection */
    bool     has_edit;       /* false → cold or pure-incremental parse (no edit to apply) */
    /* The edit, in coordinates of the text the lane last parsed for this
     * (language, view_id). Ignored when has_edit is false. */
    uint32_t start_byte;
    uint32_t old_end_byte;
    uint32_t new_end_byte;
    uint32_t start_row,  start_col;
    uint32_t old_end_row, old_end_col;
    uint32_t new_end_row, new_end_col;
    /* The full current document text (snapshot taken in main lane): */
    void    *text;
    uint32_t text_len;
};
```

(Note re the `struct Msg` shape: extending it for the text pointer is not
needed — text + edit + dispatch all fit inside the one `HlQueryReq`
allocation, and `msg.ptr` carries it. Keep `struct Msg` as is.)

### Language name → parser dispatch

The `MSG_HL_QUERY` carries a `language` string but NOT a `TSLanguage`
pointer — pointers can't be sent across `lua_State` boundaries sanely, and
the lane must resolve the grammar itself. This already exists:
`cursed/ts.lua` exports a `lang` table (`{ bash = c_api.tree_sitter_bash,
..., lua = c_api.tree_sitter_lua, ... }`) and a `ts.lang_get(name)` that
returns the `TSLanguage*` or nil + error. The highlight lane just calls
`ts.lang_get(language)` to build its parser. So queries ARE configurable
(via the query source string in `HlInitLangReq`) but parsers are NOT (the
lane dispatches on the static name→entrypoint table). This asymmetry is
acceptable today: "why are queries configurable, but parsers aren't?" —
because parsers ship compiled into the binary and there's no mechanism to
load one at runtime. Future-homer problem if it ever matters.

`MSG_HL_INITIALIZE_LANGUAGE` for a language whose `lang_get` returns nil is
an init error: the lane logs and drops the request (or pushes an empty
span response, depending on how robust we want it; logging + ignore is
fine for v1).

The text is **not null-terminated** and doesn't need to be:
`ts_parser_parse_string(parser, old, buf, len)` reads exactly `len` bytes
(unlike `ffi.string`). The lane wraps the text buffer in `wrap_gc(...,
ffi.C.free)`.

---

## Span format (response)

`MSG_HL_SPANS`'s `ptr` points to:

```c
struct HlSpansHdr {
    uint32_t gen;          /* echoes request gen — main rejects if stale */
    uint32_t bucket_idx;   /* which bucket these spans belong to */
    uint32_t count;        /* span count */
    /* followed by count × struct HlSpan: */
};
struct HlSpan {
    uint32_t start_byte;   /* ABSOLUTE byte offset in the document */
    uint32_t end_byte;
    uint32_t fg;           /* resolved termbox fg attr (0xRRGGBB or 256-index) */
};
```

Absolute byte offsets (NOT line-relative). The lane does NOT compute line
membership — main lane does that at render. Stored per-bucket by start byte
(see "Cache").

Spans cover the bucket's byte range `[bucket*8192, (bucket+1)*8192)` plus
any captures that *start inside* the range but extend past it (those get
stored in the start bucket only — main lane unions all viewport-intersecting
buckets at render). Captures whose start byte is before the bucket range
are emitted by tree-sitter too (since `set_byte_range` yields intersecting
captures); the lane drops them, since they belong to an earlier bucket's
query and would duplicate.

### Flat C array, not Lua tables

Lua tables can't cross lua_State boundaries. So the lane builds a flat
`struct HlSpan[]`, mallocs, fills, sends `ptr + count`. Main lane reads
into its own Lua representation lazily (or uses the cdata directly — both
work; reading directly off cdata avoids a copy and is fine since the main
lane owns the buffer after receipt and frees it after installing into the
cache).

---

## Bucketing

Fixed-size, byte-aligned. `BUCKET_BYTES = 8192`.

- Bucket N covers bytes `[N*8192, (N+1)*8192)`.
- Number of buckets `= ceil(total_bytes / 8192)`. Recomputed when the
  total length changes; empty high bucket indices are simply GC'd out of
  the cache map.
- "Which buckets does byte range `[a,b)` intersect?" →
  `floor(a/8192) .. floor((b-1)/8192)`.

8KiB chosen so: a typical 80-col screenful is ~8KiB → one query refills ~1
bucket; a huge single-line file still produces many buckets even though
there's one line, keeping query cost flat. Viewport_byte_span is NOT used
to size buckets — the 8KiB fixed size is what makes the math trivial and
scroll extension clean.

---

## Main-lane cache

```lua
-- View fields (replace _highlighter, _hl_lines, _hl_gen, _hl_skip):
_hl_bucket_cache -- {[bucket_idx] = {span1, span2, ...} | cdata ptr}
_hl_lang         -- string|nil: currently configured language (intent only; main lane
                  --   pairs this with a view_id when sending MSG_HL_QUERY)
_hl_query        -- string|nil: current query source (intent only)
_hl_view_id      -- integer: this View's monotonic id (assigned once at View
                  --   creation; uniqueness across Views is what lets the lane
                  --   keep separate old_trees per document)
_hl_gen          -- integer: monotonic counter for this (View, language).
                  --   Incremented on every query dispatched. The lane echoes
                  --   it back; responses whose gen isn't the last we sent are
                  --   stale and dropped on receipt.
_hl_in_flight    -- HlQueryReq ptr|nil: the outstanding query, if any
_hl_pending      -- HlQueryReq ptr|nil: next query to send after in_flight resolves
_hl_total_bytes  -- mirrors buffer length, for bucket count math
```

(The View does NOT track old_tree validity — that's the lane's job,
keyed on `(language, view_id, gen)`. The View's role on edit/swap is
simply to bump gen and re-dispatch; the lane's desync detection handles
the rest.)

Two tables, no state machine, no flags:

- `cache: { [n] = spans }` — what we render from.
- `in_flight: ptr | nil` — what the lane is currently computing.
- `pending: ptr | nil` — overwrite target for after in-flight lands.

**Fire-and-forget, last-wins.** Stale spans in the cache are shown until a
fresh response arrives then atomically replaced. No invalidation flags.

### Why this is safe to render from even when stale

Spans carry absolute byte offsets; line membership is recomputed at render
from the *current* `line_starts`. Therefore:

- **Same-line edit:** unchanged bytes around the edit are still colored
  correctly; only the edited characters briefly wear the old color (~ms
  response window). Imperceptible.
- **Line split/join edit:** bytes upstream of the edit stay exactly right
  (their line index unchanged, offsets unchanged). Bytes downstream of the
  edit briefly mis-color by the size of the edit, for the response window,
  because their line assignment shifts — but the highlight lane's response
  fixes this within one round-trip. Off-by-one for ~20ms. Not noticeable.

This is the whole reason absolute byte offsets + render-time line mapping
matter: it makes the "no invalidation tracking, just replace" approach
correct.

---

## Query triggers (the entire policy)

The main lane decides when to message the lane. Three cases. No other
state.

1. **Viewport moved.** Compute viewport buckets
   `[floor(vstart/8192) .. floor((vend-1)/8192)]`. Send `MSG_HL_QUERY`
   for each bucket not already cached (or refresh-in-place if you prefer
   simpler — re-query all viewport buckets every render; the cost is one
   ring message per bucket per render, trivial). Default: refresh only
   absent ones, fall through to idle refill otherwise.

2. **Edit happened.** Compute the bucket containing the edit byte offset.
   - Same-line edit → query that one bucket.
   - Line split/join edit → query that bucket + all buckets after it.
     (Wasteful but cheap: bytes upstream are still correct, but their
     remapping through new line_starts is correct, so we *could* skip; but
     "just re-query all after" is the simplest correct rule and the lane
     can absorb the cost async. Choose this simplicity over the
     optimization.)
   The request includes the edit (so the lane does incremental parse with
     `Tree:edit`), carries a fresh `gen`.

3. **Idle tick (every ~30ms), lane not in flight.** Scan outward from the
   viewport in bucket-index order: if a viewport bucket has cached spans,
   expand one bucket left; if that's fine, expand right; etc. Pick the
   nearest absent bucket and query it. Background fill — scrolls into
   already-highlighted regions.

These three checks run every render. The "send a query" helper is:

```
if not self._hl_in_flight then
    self:_hl_dispatch(self._hl_pending or next_query)
    self._hl_pending = nil
elif not pending or pending.gen < candidate.gen then
    self._hl_pending = candidate  -- overwrite; latest wins
```

When `MSG_HL_SPANS` arrives on `inbox_hl` (wakes main kq): read the spans,
if `gen` matches the in_flight request's gen, install into the cache map at
`bucket_idx`; free the buffer; clear in_flight; if pending exists, dispatch
it.

---

## Highlight lane: incremental parsing

The lane holds the two-layer state cache described in "Two-layer lane state
cache" above: `per_lang[language]` with parser/query/cursor + a nested
`docs[view_id]` holding `old_tree`/`last_text`/`gen`. The cold parse path
drops the whole `per_lang` entry on `MSG_HL_INITIALIZE_LANGUAGE` with a
changed query source.

### Parse path (per `MSG_HL_QUERY`)

```
1. receive request: {language, view_id, text, text_len, edit?, gen, bucket_idx}
2. lang_state = per_lang[language]
   -- (built earlier by an MSG_HL_INITIALIZE_LANGUAGE; if missing, the lane
   --  sends an empty spans response and logs — should have been initialized)
3. doc_state = lang_state.docs[view_id]
   if doc_state == nil:                 -- first time we see this (lang, view_id)
       doc_state = {old_tree=nil, last_text=nil, gen=nil}
       lang_state.docs[view_id] = doc_state
4. if req.has_edit and doc_state.old_tree and doc_state.gen == req.gen - 1
       and not desynced:
       -- incremental: shift the existing tree to the new text, then reparse
       doc_state.old_tree:edit(edit)
       tree = lang_state.parser:parse_string(text, doc_state.old_tree)
   else:
       -- cold: no old tree, or gen gap means main raced past us
       tree = lang_state.parser:parse_string(text, nil)
5. set parser timeout (see below) -- actually set in Parser.new, not per parse
6. root = tree:root()
7. cursor = lang_state.cursor   -- REUSED, not allocated per call (current
   --                                   bug: QueryCursor.new() every
   --                                   build_segments call in main-lane hl)
   cursor:set_byte_range(bucket_idx*8192, (bucket_idx+1)*8192)
   cursor:exec(lang_state.query, root)
8. walk captures:
       for cap in cursor:captures():
           local sb = cap.start_byte
           if sb < bucket_start or sb >= bucket_end:
               continue   -- capture starts outside this bucket — belongs elsewhere
           append {start_byte=sb, end_byte=cap.end_byte, resolve_fg(cap.name)}
           -- (end_byte is kept true even if it crosses into the next bucket;
           --  render-time mapping clamps per-line, no need to clamp here)
9. pack into HlSpans, malloc, send back {ptr, count, gen=req.gen,
   bucket_idx=req.bucket_idx}
10. doc_state.old_tree := tree
    doc_state.last_text := text   -- GC the previous text via wrap_gc swap
    doc_state.gen = req.gen
```

Step 4's note on `gen`: the lane tracks the gen of the text it last parsed
for this `(language, view_id)`. If an incoming edit's `gen` isn't exactly
one past what the lane has, that's desync — main raced a query past us, or
an edit message was dropped → fall through to cold parse (set `old_tree =
nil`), accept this request as fresh ground truth.

### Why reparse the whole text and not "from the changed byte"

Tree-sitter does not offer "start parsing at byte X". `parse_string(text,
old_tree)` re-walks the input but reuses cached subtrees from `old_tree`
where the byte range is unchanged — so the *real work* happens at/after the
edit. Combined with `Tree:edit` to shift the old tree's coordinates to the
new text, this is the incremental-partial-reparse we want, essentially for
free. No new primitives needed; the bindings exist (`Tree:edit`,
`parse_string(text, old_tree)`) and are currently unused.

### Desync detection

`gen` is a per-`(language, view_id)` monotonic counter maintained in the
main lane (per View is sufficient; the lane only ever sees requests from
one View at a time, but it keys grudgingly off `(language, view_id)` to be
safe). Every query the main lane pushes increments gen. The lane remembers
the gen of the last text it parsed for that `(language, view_id)`. If an
incoming edit's gen isn't exactly one past the lane's, that's desync →
drop `old_tree`, cold parse.

`MSG_HL_INITIALIZE_LANGUAGE` with a changed query source string drops the
entire `per_lang[language]` entry (can't reuse a `TSQuery`; also can't
reuse trees parsed under the old query's language definition since the
grammar itself is unchanged — but the query cursor state is bound to the
query, so rebuilding is safest). A re-init with the SAME query source is a
no-op.

Buffer switches (same language, different `view_id`, different text) drop
the per-document `old_tree` for the new view id automatically on first
contact via the "doc_state == nil" branch — no explicit signal needed.
This is the more common case than language swaps and the more important one
to get right: a tree points into a specific byte buffer, and the new
buffer's bytes are unrelated.

---

## Parser timeout (new — protects against pathological input)

**Not currently in `treesitter_ffi.lua` cdefs.** Add:

```c
void ts_parser_set_timeout_micros(TSParser *self, uint64_t timeout);
```

Set in `Parser.new` or per-parse (it's a property of the parser). Suggested
value 50–100ms. When the parse exceeds it, `parse_string` returns a partial
tree; we proceed to query it anyway (better partial highlighting than
none). The bucket's spans will be fewer; the next idle refill or viewport
move re-tries. Crucially this replaces the **whole-file** `MAX_HL_BYTES`
switch: the failure mode degrades to "this bucket is sparse right now",
not "this buffer never gets highlighted".

The io_lane brute force (disable entirely >1MiB) is removed once this +
the async lane are in.

---

## Render-time byte → line mapping (new infrastructure; currently absent)

Today `line_starts` is rebuilt from scratch every full highlight parse
(view.lua:815). Under the new model, `line_starts` must be kept current for
the render loop only — it does NOT go to the highlight lane (the lane emits
absolute bytes; mapping happens on main). So:

- Maintain a **cached `line_starts` array in the View**, invalidated on any
  buffer generation change (same `_hl_generation` hook — undo+redo count +
  theme gen). Rebuild lazily on the first render after invalidation. O(N)
  on rebuild, but amortized across many span→line lookups per render.
- `span → (line, within_line_offset)` lookup is binary search over
  `line_starts` by `span.start_byte`, then advance through subsequent
  lines until `span.end_byte` (a long span can cross lines).
- This mirrors what `build_line_spans` did in `highlighter.lua`, but at
  render time, on the spans already bucketed, per visible line.

---

## `highlighter.lua` fate

The `Highlighter` class shrinks: it becomes either
(a) deleted, with its `build_segments` + `build_line_spans` logic split
between the highlight lane (segments-from-captures, with the per-bucket
filter) and the main lane (span → per-line mapping at render), or
(b) reduced to a library of pure functions (`resolve_fg` stays here or moves
to colorscheme — `resolve_fg` is `ColorScheme.active:resolve_capture(name)`
and is already colorscheme-side). 

The `QueryCursor` reuse fix (currently allocates a new cursor every call —
a real, if minor, perf bug in `build_segments`): in the lane, the cursor
is a member, allocated once per `MSG_HL_INITIALIZE_LANGUAGE`, reused across all
queries, freed only on lane shutdown. `wrap_gc` the once-allocated cursor.

---

## Build order

1. **Plumbing — third lane stands up but is unused.**
   - `shared_state.h`: add `outbox_hl`, `inbox_hl`, `hl_kq_fd`, wire in
     `shared_state_alloc`/`free`.
   - `shared_ffi.lua`, `shared.lua`: cdefs + msg constants + Lua wrappers.
   - `main.c`: `create_lane_state` already generic; add
     `highlight_lane_thread` (twin of `io_lane_thread`); spawn + join.
   - `main.lua`: register `inbox_hl.wake_ident` on the central kqueue.
   - Minimal `cursed/highlight_lane.lua`: logs "started"/"shutdown" and
     does nothing else.

2. **Lane does cold parse + full-doc query, returns spans, but the View
   isn't using it yet.** Validate the full round-trip in isolation.
   - `HlSpansHdr`/`HlSpan` cdefs, `HlQueryReq`, `HlInitLangReq`.
   - Implement the two-layer state cache in the lane.
   - `MSG_HL_INITIALIZE_LANGUAGE` builds `per_lang[lang] = {lang_ptr via
     ts.lang_get, parser, query, cursor, docs={}}`.
   - `MSG_HL_QUERY` with `has_edit=false`, `bucket_idx=0`, full text sent,
     cold parse on first contact with `(language, view_id)`, queries the
     whole doc (or bucket 0 only to test the wire), returns flat spans.
   - Verify: a second query for the same `(language, view_id)` reuses the
     parser/query/cursor (no re-init); a different `view_id` cold-parses
     without disturbing the first document's `old_tree`; `INITIALIZE_LANGUAGE`
     with a new query source drops the whole `per_lang` entry.

3. **Wire View to the lane — cold path only (no incremental, no bucketing
   yet).** Replace `_ensure_highlights` with lane dispatch. Cache = single
   bucket holding whole-doc spans. Get correctness: every highlight that
   worked before still works, now async. `MAX_HL_BYTES` still in place
   temporarily.

4. **Bucketing + render-time line mapping + remove `MAX_HL_BYTES`.**
   - 8KiB buckets; main lane computes viewport buckets, queries absent
     ones.
   - `line_starts` cached + invalidated on gen change.
   - Render walks spans → per-line as described.
   - Delete the cap; delete the old `build_line_spans` path.

5. **Incremental parse (`Tree:edit` + `old_tree`).** Edit messages carry
   `has_edit=true` and the `TSInputEdit` fields; lane does step 4 of the
   parse path. `gen` desync detection.

6. **Parser timeout.** Add `ts_parser_set_timeout_micros` to cdefs; set
   in lane parser init. Confirm: pathological input no longer hangs,
   bucket just renders sparse.

7. **Idle refill.** 30ms timer in the main render loop; when lane idle,
   scan outward from viewport querying the nearest absent bucket.

8. **Polish.** Theme switch (`ColorScheme.generation` bump) — should "just
   work" because a theme change bumps `_hl_generation`, which (under the
   new model) just marks `line_starts` stale; the *spans* need re-resolving
   since `fg` ints are baked in. Cheapest fix: on theme change, clear the
   whole cache map (forces re-query, lane re-resolves fg). Better later:
   have the lane cache unresolved capture names and let main cache resolve
   fg on render — that'd make theme switch free, but it's an optimization
   for a much later phase.

## File hit list (for implementation)

- `src/shared_state.h` — ring + kq additions.
- `src/cursed/shared_ffi.lua` — Msg fields, new msg constants.
- `src/cursed/shared.lua` — push/pop unchanged (generic).
- `src/main.c` — lane spawn.
- `src/cursed/treesitter_ffi.lua` — add `ts_parser_set_timeout_micros`.
- `src/cursed/highlight_lane.lua` — NEW. The lane loop + parse + query +
  span packing.
- `src/cursed/view.lua` — rip out `_ensure_highlights`/`_hl_lines`/
  `_hl_gen`/`_hl_skip`/`_rebuild_highlighter` (keep language/query intent
  tracking), add bucket cache + dispatch + inset handling + render-time
  span→line mapping + idle refill.
- `src/cursed/highlighter.lua` — either fold into the lane or keep as a
  pure-function library for `build_segments` minus the per-line step.
- `src/main.lua` — register inbox_hl wake ident on central kqueue.
