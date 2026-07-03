--- FFI declarations for SharedState (IPC between lanes).
---
--- SharedState holds only ring buffers for main↔IO communication.
--- POSIX and stdlib declarations live in posix_ffi.lua.

local ffi = require("ffi")
require("cursed.posix_ffi") -- ensure POSIX cdef is loaded first

ffi.cdef([[

struct Msg {
    uint8_t  type;
    uint8_t  _pad[3];
    uint32_t arg;
    void    *ptr;
};

struct RingBuf {
    uint32_t head;
    uint32_t tail;
    struct Msg entries[1024];
    int        consumer_kq_fd;
    uintptr_t  wake_ident;
};

struct SharedState {
    struct RingBuf outbox_io;
    struct RingBuf inbox_io;
    struct RingBuf outbox_hl;
    struct RingBuf inbox_hl;
    struct RingBuf outbox_lsp;
    struct RingBuf inbox_lsp;
    int            main_kq_fd;
    int            io_kq_fd;
    int            hl_kq_fd;
    int            lsp_kq_fd;
    bool    running;
};

struct SharedState *shared_state_alloc(void);
void               shared_state_free(struct SharedState *ss);

extern struct SharedState *g_shared_state;

bool ring_push(struct RingBuf *rb, struct Msg *msg);
bool ring_pop(struct RingBuf *rb, struct Msg *msg);

/* ── Shared parse-tree slot table (highlight lane → main) ───────── */
/* A lane-published TSTree snapshot, keyed by view_id, mutex-guarded in
 * C (see shared_state.h). Lua never indexes the slot structs directly —
 * only calls these helpers against a SharedState*. `tree` is opaque
 * void* to Lua; callers cast to TSTree* via cursed.ts.Tree.new (which
 * owns the ref via ts_tree_delete on GC). */
void shared_tree_publish(struct SharedState *ss, uint32_t view_id, uint32_t gen, void *tree_ptr);
void *shared_tree_acquire(struct SharedState *ss, uint32_t view_id, uint32_t *out_gen);
void shared_tree_release(struct SharedState *ss, uint32_t view_id);

/* ── Highlight lane request/response payloads ──────────────────── */

/* MSG_HL_INITIALIZE_LANGUAGE: fixed header + variable query source bytes.
 * Layout:
 *   sizeof(HlInitLangReq)
 *   + query_len bytes            (block query, NOT null-terminated)
 *   + injection_query_len bytes   (injection query, 0 if none)
 *   + injected_lang_count × HlInjectedLang
 * where each HlInjectedLang is { char name[16]; uint32_t qlen; qlen bytes }.
 *
 * For non-injection languages (everything except markdown today),
 * injection_query_len == 0 and injected_lang_count == 0 — the lane takes
 * the fast single-parser path. For markdown, the injection query walks
 * the block tree for content regions (inline nodes, fenced code blocks,
 * metadata blocks) and resolves the grammar to use for each (either a
 * fixed #set! injection.language or the @injection.language capture's
 * label text). injected_langs lists every grammar the injection query
 * may reference + each one's highlight query source. */
struct HlInitLangReq {
    char     language[16];         /* block grammar name (NUL-padded) */
    uint32_t query_len;            /* block query source length */
    uint32_t injection_query_len;  /* injection query source length (0 if none) */
    uint32_t injected_lang_count;  /* number of HlInjectedLang entries following */
    /* followed by query_len bytes of block query,
     * then injection_query_len bytes of injection query,
     * then injected_lang_count × HlInjectedLang */
};
struct HlInjectedLang {
    char     language[16];   /* injected grammar name (NUL-padded) */
    uint32_t query_len;      /* highlight query source length */
    /* followed by query_len bytes of query source */
};

/* MSG_HL_QUERY: dispatch keys + bucket range + edit + text snapshot.
 * A single query may cover a contiguous range of buckets [bucket_start,
 * bucket_end) so an edit can re-highlight everything at/after the edit
 * point in one lane round-trip. Viewport fills pass a 1-bucket range. */
struct HlQueryReq {
    char     language[16];   /* dispatch key #1 (NUL-padded) */
    uint32_t view_id;       /* dispatch key #2 — per-document old_tree */
    uint32_t bucket_start;  /* first bucket (inclusive) to query */
    uint32_t bucket_end;    /* one past the last bucket (exclusive) */
    uint32_t gen;           /* main-lane monotonic gen for this (view,lang) */
    bool     has_edit;      /* false → cold/incremental-of-nothing */
    bool     force_cold;    /* true → old_tree invalid even if present (undo/redo snapshot swap) */
    uint32_t start_byte;   /* edit coords in the text the lane last parsed */
    uint32_t old_end_byte;
    uint32_t new_end_byte;
    uint32_t start_row,  start_col;
    uint32_t old_end_row, old_end_col;
    uint32_t new_end_row, new_end_col;
    void    *text;         /* full current document text (NOT NUL-terminated) */
    uint32_t text_len;
};

/* MSG_HL_SPANS: header + count × HlSpan + name_count × HlName.
 * The lane emits capture NAME INDICES, not resolved fg ints, because the
 * colorscheme lives only in the main lane. Main resolves fg on receipt. */
struct HlSpansHdr {
    uint32_t gen;          /* echoes request gen — main rejects if stale */
    uint32_t bucket_start; /* first bucket (inclusive) this response covers */
    uint32_t bucket_end;   /* one past the last bucket (exclusive) */
    uint32_t count;        /* span count */
    uint32_t name_count;   /* distinct capture names in this response */
    /* followed by count × struct HlSpan, then name_count × struct HlName */
};
struct HlSpan {
    uint32_t start_byte;   /* ABSOLUTE byte offset in the document */
    uint32_t end_byte;
    uint32_t cap_index;    /* index into the trailing name table */
};
struct HlName {
    char name[32];         /* NUL-padded capture name */
};

/* ── LSP lane payloads (mirror shared_state.h) ────────────────── */

struct LspSpawnReq {
    uint32_t spec_len;
    uint32_t workspace_len;
    uint32_t client_id;
    /* followed by spec_len bytes (JSON), then workspace_len bytes */
};

struct LspSendReq {
    uint32_t method_len;
    uint32_t params_len;
    uint32_t id;           /* 0 = notification, else request id */
    uint32_t client_id;   /* route to this client (lane drops if unknown) */
    /* followed by method_len bytes, then params_len bytes */
};

struct LspKillReq {
    uint32_t client_id;   /* route kill to this client */
    char     exe_name[64]; /* short basename, NUL-padded (logging only) */
};

struct LspHandshake {
    char     exe_name[64]; /* short basename, NUL-padded */
    uint32_t client_id;   /* main-assigned id; echoed by lane */
    uint8_t  status;       /* LSP_STATUS_* code */
    uint8_t  _pad[3];
    char     trigger_chars[64]; /* completionProvider.triggerCharacters, NUL-term */
};

struct LspDocSync {
    uint32_t client_id;
    uint32_t version;
    uint8_t  kind;    /* LSP_DOC_OPEN / CHANGE / CLOSE */
    uint8_t  _pad[3];
    char     uri[512];
    char     language_id[32];
    uint8_t *text_ptr;
    uint32_t text_len;
};

struct LspResponse {
    uint32_t client_id;
    uint32_t id;
    uint32_t result_len;
    uint8_t  error_present;
    uint8_t  _pad[3];
    /* followed by result_len bytes of JSON */
};
]])

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

local MSG_FILE_LOAD = 0
local MSG_FILE_LOADED = 1
local MSG_FILE_ERROR = 2
local MSG_FILE_SAVE = 3
local MSG_FILE_SAVED = 4
local MSG_SHUTDOWN = 5
local MSG_INSERT_FILE = 6
local MSG_FILE_INSERTED = 7
local MSG_HL_INITIALIZE_LANGUAGE = 8
local MSG_HL_QUERY = 9
local MSG_HL_SPANS = 10
local MSG_LSP_SPAWN = 11
local MSG_LSP_SEND = 12
local MSG_LSP_KILL = 13
local MSG_LSP_HANDSHAKE = 14
local MSG_LSP_DOC_SYNC = 15
local MSG_LSP_RESPONSE = 16

local LSP_STATUS_SPAWNING = 0
local LSP_STATUS_READY = 1
local LSP_STATUS_DEAD = 2
local LSP_STATUS_KILLED = 3
local LSP_STATUS_MISSING = 4

local LSP_DOC_OPEN = 0
local LSP_DOC_CHANGE = 1
local LSP_DOC_CLOSE = 2

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    C = ffi.C,
    MSG_FILE_LOAD = MSG_FILE_LOAD,
    MSG_FILE_LOADED = MSG_FILE_LOADED,
    MSG_FILE_ERROR = MSG_FILE_ERROR,
    MSG_FILE_SAVE = MSG_FILE_SAVE,
    MSG_FILE_SAVED = MSG_FILE_SAVED,
    MSG_SHUTDOWN = MSG_SHUTDOWN,
    MSG_INSERT_FILE = MSG_INSERT_FILE,
    MSG_FILE_INSERTED = MSG_FILE_INSERTED,
    MSG_HL_INITIALIZE_LANGUAGE = MSG_HL_INITIALIZE_LANGUAGE,
    MSG_HL_QUERY = MSG_HL_QUERY,
    MSG_HL_SPANS = MSG_HL_SPANS,
    MSG_LSP_SPAWN = MSG_LSP_SPAWN,
    MSG_LSP_SEND = MSG_LSP_SEND,
    MSG_LSP_KILL = MSG_LSP_KILL,
    MSG_LSP_HANDSHAKE = MSG_LSP_HANDSHAKE,
    MSG_LSP_DOC_SYNC = MSG_LSP_DOC_SYNC,
    MSG_LSP_RESPONSE = MSG_LSP_RESPONSE,
    LSP_STATUS_SPAWNING = LSP_STATUS_SPAWNING,
    LSP_STATUS_READY = LSP_STATUS_READY,
    LSP_STATUS_DEAD = LSP_STATUS_DEAD,
    LSP_STATUS_KILLED = LSP_STATUS_KILLED,
    LSP_STATUS_MISSING = LSP_STATUS_MISSING,
    LSP_DOC_OPEN = LSP_DOC_OPEN,
    LSP_DOC_CHANGE = LSP_DOC_CHANGE,
    LSP_DOC_CLOSE = LSP_DOC_CLOSE,
}
