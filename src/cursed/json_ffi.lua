--- JSON encode/decode backed by yyjson (MIT, vendored two-file C lib).
---
--- Why: the previous hand-rolled codec was both incorrect (the string
--- escaper produced invalid JSON like `\)` -> crashed servers) and slow
--- (the decoder did s:sub one char at a time). yyjson is the fastest
--- pure-C JSON lib and correct by construction; this module drives it
--- via FFI through a thin C shim (vendor/yyjson/yyjson_shim.c) that
--- re-exports yyjson's inline getters/builders as real symbols.
---
--- Thread model: the exported functions are reentrant (each call makes
--- + frees its own doc; yyjson is thread-safe per-doc), so this module
--- is safe to call from BOTH the main lua_State (for outbound params:
--- didOpen/completion request) and the LSP lane lua_State (for inbound
--- response decode). No Lua tables cross states — encode returns a
--- string, decode takes a string. The heavy decode now runs in C on
--- whichever thread calls it (the lane for big responses), never on
--- main unless main explicitly asks.

local ffi = require("ffi")
local C = ffi.C

ffi.cdef([[
/* ── yyjson exported API (real symbols, real linkage) ──────────── */
typedef struct yyjson_doc yyjson_doc;
typedef struct yyjson_mut_doc yyjson_mut_doc;
typedef struct yyjson_val yyjson_val;
typedef struct yyjson_mut_val yyjson_mut_val;

/* yyjson_read_flag is uint; 0 = default (copy, validate). */
yyjson_doc *yyjson_read_opts(char *dat, size_t len, uint32_t flg, void *alc, void *err);
void shim_doc_free(yyjson_doc *doc);

yyjson_mut_doc *yyjson_mut_doc_new(void *alc);
void yyjson_mut_doc_free(yyjson_mut_doc *doc);

/* (shim wrappers — see vendor/yyjson/yyjson_shim.c) */
yyjson_val  *shim_doc_get_root(const yyjson_doc *doc);

uint8_t      shim_get_type(void *val);
bool         shim_is_str(void *v);
bool         shim_is_arr(void *v);
bool         shim_is_obj(void *v);
bool         shim_is_num(void *v);
bool         shim_is_bool(void *v);
bool         shim_is_null(void *v);
bool         shim_is_int(void *v);
bool         shim_is_real(void *v);

bool         shim_get_bool(void *v);
uint64_t     shim_get_uint(void *v);
int64_t      shim_get_sint(void *v);
double       shim_get_real(void *v);
const char  *shim_get_str(void *v, size_t *len_out);

/* Iterators: opaque structs in Lua (we only pass pointers to init/next).
 * Layout mirrors yyjson's public typedefs; sized large enough. */
typedef struct {
    size_t idx;
    size_t max;
    yyjson_val *cur;
} yyjson_arr_iter;
typedef struct {
    size_t idx;
    size_t max;
    yyjson_val *cur;
    yyjson_val *obj;
} yyjson_obj_iter;

bool         shim_arr_iter_init(void *arr, yyjson_arr_iter *iter);
void        *shim_arr_iter_next(yyjson_arr_iter *iter);
bool         shim_obj_iter_init(void *obj, yyjson_obj_iter *iter);
void        *shim_obj_iter_next(yyjson_obj_iter *iter);
void        *shim_obj_iter_get_val(void *key);

/* Direct by-key / by-index accessors — faster + cleaner from Lua than
 * spinning an iterator for a known-field lookup. */
size_t      shim_arr_size(const void *arr);
yyjson_val *shim_arr_get(const void *arr, size_t idx);
yyjson_val *shim_obj_get(const void *obj, const char *key);

/* Mutable builders. */
void         shim_mut_doc_set_root(void *doc, void *root);

void        *shim_mut_null(void *doc);
void        *shim_mut_true(void *doc);
void        *shim_mut_false(void *doc);
void        *shim_mut_bool(void *doc, bool b);
void        *shim_mut_sint(void *doc, int64_t i);
void        *shim_mut_uint(void *doc, uint64_t u);
void        *shim_mut_real(void *doc, double d);
void        *shim_mut_strn(void *doc, const char *s, size_t len);

void        *shim_mut_obj(void *doc);
void        *shim_mut_arr(void *doc);
bool         shim_mut_obj_add(void *obj, void *key, void *val);
bool         shim_mut_arr_append(void *arr, void *val);

char        *shim_mut_write(const void *doc, size_t *len_out);

/* C stdlib alloc (not in LuaJIT's default cdefs). */
void        *malloc(size_t n);
void         free(void *p);
]])

----------------------------------------------------------------------------------------------------
-- yyjson type tags (from yyjson.h YYJSON_TYPE_*).
----------------------------------------------------------------------------------------------------
local T_NONE = 0
local T_NULL = 2
local T_NUM = 4
local T_STR = 5
local T_ARR = 6
local T_OBJ = 7

local M = {}

----------------------------------------------------------------------------------------------------
-- DECODE: yyjson tree -> Lua value.
----------------------------------------------------------------------------------------------------

-- Forward decl (mutual recursion between obj/arr/scalar walkers).
local decode_val

--- Decode a scalar leaf (null/bool/num/str) into a Lua value.
--- Containers (arr/obj) handled by decode_val itself.
local function decode_scalar(val)
    local t = tonumber(C.shim_get_type(val))
    if t == T_NULL then
        return nil
    elseif t == T_STR then
        local lenp = ffi.new("size_t[1]")
        local p = C.shim_get_str(val, lenp)
        if p == nil then
            return ""
        end
        return ffi.string(p, tonumber(lenp[0]))
    elseif t == T_NUM then
        -- Prefer int when the number is integral + in Lua-number range;
        -- yyjson distinguishes uint/sint/real but Lua numbers are doubles.
        if C.shim_is_int(val) then
            local sv = tonumber(C.shim_get_sint(val))
            -- get_sint returns int64; for values that fit in a double
            -- exactly (|v| <= 2^53) tonumber is lossless. For huge
            -- uints we fall back to get_uint's string form is overkill
            -- here — LSP JSON ids are small ints.
            if sv then
                return sv
            end
        end
        return tonumber(C.shim_get_real(val))
    else
        -- true/false: yyjson tags TRUE/FALSE share the bool container
        -- type but get_type collapses to... actually true=1, false=3
        -- (subtypes). get_type returns RAW type bits; for bool the tag
        -- is non-NUM/STR/ARR/OBJ. Use is_bool + get_bool.
        if C.shim_is_bool(val) then
            return C.shim_get_bool(val) ~= 0
        end
    end
    return nil
end

decode_val = function(val)
    if val == nil then
        return nil
    end
    local t = tonumber(C.shim_get_type(val))
    if t == T_ARR then
        local iter = ffi.new("yyjson_arr_iter")
        if C.shim_arr_iter_init(val, iter) == false then
            return {}
        end
        local out = {}
        local i = 1
        local cur = C.shim_arr_iter_next(iter)
        while cur ~= nil do
            out[i] = decode_val(cur)
            i = i + 1
            cur = C.shim_arr_iter_next(iter)
        end
        return out
    elseif t == T_OBJ then
        local iter = ffi.new("yyjson_obj_iter")
        if C.shim_obj_iter_init(val, iter) == false then
            return {}
        end
        local out = {}
        local key = C.shim_obj_iter_next(iter)
        while key ~= nil do
            -- key is a yyjson_val* whose string payload is the field
            -- name; the paired value is the next sibling.
            local klen = ffi.new("size_t[1]")
            local kp = C.shim_get_str(key, klen)
            local kname = kp ~= nil and ffi.string(kp, tonumber(klen[0])) or tostring(key)
            local v = C.shim_obj_iter_get_val(key)
            out[kname] = decode_val(v)
            key = C.shim_obj_iter_next(iter)
        end
        return out
    else
        return decode_scalar(val)
    end
end

--- Parse a JSON string into a Lua value (table / string / number /
--- boolean / nil). Returns nil + an error message on failure.
--- @param s string JSON text
--- @return any value
--- @return string|nil err
function M.decode(s)
    if s == nil or #s == 0 then
        return nil, "empty input"
    end
    -- yyjson_read_opts takes a non-const char* (it MAY mutate under the
    -- INSITU flag; we pass flag 0 = no-insitu so it copies, but be
    -- safe: copy into a malloc'd buffer so an immutable Lua string is
    -- never handed to a C fn that could write it).
    local n = #s
    local buf = C.malloc(n)
    if buf == nil then
        return nil, "oom"
    end
    ffi.copy(buf, s, n)
    local doc = C.yyjson_read_opts(ffi.cast("char *", buf), n, 0, nil, nil)
    C.free(buf) -- doc parsed without INSITU; input no longer referenced
    if doc == nil then
        return nil, "parse error"
    end
    local root = C.shim_doc_get_root(doc)
    local ok, v = pcall(decode_val, root)
    C.shim_doc_free(doc)
    if not ok then
        return nil, tostring(v)
    end
    return v
end

--- Parse JSON into a yyjson_doc and return the doc + root WITHOUT
--- materializing a Lua table. The caller OWNS the doc and must free it
--- via `M.free_doc`. Use this (instead of `M.decode`) when you want to:
---   • hand the parsed tree to another thread (the doc is immutable +
---     thread-safe to read once written), or
---   • walk only a slice of the tree without paying to build the full
---     Lua value. yyjson_read (the heavy parse) runs HERE, on the
---     caller's thread — never on a thread that only receives the doc.
--- @param s string JSON text
--- @return any doc yyjson_doc* cdata | nil
--- @return any root yyjson_val* cdata | nil  (== shim_doc_get_root(doc))
--- @return string|nil err
function M.decode_to_doc(s)
    if s == nil or #s == 0 then
        return nil, nil, "empty input"
    end
    local n = #s
    local buf = C.malloc(n)
    if buf == nil then
        return nil, nil, "oom"
    end
    ffi.copy(buf, s, n)
    local doc = C.yyjson_read_opts(ffi.cast("char *", buf), n, 0, nil, nil)
    C.free(buf) -- parsed without INSITU; input no longer referenced
    if doc == nil then
        return nil, nil, "parse error"
    end
    return doc, C.shim_doc_get_root(doc), nil
end

--- Free a yyjson_doc returned by `decode_to_doc`. No-op on nil.
--- @param doc any yyjson_doc* cdata | nil
function M.free_doc(doc)
    if doc ~= nil then
        C.shim_doc_free(doc)
    end
end

----------------------------------------------------------------------------------------------------
-- ENCODE: Lua value -> yyjson mutable doc -> JSON string.
----------------------------------------------------------------------------------------------------

local function encode_val(doc, v)
    local tv = type(v)
    if tv == "nil" then
        return C.shim_mut_null(doc)
    elseif tv == "boolean" then
        return C.shim_mut_bool(doc, v)
    elseif tv == "number" then
        -- Emit integers as ints when they're integral + fit int64;
        -- otherwise real. math.type isn't available in LuaJIT 2.1
        -- without 5.3 extensions, so detect via floor + range.
        if v == math.floor(v) and v >= -9.2233720368548e18 and v <= 9.2233720368548e18 then
            return C.shim_mut_sint(doc, v)
        else
            return C.shim_mut_real(doc, v)
        end
    elseif tv == "string" then
        return C.shim_mut_strn(doc, v, #v)
    elseif tv == "table" then
        -- Distinguish array vs object: array if all keys are 1..#t
        -- (Lua's standard heuristic; sufficient for LSP payloads which
        -- are either pure arrays or pure string-keyed objects).
        local n = #v
        local is_array = n > 0
        if is_array then
            local arr = C.shim_mut_arr(doc)
            for i = 1, n do
                local val = encode_val(doc, v[i])
                if val ~= nil then
                    C.shim_mut_arr_append(arr, val)
                end
            end
            return arr
        else
            local obj = C.shim_mut_obj(doc)
            for k, val in pairs(v) do
                -- yyjson keys must be mut_str values, not raw C strings.
                local kv = C.shim_mut_strn(doc, tostring(k), #tostring(k))
                local mv = encode_val(doc, val)
                if kv ~= nil and mv ~= nil then
                    C.shim_mut_obj_add(obj, kv, mv)
                end
            end
            return obj
        end
    end
    -- Unsupported type (function/userdata): encode as null.
    return C.shim_mut_null(doc)
end

--- Encode a Lua value to a JSON string. Returns nil + err on failure.
--- @param v any table/string/number/boolean/nil
--- @return string|nil json
--- @return string|nil err
function M.encode(v)
    local doc = C.yyjson_mut_doc_new(nil)
    if doc == nil then
        return nil, "oom"
    end
    local ok, root = pcall(encode_val, doc, v)
    if not ok then
        C.yyjson_mut_doc_free(doc)
        return nil, tostring(root)
    end
    if root == nil then
        C.yyjson_mut_doc_free(doc)
        return "null"
    end
    C.shim_mut_doc_set_root(doc, root)
    local lenp = ffi.new("size_t[1]")
    local buf = C.shim_mut_write(doc, lenp)
    C.yyjson_mut_doc_free(doc) -- frees the tree; buf is a separate malloc
    if buf == nil then
        return nil, "write error"
    end
    local s = ffi.string(buf, tonumber(lenp[0]))
    C.free(buf)
    return s
end

return M
