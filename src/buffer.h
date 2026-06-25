#ifndef BUFFER_H
#define BUFFER_H

#include <stdint.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

/* ── Piece table internals ──────────────────────────────────────────
 *
 * Per-line piece tables. Each line owns a heap-allocated pieces array
 * grown via realloc from Lua. The lines array itself is likewise
 * heap-allocated and realloc'd from Lua.
 */

struct OrigBuf {
    uint8_t  *data;
    uint32_t  len;
    uint32_t  cap;
};

struct AddBuf {
    uint8_t  *data;
    uint32_t  cap;
    uint32_t  len;
    /* seq is reserved for seqlock reads by highlight lane (future) */
    uint64_t  seq;
};

struct Piece {
    uint8_t  buf_id;   /* 0 = orig, 1 = add */
    uint8_t  _pad[3];
    uint32_t off;
    uint32_t len;
};

struct Line {
    struct Piece *pieces;
    uint32_t      cap;
    uint32_t      count;
};

/* ── Undo log (mmap'd, packed binary format) ────────────────────── */

struct UndoLog {
    uint8_t *data;       /* mmap'd buffer */
    uint32_t cap;        /* mapped capacity in bytes */
    uint32_t pos;        /* write position (end of last entry) */
    uint32_t count;      /* number of entries in the log */
};

/* ── Buffer ────────────────────────────────────────────────────────
 *
 * A Buffer is the core text data model: a per-line piece table with
 * an mmap'd orig buffer, an append-only add buffer, and an undo/redo
 * log. It knows its source filepath for save operations.
 *
 * Allocated and freed from Lua via ffi.C.calloc / ffi.C.free.
 * Cleanup (munmap sub-buffers, free lines/pieces/add/filepath) is done
 * in Lua before the final free.
 */

struct Buffer {
    struct Line  *lines;
    uint32_t      cap;
    uint32_t      count;
    bool          dirty;
    struct OrigBuf orig;
    struct AddBuf  add;

    /* Undo/redo logs */
    struct UndoLog undo;
    struct UndoLog redo;
    uint32_t       in_edit;   /* nesting counter: snapshot on 0→1 */

    /* Source file (heap-allocated C string, managed by Lua) */
    char         *filepath;
};

#endif /* BUFFER_H */
