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
--- yyjson_doc; main's drain_lsp_inbox walks it into a Lua table, frees
--- the doc, then RE-EMITS on the editor event bus:
---   • `"lsp_response:" .. id`       → (result, is_error, client_id)
---   • `"lsp_notification:" .. method` → (params, client_id)
---   • `"lsp_status:" .. client_id`   → (exe_name, status, prev_status)
--- (per handshake transition)
--- So callers register one-shot listeners for the request id they
--- minted (via mint_request_id) instead of passing a callback; lsp_client
--- holds NO callback or notification-handler registry itself. The
--- `lsp_status:<cid>` events are consumed by `on_status` (start/restart
--- commands) and any future lifecycle subscriber.

local ffi = require("ffi")
local constants = require("cursed.shared")
local log = require("cursed.log")
local json = require("cursed.json_ffi")
local async = require("cursed.async")
local drain_generic = require("cursed.lane_registry").drain_generic

--- Module exports table.
--- @class LSPModule
local M = {}

----------------------------------------------------------------------------------------------------
-- Registries (all main-side, all keyed off client_id)
----------------------------------------------------------------------------------------------------

--- client_id → { exe_name, status (string), modes:set, workspace_dir }.
--- Populated from MSG_LSP_HANDSHAKE. Drives server_status_for + shutdown.
--- Entries are KEPT for terminal statuses (dead/killed/missing) so the
--- modeline can distinguish them; only "spawning"/"ready" count as live
--- for dedup, and mode bindings are cleared on terminal so a re-enter
--- re-spawns.
--- @type table<integer, {exe_name:string, status:string, modes:table<string,boolean>, workspace_dir:string}>
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
--- nil). Materialized ONCE on arrival by `M.store_diagnostics` (the
--- `"lsp_notification:textDocument/publishDiagnostics"` subscriber in
--- editor_listeners.lua) walking the lane-parsed params table
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
    s:push(s._ptr.outboxes[constants.LANE_IDX_LSP], { type = constants.MSG_LSP_SPAWN, ptr = buf })
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
    if id ~= 0 then
        M._pending[id] = true
    end
    s:push(s._ptr.outboxes[constants.LANE_IDX_LSP], { type = constants.MSG_LSP_SEND, ptr = buf })
end

----------------------------------------------------------------------------------------------------
-- Dedup + spawn entry point
----------------------------------------------------------------------------------------------------

--- Find a live client whose exe_name matches any of `candidates`
--- (first-wins against the declared list). Returns its client_id, or
--- Find a live client whose exe matches any candidate AND whose
--- workspace_dir matches `workspace_dir`. Returns the client_id or
--- nil. The workspace_dir match ensures files from different project
--- roots get separate server instances (tsserver refuses to serve files
--- outside its rootUri; other servers have similar per-root behavior).
--- @param cands table[] normalized candidates
--- @param workspace_dir string workspace root to match
--- @return integer|nil
local function find_live_client(cands, workspace_dir)
    for _, c in ipairs(cands) do
        -- Scan all clients (not just exe_to_client, which holds only the
        -- last cid for this exe) so a second project root gets found
        --- even when an earlier one already registered.
        for id, entry in pairs(M.clients) do
            if
                entry.exe_name == c.bin
                and is_live(entry.status)
                and entry.workspace_dir == workspace_dir
            then
                return id
            end
        end
    end
    return nil
end

--- Get-or-spawn an LSP client for a mode and bind mode_name → client_id.
--- Dedups by (exe name, workspace_dir): two modes declaring the same
--- server binary AND the same project root share one process; files
--- from different project roots get separate server instances.
--- No fork happens on the main thread; this enqueues to the lane.
--- @param mode_name string the major-mode instance name (binding key)
--- @param servers string[]|table[] first-wins list of executions (mixed)
--- @param workspace_dir string workspace root directory (dedup key; files
---   from different roots get separate server instances)
--- @return integer client_id the id assigned/bound (0 if nothing to spawn)
function M.spawn_for_mode(mode_name, servers, workspace_dir)
    if M._ss == nil then
        return 0
    end
    local cands = M.normalize(servers)
    if #cands == 0 then
        return 0
    end

    -- Already bound for this mode AND the workspace_dir matches? Reuse
    -- if still live (a dead/killed binding falls through to re-spawn).
    local bound = M.mode_bindings[mode_name]
    if
        bound
        and M.clients[bound]
        and is_live(M.clients[bound].status)
        and M.clients[bound].workspace_dir == workspace_dir
    then
        return bound
    end

    -- Dedup: a live client for any of these exe names AND matching
    -- workspace_dir → bind this mode to it (don't spawn a duplicate).
    local existing = find_live_client(cands, workspace_dir)
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
            workspace_dir = workspace_dir,
        }
        -- exe_to_client holds the LAST cid for this exe (for the modeline
        -- resolution path). The full dedup scan in find_live_client
        -- considers all entries on M.clients against workspace_dir.
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

--- Kill ONE client (the single-process form of `shutdown`). Enqueues a
--- `MSG_LSP_KILL` for just this client_id and proactively marks it killed
--- in the registry so `is_live()` returns false immediately (without
--- waiting for the lane's KILLED handshake round-trip), clears any mode
--- bindings pointing at this cid so a fresh `spawn_for_mode` re-spawns,
--- drops this client's open-doc + trigger-char state (no didClose — the
--- process is being killed), and leaves the entry in place so the
--- modeline still distinguishes killed/missing from spawning/ready.
--- The lane's eventual KILLED handshake is idempotent against this.
--- Returns true on a known client; false if the cid isn't registered
--- (so the caller can still report "nothing to stop").
--- @param client_id integer
--- @return boolean killed true if a request was enqueued / state cleared
function M.kill_client(client_id)
    local entry = M.clients[client_id]
    if entry == nil then
        return false
    end
    local s = ss()
    if s ~= nil then
        local req =
            ffi.cast("struct LspKillReq *", ffi.C.calloc(1, ffi.sizeof("struct LspKillReq")))
        req.client_id = client_id
        ffi.copy(req.exe_name, entry.exe_name, math.min(#entry.exe_name, 63))
        s:push(
            s._ptr.outboxes[constants.LANE_IDX_LSP],
            { type = constants.MSG_LSP_KILL, ptr = req }
        )
    end
    -- Proactively mark killed + clear bindings/docs so callers can treat
    -- this client as gone without a handshake round-trip (mirrors the
    -- terminal-status branch of apply_handshake).
    entry.status = "killed"
    for mode_name, mb_cid in pairs(M.mode_bindings) do
        if mb_cid == client_id then
            M.mode_bindings[mode_name] = nil
        end
    end
    M.drop_client_docs(client_id)
    M.trigger_chars[client_id] = nil
    return true
end

--- Short name of the executable a client was spawned from, or nil when
--- the cid isn't registered. Convenience for status messages.
--- @param client_id integer
--- @return string|nil
function M.client_name(client_id)
    local entry = M.clients[client_id]
    return entry and entry.exe_name or nil
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
--- Pure counter bump — no callback registry. The caller pairs this id
--- with a one-shot listener on the editor event bus (event name
--- `"lsp_response:" .. id`); main's drain_lsp_inbox emits that event
--- with `(result, is_error, client_id)` when the lane relays the
--- response. This replaces the old id→callback table.
--- @return integer id the minted request id
function M.mint_request_id()
    local id = _next_request_id
    _next_request_id = _next_request_id + 1
    return id
end

--- Register a one-shot listener on the editor event bus for the next
--- response to request `id`. `fn` is called as `fn(editor, result,
--- is_error, client_id)` EXACTLY ONCE (when main's drain_lsp_inbox emits
--- `"lsp_response:" .. id`), then self-unregisters via `:off`. The
--- self-unregistration during emit is safe because each event name has
--- exactly one handler (the one we register here), so `:off` mutating
--- the handler array mid-`for` doesn't disturb any other handler.
--- Register BEFORE issuing the request; here both the listener register
--- and the `request_*` enqueue happen synchronously inside the same
--- command callback, and the response arrives in a future drain, so no
--- register-vs-emit race exists. No-op if `editor`/its event_system nil.
--- @param editor table? editor (needs `.event_system`)
--- @param id integer request id (returned by a request_* / mint_request_id)
--- @param fn fun(editor:table, result:any, is_error:boolean, client_id:integer)
function M.on_response(editor, id, fn)
    local es = editor and editor.event_system
    if es == nil then
        return
    end
    local event = "lsp_response:" .. tostring(id)
    local function handler(ed, result, is_err, cid)
        es:off(event, handler)
        fn(ed, result, is_err, cid)
    end
    es:on(event, handler)
end

--- Register a one-shot listener for the NEXT non-spawning lifecycle
--- transition of `client_id`. `fn` is called as `fn(editor, exe_name,
--- status, prev_status)` EXACTLY ONCE on the first `lsp_status:<cid>`
--- emit whose `status ~= "spawning"`, then self-unregisters via `:off`
--- (same mid-emit-off safety as on_response — exactly one handler per
--- event name). Main sets status="spawning" proactively at spawn time
--- WITHOUT emitting, so the lane's first handshake emit IS the settle
--- (ready / missing / dead / killed); we defensively skip a stray
--- "spawning" re-emit too. Use this from start/restart commands to
--- surface the spawn outcome without forcing the user to watch the
--- modeline. No-op if `editor`/its event_system nil.
--- @param editor table? editor (needs `.event_system`)
--- @param client_id integer the spawned client id
--- @param fn fun(editor:table, exe_name:string, status:string, prev_status:string?)
function M.on_status(editor, client_id, fn)
    local es = editor and editor.event_system
    if es == nil then
        return
    end
    local event = "lsp_status:" .. tostring(client_id)
    local function handler(ed, exe_name, status, prev_status)
        if status == "spawning" then
            return -- wait for the actual settle
        end
        es:off(event, handler)
        fn(ed, exe_name, status, prev_status)
    end
    es:on(event, handler)
end

--- Request textDocument/formatting for a document on the server bound
--- to `client_id`. `opts` is { tab_size = N, insert_spaces = bool }.
--- Returns the request id; subscribe to `"lsp_response:" .. id` on the
--- editor event bus to receive `(result, is_error, client_id)` where
--- `result` is a TextEdit[] array, or nil if the server returns null.
--- No-op + returns nil if not ready.
--- @param client_id integer
--- @param uri string file:// URI
--- @param opts {tab_size:integer, insert_spaces:boolean}
--- @return integer|nil id the request id, or nil if not ready
function M.request_format(client_id, uri, opts)
    if not M.is_ready(client_id) then
        return nil
    end
    local id = M.mint_request_id()
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
-- CompletionItem[] or null) flows back via apply_response → the editor
-- event bus as `"lsp_response:" .. id` carrying `(result, is_error,
-- client_id)`, decoded on the lane and re-encoded as just the `result`
-- field, so the (potentially large) list crosses the boundary as one
-- small JSON blob and main only does the final decode + emit.
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
--- Returns the request id; subscribe to `"lsp_response:" .. id` on the
--- editor event bus to receive `(result, is_error, client_id)` where
--- `result` is a CompletionList `{items=,isIncomplete=}`, a
--- CompletionItem[] array, or nil for null. No-op + returns nil if
--- the server isn't ready.
--- @param client_id integer
--- @param uri string file:// URI
--- @param position {line:integer,character:integer} LSP position
--- @param trigger string? single trigger character just typed, or nil
--- @return integer|nil id the request id, or nil if not ready
function M.request_completion(client_id, uri, position, trigger)
    if not M.is_ready(client_id) then
        log.info("lsp_complete", "request_skipped_not_ready", { client_id = client_id, uri = uri })
        return nil
    end
    local id = M.mint_request_id()
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
-- re-emits it on the event bus as `"lsp_response:" .. id`; the
-- requester normalizes the shape and reuses Editor:jump_to_location.
----------------------------------------------------------------------------------------------------

--- Request textDocument/definition at `position` on the server bound to
--- `client_id`. `position` is `{ line = L, character = C }` with L a 0-based
--- line and C a 0-based UTF-16 code-unit offset. Returns the request id;
--- subscribe to `"lsp_response:" .. id` to receive `(result, is_error,
--- client_id)` where `result` is a Location, Location[], LocationLink[],
--- or nil for null. No-op + returns nil if not ready.
--- @param client_id integer
--- @param uri string file:// URI
--- @param position {line:integer,character:integer} LSP position
--- @return integer|nil id the request id, or nil if not ready
function M.request_definition(client_id, uri, position)
    if not M.is_ready(client_id) then
        log.info(
            "lsp",
            "definition request skipped (not ready)",
            { client_id = client_id, uri = uri }
        )
        return nil
    end
    local id = M.mint_request_id()
    enqueue_send("textDocument/definition", {
        textDocument = { uri = uri },
        position = position,
    }, id, client_id)
    return id
end

----------------------------------------------------------------------------------------------------
-- Rename (textDocument/rename)
--
-- Same request/response pattern as definition/hover/codeAction: mint a
-- main-owned request id, enqueue textDocument/rename to the lane, route
-- the reply back via the generic MSG_LSP_RESPONSE path. The result is a
-- WorkspaceEdit ({ changes?, documentChanges? }) or null, re-emitted on
-- the editor event bus as `"lsp_response:" .. id` carrying
-- `(result, is_error, client_id)`. The caller applies the WorkspaceEdit
-- via Editor:apply_workspace_edit (which backgrounds-opens any not-open
-- target docs, so a rename touching N files is complete).
--
-- We advertise prepareSupport = false so servers accept a direct rename
-- without a preceding textDocument/prepareRename step. If/when we enable
-- prepareSupport, add request_prepare_rename + a prepare→rename two-step
-- so the server can validate the position + supply a placeholder name.
----------------------------------------------------------------------------------------------------

--- Request textDocument/rename at `position` for `new_name` on the server
--- bound to `client_id`. `position` is `{ line = L, character = C }` with
--- L a 0-based line and C a 0-based UTF-16 code-unit offset. `new_name` is
--- the symbol's new identifier. Returns the request id; subscribe to
--- `"lsp_response:" .. id` to receive `(result, is_error, client_id)` where
--- `result` is a WorkspaceEdit or nil for null. No-op + returns nil if not
--- ready.
--- @param client_id integer
--- @param uri string file:// URI
--- @param position {line:integer,character:integer} LSP position of the symbol
--- @param new_name string the new identifier for the symbol
--- @return integer|nil id the request id, or nil if not ready
function M.request_rename(client_id, uri, position, new_name)
    if not M.is_ready(client_id) then
        log.info("lsp", "rename request skipped (not ready)", { client_id = client_id, uri = uri })
        return nil
    end
    local id = M.mint_request_id()
    enqueue_send("textDocument/rename", {
        textDocument = { uri = uri },
        position = position,
        newName = new_name,
    }, id, client_id)
    return id
end

----------------------------------------------------------------------------------------------------
-- Code actions (textDocument/codeAction)
--
-- Same request/response pattern as definition/hover/completion: mint a
-- main-owned request id, enqueue the request to the lane, route the reply
-- back via the generic MSG_LSP_RESPONSE path. The result (a
-- (Command|CodeAction)[] or null) is decoded on the lane and re-emitted
-- on the editor event bus as `"lsp_response:" .. id` carrying
-- `(result, is_error, client_id)`.
--
-- `range` is the cursor-or-selection LSP range (start/end with 0-based
-- line + 0-based UTF-16 character). `context` carries the diagnostics
-- overlapping the range (so the server can return fixes-for-those),
-- `only` (filter by CodeActionKind), and `triggerKind` (1=Invoked=manual,
-- 2=Automatic). Callers pass `context = nil` for a plain manual invoke.
----------------------------------------------------------------------------------------------------

--- LSP CodeAction trigger kinds (spec): 1=Invoked (manual), 2=Automatic.
local CODE_ACTION_TRIGGER_INVOKED = 1

--- Request textDocument/codeAction for `range` on the server bound to
--- `client_id`. `range` is `{ start = {line,character}, ["end"] = {line,character} }`
--- (LSP positions, 0-based line + 0-based UTF-16 code-unit offset).
--- `context` is `{ diagnostics = [...], only = ...?, triggerKind = ...? }`;
--- pass nil to send a plain manual invoke (triggerKind=Invoked, no
--- diagnostics). Returns the request id; subscribe to
--- `"lsp_response:" .. id` to receive `(result, is_error, client_id)`
--- where `result` is a (Command|CodeAction)[] or nil for null.
--- No-op + returns nil if not ready.
--- @param client_id integer
--- @param uri string file:// URI
--- @param range {start:{line:integer,character:integer},["end"]:{line:integer,character:integer}} LSP range
--- @param context {diagnostics:table[]?,only:string[]?,triggerKind:integer?}|nil
--- @return integer|nil id the request id, or nil if not ready
function M.request_code_actions(client_id, uri, range, context)
    if not M.is_ready(client_id) then
        log.info(
            "lsp",
            "code actions request skipped (not ready)",
            { client_id = client_id, uri = uri }
        )
        return nil
    end
    local id = M.mint_request_id()
    local ctx = context
    if ctx == nil then
        ctx = { triggerKind = CODE_ACTION_TRIGGER_INVOKED }
    elseif ctx.triggerKind == nil then
        ctx = {
            diagnostics = ctx.diagnostics,
            only = ctx.only,
            triggerKind = CODE_ACTION_TRIGGER_INVOKED,
        }
    end
    enqueue_send("textDocument/codeAction", {
        textDocument = { uri = uri },
        range = range,
        context = ctx,
    }, id, client_id)
    return id
end

--- Request workspace/executeCommand for a CodeAction/Command whose
--- `command` field names a server-side command (no embedded edit). The
--- server applies its own mutation here; we don't request a back-path
--- (no workspace/applyEdit inbound-request handling yet), so callers
--- should prefer actions whose `edit` is populated when available.
--- Returns the request id; subscribe to `"lsp_response:" .. id` to
--- receive `(result, is_error, client_id)` where `result` is
--- server-defined (often nil). No-op + returns nil if not ready.
--- @param client_id integer
--- @param command string command identifier from a Command/CodeAction
--- @param arguments any[]|nil arguments array for the command
--- @return integer|nil id the request id, or nil if not ready
function M.request_execute_command(client_id, command, arguments)
    if not M.is_ready(client_id) then
        log.info(
            "lsp",
            "executeCommand request skipped (not ready)",
            { client_id = client_id, command = command }
        )
        return nil
    end
    local id = M.mint_request_id()
    enqueue_send("workspace/executeCommand", {
        command = command,
        arguments = arguments,
    }, id, client_id)
    return id
end

--- Request hover info at a position. Returns the request id; subscribe
--- to `"lsp_response:" .. id` to receive `(result, is_error, client_id)`
--- where `result` is the `Hover` (`{ range?, contents }`) or nil/error.
--- `contents` is MarkupContent / MarkedString / MarkedString[] — left
--- to the caller to normalize.
---@param client_id integer
---@param uri string
---@param position table {line, character} (UTF-16)
---@return integer|nil id
function M.request_hover(client_id, uri, position)
    if not M.is_ready(client_id) then
        log.info("lsp", "hover request skipped (not ready)", { client_id = client_id, uri = uri })
        return nil
    end
    local id = M.mint_request_id()
    enqueue_send("textDocument/hover", {
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
-- marks want_open); the `lsp_status:<cid>` READY transition in drain_lsp_inbox
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
    s:push(s._ptr.outboxes[constants.LANE_IDX_LSP], { type = constants.MSG_LSP_DOC_SYNC, ptr = d })
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
        if ptr == nil then
            return
        end
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
        if ptr ~= nil then
            enqueue_doc_sync(client_id, constants.LSP_DOC_OPEN, uri, info.language_id, 0, ptr, len)
            M._open_docs[client_id] = M._open_docs[client_id] or {}
            M._open_docs[client_id][uri] = { language_id = info.language_id, version = 0 }
        end
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
    if ptr == nil then
        return
    end
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
    -- A dead server won't reply to its pending requests; the one-shot
    -- `"lsp_response:" .. id` listeners bound for them simply never
    -- fire (and so never self-unregister). They're tiny closures; ids
    -- are main-minted + monotonic so the event-name keys are unique and
    -- never collide with a future request. Worst case the editor leaks a
    -- handful of small closures per dead-server un-replied request.
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

--- Status of the specific client bound to a buffer (by client_id).
--- Preferred over `server_status_for` when the buffer already has a
--- bound `lsp_client_id`: now that servers dedup per (exe, workspace_dir),
--- `exe_to_client` holds only the LAST cid for an exe name and may point
--- at a different project root's server. Returns nil when no client is
--- bound (the caller falls back to `server_status_for`).
--- @param client_id integer
--- @return string|nil name short name of the server
--- @return string status status string
function M.status_for_client(client_id)
    local entry = M.clients[client_id]
    if entry and entry.status ~= nil then
        return entry.exe_name, entry.status
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
        s:push(
            s._ptr.outboxes[constants.LANE_IDX_LSP],
            { type = constants.MSG_LSP_KILL, ptr = req }
        )
    end
    s:push(s._ptr.outboxes[constants.LANE_IDX_LSP], { type = constants.MSG_SHUTDOWN })
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
--- @return {client_id:integer, exe_name:string, status:string, prev_status:string?}|nil parsed info for the caller to emit as an event
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

---@param shared_state SharedState
---@param es table
function M.setup(shared_state, es)
    M._ss = shared_state
    M._es = es
    M._pending = {}
end

--- Consume a MSG_LSP_RESPONSE (called from main.lua's drain_lsp_inbox).
--- Decodes the trailing result value via yyjson (the heavy yyjson_read
--- ran off-main on the lane), frees the doc + struct, then RETURNS the
--- `(id, result, is_error, client_id)` tuple so the caller can emit it
--- on the editor event bus as `"lsp_response:" .. id` — main owns the
--- routing; lsp_client owns no callback registry. Unknown ids (e.g.
--- after a client died before its reply landed) are still returned; the
--- matching event simply has no subscribers and is a no-op emit.
--- @param ptr any struct LspResponse*
--- @return integer|nil id request id, or nil if ptr was nil
--- @return any result decoded JSON value (nil if absent/error)
--- @return boolean? is_error true if the response was an LSP error
--- @return integer|nil client_id owning client id
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
    -- independent of the doc, so free the doc before returning.
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
    })
    M._pending[id] = nil
    return id, result, is_err, cid
end

--- Consume a MSG_LSP_NOTIFICATION (called from main's drain_lsp_inbox).
--- The lane already parsed the body into a yyjson_doc (yyjson_read ran
--- off-main); here we walk the `params` value into a Lua table via
--- val_to_lua, free the doc, then RETURN the `(method, params, client_id)`
--- tuple so the caller can emit it on the editor event bus as
--- `"lsp_notification:" .. method` — main owns the routing; lsp_client
--- owns no notification-handler registry. Mirrors apply_response but is
--- method-routed instead of id-routed.
--- @param ptr any struct LspNotification*
--- @return string|nil method e.g. "textDocument/publishDiagnostics"
--- @return any params decoded params value (nil if absent/error)
--- @return integer|nil client_id owning client id
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
    return method, params, cid
end

--- Parse a server-initiated request from the lane (MSG_LSP_SERVER_REQUEST).
--- Returns `(method, params, request_id, client_id)` or nil on failure.
--- The lane allocated + pushed the struct; main frees it here.
---@param ptr any struct LspServerRequest*
---@return string|nil method
---@return table|nil params
---@return integer|nil id JSON-RPC request id (echo in response)
---@return integer|nil client_id
function M.apply_server_request(ptr)
    if ptr == nil then
        return nil
    end
    local req = ffi.cast("struct LspServerRequest *", ptr)
    local cid = tonumber(req.client_id)
    ---@cast cid integer
    local rid = tonumber(req.id)
    ---@cast rid integer
    local mlen = tonumber(req.method_len)
    ---@cast mlen integer
    local doc = req.doc
    local val = req.params_val
    local base = ffi.cast("char *", ptr) + ffi.sizeof("struct LspServerRequest")
    local method = (mlen > 0) and ffi.string(base, mlen) or ""
    ffi.C.free(ptr)

    local params = nil
    if doc ~= nil and val ~= nil then
        local ok, p = pcall(json.val_to_lua, val)
        if ok then
            params = p
        else
            log.warn("lsp", "server_request val_to_lua failed", {
                method = method,
                error = tostring(p),
            })
        end
    end
    json.free_doc(doc)
    return method, params, rid, cid
end

--- Send a JSON-RPC response to a server-initiated request.
--- Constructs {"jsonrpc": "2.0", id, result} and enqueues it
--- on the LSP lane's outbox so the lane writes it to the socket.
---@param client_id integer
---@param id integer the request id from apply_server_request
---@param result table the response result object
function M.respond(client_id, id, result)
    enqueue_send("__response", result, id, client_id)
end

--- Store diagnostics from a parsed `textDocument/publishDiagnostics`
--- notification. Subscribed to (in editor_listeners.lua) as the handler
--- for the `"lsp_notification:textDocument/publishDiagnostics"` event —
--- main's drain_lsp_inbox emits it with `(params, client_id)`.
--- Receives the parsed `params` table ({ uri, version?, diagnostics[] })
--- and stores flat per-diagnostic records keyed by uri; an empty array
--- removes the uri's entry so stale squiggles don't linger. Each item
--- keeps the same shape the yyjson slice-walk previously produced:
---   { sl, sc, el, ec, severity, message, source, code }
--- with 0-based LSP line + UTF-16 char offsets (callers convert).
--- @param params any parsed publishDiagnostics params table
--- @param cid integer owning client id
function M.store_diagnostics(params, cid)
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
        M._diagnostics_by_uri[uri] = { client_id = cid, version = ver, items = items }
    end
    log.info("lsp", "diagnostics_stored", { uri = uri, count = #items })
end

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

----------------------------------------------------------------------------------------------------
-- Async/await wrappers
----------------------------------------------------------------------------------------------------

--- Mint a request id, send the request, and return an AsyncToken for
--- async.await(). Caller does:
---   local result, is_err, cid = async.await(lsp.request_async(ed, cid, method, params))
--- No readiness check — the caller should check M.is_ready(client_id)
--- beforehand (matching the existing request_* pattern).
---@param editor table editor (needs .event_system)
---@param client_id integer
---@param method string LSP method name
---@param params table request params
---@return AsyncToken
--- Enqueue an LSP request and return an AsyncToken that resolves to
--- (result, is_error, cid) when the response arrives. Must be awaited
--- from a coroutine.
---@param editor table
---@param client_id integer
---@param method string
---@param params table
---@return AsyncToken
function M.request_async(editor, client_id, method, params)
    local id = M.mint_request_id()
    enqueue_send(method, params, id, client_id)
    return async.token(editor.event_system, "lsp_response:" .. tostring(id))
end

--- Await the next non-spawning lifecycle transition for `client_id`.
--- Yields the current coroutine until `lsp_status:<cid>` emits with
--- status != "spawning", then returns `(exe_name, status, prev_status)`.
--- If the client is already settled (status ~= "spawning"), returns
--- immediately without yielding.
--- Must be called from inside a coroutine (keybinding handler or
--- background task).
---@param editor table editor (needs .event_system)
---@param client_id integer
---@return string exe_name
---@return string status (ready / dead / killed / missing)
---@return string? prev_status
--- Return an AsyncToken that resolves to {exe_name, status, prev_status}
--- when the LSP client settles (status ~= "spawning"). If already settled,
--- the token resolves immediately via async.resolved(). Must be awaited
--- from a coroutine.
---@param editor table
---@param client_id integer
---@return AsyncToken
function M.on_status_async(editor, client_id)
    -- Check if already settled.
    local info = M.clients[client_id]
    if info and info.status and info.status ~= "spawning" then
        return async.resolved({ info.exe_name, info.status, nil })
    end

    local es = editor and editor.event_system
    if es == nil then
        return async.resolved({ "(no event system)", "missing", nil })
    end

    -- lsp_status emits (editor, exe_name, status, prev_status) —
    -- pack into a table so async.await returns a single payload.
    local token = async.token(es, "_lsp_status_pack:" .. client_id)
    local handler
    handler = es:on("lsp_status:" .. client_id, function(_, exe_name, status, prev_status)
        if status == "spawning" then
            return
        end
        es:off("lsp_status:" .. client_id, handler)
        es:emit(token._ev, { exe_name, status, prev_status })
    end)
    return token
end

--- Reinitialize after a lane restart. Respawns all known LSP servers.
--- The old subprocesses died with the lane; main-side client tracking
--- (client_id -> exe_name, workspace) is still intact. Since the full
--- candidate spec (args/env) is not preserved in M.clients entries,
--- each server is re-spawned with the stored exe_name and empty args/
--- env. Modes whose servers require non-default arguments (e.g.
--- --stdio) will re-spawn with correct args on the next mode_enter.
--- @param shared_state SharedState
--- @param _editor table
--- @param es table
function M.reinitialize(shared_state, _editor, es)
    M._ss = shared_state
    M._es = es
    for client_id, info in pairs(M.clients) do
        if info.exe_name and info.workspace_dir then
            local cands = { { bin = info.exe_name, args = {}, env = {} } }
            local ok, err = pcall(enqueue_spawn, cands, info.workspace_dir, client_id)
            if not ok then
                log.warn("lsp", "reinitialize spawn failed", {
                    client_id = client_id,
                    exe = info.exe_name,
                    error = tostring(err),
                })
            else
                info.status = "spawning"
            end
        end
    end
end

--- Emit synthetic error events for all still-pending LSP requests
--- after an LSP lane restart, so awaiting coroutines resume.
function M.flush_pending()
    for id in pairs(M._pending) do
        M._pending[id] = nil
        -- Emit matching what drain_lsp_inbox would: (result, is_error, client_id)
        -- Uses nil for result since we don't know the client_id at this point.
        -- The id-routed listener gets nil result + is_error = true.
        M._es:emit("lsp_response:" .. tostring(id), nil, true, 0)
    end
    M._pending = {}
end

---@return integer
function M.pending_count()
    local n = 0
    for _ in pairs(M._pending) do
        n = n + 1
    end
    return n
end

--- Drain the LSP lane inbox: pop handshake, response, and
--- notification messages and emit them on the editor's event bus.
function M.drain_inbox(editor)
	drain_generic(M._ss, M._ss._ptr.inboxes[constants.LANE_IDX_LSP], editor, {
		[constants.MSG_LSP_HANDSHAKE] = function(msg)
			local info = M.apply_handshake(msg.ptr)
			if info ~= nil then
				editor.event_system:emit(
					"lsp_status:" .. tostring(info.client_id),
					info.exe_name,
					info.status,
					info.prev_status
				)
			end
		end,
		[constants.MSG_LSP_RESPONSE] = function(msg)
			-- apply_response handles decoding + freeing; returns the id-routed
			-- tuple so we can re-emit on the event bus.
			local id, result, is_err, cid = M.apply_response(msg.ptr)
			if id ~= nil then
				editor.event_system:emit("lsp_response:" .. tostring(id), result, is_err, cid)
			end
		end,
		[constants.MSG_LSP_NOTIFICATION] = function(msg)
			local method, params, cid = M.apply_notification(msg.ptr)
			if method ~= nil and method ~= "" then
				editor.event_system:emit("lsp_notification:" .. method, params, cid)
			end
		end,
		[constants.MSG_LSP_SERVER_REQUEST] = function(msg)
			local method, params, rid, cid = M.apply_server_request(msg.ptr)
			if method ~= nil and method ~= "" then
				editor.event_system:emit("lsp_server_request:" .. method, params, rid, cid)
			end
		end,
	})
end

require("cursed.lane_registry").register(constants.LANE_IDX_LSP, M)
return M
