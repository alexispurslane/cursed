--- Safe, typed wrapper around SharedState (IPC between lanes).
---
--- SharedState holds ring buffers for main↔IO communication.
--- Each ring buffer owns a kqueue fd; ring_push commits the message
--- and triggers an EVFILT_USER wake on the consumer's kqueue.
--- The piece table lives in Buffer objects, not here.

local ffi = require("ffi")
local shared_ffi = require("cursed.shared_ffi")
local c = shared_ffi.C
local pffi = require("cursed.posix_ffi")

---@class SharedState
---@field _ptr any struct SharedState *
local SharedState = {}
SharedState.__index = SharedState

----------------------------------------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------------------------------------

--- Create a SharedState wrapper from the C global g_shared_state.
---@return SharedState
function SharedState.from_global()
    return setmetatable({
        _ptr = ffi.C.g_shared_state,
    }, SharedState)
end

----------------------------------------------------------------------------------------------------
-- Ring buffer primitives
---------------------------------------------------------------------------------------------------

---@class Msg
---@field type integer Message type constant
---@field arg? integer Optional integer argument
---@field ptr? any Optional pointer or Lua string

--- Push a message onto a ring buffer.
--- ring_push commits the entry and triggers an EVFILT_USER wake on the
--- ring's kq_fd, so the consumer's blocked kevent() returns.
---@param ring any RingBuf pointer
---@param msg Msg
---@return boolean
function SharedState:push(ring, msg)
    local raw = ffi.new("struct Msg")
    raw.type = msg.type
    raw.arg = msg.arg or 0
    local p = msg.ptr
    if type(p) == "string" then
        local buf = ffi.new("char[?]", #p + 1)
        ffi.copy(buf, p)
        raw.ptr = buf
    else
        raw.ptr = p or nil
    end
    return c.ring_push(ring, raw)
end

--- Pop a message from a ring buffer.
---@param ring any RingBuf pointer
---@return Msg?
function SharedState:pop(ring)
    local raw = ffi.new("struct Msg")
    if not c.ring_pop(ring, raw) then
        return nil
    end
    return {
        type = raw.type,
        arg = raw.arg,
        ptr = raw.ptr,
    }
end

----------------------------------------------------------------------------------------------------
-- Running flag
----------------------------------------------------------------------------------------------------

--- Check if the shared state is still running.
---@return boolean
function SharedState:running()
    return self._ptr.running
end

--- Signal the lanes to stop. Sends MSG_SHUTDOWN to both the IO
--- lane and the highlight lane so each exits its blocking kevent().
function SharedState:stop()
    self._ptr.running = false
    -- Send an explicit shutdown message through each lane's outbox.
    -- ring_push triggers EVFILT_USER on the consumer's kqueue,
    -- waking it so it can exit.
    self:push(self._ptr.outbox_io, { type = shared_ffi.MSG_SHUTDOWN })
    self:push(self._ptr.outbox_hl, { type = shared_ffi.MSG_SHUTDOWN })
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

--- Allocate and fill an HlInitLangReq (header + query bytes + injected
--- language bundle). The receiver (highlight lane) frees it. Returned
--- cdata owns the malloc.
---
--- `injection_query_src` is the tree-sitter injections query that walks
--- the block tree for content regions to inject another grammar into.
--- nil/empty for plain single-parser languages.
---
--- `injected_langs` is a list of {language=string, query_src=string} for
--- every grammar the injection query may reference (the lane needs each
--- one's parser + highlight query pre-built so it can dispatch at runtime).
--- Pass nil/empty for non-injection languages.
---@param language string block grammar name
---@param query_src string block query source
---@param injection_query_src string|nil injection query source, or nil
---@param injected_langs table|nil list of {language, query_src}, or nil
---@return any struct HlInitLangReq* (gc-managed: caller may keep ref)
function SharedState:make_hl_init_lang_req(language, query_src, injection_query_src, injected_langs)
    local c = shared_ffi.C
    local header_sz = ffi.sizeof("struct HlInitLangReq")
    local injql = injection_query_src and #injection_query_src or 0
    injected_langs = injected_langs or {}
    local bundle_sz = 0
    for _, il in ipairs(injected_langs) do
        bundle_sz = bundle_sz + ffi.sizeof("struct HlInjectedLang") + #il.query_src
    end
    local total = header_sz + #query_src + injql + bundle_sz
    local buf = c.calloc(1, total)
    local req = ffi.cast("struct HlInitLangReq *", buf)
    ffi.fill(req.language, 16, 0)
    ffi.copy(req.language, language, math.min(#language, 15))
    req.query_len = #query_src
    req.injection_query_len = injql
    req.injected_lang_count = #injected_langs
    local off = header_sz
    ffi.copy(ffi.cast("char *", buf) + off, query_src, #query_src)
    off = off + #query_src
    if injql > 0 then
        ffi.copy(ffi.cast("char *", buf) + off, injection_query_src, injql)
        off = off + injql
    end
    for _, il in ipairs(injected_langs) do
        local il_ptr = ffi.cast("struct HlInjectedLang *", ffi.cast("char *", buf) + off)
        ffi.fill(il_ptr.language, 16, 0)
        ffi.copy(il_ptr.language, il.language, math.min(#il.language, 15))
        il_ptr.query_len = #il.query_src
        off = off + ffi.sizeof("struct HlInjectedLang")
        ffi.copy(ffi.cast("char *", buf) + off, il.query_src, #il.query_src)
        off = off + #il.query_src
    end
    return req
end

--- Allocates and fills an HlQueryReq for a contiguous bucket range
--- [bucket_start, bucket_end). The text buffer is a SEPARATE malloc that
--- the highlight lane takes ownership of (it backs old_tree nodes); the
--- HlQueryReq struct itself is freed by the lane after it copies out the
--- fields.
---
--- `text_ptr` is a pre-allocated char* of `text_len` bytes (caller-
--- owned, typically from Buffer:write_text_direct — direct memcpy of the
--- piece table, no Lua string intermediate). Ownership transfers to the
--- lane. Pass nil/0 for an empty document.
---@param language string
---@param view_id integer
---@param bucket_start integer first bucket (inclusive)
---@param bucket_end integer one past the last bucket (exclusive)
---@param gen integer
---@param has_edit boolean
---@param edit table? {start_byte, old_end_byte, new_end_byte, start_row, start_col, old_end_row, old_end_col, new_end_row, new_end_col}
---@param text_ptr any char* malloc'd buffer of text_len bytes (ownership transfers)
---@param text_len integer byte length of text_ptr's content
---@return any struct HlQueryReq* (gc-managed)
---@return any text_ptr raw malloc buffer
function SharedState:make_hl_query_req(
    language,
    view_id,
    bucket_start,
    bucket_end,
    gen,
    has_edit,
    edit,
    text_ptr,
    text_len,
    force_cold
)
    local c = shared_ffi.C
    local req = ffi.cast("struct HlQueryReq *", c.calloc(1, ffi.sizeof("struct HlQueryReq")))
    ffi.fill(req.language, 16, 0)
    ffi.copy(req.language, language, math.min(#language, 15))
    req.view_id = view_id
    req.bucket_start = bucket_start
    req.bucket_end = bucket_end
    req.gen = gen
    req.has_edit = has_edit and true or false
    req.force_cold = force_cold and true or false
    if has_edit and edit then
        req.start_byte = edit.start_byte
        req.old_end_byte = edit.old_end_byte
        req.new_end_byte = edit.new_end_byte
        req.start_row = edit.start_row
        req.start_col = edit.start_col
        req.old_end_row = edit.old_end_row
        req.old_end_col = edit.old_end_col
        req.new_end_row = edit.new_end_row
        req.new_end_col = edit.new_end_col
    end
    -- The caller's text_ptr is taken as-is (no copy — Buffer:write_text_direct
    -- already wrote the piece table directly into a calloc'd buffer). The lane
    -- takes ownership and frees it via ffi.gc when superseded.
    req.text = text_ptr
    req.text_len = text_len
    return req, text_ptr
end

return {
    SharedState = SharedState,
    MSG_FILE_LOAD = shared_ffi.MSG_FILE_LOAD,
    MSG_FILE_LOADED = shared_ffi.MSG_FILE_LOADED,
    MSG_FILE_ERROR = shared_ffi.MSG_FILE_ERROR,
    MSG_FILE_SAVE = shared_ffi.MSG_FILE_SAVE,
    MSG_FILE_SAVED = shared_ffi.MSG_FILE_SAVED,
    MSG_SHUTDOWN = shared_ffi.MSG_SHUTDOWN,
    MSG_INSERT_FILE = shared_ffi.MSG_INSERT_FILE,
    MSG_FILE_INSERTED = shared_ffi.MSG_FILE_INSERTED,
    MSG_HL_INITIALIZE_LANGUAGE = shared_ffi.MSG_HL_INITIALIZE_LANGUAGE,
    MSG_HL_QUERY = shared_ffi.MSG_HL_QUERY,
    MSG_HL_SPANS = shared_ffi.MSG_HL_SPANS,
    O_RDONLY = pffi.O_RDONLY,
    O_WRONLY = pffi.O_WRONLY,
    O_CREAT = pffi.O_CREAT,
    O_TRUNC = pffi.O_TRUNC,
    PROT_READ = pffi.PROT_READ,
    PROT_WRITE = pffi.PROT_WRITE,
    MAP_PRIVATE = pffi.MAP_PRIVATE,
    _SC_PAGESIZE = pffi._SC_PAGESIZE,
}
