# Core Architecture

## Lanes

Each lane is a LuaJIT `lua_State` in its own pthread. Main is the hub — all communication is main ↔ lane, never lane ↔ lane.

```
         ┌──────────────────────────────────┐
         │            Main Lane              │
         │  termbox2, buffer, rendering     │
         │  reads inboxes each frame         │
         │  sole writer of piece table       │
         └───┬──────────┬──────────┬────────┘
         outbox↓    outbox↓    outbox↓
    ┌───────────┐ ┌─────────┐ ┌─────────┐
    │ Highlight │ │   LSP   │ │   I/O   │
    │   Lane    │ │  Lane   │ │  Lane   │
    └─────┬─────┘ └────┬────┘ └────┬────┘
          │seqlock      │seqlock+   │writes
          │(spans)      │inbox      │orig
          │             └────►main │inbox
          │no inbox                  └────►main
          │(spans via seqlock)
```

## Frame loop

```
1. poll termbox events
2. drain all lane inboxes
3. update shared state
4. render
5. goto 1
```

Messages pile up while main renders. They all get handled at the start of the next frame. Latency is bounded by frame time.

## Shared memory

All shared memory is C-allocated, passed to lanes as raw FFI pointers. Single-writer for each region — no mutexes, only seqlocks where needed.

```c
#include <stdint.h>
#include <stdatomic.h>

// ── Original buffer (immutable after load) ──

struct OrigBuf {
    uint8_t  *data;   // mmap'd, page-aligned
    uint32_t  len;     // actual file size
    uint32_t  cap;     // page-rounded size (for munmap)
};

// ── Add buffer (mutated by main, seqlock-protected) ──

struct AddBuf {
    uint8_t  *data;              // heap-allocated, grows with realloc
    uint32_t  cap;               // allocated capacity
    _Atomic uint32_t len;        // seqlock gate: read this before/after data
    _Atomic uint64_t seq;         // seqlock counter (odd = write in progress)
};

// ── Piece table ──

struct Piece {
    uint8_t  buf_id;  // 0 = original, 1 = add
    uint8_t  _pad[3];
    uint32_t off;
    uint32_t len;
};

struct PieceTable {
    struct Piece *pieces;
    uint32_t      cap;
    _Atomic uint32_t  count;   // seqlock gate
    _Atomic uint64_t  seq;     // seqlock counter
    struct OrigBuf orig;       // immutable after load
    struct AddBuf  add;       // main writes, seqlock protects
};

// ── Highlight spans ──

struct Span {
    uint32_t start_byte;
    uint32_t end_byte;
    uint16_t highlight_id; // maps to color/style in main lane
    uint16_t _pad;
};

struct SpanTable {
    struct Span       *spans;
    uint32_t           cap;
    _Atomic uint32_t   count;  // seqlock gate
    _Atomic uint64_t   seq;    // seqlock counter
};

// ── Ring buffer (one per lane inbox) ──

#define RING_CAP 1024 // must be power of 2

struct Msg {
    uint8_t  type;  // FILE_LOADED, FILE_SAVED, COMPLETION_REQ, EDIT_INSERT, etc.
    uint8_t  _pad[3];
    uint32_t arg;   // payload depends on type (e.g. error code)
    void    *ptr;   // pointer payload (e.g. diagnostic strings)
};

struct RingBuf {
    _Atomic uint32_t head;  // writer only
    _Atomic uint32_t tail;  // reader only
    struct Msg       entries[RING_CAP];
};

// ── Top-level shared state ──

struct SharedState {
    struct PieceTable piece_table;   // main writes, all lanes read via seqlock
    struct SpanTable  span_table;    // highlight lane writes, main reads via seqlock

    // Outboxes: main writes, lane reads
    struct RingBuf outbox_highlight;
    struct RingBuf outbox_lsp;
    struct RingBuf outbox_io;

    // Inboxes: lane writes, main reads. Only for lanes that need
    // to send non-shared-state messages (completions, errors, etc.).
    struct RingBuf inbox_lsp;
    struct RingBuf inbox_io;
};
```

### Ownership

| Shared memory | Writer | Reader | Sync |
|---|---|---|---|
| `orig` (OrigBuf) | I/O lane (once, then immutable) | All lanes | Immutable after load; no seqlock needed |
| `add` (AddBuf) | Main | All lanes | Seqlock on `len` |
| `pieces[]` | Main | All lanes | Seqlock on `count` |
| `spans[]` | Highlight lane | Main | Seqlock on `count` |
| Outboxes | Main (writer) | Lane (reader) | Lock-free atomic `head`/`tail` |
| Inboxes | Lane (writer) | Main (reader) | Lock-free atomic `head`/`tail` |

### Seqlock read pattern

```c
// Reader (e.g. highlight lane reading piece table):
uint64_t s1 = atomic_load_explicit(&pt->seq, memory_order_acquire);
uint32_t n  = pt->count;
// ... read pieces[0..n], orig, and add ...
uint64_t s2 = atomic_load_explicit(&pt->seq, memory_order_acquire);
if (s1 != s2 || (s1 & 1)) retry; // torn read or write in progress

// Writer (main lane updating piece table):
atomic_fetch_add_explicit(&pt->seq, 1, memory_order_release); // seq goes odd
// ... write pieces, update count ...
atomic_fetch_add_explicit(&pt->seq, 1, memory_order_release); // seq goes even
```

No mutexes. No syscalls. On x86, `memory_order_acquire` is a plain load.
