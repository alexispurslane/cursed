--- completers: named completion provider factories for the minibuffer.
---
--- Each exported function returns a `completer(text) -> string[]` closure,
--- binding any required context (editor, command names iterator, etc.)
--- at creation time. Users can override any completer by replacing the
--- field on this module before commands reference it.

local find_file = require("cursed.find_file")
local utf8 = require("cursed.utf8")
local log = require("cursed.log")

local completers = {}

--- Lazy require of the LSP facade. kep lazy (loaded on first use of the
--- LSP completer) so this module stays safe to require at config load
--- time before the LSP subsystem is wired.
local function lsp()
    return require("cursed.lsp_client")
end

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

--- Split text into space-separated lowercase search terms.
---@param text string
---@return string[]
local function space_terms(text)
    local words = {}
    for w in text:gmatch("%S+") do
        words[#words + 1] = w:lower()
    end
    return words
end

--- Test whether `display` matches all terms as case-insensitive substrings.
---@param display string
---@param terms string[]
---@return boolean
local function matches_all(display, terms)
    if #terms == 0 then
        return true
    end
    local lower = display:lower()
    for _, t in ipairs(terms) do
        if not lower:find(t, 1, true) then
            return false
        end
    end
    return true
end

----------------------------------------------------------------------------------------------------
-- Command completion (M-x)
----------------------------------------------------------------------------------------------------

--- Create a completer for command names.
--- Takes a `names_fn` iterator (from Commands.names) to avoid circular deps,
--- and an optional `chord_fn(name) -> string?` that resolves a command name
--- to a human-readable chord for display as completion metadata.
---@param names_fn fun(): function iterator over command name strings
---@param chord_fn fun(name: string): string?|nil
---@return fun(text: string): table
function completers.commands(names_fn, chord_fn)
    return function(text)
        -- Split on first ":" for inline argument syntax; only match
        -- command names against the part before the colon.
        local colon_pos = text:find(":", 1, true)
        local cmd_text, arg_suffix
        if colon_pos then
            cmd_text = text:sub(1, colon_pos - 1)
            arg_suffix = text:sub(colon_pos)
        else
            cmd_text = text
            arg_suffix = ""
        end
        local terms = space_terms(cmd_text)
        local results = {}
        for name in names_fn() do
            local cmd_words = {}
            for w in name:gmatch("[^_]+") do
                cmd_words[#cmd_words + 1] = w:lower()
            end
            local all_match = true
            for _, uw in ipairs(terms) do
                local found = false
                for _, cw in ipairs(cmd_words) do
                    if cw:sub(1, #uw) == uw then
                        found = true
                        break
                    end
                end
                if not found then
                    all_match = false
                    break
                end
            end
            if all_match then
                -- `name` is the canonical underscore form (e.g. save_as);
                -- display with spaces. chord_fn receives the canonical
                -- form so it matches the reverse command_name→chord map
                -- built from the keybindings (which use underscores).
                local display = name:gsub("_", " ") .. arg_suffix
                local chord = chord_fn and chord_fn(name) or nil
                results[#results + 1] = {
                    text = display,
                    metadata = chord and #chord > 0 and chord or nil,
                }
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Find-file completion
----------------------------------------------------------------------------------------------------

--- File path completer — subword-matches against directory entries.
--- Re-exports find_file.find_file_completer for a single import point.
completers.find_file = find_file.find_file_completer

----------------------------------------------------------------------------------------------------
-- Theme completion (M-x load-theme)
----------------------------------------------------------------------------------------------------

--- Create a completer for available color schemes.
--- Lists scheme names discovered by ColorScheme.list_names across the
--- standard search dirs (user config themes/, repo themes/, installed).
---@param names_fn fun(): string[]  closure returning the current name list
---@return fun(text: string): string[]
function completers.themes(names_fn)
    return function(text)
        local terms = space_terms(text)
        local results = {}
        for _, name in ipairs(names_fn()) do
            if matches_all(name, terms) then
                results[#results + 1] = name
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Ibuffer completion (C-x b)
----------------------------------------------------------------------------------------------------

--- Create a completer for the buffer list.
--- Lists all views with index, dirty marker, and filepath.
---@param editor Editor
---@return fun(text: string): string[]
function completers.ibuffer(editor)
    return function(text)
        local terms = space_terms(text)
        local results = {}
        for i, v in ipairs(editor.views) do
            local path = v.buffer:filepath() or "[no file]"
            local dirty = v.buffer:is_dirty() and "*" or " "
            local display = string.format("%d %s %s", i, dirty, path)
            if matches_all(display, terms) then
                results[#results + 1] = display
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Kill-buffer completion (C-x k)
----------------------------------------------------------------------------------------------------

--- Create a completer for killing buffers.
--- Lists the current buffer first, then all others, with dirty marker
--- and filepath. The `current` view is determined at creation time.
---@param editor Editor
---@return fun(text: string): string[]
function completers.kill_buffer(editor)
    local current = editor:current_view()

    return function(text)
        local terms = space_terms(text)
        -- Build list: current first, then the rest
        local ordered = {}
        if current then
            ordered[#ordered + 1] = current
        end
        for _, v in ipairs(editor.views) do
            if v ~= current then
                ordered[#ordered + 1] = v
            end
        end

        local results = {}
        for _, v in ipairs(ordered) do
            local path = v.buffer:filepath() or "[no file]"
            local dirty = v.buffer:is_dirty() and "*" or " "
            local display = dirty .. " " .. path
            if matches_all(display, terms) then
                results[#results + 1] = display
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Buffer-word completion (in-buffer completion dogfood source)
----------------------------------------------------------------------------------------------------

--- Build a buffer-word (dabbrev-style) completer: scans ALL loaded
--- views' buffers for `[%w_]+` tokens, keeps those that start with the
--- cursor's current prefix (case-sensitive), excludes the exact prefix
--- itself, dedups, preserves first-seen order, and caps the result so a
--- huge file doesn't blow up the popup. Used by CompletionMenu as the
--- default source — a cheap, dependency-free way to exercise the whole
--- in-buffer completion loop end-to-end. An LSP completion provider can
--- later plug in via `CompletionMenu:set_completer` without changes here.
---
--- The closure is editor-bound at creation; the per-query cost is an
--- O(buffer) scan, which is fine for a debounced (120ms) completion.
---@param editor Editor
---@param opts table? { cap?: integer, min_token?: integer }
---@return fun(ctx: table): table  items (strings)
function completers.buffer_words(editor, opts)
    opts = opts or {}
    local cap = opts.cap or 200
    local min_token = opts.min_token or 3
    return function(ctx)
        local prefix = ctx.prefix
        if prefix == nil or #prefix < 1 then
            return {}
        end
        local seen = {}
        local results = {}
        local function consider(token)
            if #token < min_token then
                return
            end
            if token:sub(1, #prefix) ~= prefix then
                return
            end
            if token == prefix then
                return
            end
            if seen[token] then
                return
            end
            seen[token] = true
            results[#results + 1] = token
            if #results >= cap then
                return true -- stop iteration
            end
            return false
        end
        -- Scan the active buffer first (most relevant), then the others.
        local active = ctx.buf
        local function scan_buf(buf)
            local n = buf:line_count()
            for li = 0, n - 1 do
                local text = buf:line_text(li)
                for tok in text:gmatch("[%w_]+") do
                    if consider(tok) then
                        return
                    end
                end
            end
        end
        if active then
            scan_buf(active)
        end
        for _, v in ipairs(editor.views) do
            if v.buffer ~= active and v.buffer ~= nil then
                scan_buf(v.buffer)
                if #results >= cap then
                    break
                end
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Yes/No/All completion (for query-replace)
----------------------------------------------------------------------------------------------------

--- Create a completer offering "yes", "no", "all" options.
---@return fun(text: string): string[]
function completers.yes_no_all()
    local options = { "y", "n", "a" }
    return function(text)
        if #text == 0 then
            return { "y", "n", "a" }
        end
        local lower = text:lower()
        local results = {}
        for _, opt in ipairs(options) do
            if opt:sub(1, #lower) == lower then
                results[#results + 1] = opt
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Static list (codeAction picker, etc.)
--
-- A zero-cost completer factory for picking from a precomputed list of
-- items the caller already has (e.g. an LSP codeAction response). Each
-- item is `{ text = string, metadata = string?, data = any }`; the
-- display text + metadata drive substring filtering (case-insensitive,
-- whitespace-AND), and `data` rides along untouched so the command's
-- on_change/on_submit can resolve the backing entry via the
-- minibuffer's `_completions[index].data`.
----------------------------------------------------------------------------------------------------

--- Build a completer over a fixed list of items. Case-insensitive
--- substring filter; empty query returns the whole list. The returned
--- items are the SAME table references as the input (not copies), so
--- `.data` identity is preserved end-to-end.
--- @param items {text:string,metadata:string?,data:any}[]
--- @return fun(text: string): table
function completers.static_list(items)
    if items == nil then
        items = {}
    end
    return function(text)
        if #text == 0 then
            return items
        end
        local terms = space_terms(text)
        if #terms == 0 then
            return items
        end
        local out = {}
        for _, it in ipairs(items) do
            local hay = ((it.text or "") .. " " .. (it.metadata or "")):lower()
            if matches_all(hay, terms) then
                out[#out + 1] = it
            end
        end
        return out
    end
end

----------------------------------------------------------------------------------------------------
-- LSP completion (in-buffer, general purpose)
--
-- Mode- and server-agnostic completion source: it uses whichever LSP
-- client is bound to the current view's buffer (buf.lsp_client_id),
-- whatever the major mode it came from. Major modes reference this
-- factory via `completer = completers.lsp` in their spec; the editor's
-- `mode_dispatch` (below) resolves the active mode's source at runtime.
--
-- Bridging the async (request/response) LSP model to the
-- CompletionMenu's synchronous `fn(ctx) -> items` interface is done via
-- a prefix-scoped cache:
--   • On each call it MAY fire a textDocument/completion request — when
--     the cache is empty, when the prefix is not an extension of the
--     cached one (user deleted/backtracked), when the cursor left the
--     cached line/position, when a trigger character was just typed, or
--     when the last list was marked incomplete and the prefix grew.
--   • It returns the cached items, client-side-filtered by the current
--     prefix, so the popup stays populated (stale) while a response is
--     in flight. When the response lands, the cache is updated and a
--     menu re-tick is scheduled so the fresh items appear.
--
-- Follow-ups not in this cut: relaying serverCapabilities (true trigger
-- chars / positionEncoding negotiation), textEdit-range acceptance, and
-- snippet expansion (insertTextFormat 2).
----------------------------------------------------------------------------------------------------

--- Convert a 0-based byte column on a line to a 0-based UTF-16
--- code-unit offset (LSP position.character). Walks codepoints in the
--- line text up to the byte column, counting 2 units for supplementary-
--- plane codepoints (>= U+10000). LSP defaults to UTF-16 when no
--- positionEncoding is negotiated (our initialize doesn't).
--- @param line_text string
--- @param byte_col integer 0-based byte offset of the cursor
--- @return integer
local function byte_col_to_utf16(line_text, byte_col)
    local units = 0
    local i = 1
    -- Include bytes [1, byte_col] (1-based) = the substring before the
    -- 0-based cursor offset.
    local limit = byte_col
    while i <= limit and i <= #line_text do
        local cp, ni = utf8.decode(line_text, i)
        units = units + (cp >= 0x10000 and 2 or 1)
        if ni <= i then
            break
        end
        i = ni
    end
    return units
end

--- Map an LSP CompletionItem (label/insertText/detail/...) into the
--- CompletionMenu's item shape `{ text, metadata }`. The menu's accept
--- replaces the trailing word left of the cursor with `text`; for v1 we
--- use `insertText` (or `label`), deferring textEdit-range / snippet
--- handling. `detail` (when present) rides along as the metadata column.
--- @param it table CompletionItem
--- @return {text:string, metadata:string?}|nil nil when the item has no usable label
local function map_lsp_item(it)
    local text = it.insertText or it.label
    if text == nil or text == "" then
        return nil
    end
    local detail = it.detail
    return { text = text, metadata = (detail ~= nil and detail ~= "") and detail or nil }
end

--- Build the general-purpose LSP completion source.
--- @param editor Editor
--- @return Completer
function completers.lsp(editor)
    --- client_id -> cache entry: { line, char, prefix, items (mapped),
    ---                              is_incomplete, pending }
    local caches = {}

    --- Schedule a CompletionMenu re-tick so a just-arrived response
    --- swaps its items into the popup. Runs on the main thread (the
    --- response callback fires during drain_lsp_inbox, outside _tick).
    local function retick()
        editor:schedule_after(0, function()
            local m = editor.completion_menu
            if m ~= nil then
                m:_tick()
            end
            return true
        end)
    end

    ---@type Completer
    local fn = setmetatable({}, {
        __call = function(_, ctx)
            local buf = ctx.buf
            if buf == nil or buf.lsp_client_id == nil then
                log.info("lsp_complete", "completer_skip", { reason = "no_buffer_or_no_client" })
                return {}
            end
            local cid = buf.lsp_client_id
            local uri = buf.lsp_uri
            if cid == nil or uri == nil or not lsp().is_ready(cid) then
                log.info(
                    "lsp_complete",
                    "completer_skip",
                    { reason = "not_ready", cid = cid, uri = uri }
                )
                return {}
            end
            ---@cast cid integer
            -- Only query once the doc is didOpen'd on the server (a
            -- pre-didOpen request usually errors / returns empty).
            if lsp().doc_sent_version(cid, uri) < 0 then
                log.info(
                    "lsp_complete",
                    "completer_skip",
                    { reason = "doc_not_open", cid = cid, uri = uri }
                )
                return {}
            end

            local prefix = ctx.prefix
            local line = ctx.line
            local line_text = buf:line_text(line) or ""
            if #line_text > 0 and line_text:byte(#line_text) == 10 then
                line_text = line_text:sub(1, #line_text - 1)
            end
            local char = byte_col_to_utf16(line_text, ctx.col)

            local c = caches[cid] or {}
            caches[cid] = c

            -- Was a trigger character (single byte) just typed? Use the
            -- server-published triggerCharacters for this client (relayed via
            -- the initialize handshake) so we send triggerKind=2 + force a
            -- request the instant the context changes. nil before the READY
            -- handshake delivers capabilities.
            local trig = false
            local trig_char
            local tset = lsp().trigger_chars_for(cid)
            if tset ~= nil and ctx.col > 0 then
                local prev = line_text:byte(ctx.col) -- 1-based index of byte before 0-based cursor
                if prev ~= nil then
                    local ch = string.char(prev)
                    if tset[ch] then
                        trig = true
                        trig_char = ch
                    end
                end
            end

            local changed_pos = c.line ~= line or c.char ~= char
            local non_ext = c.prefix ~= nil and prefix:sub(1, #c.prefix) ~= c.prefix

            local force = ctx.force == true

            local need_req
            if c.items == nil then
                need_req = true -- first query for this client
            elseif force or changed_pos then
                -- Note: `trig` alone does NOT force a request — it stays
                -- true while the cursor sits after a trigger char, so
                -- re-evaluating it on the response retick would re-send
                -- forever. The request is driven by force (trigger
                -- fast-path / M-/) or a real position change; `trig_char`
                -- is consulted separately below only to set triggerKind.
                need_req = true
            else
                local prefix_changed = c.prefix == nil or prefix:sub(1, #c.prefix) ~= c.prefix
                need_req = prefix_changed and (c.is_incomplete or non_ext)
            end

            if need_req and not c.pending then
                local rline, rchar, rtrig = line, char, trig_char
                c.line = line
                c.char = char
                c.prefix = prefix
                c.pending = true
                log.info("lsp_complete", "completer_requesting", {
                    cid = cid,
                    line = rline,
                    character = rchar,
                    prefix = prefix,
                    trigger = rtrig,
                    reason = c.items == nil and "first"
                        or (trig and "trigger" or (changed_pos and "pos_changed" or "prefix_grew")),
                })
                -- Flush any pending didChange so the server has the text
                -- up to the cursor (incl. the trigger char just typed)
                -- BEFORE it computes completions. The post_command_hook
                -- doc-sync listener DEBOUNCES didChange (~150ms); without
                -- this flush the completion request races ahead of the
                -- sync and the server answers against STALE text —
                -- returning global completions instead of object members
                -- after `.`. Cancelling the debounce task first prevents
                -- a redundant later send (sync_change bumps the sent
                -- version, so the deferred task would no-op anyway, but
                -- cancelling keeps the queue tidy). Both sync_change and
                -- request_completion push to the lane's outbox_lsp FIFO,
                -- so the lane ships didChange THEN completion.
                local b = ctx.buf
                local sent_v = (b ~= nil) and lsp().doc_sent_version(cid, uri) or -999
                local cur_v = (b ~= nil and b.lsp_version) or -999
                local will_flush = b ~= nil and cur_v ~= nil and sent_v < cur_v
                if b ~= nil and b._lsp_debounce_task ~= nil then
                    editor:cancel_task(b._lsp_debounce_task)
                    b._lsp_debounce_task = nil
                end
                if will_flush then
                    local v = b.lsp_version
                    lsp().sync_change(cid, uri, v, function()
                        return b:write_text_direct()
                    end)
                end
                local comp_id =
                    lsp().request_completion(cid, uri, { line = rline, character = rchar }, rtrig)
                if comp_id == nil then
                    c.pending = false
                    return
                end
                lsp().on_response(editor, comp_id, function(_ed, result, is_error)
                    c.pending = false
                    if is_error or result == nil then
                        if c.items == nil then
                            c.items = {}
                        end
                        log.info("lsp_complete", "completer_response", {
                            cid = cid,
                            is_error = is_error,
                            result_nil = result == nil,
                            kept_stale_count = c.items ~= nil and #c.items or 0,
                        })
                        return
                    end
                    local raw_items, incomplete
                    if type(result) == "table" then
                        if result.items ~= nil then
                            raw_items = result.items
                            incomplete = result.isIncomplete == true
                        else
                            raw_items = result
                            incomplete = false
                        end
                    end
                    local mapped = {}
                    if type(raw_items) == "table" then
                        for _, it in ipairs(raw_items) do
                            local m = it ~= nil and type(it) == "table" and map_lsp_item(it) or nil
                            if m ~= nil then
                                mapped[#mapped + 1] = m
                            end
                        end
                    end
                    c.items = mapped
                    c.is_incomplete = incomplete
                    log.info("lsp_complete", "completer_response", {
                        cid = cid,
                        is_error = false,
                        raw_count = type(raw_items) == "table" and #raw_items or 0,
                        mapped_count = #mapped,
                        is_incomplete = incomplete,
                    })
                    retick()
                end)
            end

            --- Client-side-filter the (possibly stale) cached items by prefix.
            local items = c.items
            if items == nil or prefix == nil or prefix == "" then
                log.info(
                    "lsp_complete",
                    "completer_returning",
                    { cid = cid, count = 0, reason = "no_cache" }
                )
                return items or {}
            end
            local pl = prefix:lower()
            local out = {}
            for _, it in ipairs(items) do
                local t = it.text or ""
                if t:lower():sub(1, #pl) == pl then
                    out[#out + 1] = it
                end
            end
            log.info("lsp_complete", "completer_returning", {
                cid = cid,
                cached_count = #items,
                filtered_count = #out,
                prefix = prefix,
            })
            return out
        end,
    })

    --- Completion triggerCharacters set for the current view's bound
    --- client (table<char,boolean>), or nil. Lets the menu fast-path a
    --- trigger char without going through the (deeper) main closure.
    function fn.trigger_chars()
        local view = editor:current_view()
        local buf = view and view.buffer
        local cid2 = buf and buf.lsp_client_id
        if cid2 == nil then
            return nil
        end
        ---@cast cid2 integer
        return lsp().trigger_chars_for(cid2)
    end

    --- Is a completion request in flight for the current view's client?
    --- Drives the menu's keep-open-loading behaviour: a pending (resp.
    --- empty-cache) source should NOT close the popup while a request is
    --- in flight; the retick on response will populate it.
    function fn.pending()
        local view = editor:current_view()
        local buf = view and view.buffer
        local cid2 = buf and buf.lsp_client_id
        if cid2 == nil then
            return false
        end
        ---@cast cid2 integer
        local c = caches[cid2]
        return c ~= nil and c.pending == true
    end

    return fn
end

----------------------------------------------------------------------------------------------------
-- LSP symbol navigation (workspace + intra-document)
--
-- Two minibuffer completion sources that drive a Helm/ido-style
-- symbol picker: `document_symbols` (intra-document: fetch the current
-- buffer's symbol tree once, client-side-filter by typed query) and
-- `workspace_symbols` (workspace-wide: debounced `workspace/symbol`
-- per query, server-side filtering). Both bridge the async LSP
-- request/response model to the minibuffer's synchronous
-- `completer(text) -> items` interface via a closure-local cache plus
-- `Minibuffer:refresh_completions()` retick on response — the same
-- shape the in-buffer `completers.lsp` source uses.
--
-- Completion items are `{ text = name, metadata = "path:line  kind",
-- data = { uri, line, char } }`. The hidden `data` carries the LSP
-- Location the command's on_submit needs to jump; `on_change` is used
-- to track the currently-highlighted row so submit can resolve it
-- (the minibuffer passes the typed text to on_submit, not the item).
----------------------------------------------------------------------------------------------------

--- LSP SymbolKind enum → short display label (1..26). Sources whose
--- servers omit `kind` get the generic "sym".
--- @type table<integer,string>
local SYMBOL_KINDS = {
    [1] = "file",
    [2] = "module",
    [3] = "ns",
    [4] = "pkg",
    [5] = "class",
    [6] = "method",
    [7] = "prop",
    [8] = "field",
    [9] = "ctor",
    [10] = "enum",
    [11] = "iface",
    [12] = "fn",
    [13] = "var",
    [14] = "const",
    [15] = "str",
    [16] = "num",
    [17] = "bool",
    [18] = "arr",
    [19] = "obj",
    [20] = "key",
    [21] = "null",
    [22] = "enumm",
    [23] = "struct",
    [24] = "event",
    [25] = "op",
    [26] = "typeparam",
}

--- A normalized symbol record: the flat shape both completers build
--- their completion items from, regardless of which LSP response variant
--- (DocumentSymbol / SymbolInformation / WorkspaceSymbol) it came from.
--- `container` carries `containerName` or the parent DocumentSymbol name.
---@class LspSym
---@field name string
---@field kind integer?
---@field uri string?
---@field line integer 0-based LSP line
---@field char integer 0-based UTF-16 code-unit offset
---@field container string?

--- Strip a `file://` (or `file:///`) URI prefix to an absolute path.
--- Leaves a bare path untouched. Per the LSP spec URIs are absolute.
--- @param uri string?
--- @return string path empty when uri is nil/empty
local function path_from_uri(uri)
    if uri == nil then
        return ""
    end
    local p = uri
    -- `file://localhost/...` is the rare host-qualified form; strip it
    -- so it compares equal to the plain `file:///...` shape.
    p = p:gsub("^file://localhost", "")
    p = p:gsub("^file://", "")
    return p
end

--- Best-effort relative form of `path` against `workspace_dir`.
--- Falls back to the absolute path (or basename when neither is set).
--- @param path string
--- @param workspace_dir string?
--- @return string
local function relativize(path, workspace_dir)
    if path == nil or path == "" then
        return ""
    end
    local base = workspace_dir
    if base == nil or base == "" then
        base = os.getenv("PWD")
    end
    if base == nil or base == "" then
        -- No workspace anchor: show the basename so the metadata column
        -- stays narrow.
        local b = path:match("([^/]+)$")
        return b or path
    end
    if path:sub(1, #base) == base then
        local rest = path:sub(#base + 1)
        rest = rest:gsub("^/+", "")
        if rest == "" then
            return "."
        end
        return rest
    end
    return path
end

--- Normalize the three LSP symbol shapes a server may return into a
--- flat `{name, kind, uri, line, char, container}` record:
---   • DocumentSymbol (hierarchical): {name, kind, range, selectionRange, children?}
---   • SymbolInformation (flat): {name, kind, location:{uri,range}, containerName?}
---   • WorkspaceSymbol (3.17): location may be {uri,range} OR
---     {targetUri, targetRange, targetSelectionRange}.
--- `default_uri` supplies the URI for DocumentSymbols (which omit it).
--- Returns nil for malformed entries (no name / no usable range).
--- @param s table a symbol object
--- @param default_uri string? the URI to assume when the symbol lacks one
--- @return LspSym|nil
local function normalize_symbol(s, default_uri)
    if type(s) ~= "table" then
        return nil
    end
    local name = s.name
    if name == nil or name == "" then
        return nil
    end
    local uri, line, char
    if s.location ~= nil and type(s.location) == "table" then
        local loc = s.location
        -- 3.17 WorkspaceSymbol with a (targetUri, targetSelectionRange) pair.
        if loc.targetUri ~= nil then
            uri = loc.targetUri
            local r = loc.targetSelectionRange or loc.targetRange
            if r and r.start then
                line = r.start.line
                char = r.start.character
            end
        elseif loc.range and loc.range.start then
            uri = loc.uri or default_uri
            line = loc.range.start.line
            char = loc.range.start.character
        end
    else
        -- DocumentSymbol: prefer selectionRange (the name span) and
        -- fall back to the full range so a degenerate symbol still jumps.
        local r = s.selectionRange or s.range
        if r and r.start then
            uri = default_uri
            line = r.start.line
            char = r.start.character
        end
    end
    if line == nil then
        return nil
    end
    return {
        name = name,
        kind = s.kind,
        uri = uri,
        line = line or 0,
        char = char or 0,
        container = s.containerName,
    }
end

--- The shared, static metadata prefix for a symbol item used as the
--- completion item's `text` (the `metadata` side is computed per-call
--- from the live workspace). Separated here so the highlighter's
--- match-byte logic operates on the name only.
--- @param sym LspSym
--- @return string
local function symbol_text(sym)
    -- Flatten the qualified name onto a `container::name` display when
    -- the symbol carries a container so identical names in different
    -- scopes are distinguishable in the list.
    if sym.container and sym.container ~= "" then
        return sym.container .. "::" .. sym.name
    end
    return sym.name
end

--- Build a minibuffer completion item from a normalized symbol: the
--- display text is the (qualified) name, metadata carries
--- `relpath:line  kind` so the second column doubles as a position
--- preview, and the hidden `data` field holds the LSP Location for
--- the command's jump handler. `workspace_dir` only affects metadata
--- rendering, not jumping.
--- @param sym LspSym a normalize_symbol result
--- @param workspace_dir string?
--- @return {text:string,metadata:string,data:table}
local function build_symbol_item(sym, workspace_dir)
    local path = path_from_uri(sym.uri)
    local rel = relativize(path, workspace_dir)
    local kind = (sym.kind and SYMBOL_KINDS[sym.kind]) or "sym"
    local meta
    if rel ~= "" then
        meta = rel .. ":" .. tostring((sym.line or 0) + 1) .. "  " .. kind
    else
        meta = "L" .. tostring((sym.line or 0) + 1) .. "  " .. kind
    end
    return {
        text = symbol_text(sym),
        metadata = meta,
        data = { uri = sym.uri, line = sym.line or 0, char = sym.char or 0 },
    }
end

--- Client-side fuzzy filter: a symbol item matches when EVERY
--- whitespace-separated query term appears as a case-insensitive
--- substring in the display text (`text`) OR metadata (`metadata`).
--- Empty query → all items pass (so the picker is populated on open).
--- @param items table[] completion items with `.text` and `.metadata`
--- @param query string the user's minibuffer text
--- @return table[] filtered items, first-seen order
local function filter_symbols(items, query)
    if items == nil then
        return {}
    end
    local terms = space_terms(query)
    if #terms == 0 then
        return items
    end
    local out = {}
    for _, it in ipairs(items) do
        local hay = ((it.text or "") .. " " .. (it.metadata or "")):lower()
        local ok = true
        for _, t in ipairs(terms) do
            if not hay:find(t, 1, true) then
                ok = false
                break
            end
        end
        if ok then
            out[#out + 1] = it
        end
    end
    return out
end

--- Current buffer's LSP client + URI as a `(cid, uri)` pair, or nil.
--- Shared by both symbol completers to resolve the active server.
--- @param editor Editor
--- @return integer|nil cid
--- @return string|nil uri
local function current_doc(editor)
    local view = editor:current_view()
    local buf = view and view.buffer
    local cid = buf and buf.lsp_client_id
    local uri = buf and buf.lsp_uri
    if cid == nil or uri == nil then
        return nil, nil
    end
    if not lsp().is_ready(cid) then
        return nil, nil
    end
    ---@cast cid integer
    return cid, uri
end

--- Recursively flatten a (possibly hierarchical) DocumentSymbol tree
--- into flat symbol records. `textDocument/documentSymbol` may return
--- either `DocumentSymbol[]` (with `children`) or `SymbolInformation[]`
--- (flat); the latter has no `children` so the walk stops at depth 1.
--- `workspace_dir` is unused here but threaded for symmetry.
--- @param syms table[]
--- @param uri string the buffer's URI (DocumentSymbols omit their own)
--- @param container string? parent name for qualification
--- @param out table[] accumulator
local function flatten_document_symbols(syms, uri, container, out)
    for _, s in ipairs(syms) do
        if type(s) == "table" then
            -- Only DocumentSymbols (no .location) carry children.
            local children = s.children
            local sym = normalize_symbol(s, uri)
            if sym then
                if container and not sym.container then
                    sym.container = container
                end
                out[#out + 1] = sym
            end
            if type(children) == "table" and #children > 0 then
                local child_container = sym and (sym.name or container) or container
                flatten_document_symbols(children, uri, child_container, out)
            end
        end
    end
end

--- Build the intra-document (imenu-style) symbol picker. Requests
--- `textDocument/documentSymbol` ONCE (when first queried), flattens the
--- (possibly hierarchical) result into completion items, then
--- client-side-filters by the typed query. The retick on response
--- swaps the list in even though the text hasn't changed.
--- @param editor Editor
--- @return fun(text: string): table
function completers.document_symbols(editor)
    --- closure-local state: items=nil until the response lands.
    local state = { items = nil, pending = false }
    --- Capture the (cid, uri, workspace_dir) of the buffer the picker
    --- was opened against; if that buffer changes (shouldn't while the
    --- minibuffer is active), we'd re-fetch, but the simple nil-guard
    --- +"already fetched" keeps the one-shot fetch semantic.
    local cid, uri = current_doc(editor)
    local workspace_dir = editor.workspace_dir

    --- Schedule a completion-list retick so a just-landed response
    --- swaps its items into the list. Runs on the main thread (the
    --- response callback fires during drain_lsp_inbox, off-render).
    local function retick()
        editor:schedule_after(0, function()
            if editor.minibuffer and editor.minibuffer.active then
                editor.minibuffer:refresh_completions()
            end
            return true
        end)
    end

    if cid == nil or uri == nil then
        -- No usable server: stay an empty-but-harmless completer so the
        --- command can surface a status message instead of crashing.
        return function(_text)
            return {}
        end
    end

    --- Fetch the symbol tree for the captured doc. Idempotent: the
    --- closure only fires it once (state.items == nil + not pending).
    local function fetch()
        if state.pending then
            return
        end
        state.pending = true
        log.info("lsp_symbols", "document_symbol_request", { cid = cid })
        local id = lsp().mint_request_id()
        lsp().on_response(editor, id, function(_ed, result, is_error)
            state.pending = false
            if is_error or result == nil or type(result) ~= "table" then
                state.items = {}
                log.info("lsp_symbols", "document_symbol_response", {
                    cid = cid,
                    is_error = is_error or false,
                    count = 0,
                })
                retick()
                return
            end
            local flat = {}
            flatten_document_symbols(result, uri, nil, flat)
            local mapped = {}
            for _, sym in ipairs(flat) do
                mapped[#mapped + 1] = build_symbol_item(sym, workspace_dir)
            end
            state.items = mapped
            log.info("lsp_symbols", "document_symbol_response", {
                cid = cid,
                count = #mapped,
            })
            retick()
        end)
        lsp().request(cid, "textDocument/documentSymbol", { textDocument = { uri = uri } }, id)
    end

    return function(text)
        if state.items == nil then
            if lsp().doc_sent_version(cid, uri) >= 0 then
                fetch()
            end
            return {}
        end
        return filter_symbols(state.items, text)
    end
end

--- Build the intra-document (imenu-style) symbol picker from the
--- tree-sitter parse tree instead of an LSP `textDocument/documentSymbol`
--- request. Used as the goto_symbol fallback when no language server is
--- bound to the buffer (but a major mode with `symbol_queries` is).
--- Walks `@symbol`-captured declaration nodes once, synchronously (the
--- tree is current at picker-open time), and client-side-filters by the
--- typed query. Each node's display text is its first source line
--- (trimmed); the hidden `data` carries the node's start point as a
--- 0-based (line, byte-col) the command jumps to via Editor:goto_byte.
--- Returns a no-item completer when the buffer has no tree-sitter
--- language, no symbol query, or no parse tree yet.
--- @param editor Editor
--- @return fun(text: string): table
function completers.ts_document_symbols(editor)
    local view = editor:current_view()
    local buf = view and view.buffer
    if view == nil or buf == nil then
        return function(_text)
            return {}
        end
    end
    local ts = require("cursed.ts")
    local query = view:_symbol_query()
    local tree = view:hl_tree()
    if query == nil or tree == nil then
        return function(_text)
            return {}
        end
    end
    local root = tree:root()
    if ts.node_is_null(root) then
        return function(_text)
            return {}
        end
    end

    --- Walk every @symbol capture once, building flat completion items.
    --- The node's START point (row + byte column) is the jump target;
    --- the label is the start row's text from that column, trimmed.
    local items = {}
    local cursor, cerr = ts.QueryCursor.new()
    if cursor == nil then
        log.warn("ts_symbols", "query_cursor_new_failed", { error = tostring(cerr) })
        return function(_text)
            return {}
        end
    end
    cursor:exec(query, root)
    for match in cursor:matches() do
        for _, cap in ipairs(match.captures) do
            if cap.name == "symbol" then
                local node = cap.node
                local srow, scol = ts.node_point_range(node)
                local row = tonumber(srow) or 0
                local col = tonumber(scol) or 0
                local kind = ts.node_type(node) or "sym"
                local label = kind
                local line_text = buf:line_text(row)
                if line_text ~= nil then
                    local s = line_text:sub(col + 1)
                    s = s:gsub("^%s+", "")
                    -- Collapse trailing block punctuation so the list row
                    -- stays narrow (e.g. `function foo() end` → `function foo()`).
                    s = s:gsub("%s*$", "")
                    if s ~= "" then
                        label = s
                    end
                end
                items[#items + 1] = {
                    text = label,
                    metadata = "L" .. tostring(row + 1) .. "  " .. kind,
                    data = { line = row, char = col },
                }
            end
        end
    end
    log.info("ts_symbols", "document_outline", { count = #items })
    return function(text)
        return filter_symbols(items, text)
    end
end

--- Build the workspace-wide symbol picker. Debounces a
--- `workspace/symbol` request per query (server-side filtering), caches
--- the response, and client-side-refilters the (possibly stale) list so
--- the picker stays populated while a request is in flight. Most
--- servers reject an empty query, so we wait for at least one char.
--- @param editor Editor
--- @return fun(text: string): table
function completers.workspace_symbols(editor)
    --- closure-local state.
    local state = { items = {}, pending = false, last_query = "", debounce = nil }
    local workspace_dir = editor.workspace_dir

    --- Resolve the active server (re-evaluated each call so a server
    --- coming up mid-search starts answering).
    local cid, _uri = current_doc(editor)

    local function retick()
        editor:schedule_after(0, function()
            if editor.minibuffer and editor.minibuffer.active then
                editor.minibuffer:refresh_completions()
            end
            return true
        end)
    end

    local DEBOUNCE_US = 120000

    local function send(query)
        if cid == nil or not lsp().is_ready(cid) then
            return
        end
        if state.debounce ~= nil then
            editor:cancel_task(state.debounce)
            state.debounce = nil
        end
        state.pending = true
        log.info("lsp_symbols", "workspace_symbol_request", {
            cid = cid,
            query = query,
        })
        local id = lsp().mint_request_id()
        lsp().on_response(editor, id, function(_ed, result, is_error)
            state.pending = false
            if is_error or result == nil or type(result) ~= "table" then
                state.items = {}
                log.info("lsp_symbols", "workspace_symbol_response", {
                    cid = cid,
                    query = query,
                    is_error = is_error or false,
                    count = 0,
                })
                retick()
                return
            end
            local mapped = {}
            for _, s in ipairs(result) do
                local sym = normalize_symbol(s, nil)
                if sym then
                    mapped[#mapped + 1] = build_symbol_item(sym, workspace_dir)
                end
            end
            state.items = mapped
            log.info("lsp_symbols", "workspace_symbol_response", {
                cid = cid,
                query = query,
                count = #mapped,
            })
            retick()
        end)
        lsp().request(cid, "workspace/symbol", { query = query }, id)
    end

    local function schedule_send(query)
        if state.debounce ~= nil then
            editor:cancel_task(state.debounce)
        end
        state.debounce = editor:schedule_after(DEBOUNCE_US, function()
            state.debounce = nil
            send(query)
            return true
        end)
    end

    return function(text)
        -- Re-resolve the server if we didn't capture one at build time.
        if cid == nil then
            cid = current_doc(editor)
        end
        if cid == nil then
            return {}
        end
        local query = text or ""
        -- Strip the leading trigger token some servers dislike (empty).
        if query == state.last_query then
            return filter_symbols(state.items, query)
        end
        state.last_query = query
        if #query >= 1 then
            schedule_send(query)
        end
        return filter_symbols(state.items, query)
    end
end

----------------------------------------------------------------------------------------------------
-- Per-mode completer dispatcher
--
-- The CompletionMenu holds ONE completer for the whole editor. Major
-- modes declare their own `completer` factory (e.g. `completers.lsp`);
-- this dispatcher resolves the active view's highest-precedence mode
-- that declares one and delegates to a (cached) instance of it. Falls
-- back to `completers.buffer_words` when no active mode declares a
-- source, so files without an LSP (base mode) still get dabbrev.
----------------------------------------------------------------------------------------------------

--- Build the editor-wide per-mode completer dispatcher.
--- @param editor Editor
--- @return Completer
function completers.mode_dispatch(editor)
    local built = {} -- factory (function identity) -> closure
    local fallback

    --- Resolve the active view's highest-precedence mode-declared source
    --- closure (lazily built + cached), or nil when no mode declares one
    --- (caller falls back to buffer_words).
    local function resolve(ctx)
        local factory
        local view = ctx and ctx.view or editor:current_view()
        if view ~= nil and view._major_modes ~= nil then
            for i = #view._major_modes, 1, -1 do
                local m = view._major_modes[i]
                if m.completer ~= nil then
                    factory = m.completer
                    break
                end
            end
        end
        if factory == nil then
            return nil
        end
        local fn = built[factory]
        if fn == nil then
            fn = factory(editor)
            built[factory] = fn
        end
        return fn
    end

    ---@type Completer
    local dispatch = setmetatable({}, {
        __call = function(_, ctx)
            local fn = resolve(ctx)
            if fn == nil then
                if fallback == nil then
                    fallback = completers.buffer_words(editor)
                end
                local view = ctx.view
                log.info("lsp_complete", "dispatch_fallback_buffer_words", {
                    n_modes = view and view._major_modes and #view._major_modes or 0,
                })
                return fallback(ctx)
            end
            if ctx.view ~= nil and ctx.view._major_modes ~= nil and #ctx.view._major_modes > 0 then
                log.info("lsp_complete", "dispatch_resolved", {
                    source = "lsp",
                    mode = ctx.view._major_modes[#ctx.view._major_modes].name,
                })
            end
            return fn(ctx)
        end,
    })

    --- Delegate to the active source's trigger_chars (if it exposes one).
    --- nil for buffer_words / sources without the hook → the menu's
    --- immediate-on-trigger fast-path simply doesn't fire.
    function dispatch.trigger_chars()
        local fn = resolve(nil)
        if fn == nil or fn.trigger_chars == nil then
            return nil
        end
        return fn.trigger_chars()
    end

    --- Delegate to the active source's pending flag (if it exposes one).
    function dispatch.pending()
        local fn = resolve(nil)
        if fn == nil or fn.pending == nil then
            return false
        end
        return fn.pending()
    end

    return dispatch
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

-- Re-export the completion-item helpers (canonical home is minibuffer.lua)
-- for callers that reach them via the completers module. Resolved lazily
-- on first use to avoid a require cycle at module-load time.
completers.comp_text = function(item)
    return require("cursed.minibuffer").comp_text(item)
end
completers.comp_meta = function(item)
    return require("cursed.minibuffer").comp_meta(item)
end

return completers
