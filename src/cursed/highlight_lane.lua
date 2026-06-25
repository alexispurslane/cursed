--- Highlight Lane — runs tree-sitter parse + query off the main thread.
---
--- Own pthread + own lua_State (spawned from main.c::highlight_lane_thread).
--- Receives byte regions from the main lane via outbox_hl, queries the
--- parse tree for that region, and returns absolute-byte spans via
--- inbox_hl. Full state cache lives here (per-language parser/query +
--- per-document old_tree); see docs/highlight-async-design.md.
---
--- This module is loaded as a top-level chunk (twin of io_lane.lua):
--- its body is the lane's main loop, not a library.

local ffi = require("ffi")
local log = require("cursed.log")
local ss = require("cursed.shared").SharedState.from_global()
local constants = require("cursed.shared")
local Kqueue = require("cursed.kqueue").Kqueue
local ts = require("cursed.ts")

-- Wrap the highlight lane's kqueue. Main pushes to outbox_hl and
-- ring_push triggers EVFILT_USER here; we block until that fires.
local hl_kq = Kqueue.wrap(ss._ptr.hl_kq_fd)
hl_kq:add_wake(assert(tonumber(ss._ptr.outbox_hl.wake_ident)))

log.configure({ level = "info", output = "/tmp/cursed.log" })
log.info("highlight_lane", "started")

--- Wall-clock microseconds for per-stage profiling of handle_query.
--- Temporary instrumentation for the big-file flash investigation.
local pffi_prof = require("cursed.posix_ffi")
local function now_us()
    local tv = ffi.new("struct timeval[1]")
    pffi_prof.C.gettimeofday(tv, nil)
    return tonumber(tv[0].tv_sec) * 1000000 + tonumber(tv[0].tv_usec)
end

----------------------------------------------------------------------------------------------------
-- Two-layer state cache: per_lang[language] = {parser, query, cursor, docs}
----------------------------------------------------------------------------------------------------

---@type table<string, {lang_ptr:any, parser:any, query:any, cursor:any, injection_query:any|nil, injected:table<string, {parser:any, query:any, cursor:any}>|nil, docs:table<integer, {old_tree:any, last_text:any, last_text_len:integer, gen:integer}>}>
local per_lang = {}

--- Build (or rebuild) the per-language state for `language` using the
--- given query source. Drops any existing entry first (TSQuery is not
--- mutable; the parser is cheap to rebuild relative to the query).
---
--- For injecting languages (markdown), `injection_query_src` walks the
--- block tree for content regions belonging to another grammar, and
--- `injected_langs` lists every grammar the injection may reference
--- (each with its own highlight query). The state then owns the block
--- parser/query/cursor PLUS a per-injected-grammar {parser,query,cursor}
--- table; handle_query runs the injection query, resolves each match's
--- grammar (from @injection.language capture text or #set!
--- injection.language directive), parses the content range with that
--- grammar's parser (set_included_ranges), and merges captures.
---@param language string
---@param query_src string block highlight query
---@param injection_query_src string|nil injection query, or nil
---@param injected_langs table|nil list of {language=string, query_src=string}
---@return table|nil state
---@return string|nil errmsg
local function init_language(language, query_src, injection_query_src, injected_langs)
    local lang_ptr, lerr = ts.lang_get(language)
    if not lang_ptr then
        return nil, lerr
    end

    local parser, perr = ts.Parser.new(lang_ptr)
    if not parser then
        return nil, perr
    end

    -- NOTE: ts_parser_set_timeout_micros is not available in this vendored
    -- tree-sitter (ABI 15; the timeout API landed in v0.25+). Pathological
    -- input is instead bounded by the async lane + bucket structure: a
    -- slow parse blocks the lane (not the UI), and a bucket just renders
    -- plain until the lane responds. Revisit when the vendored tree-sitter
    -- is upgraded.

    local query, qerr = ts.Query.new(lang_ptr, query_src)
    if not query then
        return nil, qerr
    end

    local cursor, cerr = ts.QueryCursor.new()
    if not cursor then
        return nil, cerr
    end

    local state = {
        lang_ptr = lang_ptr,
        parser = parser,
        query = query,
        cursor = cursor,
        injection_query = nil,
        injected = nil,
        docs = {}, ---@type table<integer, {old_tree:any, last_text:any, last_text_len:integer, gen:integer}>
    }

    if injection_query_src ~= nil and injection_query_src ~= "" then
        local iq, ierr = ts.Query.new(lang_ptr, injection_query_src)
        if not iq then
            return nil, ierr
        end
        state.injection_query = iq
        state.injected = {}
        for _, il in ipairs(injected_langs or {}) do
            local il_ptr, ile = ts.lang_get(il.language)
            if il_ptr then
                local ip, ipe = ts.Parser.new(il_ptr)
                local iq2, iqe
                local ic, ice
                if ip then
                    iq2, iqe = ts.Query.new(il_ptr, il.query_src)
                end
                if iq2 then
                    ic, ice = ts.QueryCursor.new()
                end
                if ip and iq2 and ic then
                    state.injected[il.language] = { parser = ip, query = iq2, cursor = ic }
                else
                    log.warn("highlight_lane", "failed to init injected grammar", {
                        language = il.language,
                        err = tostring(ile or ipe or iqe or ice),
                    })
                end
            end
        end
    end

    per_lang[language] = state
    return state, nil
end

----------------------------------------------------------------------------------------------------
-- Capture collection: gather all matching captures from a query over a
-- (sub)tree, restricted to [bucket_start, bucket_end). Returns a flat
-- list of {cs, ce, name, node} in start-byte order (ties → smaller
-- pattern index, which tree-sitter's cursor:captures() already yields).
-- Both block and inline captures use ABSOLUTE byte offsets, so they can
-- be merged into one stream and the same stack walk resolves overlaps.
----------------------------------------------------------------------------------------------------

--- Collect captures from `cursor` exec'd over `root`, filtered to those
--- starting inside [bucket_start, bucket_end). Returns captures in order.
--- Uses filtered_captures (next_match + predicate eval) so queries with
--- #eq?/#set!/etc. work; predicate-free queries take the same path
--- (predicates_for_pattern returns nil → no filtering).
--- `get_text_fn(start_byte, end_byte)` provides node text for predicates.
---@param cursor any QueryCursor (already exec'd)
---@param bucket_start integer
---@param bucket_end integer
---@param get_text_fn function(int,int)->string
---@return table[] caps {cs, ce, name, node}
local function collect_captures(cursor, bucket_start, bucket_end, get_text_fn)
    local caps = {}
    for cap in cursor:filtered_captures(get_text_fn) do
        local cs = cap.start_byte
        local ce = cap.end_byte
        if cs < ce and cs < bucket_end and ce > bucket_start then
            caps[#caps + 1] = { cs = cs, ce = ce, name = cap.name, node = cap.node }
        end
    end
    return caps
end

--- Filter a pre-collected, sorted capture list to those intersecting
--- [bucket_start, bucket_end). `caps` is sorted by `cs` ascending, so we
--- can stop early once a capture starts past the bucket end. Returns a
--- new list (stable order preserved).
---@param caps table[] {cs, ce, name, node} sorted by cs
---@param bucket_start integer
---@param bucket_end integer
---@return table[]
local function filter_caps(caps, bucket_start, bucket_end)
    local out = {}
    for i = 1, #caps do
        local c = caps[i]
        if c.cs >= bucket_end then
            break
        end
        if c.ce > bucket_start then
            out[#out + 1] = c
        end
    end
    return out
end

-- Merge two sorted capture lists (by start byte; ties keep block before
-- inline so an inline capture declared at the same byte stacks ON TOP of
-- the block one — inline spans are the more specific styling). Stable.
---@param a table[] block captures (sorted)
---@param b table[] inline captures (sorted)
---@return table[] merged
local function merge_captures(a, b)
    if b == nil or #b == 0 then
        return a
    end
    if a == nil or #a == 0 then
        return b
    end
    local merged = {}
    local i, j = 1, 1
    while i <= #a and j <= #b do
        if a[i].cs <= b[j].cs then
            merged[#merged + 1] = a[i]
            i = i + 1
        else
            merged[#merged + 1] = b[j]
            j = j + 1
        end
    end
    while i <= #a do
        merged[#merged + 1] = a[i]
        i = i + 1
    end
    while j <= #b do
        merged[#merged + 1] = b[j]
        j = j + 1
    end
    return merged
end

----------------------------------------------------------------------------------------------------
-- Stack algorithm: walk captures in start-byte order, resolve overlaps
-- (last-pushed wins for its range; outer resumes when inner closes),
-- filter to captures that START inside [bucket_start, bucket_end).
--
-- Returns a flat list of {start_byte, end_byte, cap_index} where
-- cap_index is into the local `names` table (capture name → index).
-- The name table is emitted alongside the spans in the response.
--
-- This mirrors highlighter.lua's build_segments, minus the per-line step
-- and minus fg resolution (the main lane resolves fg from capture name).
----------------------------------------------------------------------------------------------------

local BUCKET_BYTES = 8192

--- Run the stack algorithm for a contiguous bucket range
--- [bucket_lo, bucket_hi) (byte range [bucket_lo*BUCKET_BYTES,
--- bucket_hi*BUCKET_BYTES)). A single response covers the whole range with
--- one shared capture-name table; spans carry no bucket tag (main sorts by
--- start byte) and the response echoes bucket_lo/hi so main can replace
--- every bucket in the range, empty ones included.
---
--- For injecting languages (markdown), `injection_caps` is a SORTED list
--- of captures from all injected-grammar parses (one entry per content
--- region × capture). They use ABSOLUTE byte offsets, so they merge with
--- the block captures straight into the same stack walk so e.g. bold/italic
--- spans (markdown_inline) layer on top of heading structure, and a
--- ```lua fenced block's content gets lua syntax colors. nil for
--- single-parser languages.
---@param state table per_lang entry
---@param root any TSNode block tree root
---@param bucket_lo integer first bucket (inclusive)
---@param bucket_hi integer one past the last bucket (exclusive)
---@param injection_caps table[]|nil sorted injected captures
---@param get_text_fn function(int,int)->string
---@return {start_byte:integer, end_byte:integer, cap_index:integer}[] spans
---@return string[] names capture-name table (index 1..n)
local function build_range_spans(state, root, bucket_lo, bucket_hi, injection_caps, get_text_fn)
    local cursor = state.cursor
    local query = state.query

    -- Capture-name interning shared across all buckets in this response.
    local name_index = {} ---@type table<string, integer>
    local names = {} ---@type string[]

    local function intern(name)
        local idx = name_index[name]
        if idx == nil then
            idx = #names + 1
            names[idx] = name
            name_index[name] = idx
        end
        -- 0-based so the C HlSpan.cap_index + main's `names[cap_index+1]` line up.
        return idx - 1
    end

    local spans = {} ---@type {start_byte:integer, end_byte:integer, cap_index:integer}[]

    for b = bucket_lo, bucket_hi - 1 do
        local bucket_start = b * BUCKET_BYTES
        local bucket_end = bucket_start + BUCKET_BYTES
        cursor:set_byte_range(bucket_start, bucket_end)
        cursor:exec(query, root)
        local caps = collect_captures(cursor, bucket_start, bucket_end, get_text_fn)

        -- Injecting: also include injected captures intersecting this
        -- bucket, and merge. Injected captures stack on top of block
        -- captures so e.g. a bold span inside a heading gets the
        -- emphasis color, and a `````lua fenced block gets lua colors.
        if injection_caps ~= nil and #injection_caps > 0 then
            local inj = filter_caps(injection_caps, bucket_start, bucket_end)
            if #inj > 0 then
                caps = merge_captures(caps, inj)
            end
        end

        local stack = {} ---@type {eb:integer, cap_index:integer, node:any}[]
        local pos = bucket_start

        local function current_cap_index()
            local top = stack[#stack]
            return top and top.cap_index or nil
        end

        --- Emit [pos, up_to] under the current top's color, clamped to the
        --- bucket range. Captures starting before the bucket still go on
        --- the stack so their color resumes correctly inside the bucket.
        local function emit(up_to)
            if up_to > bucket_end then
                up_to = bucket_end
            end
            if up_to <= pos then
                return
            end
            local idx = current_cap_index()
            if idx ~= nil then
                spans[#spans + 1] = { start_byte = pos, end_byte = up_to, cap_index = idx }
            end
            pos = up_to
        end

        for ci = 1, #caps do
            local cap = caps[ci]
            local cs, ce = cap.cs, cap.ce
            -- Close any open captures that end at or before this one starts.
            while #stack > 0 and stack[#stack].eb <= cs do
                emit(stack[#stack].eb)
                stack[#stack] = nil
            end
            -- Advance to this capture's start under the (possibly new) top,
            -- filling the gap with the enclosing color (resume logic).
            emit(cs)
            local idx = intern(cap.name)
            -- Same-node later-capture wins (replace top's color).
            local top = stack[#stack]
            if top ~= nil and top.eb == ce and ts.node_eq(top.node, cap.node) then
                top.cap_index = idx
            else
                stack[#stack + 1] = { eb = ce, cap_index = idx, node = cap.node }
            end
        end

        -- Flush remaining open captures (clamped to bucket_end by emit).
        while #stack > 0 do
            emit(stack[#stack].eb)
            stack[#stack] = nil
        end
    end

    return spans, names
end

----------------------------------------------------------------------------------------------------
-- Pack spans + names into a malloc'd HlSpansHDR + body, send to inbox_hl.
-- Main lane frees the buffer after installing into its cache.
----------------------------------------------------------------------------------------------------

local HlSpansHdr_t = ffi.typeof("struct HlSpansHdr")
local HlSpan_t = ffi.typeof("struct HlSpan")
local HlName_t = ffi.typeof("struct HlName")

--- Pack and enqueue an empty response (lane error / unknown language).
---@param gen integer
---@param bucket_start integer
---@param bucket_end integer
local function send_empty_spans(gen, bucket_start, bucket_end)
    local hdr = ffi.cast("struct HlSpansHdr *", ffi.C.calloc(1, ffi.sizeof(HlSpansHdr_t)))
    hdr.gen = gen
    hdr.bucket_start = bucket_start
    hdr.bucket_end = bucket_end
    hdr.count = 0
    hdr.name_count = 0
    ss:push(ss._ptr.inbox_hl, { type = constants.MSG_HL_SPANS, ptr = hdr })
end
--- Pack spans + names into one allocation and push onto inbox_hl.
--- `buf_text` is the malloc'd text buffer the main lane sent us; the
--- lane retains it as old_text backing (tree-sitter nodes reference
--- the parser's retained input), so we keep ownership here, NOT freed.
---@param gen integer
---@param bucket_start integer first bucket this response covers (inclusive)
---@param bucket_end integer one past the last bucket (exclusive)
---@param spans {start_byte:integer, end_byte:integer, cap_index:integer}[]
---@param names string[]
local function send_spans(gen, bucket_start, bucket_end, spans, names)
    local total = ffi.sizeof(HlSpansHdr_t)
        + #spans * ffi.sizeof(HlSpan_t)
        + #names * ffi.sizeof(HlName_t)
    local buf = ffi.C.calloc(1, total)
    if buf == nil then
        log.error("highlight_lane", "calloc failed", { total = total })
        ss:push(ss._ptr.inbox_hl, { type = constants.MSG_HL_SPANS, ptr = nil })
        return
    end
    local hdr = ffi.cast("struct HlSpansHdr *", buf)
    hdr.gen = gen
    hdr.bucket_start = bucket_start
    hdr.bucket_end = bucket_end
    hdr.count = #spans
    hdr.name_count = #names

    local span_arr = ffi.cast("struct HlSpan *", ffi.cast("char *", buf) + ffi.sizeof(HlSpansHdr_t))
    for i, s in ipairs(spans) do
        span_arr[i - 1].start_byte = s.start_byte
        span_arr[i - 1].end_byte = s.end_byte
        span_arr[i - 1].cap_index = s.cap_index
    end

    local name_arr = ffi.cast(
        "struct HlName *",
        ffi.cast("char *", buf) + ffi.sizeof(HlSpansHdr_t) + #spans * ffi.sizeof(HlSpan_t)
    )
    for i, n in ipairs(names) do
        local field = name_arr[i - 1].name
        ffi.fill(field, 32, 0)
        ffi.copy(field, n, math.min(#n, 31))
    end

    ss:push(ss._ptr.inbox_hl, { type = constants.MSG_HL_SPANS, ptr = buf })
end

----------------------------------------------------------------------------------------------------
-- Message handlers
----------------------------------------------------------------------------------------------------

--- MSG_HL_INITIALIZE_LANGUAGE: build/replace parser+query for a language.
--- Payload (HlInitLangReq) is freed by the lane (allocated by main).
local function handle_init_language(msg)
    if msg.ptr == nil then
        return
    end
    local req = ffi.cast("struct HlInitLangReq *", msg.ptr)
    local language = ffi.string(req.language, 16)
    local nul = language:find("%z")
    if nul then
        language = language:sub(1, nul - 1)
    end
    local query_len = tonumber(req.query_len)
    ---@cast query_len integer
    local injection_query_len = tonumber(req.injection_query_len)
    ---@cast injection_query_len integer
    local injected_count = tonumber(req.injected_lang_count)
    ---@cast injected_count integer
    local off = ffi.sizeof("struct HlInitLangReq")
    local query_src = ffi.string(ffi.cast("const char *", req) + off, query_len)
    off = off + query_len
    local injection_query_src = nil
    if injection_query_len > 0 then
        injection_query_src = ffi.string(ffi.cast("const char *", req) + off, injection_query_len)
    end
    off = off + injection_query_len
    local injected_langs = nil
    if injected_count > 0 then
        injected_langs = {}
        for _ = 1, injected_count do
            local il = ffi.cast("struct HlInjectedLang *", ffi.cast("char *", req) + off)
            local name = ffi.string(il.language, 16)
            local ln = name:find("%z")
            if ln then
                name = name:sub(1, ln - 1)
            end
            local qlen = tonumber(il.query_len)
            ---@cast qlen integer
            off = off + ffi.sizeof("struct HlInjectedLang")
            local qsrc = ffi.string(ffi.cast("const char *", req) + off, qlen)
            off = off + qlen
            injected_langs[#injected_langs + 1] = { language = name, query_src = qsrc }
        end
    end
    ffi.C.free(req)

    local ok, err = xpcall(function()
        local state, ierr = init_language(language, query_src, injection_query_src, injected_langs)
        if not state then
            log.error(
                "highlight_lane",
                "init_language failed",
                { language = language, error = tostring(ierr) }
            )
        else
            log.info("highlight_lane", "language initialized", {
                language = language,
                query_len = query_len,
                injecting = injection_query_src ~= nil,
                injected_count = injected_count,
            })
        end
    end, function(e)
        log.error(
            "highlight_lane",
            "init_language panic",
            { language = language, error = tostring(e) }
        )
    end)
    if not ok then
        -- swiped under the rug; the next query for this lang will send
        -- an empty spans response.
    end
end

--- MSG_HL_QUERY: parse, query the bucket, return spans.
--- Payload (HlQueryReq) holds the text snapshot; ownership of the text
--- transfers to the lane (it backs old_tree nodes). The HlQueryReq
--- struct itself is freed here; the text buffer is retained in
--- doc_state.last_text (GC'd when superseded).
local function handle_query(msg)
    if msg.ptr == nil then
        return
    end
    local req = ffi.cast("struct HlQueryReq *", msg.ptr)

    -- Copy out the scalar fields we need before freeing the struct.
    -- The text buffer stays alive (it's a separate allocation owned by
    -- the lane from here on).
    local language = ffi.string(req.language, 16)
    local nul = language:find("%z")
    if nul then
        language = language:sub(1, nul - 1)
    end
    local view_id = tonumber(req.view_id)
    local bucket_start = tonumber(req.bucket_start)
    local bucket_end = tonumber(req.bucket_end)
    local gen = tonumber(req.gen)
    local has_edit = req.has_edit
    local force_cold = req.force_cold
    local start_byte = tonumber(req.start_byte)
    local old_end_byte = tonumber(req.old_end_byte)
    local new_end_byte = tonumber(req.new_end_byte)
    local start_row = tonumber(req.start_row)
    local start_col = tonumber(req.start_col)
    local old_end_row = tonumber(req.old_end_row)
    local old_end_col = tonumber(req.old_end_col)
    local new_end_row = tonumber(req.new_end_row)
    local new_end_col = tonumber(req.new_end_col)
    local text_ptr = req.text
    local text_len = tonumber(req.text_len)

    -- Free the HlQueryReq struct (NOT the text buffer).
    ffi.C.free(req)

    local state = per_lang[language]
    if not state then
        log.error("highlight_lane", "query for uninitialized language", { language = language })
        send_empty_spans(gen or 0, bucket_start or 0, bucket_end or (bucket_start or 0))
        if text_ptr ~= nil then
            ffi.C.free(text_ptr)
        end
        return
    end

    -- All scalar fields are non-nil past this point (parse succeeded).
    ---@cast view_id integer
    ---@cast bucket_start integer
    ---@cast bucket_end integer
    ---@cast gen integer
    ---@cast text_len integer

    local ok, err = xpcall(function()
        local t0 = now_us()
        local doc_state = state.docs[view_id]
        if doc_state == nil then
            doc_state = {
                old_tree = nil,
                last_text = nil,
                last_text_len = 0,
                gen = 0,
            }
            state.docs[view_id] = doc_state
        end

        local injecting = state.injection_query ~= nil and state.injected ~= nil

        -- Block parse (same logic as single-parser languages).
        local text_cdata = nil
        if text_ptr ~= nil then
            text_cdata = ffi.gc(ffi.cast("char *", text_ptr), ffi.C.free)
        end
        local tree = nil
        local inc = false
        local reused = false
        if has_edit and doc_state.old_tree and doc_state.gen == gen - 1 then
            doc_state.old_tree:edit({
                start_byte = start_byte,
                old_end_byte = old_end_byte,
                new_end_byte = new_end_byte,
                start_point = { row = start_row, column = start_col },
                old_end_point = { row = old_end_row, column = old_end_col },
                new_end_point = { row = new_end_row, column = new_end_col },
            })
            inc = true
            tree = state.parser:parse_string_ptr(text_ptr, text_len, doc_state.old_tree)
        elseif (not force_cold) and doc_state.old_tree and doc_state.last_text_len == text_len then
            tree = doc_state.old_tree
            reused = true
        else
            tree = state.parser:parse_string_ptr(text_ptr, text_len, nil)
        end

        if not tree then
            log.error("highlight_lane", "block parse failed", { language = language })
            send_empty_spans(gen, bucket_start, bucket_end)
            doc_state.old_tree = nil
            doc_state.last_text = text_cdata
            doc_state.last_text_len = text_len
            doc_state.gen = gen
            return
        end

        -- Node-text slicer for predicate evaluation: pulls [sb, eb) bytes
        -- directly from the malloc'd text buffer (no Lua string copy).
        -- Defined here so the injection pass below can use it too.
        local function get_text_fn(sb, eb)
            if text_ptr == nil then
                return ""
            end
            if eb > text_len then
                eb = text_len
            end
            if sb >= eb then
                return ""
            end
            return ffi.string(ffi.cast("const char *", text_ptr) + sb, eb - sb)
        end
        local t2 = now_us()

        -- Injection pass (injecting languages only): run the injection
        -- query (filtered_matches over the block tree) to find content
        -- regions + which grammar to parse each with. For each match,
        -- resolve the language (either the @injection.language capture's
        -- text, or #set! injection.language directive), parse that range
        -- with the resolved grammar's parser (set_included_ranges),
        -- collect its captures (filtered_captures over the injected
        -- query), and merge into one sorted list for build_range_spans.
        -- All injected captures use ABSOLUTE byte offsets, so they merge
        -- with block captures directly. No incremental reuse for
        -- injected trees (re-parse each query) — the ranges are small and
        -- incremental edit-shift for ranged parses is non-trivial.
        local injection_caps = nil
        local injection_count = 0
        if injecting then
            local inj_cursor = state.cursor -- reuse the lane's only cursor
            inj_cursor:set_byte_range(0, text_len)
            inj_cursor:exec(state.injection_query, tree:root())
            injection_caps = {} ---@type table[] {cs, ce, name, node}

            -- Process one injection match: resolve language, parse the
            -- content range with that grammar, collect captures. Returns
            -- the number of captures added (0 on skip/failure).
            local function process_match(match)
                local lang_name = nil
                if match.directives ~= nil then
                    lang_name = match.directives["injection.language"]
                end
                local content_node = nil
                -- Always scan for @injection.content (independent of how
                -- lang_name was resolved) and, if needed, the
                -- @injection.language capture text.
                for _, cap in ipairs(match.captures) do
                    if cap.name == "injection.content" and content_node == nil then
                        content_node = cap.node
                    elseif cap.name == "injection.language" and lang_name == nil then
                        local sb = ts.node_start_byte(cap.node)
                        local eb = ts.node_end_byte(cap.node)
                        lang_name = get_text_fn(sb, eb)
                    end
                end
                if lang_name == nil or content_node == nil then
                    return 0
                end
                local injected = state.injected and state.injected[lang_name]
                -- Unknown fence label (e.g. `````text```) — no injected
                -- grammar; the block tree's @text.literal already covers it.
                if injected == nil then
                    return 0
                end
                local csb = ts.node_start_byte(content_node)
                local ceb = ts.node_end_byte(content_node)
                if ceb <= csb then
                    return 0
                end
                injected.parser:set_included_ranges({
                    { start_byte = csb, end_byte = ceb },
                })
                local ok_inl, itree = pcall(
                    injected.parser.parse_string_ptr,
                    injected.parser,
                    text_ptr,
                    text_len,
                    nil
                )
                injected.parser:set_included_ranges(nil)
                if not ok_inl or itree == nil then
                    log.error("highlight_lane", "injected parse failed", {
                        language = language,
                        injected = lang_name,
                        error = tostring(itree),
                    })
                    return 0
                end
                injected.cursor:set_byte_range(csb, ceb)
                injected.cursor:exec(injected.query, itree:root())
                local added = 0
                for cap in injected.cursor:filtered_captures(get_text_fn) do
                    if cap.start_byte < cap.end_byte then
                        injection_caps[#injection_caps + 1] = {
                            cs = cap.start_byte,
                            ce = cap.end_byte,
                            name = cap.name,
                            node = cap.node,
                        }
                        added = added + 1
                    end
                end
                return added
            end

            local match_total = 0
            for match in inj_cursor:filtered_matches(get_text_fn) do
                match_total = match_total + 1
                if process_match(match) > 0 then
                    injection_count = injection_count + 1
                end
            end
            log.info("highlight_lane", "injection pass", {
                language = language,
                matches = match_total,
                injected = injection_count,
                cap_count = #injection_caps,
            })
            -- Sort injected captures by start byte (stable: ties keep
            -- insertion order, so block then inline for the same byte).
            table.sort(injection_caps, function(a, b)
                return a.cs < b.cs
            end)
        end

        local total_buckets = math.floor((text_len + BUCKET_BYTES - 1) / BUCKET_BYTES)
        if bucket_end > total_buckets then
            bucket_end = total_buckets
        end
        if bucket_start > total_buckets then
            bucket_start = total_buckets
        end
        local spans, names = build_range_spans(
            state,
            tree:root(),
            bucket_start,
            bucket_end,
            injection_caps,
            get_text_fn
        )
        local t3 = now_us()
        send_spans(gen, bucket_start, bucket_end, spans, names)
        local t4 = now_us()
        log.info("highlight_lane", "hl_stage", {
            gen = gen,
            inc = inc,
            reused = reused,
            injecting = injecting,
            injection_count = injection_count,
            text_len = text_len,
            buckets = bucket_end - bucket_start,
            span_count = #spans,
            parse_us = t2 - t0,
            build_us = t3 - t2,
            send_us = t4 - t3,
            total_us = t4 - t0,
        })

        -- Retain trees + text for the next incremental parse.
        if reused then
            doc_state.gen = gen
        else
            doc_state.old_tree = tree
            doc_state.last_text = text_cdata
            doc_state.last_text_len = text_len
            doc_state.gen = gen
        end
    end, function(e)
        log.error("highlight_lane", "query panic", {
            language = language,
            view_id = view_id,
            error = tostring(e),
        })
        send_empty_spans(gen, bucket_start, bucket_end)
        if text_ptr ~= nil then
            -- On panic, free the text buffer ourselves since the
            -- xpcall'd closure never took ownership of it via ffi.gc.
            ffi.C.free(text_ptr)
        end
    end)
    ---@cast ok boolean
    if not ok then
        -- Text was already freed inside the error handler in the panic
        -- path; nothing more to do.
    end
end

----------------------------------------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------------------------------------

while ss:running() do
    hl_kq:wait(-1)

    local msg = ss:pop(ss._ptr.outbox_hl)
    while msg ~= nil do
        local _, perr = xpcall(function()
            if msg.type == constants.MSG_HL_INITIALIZE_LANGUAGE then
                handle_init_language(msg)
            elseif msg.type == constants.MSG_HL_QUERY then
                handle_query(msg)
            elseif msg.type == constants.MSG_SHUTDOWN then
                log.info("highlight_lane", "shutdown received")
                return
            else
                log.warn("highlight_lane", "unknown message type", { type = msg.type })
            end
        end, function(e)
            log.error("highlight_lane", "unhandled error", {
                type = msg.type,
                error = tostring(e),
            })
        end)
        if not _ and perr then
            -- xpcall error; payload (if any) may leak here. Acceptable
            -- v1: better to keep the lane alive than to crash it.
        end
        msg = ss:pop(ss._ptr.outbox_hl)
    end
end
