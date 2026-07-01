#ifndef SHARED_STATE_H
#define SHARED_STATE_H

#include <stdint.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/event.h>
#include <unistd.h>
#include <pthread.h>
#include <tree_sitter/api.h>

/* ── SharedState ────────────────────────────────────────────────────
 *
 * SharedState is the IPC mechanism between lanes. It holds ring buffers
 * for communication and a staging area for the IO lane to relay mmap'd
 * file data to the main lane.
 *
 * The piece table lives in Buffer objects (see buffer.h), not here.
 */

#define RING_CAP 1024

#define MSG_FILE_LOAD   0   /* main → IO: please load this file (ptr = filepath string) */
#define MSG_FILE_LOADED 1   /* IO → main: file loaded — read io_orig_* fields */
#define MSG_FILE_ERROR  2   /* IO → main: file load failed (arg = error code) */
#define MSG_FILE_SAVE   3   /* main → IO: please save file (ptr = filepath string, arg = text ptr, arg2 = text len) */
#define MSG_FILE_SAVED   4   /* IO → main: file saved */

#define MSG_HL_INITIALIZE_LANGUAGE 8  /* main → hl: ptr = struct HlInitLangReq* */
#define MSG_HL_QUERY              9  /* main → hl: ptr = struct HlQueryReq* */
#define MSG_HL_SPANS              10 /* hl → main: ptr = struct HlSpansHdr* */

/* ── LSP lane message types ───────────────────────────────────────
 * The LSP lane owns all subprocess management + JSON-RPC framing +
 * JSON decode/encode (so heavy JSON never runs on the main thread).
 * Main relays outbound requests through outbox_lsp and receives
 * inbound (decoded + packed into bespoke C structs per message type)
 * through inbox_lsp.
 *
 * Outbound (main → lane):
 *   MSG_LSP_SPAWN      ptr = struct LspSpawnReq* (exe_names + workspace
 *                        + client_id). The lane mints the id? NO — main
 *                        assigns the client_id it wants the spawn to
 *                        use, so main can pre-bind mode→id. Lane
 *                        echoes it in every handshake for this client.
 *                        arg = unused
 *   MSG_LSP_SEND       ptr = struct LspSendReq* (method + JSON params,
 *                        request if id != 0 else notification). Lane
 *                        frames + writes. arg = unused.
 *   MSG_LSP_KILL       ptr = struct LspKillReq*; arg = unused
 *   MSG_SHUTDOWN       (reuse) lane exits its blocking kevent()
 *
 * Inbound (lane → main) — bespoke per message type; extended as
 * features land. v1 relays only the handshake (initialize response):
 *   MSG_LSP_HANDSHAKE  ptr = struct LspHandshake*; arg = unused
 *   (diagnostics, completion, hover, etc. get their own structs when
 *   their consumers are wired; until then the lane decodes and drops
 *   them off-main.)
 */
#define MSG_LSP_SPAWN      11 /* main → lsp: ptr = struct LspSpawnReq* */
#define MSG_LSP_SEND       12 /* main → lsp: ptr = struct LspSendReq* */
#define MSG_LSP_KILL       13 /* main → lsp: ptr = struct LspKillReq* */
#define MSG_LSP_HANDSHAKE  14 /* lsp → main: ptr = struct LspHandshake* */
#define MSG_LSP_DOC_SYNC   15 /* main → lsp: ptr = struct LspDocSync* (didOpen/didChange/didClose, full-text sync) */

/* ── LSP server status codes (carried in LspHandshake.status) ──────── */
#define LSP_STATUS_SPAWNING 0   /* spawned, initialize response not yet received */
#define LSP_STATUS_READY    1   /* initialize response received; server usable */
#define LSP_STATUS_DEAD      2  /* server exited/crashed on its own (stdout EOF) */
#define LSP_STATUS_KILLED    3  /* killed via MSG_LSP_KILL / shutdown */
#define LSP_STATUS_MISSING    4  /* spawn failed: executable not on PATH */

/* LSP document sync kinds (LspDocSync.kind) */
#define LSP_DOC_OPEN    0  /* textDocument/didOpen (full text, version=0) */
#define LSP_DOC_CHANGE 1  /* textDocument/didChange (full-text replace, version++) */
#define LSP_DOC_CLOSE   2  /* textDocument/didClose */

struct Msg {
    uint8_t  type;
    uint8_t  _pad[3];
    uint32_t arg;
    void    *ptr;
};

struct RingBuf {
    _Atomic uint32_t head;
    _Atomic uint32_t tail;
    struct Msg       entries[RING_CAP];
    int              consumer_kq_fd;   /* kqueue fd of the consumer lane */
    uintptr_t       wake_ident;        /* EVFILT_USER ident for wake */
};

/* ── Shared parse tree (highlight lane → main, mutex-guarded) ────────
 *
 * The highlight lane parses the document off-thread and publishes a
 * snapshot of the resulting TSTree here, keyed by view_id. The main
 * lane acquires (ts_tree_copy → its own refcount ref) to run
 * tree-sitter-backed USER inputs (indent, imenu/xref, textobjects)
 * WITHOUT a second parse on main and WITHOUT importing LuaJS values
 * across the lua_State boundary.
 *
 * Invariant: main NEVER edits these trees. Only the lane writes
 * (briefly — swap the slot pointer under the mutex during reparsing),
 * so the mutex critical section is a few field writes; the lane's own
 * old_tree is edited out-of-band and tree-sitter's copy-on-write
 * (subtree refcounting) keeps a previously-published snapshot stable
 * even while the lane incrementally re-edits its working tree.
 */
#define SHARED_TREE_CAP 64

struct SharedTreeSlot {
    uint32_t view_id;   /* 0 = empty slot */
    uint32_t gen;       /* lane-side gen that produced `tree` */
    TSTree  *tree;      /* lane's ts_tree_copy ref; slot-owned */
};

struct SharedTree {
    pthread_mutex_t     lock;
    struct SharedTreeSlot slots[SHARED_TREE_CAP];
};

struct SharedState {
    /* Ring buffers for lane communication */
    struct RingBuf outbox_io;
    struct RingBuf inbox_io;
    struct RingBuf outbox_hl;   /* main → highlight */
    struct RingBuf inbox_hl;    /* highlight → main */
    struct RingBuf outbox_lsp;  /* main → LSP */
    struct RingBuf inbox_lsp;  /* LSP → main */
    int            main_kq_fd;  /* central kqueue for main lane (tty, resize, inbox wakes) */
    int            io_kq_fd;    /* kqueue for IO lane (outbox wake) */
    int            hl_kq_fd;   /* kqueue for highlight lane (outbox_hl wake) */
    int            lsp_kq_fd; /* kqueue for LSP lane (outbox_lsp wake + child stdout EVFILT_READ) */
    _Atomic bool   running;

    /* Shared parse-tree slot table (highlight → main). */
    struct SharedTree shared_tree;
};

/* ── Global pointer (set by main.c before lanes start) ──────────── */

extern struct SharedState *g_shared_state;

/* ── Lifecycle ──────────────────────────────────────────────────── */

static inline void shared_state_free(struct SharedState *ss);

static inline struct SharedState *shared_state_alloc(void)
{
    struct SharedState *ss = calloc(1, sizeof(*ss));
    if (!ss) return NULL;

    atomic_store_explicit(&ss->inbox_io.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->inbox_io.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_io.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_io.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->inbox_hl.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->inbox_hl.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_hl.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_hl.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->inbox_lsp.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->inbox_lsp.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_lsp.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_lsp.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->running, true, memory_order_relaxed);

    ss->main_kq_fd = kqueue();
    ss->io_kq_fd = kqueue();
    ss->hl_kq_fd = kqueue();
    ss->lsp_kq_fd = kqueue();

    /* Each ring wakes its consumer lane via a distinct EVFILT_USER ident.
     * Idents are lane-local: outbox_* wakes the consumer lane (io/hl/lsp),
     * inbox_* wakes main. Using distinct idents per ring on main's kq lets
     * the main loop tell which lane replied. */
    ss->outbox_io.consumer_kq_fd = ss->io_kq_fd;
    ss->outbox_io.wake_ident = 1;
    ss->inbox_io.consumer_kq_fd = ss->main_kq_fd;
    ss->inbox_io.wake_ident = 1;
    ss->outbox_hl.consumer_kq_fd = ss->hl_kq_fd;
    ss->outbox_hl.wake_ident = 1;
    ss->inbox_hl.consumer_kq_fd = ss->main_kq_fd;
    ss->inbox_hl.wake_ident = 2;
    ss->outbox_lsp.consumer_kq_fd = ss->lsp_kq_fd;
    ss->outbox_lsp.wake_ident = 1;
    ss->inbox_lsp.consumer_kq_fd = ss->main_kq_fd;
    ss->inbox_lsp.wake_ident = 3;

    if (ss->main_kq_fd < 0 || ss->io_kq_fd < 0 || ss->hl_kq_fd < 0 || ss->lsp_kq_fd < 0) {
        shared_state_free(ss);
        return NULL;
    }

    pthread_mutex_init(&ss->shared_tree.lock, NULL);
    /* slots already zeroed by calloc (view_id=0 == empty, tree=NULL) */

    return ss;
}

static inline void shared_state_free(struct SharedState *ss)
{
    if (!ss) return;
    /* Drop any live shared-tree snapshots (lane already exitting; main
     * held its own refs separately via ts_tree_copy on acquire). */
    for (uint32_t i = 0; i < SHARED_TREE_CAP; i++) {
        if (ss->shared_tree.slots[i].tree != NULL) {
            ts_tree_delete(ss->shared_tree.slots[i].tree);
            ss->shared_tree.slots[i].tree = NULL;
        }
    }
    pthread_mutex_destroy(&ss->shared_tree.lock);
    if (ss->main_kq_fd >= 0) close(ss->main_kq_fd);
    if (ss->io_kq_fd >= 0) close(ss->io_kq_fd);
    if (ss->hl_kq_fd >= 0) close(ss->hl_kq_fd);
    if (ss->lsp_kq_fd >= 0) close(ss->lsp_kq_fd);
    free(ss);
}

/* ── Ring buffer ────────────────────────────────────────────────── */

bool ring_push(struct RingBuf *rb, const struct Msg *msg)
{
    uint32_t head = atomic_load_explicit(&rb->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);

    if (head - tail >= RING_CAP)
        return false;

    rb->entries[head & (RING_CAP - 1)] = *msg;
    atomic_store_explicit(&rb->head, head + 1, memory_order_release);
    /* Wake the consumer lane via EVFILT_USER on its kqueue. */
    if (rb->consumer_kq_fd >= 0) {
        struct kevent trigger;
        EV_SET(&trigger, rb->wake_ident, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
        kevent(rb->consumer_kq_fd, &trigger, 1, NULL, 0, NULL);
    }
    return true;
}

bool ring_pop(struct RingBuf *rb, struct Msg *msg)
{
    uint32_t tail = atomic_load_explicit(&rb->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&rb->head, memory_order_acquire);

    if (tail >= head)
        return false;

    *msg = rb->entries[tail & (RING_CAP - 1)];
    atomic_store_explicit(&rb->tail, tail + 1, memory_order_release);
    return true;
}

/* ── Shared parse-tree slot table ───────────────────────────────────
 *
 * publish: lane calls after each successful parse with its TSTree*.
 * The slot keeps its OWN ref (ts_tree_copy bumps the root subtree's
 * atomic refcount) so the lane may subsequently ts_tree_edit its
 * working old_tree (copy-on-write) without disturbing the snapshot.
 * Old slot tree is freed outside the critical section. */
void shared_tree_publish(struct SharedState *ss, uint32_t view_id, uint32_t gen, void *tree_ptr)
{
    if (!ss || view_id == 0 || tree_ptr == NULL) return;

    TSTree *copy = ts_tree_copy((const TSTree *)tree_ptr);
    TSTree *old_to_free = NULL;

    pthread_mutex_lock(&ss->shared_tree.lock);
    struct SharedTreeSlot *slot = NULL;   /* existing match */
    struct SharedTreeSlot *empty = NULL;  /* first free slot */
    struct SharedTreeSlot *victim = NULL;/* oldest-gen slot, for eviction */
    uint32_t victim_gen = 0;
    for (uint32_t i = 0; i < SHARED_TREE_CAP; i++) {
        struct SharedTreeSlot *s = &ss->shared_tree.slots[i];
        if (s->view_id == view_id) { slot = s; break; }
        if (empty == NULL && s->view_id == 0) { empty = s; }
        if (s->view_id != 0 && (victim == NULL || s->gen < victim_gen)) {
            victim = s; victim_gen = s->gen;
        }
    }
    if (slot == NULL) slot = (empty != NULL) ? empty : victim;
    if (slot != NULL) {
        old_to_free = slot->tree;
        slot->tree = copy;
        slot->gen = gen;
        slot->view_id = view_id;
    } else {
        old_to_free = copy;  /* table full and nothing to evict: drop it */
    }
    pthread_mutex_unlock(&ss->shared_tree.lock);

    if (old_to_free) ts_tree_delete(old_to_free);
}

/* acquire: main calls to read the latest published tree for a view.
 * Returns a NEW ts_tree_copy the caller must ts_tree_delete (main wraps
 * it in cursed.ts.Tree for RAII). *out_gen receives the publishing gen
 * (0 on miss). Never call ts_tree_edit on the returned tree. */
void *shared_tree_acquire(struct SharedState *ss, uint32_t view_id, uint32_t *out_gen)
{
    TSTree *result = NULL;
    uint32_t gen = 0;
    if (out_gen) *out_gen = 0;
    if (!ss || view_id == 0) return NULL;

    pthread_mutex_lock(&ss->shared_tree.lock);
    for (uint32_t i = 0; i < SHARED_TREE_CAP; i++) {
        struct SharedTreeSlot *s = &ss->shared_tree.slots[i];
        if (s->view_id == view_id && s->tree != NULL) {
            result = ts_tree_copy(s->tree);  /* main's own refcount ref */
            gen = s->gen;
            break;
        }
    }
    pthread_mutex_unlock(&ss->shared_tree.lock);

    if (out_gen) *out_gen = gen;
    return result;
}

/* release: drop a slot when its view is closed so dead views don't hold a
 * tree ref indefinitely. Main holds its own refs separately, so callers
 * racing with an in-flight acquire are unaffected. */
void shared_tree_release(struct SharedState *ss, uint32_t view_id)
{
    TSTree *to_free = NULL;
    if (!ss || view_id == 0) return;

    pthread_mutex_lock(&ss->shared_tree.lock);
    for (uint32_t i = 0; i < SHARED_TREE_CAP; i++) {
        struct SharedTreeSlot *s = &ss->shared_tree.slots[i];
        if (s->view_id == view_id) {
            to_free = s->tree;
            s->tree = NULL;
            s->gen = 0;
            s->view_id = 0;
            break;
        }
    }
    pthread_mutex_unlock(&ss->shared_tree.lock);

    if (to_free) ts_tree_delete(to_free);
}

/* ── LSP lane payloads ────────────────────────────────────────────── */

/* MSG_LSP_SPAWN: exe_names is a NUL-separated (first-wins) list of short
 * executable names to resolve on PATH. The lane resolves, forks the
 * first found, sends `initialize`, and registers the child stdout on its
 * own kq for EVFILT_READ. On the initialize response the lane pushes a
 * MSG_LSP_HANDSHAKE back. The lane frees this struct (and its strings). */
struct LspSpawnReq {
    uint32_t exe_names_len;   /* bytes of NUL-separated exe_names payload */
    uint32_t workspace_len;   /* bytes of workspace dir payload (no NUL) */
    uint32_t client_id;       /* main-assigned id; lane echoes in handshake */
    /* followed by exe_names_len bytes, then workspace_len bytes */
};

/* MSG_LSP_SEND: main pre-encodes params to a JSON string (the encode is
 * pure Lua but outbound params are currently tiny — initialize only is
 * owned by the lane itself; this path exists for future didOpen/
 * didChange/completion). If id != 0 it's a request (lane owns id
 * allocation is NOT done here — main passes the id it wants, or 0 for a
 * notification). Lane frames with Content-Length + writes + frees. */
struct LspSendReq {
    uint32_t method_len;   /* method string bytes (no NUL) */
    uint32_t params_len;   /* JSON body bytes (no NUL); 0 = no params */
    uint32_t id;           /* 0 = notification, else request id */
    uint32_t client_id;   /* route to this client (lane drops if unknown) */
    /* followed by method_len bytes, then params_len bytes */
};

/* MSG_LSP_KILL: SIGTERM a client identified by exe_name (short basename).
 * Lane frees. */
struct LspKillReq {
    uint32_t client_id;   /* route kill to this client */
    char     exe_name[64]; /* short basename, NUL-padded (for logging only) */
};

/* MSG_LSP_HANDSHAKE (lane → main): the server's current status, relayed
 * at every transition: spawn (spawning), initialize response (ready),
 * stdout EOF (dead), explicit kill (killed), or binary-not-found
 * (missing). Main keeps the registry entry for ALL statuses so the
 * modeline can distinguish dead/killed/missing — only spawning/ready
 * count as live for dedup. Lane frees this struct after pushing
 * (ring_pop copies Msg by value; ptr is malloc'd, main frees). */
struct LspHandshake {
    char     exe_name[64];   /* short basename, NUL-padded */
    uint32_t client_id;   /* main-assigned id; echoed by lane */
    uint8_t  status;         /* LSP_STATUS_* code */
    uint8_t  _pad[3];
};

/* MSG_LSP_DOC_SYNC (main → lsp): document synchronization so the
 * server's view of the buffer matches main's. Carries the full text
 * as a separately-malloc'd buffer (produced by Buffer:write_text_direct)
 * — NO JSON encode happens on main; the lane builds the didOpen/
 * didChange notification envelope itself (heavy work stays off-main).
 * text_ptr ownership transfers: the lane frees text_ptr (if non-NULL)
 * and the struct itself. uri/language_id are inline (NUL-padded). */
struct LspDocSync {
    uint32_t client_id;   /* route to this server */
    uint32_t version;      /* document version (0 on open, increments per change) */
    uint8_t  kind;         /* LSP_DOC_OPEN / CHANGE / CLOSE */
    uint8_t  _pad[3];
    char     uri[512];       /* file:// URI, NUL-padded */
    char     language_id[32]; /* LSP languageId (e.g. "lua"), NUL-padded */
    uint8_t *text_ptr;      /* malloc'd full-buffer text (NULL for CLOSE); lane frees */
    uint32_t text_len;     /* byte length of text_ptr */
};

#endif /* SHARED_STATE_H */
