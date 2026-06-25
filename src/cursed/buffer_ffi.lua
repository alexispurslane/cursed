--- FFI declarations for Buffer structs.
---
--- Declares the C types via ffi.cdef for the Buffer piece table and undo logs.
--- POSIX and stdlib declarations live in posix_ffi.lua.

local ffi = require("ffi")
require("cursed.posix_ffi") -- ensure POSIX cdef is loaded first

ffi.cdef([[

struct OrigBuf {
    uint8_t  *data;
    uint32_t  len;
    uint32_t  cap;
};

struct AddBuf {
    uint8_t  *data;
    uint32_t  cap;
    uint32_t  len;
    uint64_t  seq;
};

struct Piece {
    uint8_t  buf_id;
    uint8_t  _pad[3];
    uint32_t off;
    uint32_t len;
};

struct Line {
    struct Piece *pieces;
    uint32_t      cap;
    uint32_t      count;
};

struct UndoLog {
    uint8_t  *data;
    uint32_t  cap;
    uint32_t  pos;
    uint32_t  count;
};

struct Buffer {
    struct Line  *lines;
    uint32_t      cap;
    uint32_t      count;
    bool          dirty;
    struct OrigBuf orig;
    struct AddBuf  add;

    struct UndoLog undo;
    struct UndoLog redo;
    uint32_t       in_edit;

    char         *filepath;
};

]])

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    C = ffi.C,
}
