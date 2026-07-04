--- LSP client — main-side facade over the LSP lane.
---
--- The actual subprocess management, JSON-RPC framing, and JSON
--- decode/encode live in cursed.lsp_lane (a pthread + lua_State), so
--- heavy JSON never runs on the main/render thread. This module is the
--- thin main-side API the editor uses:
---
---   - spawn_for_mode  → generate/reuse a client_id, enqueue MSG_LSP_SPAWN
---     (idempotent: dedups by exe-name set so two modes sharing the same
---     server binary don't double-spawn), and bind mode_name → client_id
---   - request/notify   → enqueue MSG_LSP_SEND, routed by client_id
---   - server_status_for → reflect ⛏ modeline status by looking up the
---     live client for a mode's declared exe names
---   - client_for_mode   → the client_id bound to a mode (for routing)
---   - shutdown → enqueue KILL for every known client, then SHUTDOWN
---
--- Identity model: each running server has a main-assigned uint32
--- client_id. Main mints it (so it can bind mode→id + dedup synchronously
--- before the round-trip); the lane echoes it in every MSG_LSP_HANDSHAKE
--- and uses it to route outbound SEND/KILL. The status registry is keyed
--- by client_id; a reverse exe_name→client_id map lets the modeline look
--- up "is the server for these declared names up?" without knowing ids.
---
--- Inbound decoded messages arrive as packed C structs per message
--- type via inbox_lsp: MSG_LSP_HANDSHAKE (initialize result + status),
--- MSG_LSP_RESPONSE (generic request response, id-routed), and
--- MSG_LSP_NOTIFICATION (generic server notification, method-routed).
--- Both the response + notification paths transfer a lane-parsed
--- yyjson_doc; main walks it into a Lua table and frees the doc.

local ffi = require("ffi")
local constants = require("cursed.shared")
local log = require("cursed.log")
local json = require("cursed.json_ffi")

--- Module exports table.
--- @class LSPModule
local M = {}

----------------------------------------------------------------------------------------------------
-- Registries (all main-side, all keyed off client_id)
----------------------------------------------------------------------------------------------------

--- client_id → { exe_name, status (string), modes:set }.
--- Populated from MSG_LSP_HANDSHAKE. Drives server_status_for + shutdown.
--- Entries are KEPT for terminal statuses (dead/killed/missing) so the
--- modeline can distinguish them; only "spawning"/"ready" count as live
--- for dedup, and mode bindings are cleared on terminal so a re-enter
--- re-spawns.
--- @type table<integer, {exe_name:string, status:string, modes:table<string,boolean>}>
M.clients = {}

--- mode_name → client_id. The central "which server serves this mode?"
--- binding the editor tracks. Set by spawn_for_mode; consulted by
--- client_for_mode + cleared by unbind_mode.
--- @type table<string, integer>
M.mode_bindings = {}

--- exe_name → client_id. Reverse lookup so server_status_for(names)
--- (called by the modeline with a mode's declared exe list) resolves to
--- the live client without callers needing to know ids.
--- @type table<string, integer>
M.exe_to_client = {}

--- client_id → completion triggerCharacters set (table<char,boolean>).
--- Populated from the READY handshake (serverCapabilities); drives the
--- editor's immediate-on-trigger-char completion fast-path. Cleared on
--- terminal status.
--- @type table<integer, table<string,boolean>>
M.trigger_chars = {}

--- Open documents per client: client_id → { uri → {language_id, version} }.
--- Tracks which docs we've didOpen'd on each server so we don't double-open
--- (servers error on duplicate didOpen) and so didChange/didClose route
--- correctly. Cleared on client death (drop_client_docs).
--- @type table<integer, table<string, {language_id:string, version:integer}>>
M._open_docs = {}

--- Pending didOpens deferred until the client's initialize handshake
--- completes (READY): client_id → { uri → {language_id, get_text} }.
--- `get_text` snapshots the buffer lazily at flush time.
--- @type table<integer, table<string, {language_id:string, get_text:function}>>
M._pending_opens = {}

--- Diagnostics by uri: uri → { client_id=integer, version=integer|nil,
--- items=flat[] } where each item is { sl, sc, el, ec, severity,
--- message, source, code } (0-based LSP line + UTF-16 character
--- offsets; severity 1..4 or 0; message/source/code are strings or
--- nil). Materialized ONCE on arrival by
--- `handle_publish_diagnostics` walking the lane-parsed params table
--- (val_to_lua on the doc the lane handed via MSG_LSP_NOTIFICATION) —
--- main never runs yyjson_read. Cleared per-uri by an empty array, by
--- drop_client_docs, or by buffer_close.
--- @type table<string, {client_id:integer, version:integer|nil, items:table[]}>
M._diagnostics_by_uri = {}

--- Next client_id to assign. 0 is reserved ("unassigned"/notification).
local _next_client_id = 1

--- Next request id to mint. id 1 is reserved for the lane's own
--- `initialize` request; main-owned requests start at 2.
local _next_request_id = 2

--- Pending main-owned requests: id → callback(decoded_result, is_error).
--- The lane relays every non-initialize response back as MSG_LSP_RESPONSE;
--- apply_response walks the lane-parsed yyjson value into a Lua table
--- (the heavy yyjson_read ran off-main on the lane; main only walks)
--- + invokes the matching callback here, then frees the doc.
--- @type table<integer, fun(result:any, is_error:boolean)>
M._pending_requests = {}

--- Inbound-notification handlers: method → handler(params, client_id).
--- The lane relays every server notification (method set, no id) back as
--- MSG_LSP_NOTIFICATION; apply_notification walks the lane-parsed params
--- value into a Lua table (val_to_lua), frees the doc, and dispatches
--- here by method. Mirrors the request-callback registry. Handlers are
--- registered via on_notification; unhandled methods are logged + dropped.
--- @type table<string, fun(params:any, client_id:integer)>
M._notification_handlers = {}

--- LSP_STATUS_* code (uint8 from the lane) → status string.
--- Kept in sync with shared_state.h LSP_STATUS_*.
local _STATUS_NAMES = {
    [constants.LSP_STATUS_SPAWNING] = "spawning",
    [constants.LSP_STATUS_READY] = "ready",
    [constants.LSP_STATUS_DEAD] = "dead",
    [constants.LSP_STATUS_KILLED] = "killed",
    [constants.LSP_STATUS_MISSING] = "missing",
}

--- status string → is the process alive? (only spawning/ready are live;
--- dead/killed/missing should be re-spawned on next mode_enter).
local function is_live(status)
    return status == "spawning" or status == "ready"
end

----------------------------------------------------------------------------------------------------
-- SharedState access (set once from main.lua)
----------------------------------------------------------------------------------------------------

local function ss()
    return M._ss
end

----------------------------------------------------------------------------------------------------
-- Candidate normalization
----------------------------------------------------------------------------------------------------

--- Coerce a major mode's `lsp_servers` (a first-wins list whose
--- entries are EITHER a bare executable-name string OR a table
---   { bin = "name", args = {"--stdio"}, env = { VAR = "value" } })
--- into a uniform list of candidate specs: {
---   bin  = string  (short executable name to resolve on PATH),
---   args = string[] (argv tail; may be empty),
---   env  = table<string,string>  (extra env vars to set; may be empty),
--- }. env values are stringified so `ENV_VAR = 1` works. Empty/missing
--- args/env collapse to empty containers so the lane can iterate
--- unconditionally. Returns an empty list (not nil) for nil input.
--- @param servers string[]|table[]|nil  mixed first-wins list
--- @return table[] candidates  each {bin:string, args:string[], env:table}
function M.normalize(servers)
    local out = {}
    if servers == nil then
        return out
    end
    for _, s in ipairs(servers) do
        if type(s) == "string" then
            out[#out + 1] = { bin = s, args = {}, env = {} }
        elseif type(s) == "table" then
            local bin = s.bin
            if type(bin) == "string" and bin ~= "" then
                local args = {}
                if type(s.args) == "table" then
                    for _, a in ipairs(s.args) do
                        args[#args + 1] = tostring(a)
                    end
                end
                local env = {}
                if type(s.env) == "table" then
                    for k, v in pairs(s.env) do
                        env[tostring(k)] = tostring(v)
                    end
                end
                out[#out + 1] = { bin = bin, args = args, env = env }
            end
        end
    end
    return out
end

----------------------------------------------------------------------------------------------------
-- Outbound payload builders (lane frees each struct after consuming)
----------------------------------------------------------------------------------------------------

--- @param cands table[] normalized candidates (each {bin,args,env})
--- @param workspace_dir string
--- @param client_id integer
local function enqueue_spawn(cands, workspace_dir, client_id)
    local s = ss()
    if s == nil then
        return
    end
    local spec, err = json.encode(cands)
    if spec == nil then
        log.warn("lsp", "spawn spec encode failed", { error = err })
        return
    end
    local total = ffi.sizeof("struct LspSpawnReq") + #spec + #workspace_dir
    local buf = ffi.C.calloc(1, total)
    local req = ffi.cast("struct LspSpawnReq *", buf)
    req.spec_len = #spec
    req.workspace_len = #workspace_dir
    req.client_id = client_id
    local base = ffi.cast("char *", buf) + ffi.sizeof("struct LspSpawnReq")
    ffi.copy(base, spec, #spec)
    ffi.copy(base + #spec, workspace_dir, #workspace_dir)
    s:push(s._ptr.outbox_lsp, { type = constants.MSG_LSP_SPAWN, ptr = buf })
end

--- @param method string
--- @param params table|nil
--- @param id integer 0 = notification, else request id
--- @param client_id integer
local function enqueue_send(method, params, id, client_id)
    local s = ss()
    if s == nil then
        return
    end
    local params_json = ""
    if params ~= nil then
        -- Outbound params are small/infrequent (initialize/completion
        -- request); encode on main via yyjson (correct + fast). The
        -- heavy DECODE of inbound responses runs in the lane.
        local enc, err = json.encode(params)
        if enc == nil then
            log.warn("lsp", "param encode failed", { error = err, method = method })
            return
        end
        params_json = enc
    end
    local total = ffi.sizeof("struct LspSendReq") + #method + #params_json
    local buf = ffi.C.calloc(1, total)
    local req = ffi.cast("struct LspSendReq *", buf)
    req.method_len = #method
    req.params_len = #params_json
    req.id = id
    req.client_id = client_id
    local base = ffi.cast("char *", buf) + ffi.sizeof("struct LspSendReq")
    ffi.copy(base, method, #method)
    ffi.copy(base + #method, params_json, #params_json)
    s:push(s._ptr.outbox_lsp, { type = constants.MSG_LSP_SEND, ptr = buf })
end

----------------------------------------------------------------------------------------------------
-- Dedup + spawn entry point
----------------------------------------------------------------------------------------------------

--- Find a live client whose exe_name matches any of `candidates`
--- (first-wins against the declared list). Returns its client_id, or
--- nil if none. Used so two modes declaring the same server binary
--- share one process.
--- @param cands table[] normalized candidates
--- @return integer|nil
local function find_live_client(cands)
    for _, c in ipairs(cands) do
        local cid = M.exe_to_client[c.bin]
        if cid and M.clients[cid] and is_live(M.clients[cid].status) then
            return cid
        end
    end
    return nil
end

--- Get-or-spawn an LSP client for a mode and bind mode_name → client_id.
--- Dedups by exe name set (two modes with the same lsp_servers share one
--- process). The matching legacy entry point `spawn_or_get` delegates
--- here. No fork happens on the main thread; this enqueues to the lane.
--- @param mode_name string the major-mode instance name (binding key)
--- @param servers string[]|table[] first-wins list of executions (mixed)
--- @param workspace_dir string workspace root directory
--- @return integer client_id the id assigned/bound (0 if nothing to spawn)
function M.spawn_for_mode(mode_name, servers, workspace_dir)
    if M._ss == nil then
        return 0
    end
    local cands = M.normalize(servers)
    if #cands == 0 then
        return 0
    end

    -- Already bound for this mode? Reuse if still live (a dead/killed
    -- binding falls through to re-spawn below).
    local bound = M.mode_bindings[mode_name]
    if bound and M.clients[bound] and is_live(M.clients[bound].status) then
        return bound
    end

    -- Dedup: a live client for any of these exe names already exists →
    -- bind this mode to it (don't spawn a second process).
    local existing = find_live_client(cands)
    local client_id
    if existing then
        client_id = existing
    else
        client_id = _next_client_id
        _next_client_id = _next_client_id + 1
        enqueue_spawn(cands, workspace_dir, client_id)
        -- Provisional registry entry so server_status_for reflects
        -- "spawning" (the lane will correct to missing if the binary
        -- isn't on PATH, or ready on the initialize response).
        M.clients[client_id] = {
            exe_name = cands[1].bin,
            status = "spawning",
            modes = {},
        }
        M.exe_to_client[cands[1].bin] = client_id
    end

    -- Bind mode → client_id (overwrite any stale binding for this mode).
    M.mode_bindings[mode_name] = client_id
    local entry = M.clients[client_id]
    if entry then
        entry.modes[mode_name] = true
    end

    return client_id
end

--- Legacy entry point preserved for editor_listeners / editor.lua: takes
--- a (now-unused) kqueue + callbacks and returns a placeholder so the old
--- "client == nil ⇒ not found" branch keeps its semantics. Delegates to
--- spawn_for_mode with a mode key derived from the first candidate's bin.
--- @param _main_kqueue any unused — lane owns its kq
--- @param servers (string|table)[] first-wins list of executables (strings or `{bin,args,env}` tables)
--- @param workspace_dir string
--- @param _on_message any unused — inbound is via inbox_lsp
--- @param _on_exit any unused — lane relays handshakes
--- @return LSPClient|nil placeholder; nil if no ss wired
function M.spawn_or_get(_main_kqueue, servers, workspace_dir, _on_message, _on_exit)
    if M._ss == nil then
        return nil
    end
    local first_bin = M.normalize(servers)[1]
    if first_bin == nil then
        return nil
    end
    local mode_key = first_bin.bin
    local id = M.spawn_for_mode(mode_key, servers, workspace_dir)
    if id == 0 then
        return nil
    end
    return { _placeholder = true, client_id = id }
end

--- The client_id bound to a mode (which server serves this mode?), or nil.
--- @param mode_name string
--- @return integer|nil
function M.client_for_mode(mode_name)
    return M.mode_bindings[mode_name]
end

--- Drop a mode's binding (e.g. on mode_exit if the server isn't shared).
--- Does NOT kill the server — other modes may still use it.
--- @param mode_name string
function M.unbind_mode(mode_name)
    local cid = M.mode_bindings[mode_name]
    if cid == nil then
        return
    end
    M.mode_bindings[mode_name] = nil
    local entry = M.clients[cid]
    if entry then
        entry.modes[mode_name] = nil
    end
end

----------------------------------------------------------------------------------------------------
-- Outbound requests / notifications
----------------------------------------------------------------------------------------------------

--- Send a request to the server bound to a mode.
--- @param mode_name string
--- @param method string
--- @param params table|nil
--- @param id integer request id (caller-allocated; lane owns id 1 = initialize)
function M.request_for_mode(mode_name, method, params, id)
    local cid = M.mode_bindings[mode_name]
    if cid == nil then
        return
    end
    enqueue_send(method, params, id, cid)
end

--- Send a notification to the server bound to a mode.
--- @param mode_name string
--- @param method string
--- @param params table|nil
function M.notify_for_mode(mode_name, method, params)
    local cid = M.mode_bindings[mode_name]
    if cid == nil then
        return
    end
    enqueue_send(method, params, 0, cid)
end

--- Send a request by explicit client_id. Kept for callers that track an
--- id directly rather than a mode name.
--- @param client_id integer
--- @param method string
--- @param params table|nil
--- @param id integer request id
function M.request(client_id, method, params, id)
    enqueue_send(method, params, id, client_id)
end

--- Send a notification by explicit client_id.
--- @param client_id integer
--- @param method string
--- @param params table|nil
function M.notify(client_id, method, params)
    enqueue_send(method, params, 0, client_id)
end

--- Mint the next request id (main-owned; skips id 1 = lane's initialize).
--- Stored so apply_response can route the reply.
--- @param callback fun(result:any, is_error:boolean) invoked on main when
---   the response arrives; result is the decoded JSON value.
--- @return integer id the minted request id
function M.mint_request_id(callback)
    local id = _next_request_id
    _next_request_id = _next_request_id + 1
    M._pending_requests[id] = callback
    return id
end

--- Register a handler for an inbound server notification (method set,
--- no id). The handler receives the parsed `params` Lua table + the
--- client_id; the lane-parsed yyjson doc is already freed by the time
--- it runs. Registering nil clears the handler._unregisterd methods
--- are logged + dropped by apply_notification.
--- @param method string e.g. "textDocument/publishDiagnostics"
--- @param handler fun(params:any, client_id:integer)|nil
function M.on_notification(method, handler)
    M._notification_handlers[method] = handler
end

--- Request textDocument/formatting for a document on the server bound
--- to `client_id`. `opts` is { tab_size = N, insert_spaces = bool }.
--- `callback` receives the decoded result (a TextEdit[] array, or nil
--- if the server returns null). No-op + returns nil if not ready.
--- @param client_id integer
--- @param uri string file:// URI
--- @param opts {tab_size:integer, insert_spaces:boolean}
--- @param callback fun(result:any, is_error:boolean)
--- @return integer|nil id the request id, or nil if not ready
function M.request_format(client_id, uri, opts, callback)
    if not M.is_ready(client_id) then
        return nil
    end
    local id = M.mint_request_id(callback)
    enqueue_send("textDocument/formatting", {
        textDocument = { uri = uri },
        options = {
            tabSize = opts.tab_size or 4,
            insertSpaces = opts.insert_spaces ~= false,
        },
    }, id, client_id)
    return id
end

----------------------------------------------------------------------------------------------------
-- Completion (textDocument/completion)
--
-- Mirrors request_format: mints a main-owned request id + enqueues a
-- textDocument/completion request. The result (a CompletionList or
-- CompletionItem[] or null) flows back via apply_response → the supplied
-- callback, decoded on the lane and re-encoded as just the `result`
-- field, so the (potentially large) list crosses the boundary as one
-- small JSON blob and main only does the final decode + dispatch.
--
-- `position.character` is a 0-based UTF-16 code-unit offset per the LSP
-- spec; callers must convert from the buffer's 0-based byte col.
----------------------------------------------------------------------------------------------------

--- LSP CompletionTriggerKind values (spec). 1=Invoked, 2=TriggerCharacter,
--- 3=TriggerForIncompleteCompletions.
local COMPLETION_TRIGGER_INVOKED = 1
local COMPLETION_TRIGGER_CHARACTER = 2

--- Request completions for a document on the server bound to
--- `client_id`. `position` is `{ line = L, character = C }` with L a
--- 0-based line and C a 0-based UTF-16 code-unit offset. `trigger` is an
--- optional single character the user just typed (forces triggerKind=2).
--- `callback` receives the decoded result (a CompletionList
--- `{items=,isIncomplete=}`, a CompletionItem[] array, or nil for null).
--- No-op + returns nil if the server isn't ready.
--- @param client_id integer
--- @param uri string file:// URI
--- @param position {line:integer, character:integer} LSP position
--- @param trigger string? single trigger character just typed, or nil
--- @param callback fun(result:any, is_error:boolean)
--- @return integer|nil id the request id, or nil if not ready
function M.request_completion(client_id, uri, position, trigger, callback)
    if not M.is_ready(client_id) then
        log.info("lsp_complete", "request_skipped_not_ready", { client_id = client_id, uri = uri })
        return nil
    end
    local id = M.mint_request_id(callback)
    local ctx
    if trigger ~= nil and trigger ~= "" then
        ctx = {
            triggerKind = COMPLETION_TRIGGER_CHARACTER,
            triggerCharacter = trigger,
        }
    else
        ctx = { triggerKind = COMPLETION_TRIGGER_INVOKED }
    end
    log.info("lsp_complete", "request_enqueued_main_to_lane", {
        client_id = client_id,
        id = id,
        uri = uri,
        line = position.line,
        character = position.character,
        trigger = trigger,
    })
    enqueue_send("textDocument/completion", {
        textDocument = { uri = uri },
        position = position,
        context = ctx,
    }, id, client_id)
    return id
end

----------------------------------------------------------------------------------------------------
-- Go-to-definition (textDocument/definition)
--
-- Like request_format/request_completion: mints a main-owned request id
-- + enqueues the request. The result flows back via apply_response
-- (the generic doc-transfer path) and is a Location, Location[],
-- LocationLink[] (if the client declared hierarchical chrSupport — we
-- don't, so servers return plain Location/Location[]), or null. Main
-- dispatches by id against the pending-request registry; the callback
-- normalizes the shape and reuses Editor:jump_to_location.
----------------------------------------------------------------------------------------------------

--- Request textDocument/definition at `position` on the server bound to
--- `client_id`. `position` is `{ line = L, character = C }` with L a 0-based
--- line and C a 0-based UTF-16 code-unit offset. `callback` receives the
--- decoded result (a Location, Location[], LocationLink[], or nil for
--- null) + `is_error`. No-op + returns nil if not ready.
--- @param client_id integer
--- @param uri string file:// URI
--- @param position {line:integer, character:integer} LSP position
--- @param callback fun(result:any, is_error:boolean)
--- @return integer|nil id the request id, or nil if not ready
function M.request_definition(client_id, uri, position, callback)
    if not M.is_ready(client_id) then
        log.info(
            "lsp",
            "definition request skipped (not ready)",
            { client_id = client_id, uri = uri }
        )
        return nil
    end
    local id = M.mint_request_id(callback)
    enqueue_send("textDocument/definition", {
        textDocument = { uri = uri },
        position = position,
    }, id, client_id)
    return id
end

----------------------------------------------------------------------------------------------------
-- Document synchronization (didOpen / didChange / didClose)
--
-- Full-text sync: main hands the buffer's full text as a malloc'd
-- pointer (Buffer:write_text_direct) to the lane; the lane builds the
-- JSON-RPC notification envelope itself, so NO JSON encode of the
-- (potentially large) text happens on the main thread. Main only does
-- the calloc + memcpy of the doc header (uri/language_id) + transfers
-- the text buffer pointer (ownership → lane frees).
--
-- Readiness gating: a server only accepts didOpen AFTER its initialize
-- handshake completes (status == ready). Main mints the version counter
-- but DEFERS the actual didOpen until the READY handshake lands. Callers
-- record intent via sync_open_for_mode (sets the buffer's lsp_* fields +
-- marks want_open); the `lsp_status` READY transition in drain_lsp_inbox
-- flushes pending opens for that client via flush_pending_opens below.
----------------------------------------------------------------------------------------------------

--- Build + push a struct LspDocSync. Takes ownership of `text_ptr`
--- (the lane frees it). text_ptr may be nil for close.
--- @param client_id integer
--- @param kind integer constants.LSP_DOC_*
--- @param uri string
--- @param language_id string
--- @param version integer
--- @param text_ptr any malloc'd char* (ownership transfers) or nil
--- @param text_len integer
local function enqueue_doc_sync(client_id, kind, uri, language_id, version, text_ptr, text_len)
    local s = ss()
    if s == nil then
        if text_ptr ~= nil then
            ffi.C.free(text_ptr)
        end
        return
    end
    local d = ffi.cast("struct LspDocSync *", ffi.C.calloc(1, ffi.sizeof("struct LspDocSync")))
    d.client_id = client_id
    d.version = version
    d.kind = kind
    ffi.copy(d.uri, uri, math.min(#uri, 511))
    ffi.copy(d.language_id, language_id, math.min(#language_id, 31))
    d.text_ptr = text_ptr
    d.text_len = text_len
    s:push(s._ptr.outbox_lsp, { type = constants.MSG_LSP_DOC_SYNC, ptr = d })
end

--- Is this client ready to accept didOpen (initialize handshake done)?
--- @param client_id integer
--- @return boolean
function M.is_ready(client_id)
    local entry = M.clients[client_id]
    return entry ~= nil and entry.status == "ready"
end

--- Completion triggerCharacters set for a client (table<char,boolean>), or
--- nil if none / not yet relayed. Used by the completion source to send
--- triggerKind=2 AND by the menu's immediate-on-trigger fast-path.
--- @param client_id integer
--- @return table<string,boolean>|nil
function M.trigger_chars_for(client_id)
    return M.trigger_chars[client_id]
end

--- Record intent to open a document for a client. If the client is
--- already ready, emits didOpen immediately; else defers until the
--- READY handshake (flush_pending_opens, called from drain_lsp_inbox).
--- `get_text` is a zero-arg function returning (text_ptr, text_len)
--- called lazily at flush time, so we don't snapshot the buffer text
--- until the moment we actually send.
--- @param client_id integer
--- @param uri string
--- @param language_id string
--- @param get_text fun():(any, integer) returns malloc'd char* + len
function M.sync_open(client_id, uri, language_id, get_text)
    if M._ss == nil or client_id == 0 then
        return
    end
    -- De-dup: don't open the same uri twice on the same client.
    local open = M._open_docs[client_id]
    if open and open[uri] then
        return
    end
    if M.is_ready(client_id) then
        local ptr, len = get_text()
        enqueue_doc_sync(client_id, constants.LSP_DOC_OPEN, uri, language_id, 0, ptr, len)
        M._open_docs[client_id] = M._open_docs[client_id] or {}
        M._open_docs[client_id][uri] = { language_id = language_id, version = 0 }
    else
        -- Defer. Stored without text; captured at flush.
        M._pending_opens[client_id] = M._pending_opens[client_id] or {}
        M._pending_opens[client_id][uri] = { language_id = language_id, get_text = get_text }
    end
end

--- Flush pending didOpen requests for a client now that it's READY.
--- Called from main.lua's drain_lsp_inbox on the ready transition.
--- @param client_id integer
function M.flush_pending_opens(client_id)
    local pending = M._pending_opens[client_id]
    if pending == nil then
        return
    end
    M._pending_opens[client_id] = nil
    for uri, info in pairs(pending) do
        local ptr, len = info.get_text()
        info.get_text = nil -- drop closure reference so the buffer can GC
        enqueue_doc_sync(client_id, constants.LSP_DOC_OPEN, uri, info.language_id, 0, ptr, len)
        M._open_docs[client_id] = M._open_docs[client_id] or {}
        M._open_docs[client_id][uri] = { language_id = info.language_id, version = 0 }
    end
end

--- Send a full-text didChange. No-op if the doc isn't open yet (the
--- pending didOpen will carry the latest text). `get_text` snapshots
--- the buffer lazily at call time.
--- @param client_id integer
--- @param uri string
--- @param version integer
--- @param get_text fun():(any, integer) returns malloc'd char* + len
function M.sync_change(client_id, uri, version, get_text)
    if M._ss == nil or client_id == 0 then
        return
    end
    local open = M._open_docs[client_id]
    if open == nil or open[uri] == nil then
        log.info(
            "lsp_sync",
            "sync_change_skip_not_open",
            { client_id = client_id, uri = uri, version = version }
        )
        return -- not open yet; didOpen will carry latest text
    end
    local ptr, len = get_text()
    -- language_id unused for CHANGE (doc already open); pass empty.
    enqueue_doc_sync(client_id, constants.LSP_DOC_CHANGE, uri, "", version, ptr, len)
    open[uri].version = version
end

--- Last version we relayed to the server for (client_id, uri), or -1 if
--- the doc isn't open. Used by the editor's debounce to decide whether a
--- didChange is pending (buf.lsp_version > sent).
--- @param client_id integer
--- @param uri string
--- @return integer
function M.doc_sent_version(client_id, uri)
    local open = M._open_docs[client_id]
    if open == nil or open[uri] == nil then
        return -1
    end
    return open[uri].version
end

--- Send didClose for a document + drop it from the open registry.
--- Also clears any pending open for this uri.
--- @param client_id integer
--- @param uri string
function M.sync_close(client_id, uri)
    if M._ss == nil or client_id == 0 then
        return
    end
    local open = M._open_docs[client_id]
    local lang_id = open and open[uri] and open[uri].language_id or ""
    if open and open[uri] then
        enqueue_doc_sync(client_id, constants.LSP_DOC_CLOSE, uri, lang_id, 0, nil, 0)
        open[uri] = nil
    end
    local pending = M._pending_opens[client_id]
    if pending then
        pending[uri] = nil
    end
end

--- Drop ALL open documents for a client (e.g. on the client's death:
--- the server's doc state is gone with the process). Does NOT send
--- didClose (the server is gone).
--- @param client_id integer
function M.drop_client_docs(client_id)
    M._open_docs[client_id] = nil
    M._pending_opens[client_id] = nil
    -- Drop this client's diagnostics so a dead/respawned server's stale
    -- squiggles don't outlive its doc state. (A re-spawn will re-publish.)
    for uri, entry in pairs(M._diagnostics_by_uri) do
        if entry.client_id == client_id then
            M._diagnostics_by_uri[uri] = nil
        end
    end
    -- A dead server won't reply to its pending requests, so their
    -- callbacks simply never fire (the closures GC once the table entry
    -- is overwritten by id reuse — ids are main-minted + monotonic).
end

----------------------------------------------------------------------------------------------------
-- Status (modeline ⛏)
----------------------------------------------------------------------------------------------------

--- Status of the first server among the given short executable names.
--- Returns the name + a status string ("spawning"/"ready"/"dead"/
--- "killed"/"missing") so the modeline can render a distinct glyph.
--- Looks up a registered client by declared exe name; if a spawn was
--- requested but no client exists yet, falls back to "missing".
--- @param servers (string|table)[] first-wins list of executables (strings or `{bin,args,env}` tables)
--- @return string|nil name short name of the matching server
--- @return string status status string ("missing" if none found)
function M.server_status_for(servers)
    local cands = M.normalize(servers)
    for _, c in ipairs(cands) do
        local cid = M.exe_to_client[c.bin]
        if cid then
            local entry = M.clients[cid]
            if entry and entry.status ~= nil then
                return c.bin, entry.status
            end
        end
    end
    if cands[1] then
        return cands[1].bin, "missing"
    end
    return nil, "missing"
end

----------------------------------------------------------------------------------------------------
-- Shutdown / cleanup
---------------------------------------------------------------------------------------------------

--- Kill every known client + SHUTDOWN the lane. Wipes registries.
function M.shutdown()
    local s = ss()
    if s == nil then
        return
    end
    for cid, entry in pairs(M.clients) do
        local req =
            ffi.cast("struct LspKillReq *", ffi.C.calloc(1, ffi.sizeof("struct LspKillReq")))
        req.client_id = cid
        ffi.copy(req.exe_name, entry.exe_name, math.min(#entry.exe_name, 63))
        s:push(s._ptr.outbox_lsp, { type = constants.MSG_LSP_KILL, ptr = req })
    end
    s:push(s._ptr.outbox_lsp, { type = constants.MSG_SHUTDOWN })
    M.clients = {}
    M.mode_bindings = {}
    M.exe_to_client = {}
    M.trigger_chars = {}
end

----------------------------------------------------------------------------------------------------
-- Inbound (MSG_LSP_HANDSHAKE from the lane)
----------------------------------------------------------------------------------------------------

--- Consume a MSG_LSP_HANDSHAKE (called from main.lua's drain_lsp_inbox).
--- Updates the client_id-keyed registry with the relayed status. The id
--- was main-assigned at SPAWN time; the lane only echoes it + the status.
--- Entries are KEPT for terminal statuses (dead/killed/missing) so the
--- modeline distinguishes them; mode bindings pointing at a terminal
--- client are cleared so a re-enter re-spawns. Frees the struct.
--- @param ptr any struct LspHandshake*
--- @return {client_id:integer, exe_name:string, status:string}|nil parsed info for the caller to emit as an event
function M.apply_handshake(ptr)
    if ptr == nil then
        return nil
    end
    local hs = ffi.cast("struct LspHandshake *", ptr)
    local cid = tonumber(hs.client_id)
    ---@cast cid integer
    local name = ffi.string(hs.exe_name, 64)
    local nul = name:find("%z")
    if nul then
        name = name:sub(1, nul - 1)
    end
    local status = _STATUS_NAMES[tonumber(hs.status)] or "missing"

    -- trigger_chars (NUL-terminated, 0..63 single chars). Captured once
    -- on the READY handshake from serverCapabilities; echoed on every
    -- subsequent handshake for this client (empty until capabilities
    -- arrive). Build the lookup set lazily.
    local tc_raw = ffi.string(hs.trigger_chars, 64)
    local tc_nul = tc_raw:find("%z")
    if tc_nul then
        tc_raw = tc_raw:sub(1, tc_nul - 1)
    end

    -- Upsert. Preserve the modes set across handshakes (a re-spawn of
    -- the same id reuses the entry).
    local entry = M.clients[cid]
    if entry == nil then
        entry = { exe_name = name, status = status, modes = {} }
        M.clients[cid] = entry
    end
    local prev_status = entry.status
    entry.exe_name = name
    entry.status = status
    M.exe_to_client[name] = cid

    -- On a terminal status, clear this client's mode bindings so a
    -- later spawn_for_mode for those modes re-spawns (the dead entry
    -- stays in the registry so the modeline keeps showing srv✝/srv—).
    if not is_live(status) then
        for mode_name, mb_cid in pairs(M.mode_bindings) do
            if mb_cid == cid then
                M.mode_bindings[mode_name] = nil
            end
        end
        -- The server process is gone; its doc state is too. Drop
        -- our open-doc registry for it (no didClose — nobody to send to)
        -- and forget its trigger chars (a re-spawn will re-publish them).
        M.drop_client_docs(cid)
        M.trigger_chars[cid] = nil
    elseif #tc_raw > 0 then
        local set = {}
        for i = 1, #tc_raw do
            set[tc_raw:sub(i, i)] = true
        end
        M.trigger_chars[cid] = set
    end

    -- On a READY transition, flush any didOpens deferred while the
    -- client was still SPAWNING (mode_enter can fire before the
    -- initialize response lands).
    if status == "ready" and prev_status ~= "ready" then
        M.flush_pending_opens(cid)
    end

    ffi.C.free(ptr)
    return { client_id = cid, exe_name = name, status = status, prev_status = prev_status }
end

--- Install the SharedState wrapper (called once from main.lua after init).
--- @param s any SharedState
function M.set_shared_state(s)
    M._ss = s
end

--- Consume a MSG_LSP_RESPONSE (called from main.lua's drain_lsp_inbox).
--- Decodes the trailing result JSON via yyjson + dispatches it to the
--- matching pending-request callback (registered by mint_request_id).
--- Frees the struct. Unknown ids (e.g. after a client died) are dropped.
--- @param ptr any struct LspResponse*
--- @return integer|nil client_id replied (nil if ptr was nil)
function M.apply_response(ptr)
    if ptr == nil then
        return nil
    end
    local resp = ffi.cast("struct LspResponse *", ptr)
    local cid = tonumber(resp.client_id)
    ---@cast cid integer
    local id = tonumber(resp.id)
    ---@cast id integer
    local is_err = tonumber(resp.error_present) ~= 0
    local doc = resp.doc
    local val = resp.val

    -- Walk the lane-parsed value into a Lua table (no re-parse; the
    -- heavy yyjson_read ran off-main on the lane). The result table is
    -- independent of the doc, so free the doc before dispatching.
    local result = nil
    if doc ~= nil and val ~= nil then
        local ok, v = pcall(json.val_to_lua, val)
        if ok then
            result = v
        else
            log.warn("lsp", "response val_to_lua failed", { id = id, error = tostring(v) })
        end
    end
    if doc ~= nil then
        json.free_doc(doc)
    end
    ffi.C.free(ptr)

    log.info("lsp_complete", "response_decoded_lane_to_main", {
        client_id = cid,
        id = id,
        is_error = is_err,
        has_callback = M._pending_requests[id] ~= nil,
    })
    local cb = M._pending_requests[id]
    if cb ~= nil then
        M._pending_requests[id] = nil
        cb(result, is_err)
    end
    return cid
end

--- Consume a MSG_LSP_NOTIFICATION (called from main's drain_lsp_inbox).
--- The lane already parsed the body into a yyjson_doc (yyjson_read ran
--- off-main); here we walk the `params` value into a Lua table via
--- val_to_lua, free the doc, then dispatch by method to a handler
--- registered via on_notification. Unhandled methods are logged +
--- dropped. Mirrors apply_response but method-routed instead of id-routed.
--- @param ptr any struct LspNotification*
--- @return integer|nil client_id
function M.apply_notification(ptr)
    if ptr == nil then
        return nil
    end
    local n = ffi.cast("struct LspNotification *", ptr)
    local cid = tonumber(n.client_id)
    ---@cast cid integer
    local mlen = tonumber(n.method_len)
    ---@cast mlen integer
    local doc = n.doc -- ownership transfers here; freed below
    local val = n.params_val -- yyjson_val* (params) into *doc
    local base = ffi.cast("char *", ptr) + ffi.sizeof("struct LspNotification")
    local method = (mlen > 0) and ffi.string(base, mlen) or ""
    ffi.C.free(ptr) -- struct no longer needed; doc lives on until walked

    local params = nil
    if doc ~= nil and val ~= nil then
        local ok, p = pcall(json.val_to_lua, val)
        if ok then
            params = p
        else
            log.warn("lsp", "notification val_to_lua failed", {
                method = method,
                error = tostring(p),
            })
        end
    end
    json.free_doc(doc) -- always free the tree, even on partial walk

    local h = M._notification_handlers[method]
    if h ~= nil then
        h(params, cid)
    else
        log.debug("lsp", "notification dropped (no handler)", { method = method })
    end
    return cid
end

--- Handler for textDocument/publishDiagnostics (registered via
--- on_notification at module load). Receives the parsed `params` table
--- ({ uri, version?, diagnostics[] }) and stores flat per-diagnostic
--- records keyed by uri; an empty array removes the uri's entry so
--- stale squiggles don't linger. Each item keeps the same shape the
--- yyjson slice-walk previously produced:
---   { sl, sc, el, ec, severity, message, source, code }
--- with 0-based LSP line + UTF-16 char offsets (callers convert).
--- @param params any parsed publishDiagnostics params table
--- @param cid integer owning client id
local function handle_publish_diagnostics(params, cid)
    if type(params) ~= "table" then
        return
    end
    local uri = params.uri
    if type(uri) ~= "string" or uri == "" then
        return
    end
    local function num(x)
        return type(x) == "number" and x or 0
    end
    local function str(x)
        return type(x) == "string" and x or nil
    end
    local items = {}
    local diags = params.diagnostics
    if type(diags) == "table" then
        for _, d in ipairs(diags) do
            local r = d.range
            local s = r and r.start
            local e = r and r["end"]
            if type(s) == "table" and type(e) == "table" then
                items[#items + 1] = {
                    sl = num(s.line),
                    sc = num(s.character),
                    el = num(e.line),
                    ec = num(e.character),
                    severity = num(d.severity),
                    message = str(d.message),
                    source = str(d.source),
                    code = str(d.code),
                }
            end
        end
    end
    local ver = type(params.version) == "number" and params.version or 0
    if #items == 0 then
        M._diagnostics_by_uri[uri] = nil
    else
        M._diagnostics_by_uri[uri] =
            { client_id = cid, version = (ver ~= 0 and ver or nil), items = items }
    end
    log.info("lsp", "diagnostics_stored", { uri = uri, count = #items })
end
M.on_notification("textDocument/publishDiagnostics", handle_publish_diagnostics)

--- Clear stored diagnostics for a uri (e.g. on buffer close).
---@param uri string
function M.clear_diagnostics(uri)
    M._diagnostics_by_uri[uri] = nil
end

--- Read stored diagnostics for a uri, or nil if none. Each item is
--- { sl, sc, el, ec, severity, message, source, code }: 0-based LSP
--- line + UTF-16 character offsets (callers convert to byte offsets
--- against the current line text) + severity 1..4 (error/warn/info/
--- hint) or 0 if absent + the human-readable message text/source/code.
---@param uri string
---@return {client_id:integer, version:integer|nil, items:table[]}|nil
function M.diagnostics_for_uri(uri)
    return M._diagnostics_by_uri[uri]
end

return M
