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
 *   MSG_LSP_SPAWN      ptr = struct LspSpawnReq* (spec JSON + workspace
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
 *   MSG_LSP_RESPONSE   ptr = struct LspResponse* (lane relays a request
 *                      result back to main; main dispatches by id)
 */
#define MSG_LSP_SPAWN       11 /* main → lsp: ptr = struct LspSpawnReq* */
#define MSG_LSP_SEND        12 /* main → lsp: ptr = struct LspSendReq* */
#define MSG_LSP_KILL        13 /* main → lsp: ptr = struct LspKillReq* */
#define MSG_LSP_HANDSHAKE   14 /* lsp → main: ptr = struct LspHandshake* */
#define MSG_LSP_DOC_SYNC    15 /* main → lsp: ptr = struct LspDocSync* (didOpen/didChange/didClose, full-text sync) */
#define MSG_LSP_RESPONSE   16 /* lsp → main: ptr = struct LspResponse* (generic request-result relay)
                                 NOTE: 17 reserved for MSG_LSP_NOTIFICATION (declared in shared_ffi.lua).  */

/* ── Proc lane message types ───────────────────────────────────────
 * A general subprocess-control lane (sibling of the LSP lane, but
 * shape-agnostic: no JSON-RPC framing) owns arbitrary child
 * processes. Main assigns a monotonic `procid`; the lane echoes it in
 * every report. STDOUT/STDERR chunks carry their own bytes (malloc'd,
 * ownership → main on pop). Main relays inbound reports as
 * `process_out:<procid>` events on the editor event bus and feeds
 * STDIN by listening for `process_in:<procid>` events (the proc_client
 * facade wires that listener at spawn time).
 *
 * Outbound (main → lane):
 *   MSG_PROC_SPAWN  ptr = struct ProcSpawnReq* (JSON spec + procid)
 *   MSG_PROC_STDIN  ptr = struct ProcStdinReq* (bytes; len==0 → close stdin / EOF)
 *   MSG_PROC_KILL   ptr = struct ProcKillReq*  (deliver signal; fire-and-forget)
 *   MSG_SHUTDOWN    lane exits its blocking kevent()
 *
 * Inbound (lane → main):
 *   MSG_PROC_OUTPUT ptr = struct ProcOutput* (stdout/stderr chunk)
 *   MSG_PROC_EXIT   ptr = struct ProcExit*   (lifecycle: exit/killed/failed/signal-sent)
 */
#define MSG_PROC_SPAWN    18 /* main → proc: ptr = struct ProcSpawnReq* */
#define MSG_PROC_STDIN    19 /* main → proc: ptr = struct ProcStdinReq* */
#define MSG_PROC_KILL     20 /* main → proc: ptr = struct ProcKillReq*  */
#define MSG_PROC_OUTPUT   21 /* proc → main: ptr = struct ProcOutput* */
#define MSG_PROC_EXIT     22 /* proc → main: ptr = struct ProcExit*   */

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
    struct RingBuf outbox_proc; /* main → proc */
    struct RingBuf inbox_proc;  /* proc → main */
    int            main_kq_fd;  /* central kqueue for main lane (tty, resize, inbox wakes) */
    int            io_kq_fd;    /* kqueue for IO lane (outbox wake) */
    int            hl_kq_fd;   /* kqueue for highlight lane (outbox_hl wake) */
    int            lsp_kq_fd; /* kqueue for LSP lane (outbox_lsp wake + child stdout EVFILT_READ) */
    int            proc_kq_fd; /* kqueue for proc lane (outbox_proc wake + child stdout/stderr EVFILT_READ) */
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
    atomic_store_explicit(&ss->outbox_proc.head, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->outbox_proc.tail, 0, memory_order_relaxed);
    atomic_store_explicit(&ss->running, true, memory_order_relaxed);

    ss->main_kq_fd = kqueue();
    ss->io_kq_fd = kqueue();
    ss->hl_kq_fd = kqueue();
    ss->lsp_kq_fd = kqueue();
    ss->proc_kq_fd = kqueue();

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
    ss->outbox_proc.consumer_kq_fd = ss->proc_kq_fd;
    ss->outbox_proc.wake_ident = 1;
    ss->inbox_proc.consumer_kq_fd = ss->main_kq_fd;
    ss->inbox_proc.wake_ident = 4;

    if (ss->main_kq_fd < 0 || ss->io_kq_fd < 0 || ss->hl_kq_fd < 0 || ss->lsp_kq_fd < 0 || ss->proc_kq_fd < 0) {
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
    if (ss->proc_kq_fd >= 0) close(ss->proc_kq_fd);
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

/* MSG_LSP_SPAWN: spec is a JSON array of candidate objects, each
 *   { "bin": short_name, "args?": [..], "env?": {K:V} }. The lane
 * resolves the first `bin` found on PATH, applies that candidate's
 * args (argv[1..]) + env (putenv each), forks it, sends `initialize`,
 * and registers the child stdout on its own kq for EVFILT_READ. On the
 * initialize response the lane pushes a MSG_LSP_HANDSHAKE back. The
 * lane frees this struct (and its strings). */
struct LspSpawnReq {
    uint32_t spec_len;       /* bytes of JSON candidate-spec payload (no NUL) */
    uint32_t workspace_len;  /* bytes of workspace dir payload (no NUL) */
    uint32_t client_id;      /* main-assigned id; lane echoes in handshake */
    /* followed by spec_len bytes (JSON), then workspace_len bytes */
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
    /* Completion triggerCharacters from serverCapabilities.
     * Populated once on the READY (initialize-response) transition
     * (a NUL-terminated concatenation of single chars; empty when the
     * server declares none or before capabilities arrive). Drives the
     * editor's immediate-on-trigger-char completion fast-path. */
    char     trigger_chars[64];
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

/* MSG_LSP_RESPONSE (lane → main): the lane relays a response to a
 * main-owned request (textDocument/formatting today; completion /
 * hover / signatureHelp later). The lane owns the JSON-RPC socket and
 * decodes the full message to a Lua table; it then RE-ENCODES just the
 * `result` field (which may be null, an array of TextEdits, etc.) via
 * yyjson and ships it as a JSON string. Main decodes the small result
 * via yyjson + dispatches by `id` against its pending-request registry.
 * This keeps the lane generic (no knowledge of TextEdit shape) while
 * keeping the (potentially large) full-message decode off-main: only the
 * result substring crosses the boundary, and only the small-result
 * decode runs on main.
 * Lane frees this struct (and the trailing result bytes) after pushing.
 * error_present is non-zero when `msg.error` was set (LSP error reply);
 * result_len is 0 for a null result. */
struct LspResponse {
    uint32_t client_id;    /* which server replied */
    uint32_t id;            /* request id main minted; dispatch key */
    uint32_t result_len;   /* bytes of trailing result JSON (no NUL); 0 = null */
    uint8_t  error_present;/* 1 = this is an error reply (result carries `error`) */
    uint8_t  _pad[3];
    /* followed by result_len bytes of JSON */
};

/* ── Proc lane payloads ───────────────────────────────────────────── */

/* MSG_PROC_SPAWN (main → proc): spec is a JSON object
 *   { "argv": ["prog", "arg", ...],  (REQUIRED, argv[0] is the program)
 *     "env":  { "KEY": "VAL", ... },   (optional; merged into environ via putenv)
 *     "cwd":  "/path",                  (optional; chdir before execvp)
 *     "buffer_bytes": 8192 }            (optional; per-stream flush threshold —
 *                                       the lane accumulates stdout/stderr until
 *                                       this many bytes accumulate before pushing
 *                                       one MSG_PROC_OUTPUT, so chatty programs
 *                                       don't flood main with per-read chunks.
 *                                       0 = flush every read (unbuffered).
 *                                       default 8192.)
 * procid is main-assigned + monotonic; the lane echoes it in every
 * report. The lane frees the struct + spec bytes. On spawn failure
 * (fork/exec) the lane reports MSG_PROC_EXIT with kind=FAILED. */
struct ProcSpawnReq {
    uint32_t procid;     /* main-assigned id; lane echoes in all reports */
    uint32_t spec_len;   /* bytes of JSON spec (no NUL) */
    /* followed by spec_len bytes of JSON */
};

/* MSG_PROC_STDIN (main → proc): write `ptr` (len bytes) to the child's
 * stdin. len==0 signals EOF (close child stdin). Ownership of ptr
 * transfers to the lane — it frees after write (or immediately for
 * len==0 when ptr is NULL). Lane drops silently if procid unknown/
 * stdin already closed. */
struct ProcStdinReq {
    uint32_t procid;
    uint32_t len;       /* bytes; 0 == close stdin (EOF) */
    uint8_t *ptr;       /* malloc'd bytes (NULL when len==0) */
};

/* MSG_PROC_KILL (main → proc): deliver `signal` to the live process.
 * Fire-and-forget: the lane sends the signal, then immediately reports
 * MSG_PROC_EXIT with kind=KILL_SENT (code=signal) as an acknowledgment.
 * The authoritative death notice (kind=SIGNALED/EXITED) arrives later
 * when the child's stdout+stderr EOF and waitpid reaps it. */
struct ProcKillReq {
    uint32_t procid;
    uint32_t signal;    /* 9=SIGKILL, 15=SIGTERM, ... */
};

/* MSG_PROC_OUTPUT (proc → main): a stdout or stderr chunk. ptr is
 * malloc'd by the lane; ownership transfers to main on pop (ring_pop
 * copies Msg by value; main frees ptr after copying to a Lua string).
 * stream: 1=stdout, 2=stderr. */
struct ProcOutput {
    uint32_t procid;
    uint8_t  stream;    /* 1=stdout, 2=stderr */
    uint8_t  _pad[3];
    uint32_t len;       /* bytes (may be 0 if a zero-length read slipped) */
    uint8_t *ptr;       /* malloc'd bytes, ownership → main */
};

/* MSG_PROC_EXIT (proc → main): lifecycle notification. kind codes:
 *   EXITED    (0)  process exited; code = exit status (0-255)
 *   SIGNALED  (1)  process killed by a signal; code = signal number
 *   FAILED    (2)  spawn failed (fork/exec); code = errno; no child reaped
 *   KILL_SENT (3)  informational: lane delivered `code` signal at main's request
 * EXITED/SIGNALED/FAILED are terminal (the procid is retired after);
 * KILL_SENT is advisory and is followed later by SIGNALED/EXITED. */
struct ProcExit {
    uint32_t procid;
    uint8_t  kind;      /* 0=exited 1=signaled 2=failed 3=kill_sent */
    uint8_t  _pad[3];
    uint32_t code;      /* exit status (exited) | signal number (signaled/kill_sent) | errno (failed) */
};

#endif /* SHARED_STATE_H */
