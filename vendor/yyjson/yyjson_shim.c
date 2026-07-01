/* yyjson_shim.c — thin re-export layer over yyjson's `inline` API.
 *
 * Why: yyjson declares its value constructors (yyjson_mut_str, etc.) and
 * getters (yyjson_get_str, yyjson_is_obj, iter functions) as `static
 * inline` in yyjson.h — they have no exported symbol, so LuaJIT FFI
 * can't call them directly. This shim #includes the header (so the
 * inline bodies compile into THIS translation unit) and re-exports the
 * subset we need as real, non-inline functions with the `shim_` prefix.
 * The linker then resolves them from LuaJIT FFI cdefs.
 *
 * Only the non-trivial (inline) functions are wrapped here; the heavy
 * exported ones (yyjson_read_opts, yyjson_doc_free, yyjson_mut_doc_new,
 * yyjson_mut_write_opts) are called directly via FFI from json_ffi.lua
 * since they carry the `yyjson_api` linkage and are real symbols.
 *
 * All pointers use `void *` / `const void *` here so FFI callers can
 * pass opaque cdata without naming yyjson's struct types; the shim
 * casts back to the typed yyjson_* internally.
 */

#include "yyjson.h"
#include <stdint.h>
#include <stddef.h>

/* ── Read path: doc lifecycle + getters ─────────────────────────── */

yyjson_val *shim_doc_get_root(const yyjson_doc *doc) {
    return yyjson_doc_get_root(doc);
}

void shim_doc_free(yyjson_doc *doc) {
    yyjson_doc_free(doc);
}

uint8_t shim_get_type(const yyjson_val *val) {
    return (uint8_t)yyjson_get_type(val);
}

bool shim_is_str(const yyjson_val *v) { return yyjson_is_str(v); }
bool shim_is_arr(const yyjson_val *v) { return yyjson_is_arr(v); }
bool shim_is_obj(const yyjson_val *v) { return yyjson_is_obj(v); }
bool shim_is_num(const yyjson_val *v) { return yyjson_is_num(v); }
bool shim_is_bool(const yyjson_val *v) { return yyjson_is_bool(v); }
bool shim_is_null(const yyjson_val *v) { return yyjson_is_null(v); }
bool shim_is_int(const yyjson_val *v) { return yyjson_is_int(v); }
bool shim_is_real(const yyjson_val *v) { return yyjson_is_real(v); }

bool shim_get_bool(const yyjson_val *v) { return yyjson_get_bool(v); }
uint64_t shim_get_uint(const yyjson_val *v) { return yyjson_get_uint(v); }
int64_t shim_get_sint(const yyjson_val *v) { return yyjson_get_sint(v); }
double shim_get_real(const yyjson_val *v) { return yyjson_get_real(v); }

const char *shim_get_str(const yyjson_val *v, size_t *len_out) {
    size_t l = yyjson_get_len(v);
    if (len_out) *len_out = l;
    return yyjson_get_str(v);
}

/* ── Read path: iteration ───────────────────────────────────────── */

bool shim_arr_iter_init(const yyjson_val *arr, yyjson_arr_iter *iter) {
    return yyjson_arr_iter_init(arr, iter);
}
yyjson_val *shim_arr_iter_next(yyjson_arr_iter *iter) {
    return yyjson_arr_iter_next(iter);
}

bool shim_obj_iter_init(const yyjson_val *obj, yyjson_obj_iter *iter) {
    return yyjson_obj_iter_init(obj, iter);
}
yyjson_val *shim_obj_iter_next(yyjson_obj_iter *iter) {
    return yyjson_obj_iter_next(iter);
}
yyjson_val *shim_obj_iter_get_val(yyjson_val *key) {
    return yyjson_obj_iter_get_val(key);
}

/* ── Write path: mutable doc lifecycle ─────────────────────────── */

yyjson_mut_doc *shim_mut_doc_new(void) { return yyjson_mut_doc_new(NULL); }
void shim_mut_doc_free(yyjson_mut_doc *doc) { yyjson_mut_doc_free(doc); }

void shim_mut_doc_set_root(yyjson_mut_doc *doc, yyjson_mut_val *root) {
    yyjson_mut_doc_set_root(doc, root);
}

/* ── Write path: value constructors ─────────────────────────────── */

yyjson_mut_val *shim_mut_null(yyjson_mut_doc *doc) { return yyjson_mut_null(doc); }
yyjson_mut_val *shim_mut_true(yyjson_mut_doc *doc) { return yyjson_mut_true(doc); }
yyjson_mut_val *shim_mut_false(yyjson_mut_doc *doc) { return yyjson_mut_false(doc); }
yyjson_mut_val *shim_mut_bool(yyjson_mut_doc *doc, bool b) { return yyjson_mut_bool(doc, b); }
yyjson_mut_val *shim_mut_sint(yyjson_mut_doc *doc, int64_t i) { return yyjson_mut_sint(doc, i); }
yyjson_mut_val *shim_mut_uint(yyjson_mut_doc *doc, uint64_t u) { return yyjson_mut_uint(doc, u); }
yyjson_mut_val *shim_mut_real(yyjson_mut_doc *doc, double d) { return yyjson_mut_real(doc, d); }
yyjson_mut_val *shim_mut_strn(yyjson_mut_doc *doc, const char *s, size_t len) {
    return yyjson_mut_strn(doc, s, len);
}

yyjson_mut_val *shim_mut_obj(yyjson_mut_doc *doc) { return yyjson_mut_obj(doc); }
yyjson_mut_val *shim_mut_arr(yyjson_mut_doc *doc) { return yyjson_mut_arr(doc); }

bool shim_mut_obj_add(yyjson_mut_val *obj, yyjson_mut_val *key, yyjson_mut_val *val) {
    return yyjson_mut_obj_add(obj, key, val);
}
bool shim_mut_arr_append(yyjson_mut_val *arr, yyjson_mut_val *val) {
    return yyjson_mut_arr_append(arr, val);
}

/* Write the mutable doc to a malloc'd null-terminated JSON string.
 * Caller frees with free(). Writes the byte length (excl. NUL) to
 * *len_out if non-NULL. Returns NULL on failure. */
char *shim_mut_write(const yyjson_mut_doc *doc, size_t *len_out) {
    return yyjson_mut_write_opts(doc, 0, NULL, len_out, NULL);
}
