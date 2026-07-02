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
            elseif force or trig or changed_pos then
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
                lsp().request_completion(
                    cid,
                    uri,
                    { line = rline, character = rchar },
                    rtrig,
                    function(result, is_error)
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
                                local m = it ~= nil and type(it) == "table" and map_lsp_item(it)
                                    or nil
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
                    end
                )
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
