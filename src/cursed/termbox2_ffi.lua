--- Termbox2 FFI bindings for LuaJIT.
---
--- Declares the termbox2 C API types and functions via ffi.cdef,
--- then returns ffi.C so callers can invoke C functions directly.
--- The safe RAII wrapper is in `cursed.tb`.

local ffi = require("ffi")

ffi.cdef([[
/* ── termbox2 types ──────────────────────────────────────────────────── */

typedef uint64_t uintattr_t;

struct tb_cell {
    uint32_t ch;      // a Unicode codepoint
    uintattr_t fg;    // bitwise foreground attributes
    uintattr_t bg;    // bitwise background attributes
};

struct tb_event {
    uint8_t type;     // one of TB_EVENT_* constants
    uint8_t mod;      // bitwise TB_MOD_* constants
    uint16_t key;     // one of TB_KEY_* constants
    uint32_t ch;      // a Unicode codepoint
    int32_t w;        // resize width
    int32_t h;        // resize height
    int32_t x;        // mouse x
    int32_t y;        // mouse y
};

/* ── Lifecycle ──────────────────────────────────────────────────────── */

int tb_init(void);
int tb_init_file(const char *path);
int tb_shutdown(void);

/* ── Dimensions ──────────────────────────────────────────────────────── */

int tb_width(void);
int tb_height(void);

/* ── Drawing ─────────────────────────────────────────────────────────── */

int tb_clear(void);
int tb_set_clear_attrs(uintattr_t fg, uintattr_t bg);
int tb_present(void);
int tb_invalidate(void);

/* ── Cursor ──────────────────────────────────────────────────────────── */

int tb_set_cursor(int cx, int cy);
int tb_hide_cursor(void);

/* ── Cells ───────────────────────────────────────────────────────────── */

int tb_set_cell(int x, int y, uint32_t ch, uintattr_t fg, uintattr_t bg);
int tb_extend_cell(int x, int y, uint32_t ch);

/* ── Input / Output modes ───────────────────────────────────────────── */

int tb_set_input_mode(int mode);
int tb_set_output_mode(int mode);

/* ── Events ──────────────────────────────────────────────────────────── */

int tb_peek_event(struct tb_event *event, int timeout_ms);
int tb_poll_event(struct tb_event *event);
int tb_get_fds(int *ttyfd, int *resizefd);

/* ── Print ───────────────────────────────────────────────────────────── */

int tb_print(int x, int y, uintattr_t fg, uintattr_t bg, const char *str);

/* ── UTF-8 helpers ──────────────────────────────────────────────────── */

int tb_utf8_char_length(char c);
int tb_utf8_unicode_to_char(char *out, uint32_t c);

/* ── Introspection ──────────────────────────────────────────────────── */

int tb_has_truecolor(void);
int tb_has_egc(void);
int tb_attr_width(void);
]])

return ffi.C
