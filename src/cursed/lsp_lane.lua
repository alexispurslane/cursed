--- LSP Lane — owns all language-server subprocess management and all
--- JSON-RPC framing + JSON decode/encode, off the main thread.
---
--- Runs in its own pthread + lua_State (spawned from main.c::lsp_lane_thread).
--- Two event sources on its kqueue (lane_kq_fds[LANE_IDX_LSP]):
---   1. EVFILT_USER (ident 1) — main pushed a message to outboxes[LANE_IDX_LSP]
---      (SPAWN / SEND / KILL / SHUTDOWN). Ring_push triggers it.
---   2. EVFILT_READ — a child server's stdout became readable. We drain,
---      frame, and decode here; heavy JSON never touches the main loop.
---
--- Main relays outbound requests as messages to this lane and receives
--- inbound (decoded + packed into bespoke C structs per message type)
--- via inboxes[LANE_IDX_LSP]. v1 relays only the initialize handshake
--- (MSG_LSP_HANDSHAKE → modeline ⛏ status). Other inbound message types
--- are decoded here then logged and dropped — each gets its own packed
--- struct + main-side consumer as its feature lands.
---
--- This module is loaded as a top-level chunk (twin of io_lane.lua /
--- highlight_lane.lua): its body is the lane's main loop, not a library.

local ffi = require("ffi")
local bit = require("bit")
local log = require("cursed.log")
local ss = require("cursed.shared").SharedState.from_global()
local constants = require("cursed.shared")
local json = require("cursed.json_ffi")
local Kqueue = require("cursed.kqueue").Kqueue
local kq_ffi = require("cursed.kqueue_ffi")
local pffi = require("cursed.posix_ffi")

local lsp_kq = Kqueue.wrap(ss._ptr.lane_kq_fds[constants.LANE_IDX_LSP])
lsp_kq:add_wake(assert(tonumber(ss._ptr.outboxes[constants.LANE_IDX_LSP].wake_ident)))

log.configure({ level = "info", output = "/tmp/cursed.log" })
log.info("lsp_lane", "started")

----------------------------------------------------------------------------------------------------
-- Client state (one per spawned server). Indexed by short exe basename
-- (the dedup key main passes in SPAWN) AND by stdout_fd for kq dispatch.
----------------------------------------------------------------------------------------------------

--- @class LSPClient
--- @field stdout_fd integer
--- @field stdin_fd integer
--- @field pid integer
--- @field running boolean process alive (status is spawning/ready while true)
--- @field client_id integer main-assigned id (routing key for SEND/KILL)
--- @field exe_name string short basename of the resolved binary
--- @field status integer LSP_STATUS_* code (current lifecycle status)
--- @field next_id number
--- @field read_buf any malloc'd uint8_t* growth buffer
--- @field read_total number bytes written
--- @field read_head number oldest unconsumed offset
--- @field read_unread number read_total - read_head
--- @field awaiting_body number|nil body bytes still needed
--- @field buffer_capacity number
local LSPClient = {}
LSPClient.__index = LSPClient

local _clients_by_fd = {} ---@type table<integer, LSPClient>
local _clients_by_id = {} ---@type table<integer, LSPClient>

local STATUS = {
    SPAWNING = constants.LSP_STATUS_SPAWNING,
    READY = constants.LSP_STATUS_READY,
    DEAD = constants.LSP_STATUS_DEAD,
    KILLED = constants.LSP_STATUS_KILLED,
}

local function new_client(stdout_fd, stdin_fd, pid, client_id, exe_name)
    return setmetatable({
        stdout_fd = stdout_fd,
        stdin_fd = stdin_fd,
        pid = pid,
        running = true,
        client_id = client_id,
        exe_name = exe_name,
        status = STATUS.SPAWNING,
        trigger_chars = "", -- populated from initialize result capabilities
        next_id = 1,
        read_buf = ffi.cast("uint8_t *", ffi.C.malloc(65536)),
        read_total = 0,
        read_head = 0,
        read_unread = 0,
        awaiting_body = nil,
        buffer_capacity = 65536,
    }, LSPClient)
end

--- Push a handshake status snapshot to main so the modeline reflects it.
--- client_id + exe_name + status drive ⛏ status. Lane allocates
--- (main frees on consume).
local function send_handshake(client)
    local hs = ffi.cast("struct LspHandshake *", ffi.C.calloc(1, ffi.sizeof("struct LspHandshake")))
    if client.exe_name ~= nil then
        ffi.copy(hs.exe_name, client.exe_name, math.min(#client.exe_name, 63))
    end
    hs.client_id = client.client_id
    hs.status = client.status
    if client.trigger_chars ~= nil and #client.trigger_chars > 0 then
        ffi.copy(hs.trigger_chars, client.trigger_chars, math.min(#client.trigger_chars, 63))
    end
    ss:push(ss._ptr.inboxes[constants.LANE_IDX_LSP], { type = constants.MSG_LSP_HANDSHAKE, ptr = hs })
end

--- Relay a response to a main-owned request back to main.
--- Re-encodes just the `result` (or `error`) field as a JSON string and
--- ships it in a struct LspResponse; main decodes the (small) result via
--- yyjson + dispatches by id. Keeps the lane generic about result shape.
--- msg.result / msg.error are Lua tables (or nil) from json_ffi.decode.
--- Relay a main-owned request's response. Parses body_text ONCE into a
--- yyjson_doc (yyjson_read runs off-main), navigates to the `result` or
--- `error` value, and ships the doc + value pointer to main. Main walks
--- the value into a Lua table (val_to_lua) and frees the doc. Ownership
--- transfers to main; the lane frees nothing on success. Shape-agnostic
--- — main re-emits the response on its event bus keyed by id. On a
--- parse failure the lane NACKs the caller by shipping a doc-less
--- response (main fires the callback with is_error=true, result=nil)
--- rather than leaking the pending entry.
local function relay_response(client, msg, body_text)
    local err_present = msg.error ~= nil
    local doc, root, derr = json.decode_to_doc(body_text)
    if doc == nil then
        log.warn("lsp", "response doc parse failed", { id = msg.id, error = derr })
        -- Still must NACK so the caller's callback isn't leaked: ship a
        -- response with no doc; main treats nil result + is_error=true.
        doc = nil
        root = nil
    end
    local val = nil
    if root ~= nil then
        local key = err_present and "error" or "result"
        val = ffi.C.shim_obj_get(root, key)
        -- `result` may be legitimately absent (server returned {} with
        -- neither result nor error); val==nil is fine — main yields nil.
    end
    local buf = ffi.C.calloc(1, ffi.sizeof("struct LspResponse"))
    if buf == nil then
        ffi.C.shim_doc_free(doc) -- can't ship; don't leak the parse
        return
    end
    local resp = ffi.cast("struct LspResponse *", buf)
    resp.client_id = client.client_id
    resp.id = msg.id
    resp.error_present = (err_present or doc == nil) and 1 or 0
    resp.doc = doc
    resp.val = val
    if (tonumber(msg.id) or 0) > 1 then
        log.info("lsp_complete", "lane_relaying_response_to_main", {
            client_id = client.client_id,
            id = msg.id,
            is_error = err_present,
            doc_handed = doc ~= nil,
        })
    end
    ss:push(ss._ptr.inboxes[constants.LANE_IDX_LSP], { type = constants.MSG_LSP_RESPONSE, ptr = buf })
end

--- Relay a server→main JSON-RPC notification (any `msg.method` set,
--- `msg.id == nil`). Parses body_text ONCE into a yyjson_doc (yyjson_read
--- runs off-main), navigates to the `params` value, and ships the doc +
--- value pointer + the method string to main. Main walks `params` into
--- a Lua table (val_to_lua), frees the doc, and re-emits on its event
--- bus keyed by method. Ownership transfers to main; the lane frees
--- nothing on success. Mirrors relay_response.
--- `params` may be absent (some notifications carry none) — params_val
--- is then nil and the handler receives nil.
local function relay_notification(client, msg, body_text)
    local method = msg.method or ""
    local doc, root, derr = json.decode_to_doc(body_text)
    if doc == nil then
        log.warn("lsp", "notification doc parse failed", {
            method = method,
            error = derr,
        })
        return
    end
    local params_val = ffi.C.shim_obj_get(root, "params")
    local mlen = #method
    local total = ffi.sizeof("struct LspNotification") + mlen
    local buf = ffi.C.calloc(1, total)
    if buf == nil then
        ffi.C.shim_doc_free(doc) -- can't ship; don't leak the parse
        return
    end
    local notif = ffi.cast("struct LspNotification *", buf)
    notif.client_id = client.client_id
    notif.method_len = mlen
    notif.doc = doc
    notif.params_val = params_val
    if mlen > 0 then
        ffi.copy(ffi.cast("char *", buf) + ffi.sizeof("struct LspNotification"), method, mlen)
    end
    log.info("lsp", "lane_relaying_notification_to_main", {
        client_id = client.client_id,
        method = method,
        doc_handed = true,
    })
    ss:push(ss._ptr.inboxes[constants.LANE_IDX_LSP], { type = constants.MSG_LSP_NOTIFICATION, ptr = buf })
end

--- Relay a server\xe2\x86\x92main JSON-RPC request (any `msg.method` set,
--- `msg.id ~= nil`). Same pattern as relay_notification but carries
--- the request id so main can send a response. Currently handles
--- workspace/applyEdit; other methods are relayed but dropped on main.
local function relay_request(client, msg, body_text)
    local method = msg.method or ""
    local rid = tonumber(msg.id) or 0
    local doc, root, derr = json.decode_to_doc(body_text)
    if doc == nil then
        log.warn("lsp", "request doc parse failed", {
            method = method,
            id = rid,
            error = derr,
        })
        return
    end
    local params_val = ffi.C.shim_obj_get(root, "params")
    local mlen = #method
    local total = ffi.sizeof("struct LspServerRequest") + mlen
    local buf = ffi.C.calloc(1, total)
    if buf == nil then
        ffi.C.shim_doc_free(doc)
        return
    end
    local req = ffi.cast("struct LspServerRequest *", buf)
    req.client_id = client.client_id
    req.id = rid
    req.method_len = mlen
    req.doc = doc
    req.params_val = params_val
    if mlen > 0 then
        ffi.copy(ffi.cast("char *", buf) + ffi.sizeof("struct LspServerRequest"), method, mlen)
    end
    log.info("lsp", "lane_relaying_request_to_main", {
        client_id = client.client_id,
        method = method,
        id = rid,
    })
    ss:push(ss._ptr.inboxes[constants.LANE_IDX_LSP], { type = constants.MSG_LSP_SERVER_REQUEST, ptr = buf })
end

--- Framing + send
----------------------------------------------------------------------------------------------------

function LSPClient:send_frame(msg)
    local body, encerr = json.encode(msg)
    if body == nil then
        log.warn("lsp_lane", "json encode failed", { error = encerr })
        return
    end
    local header = ("Content-Length: %d\r\n\r\n"):format(#body)
    ffi.C.write(self.stdin_fd, header, #header)
    ffi.C.write(self.stdin_fd, body, #body)
end

function LSPClient:request(method, params)
    local id = self.next_id
    self.next_id = id + 1
    self:send_frame({
        jsonrpc = "2.0",
        id = id,
        method = method,
        params = params,
    })
    return id
end

function LSPClient:notify(method, params)
    self:send_frame({
        jsonrpc = "2.0",
        method = method,
        params = params,
    })
end

----------------------------------------------------------------------------------------------------
-- Drain: 8KB read, Content-Length framing, JSON decode, dispatch.
-- Runs on the lane (off main). Heavy decode is the whole point.
----------------------------------------------------------------------------------------------------

function LSPClient:_compact()
    local unread = self.read_total - self.read_head
    if unread == 0 then
        self.read_head = 0
        self.read_total = 0
        return
    end
    ffi.C.memmove(self.read_buf, self.read_buf + self.read_head, unread)
    self.read_total = unread
    self.read_head = 0
end

--- Tear down a dead client's fd bookkeeping so a closed/EOF'd stdout
--- PIPE doesn't keep the lane's kevent busy-spinning (pipe EOF is a
--- persistent EVFILT_READ condition EV_CLEAR does not auto-clear).
--- Idempotent.
function LSPClient:_teardown_dead()
    if self._dead then
        return
    end
    self._dead = true
    self.running = false
    if self.read_buf ~= nil then
        ffi.C.free(self.read_buf)
        self.read_buf = nil
    end
    local fd = self.stdout_fd
    _clients_by_fd[fd] = nil
    _clients_by_id[self.client_id] = nil
    lsp_kq:del_fd(fd)
    pcall(function()
        ffi.C.close(fd)
    end)
end

--- @return boolean alive
function LSPClient:drain()
    local buf = ffi.new("uint8_t[8192]")
    local fd = self.stdout_fd
    local n = tonumber(ffi.C.read(fd, buf, 8192)) or 0

    if n <= 0 then
        -- Server exited/crashed on its own (stdout EOF). Mark DEAD then
        -- teardown + relay so the modeline distinguishes it from killed.
        self.status = STATUS.DEAD
        self:_teardown_dead()
        send_handshake(self)
        return false
    end

    if self.read_total + n > self.buffer_capacity then
        local new_cap = self.buffer_capacity * 2
        ---@diagnostic disable-next-line: cast-local-type
        self.read_buf = ffi.cast("uint8_t *", ffi.C.realloc(self.read_buf, new_cap))
        self.buffer_capacity = new_cap
    end

    ffi.C.memmove(self.read_buf + self.read_total, buf, n)
    self.read_total = self.read_total + n
    self.read_unread = self.read_total - self.read_head

    while true do
        if self.awaiting_body ~= nil then
            if self.read_unread < self.awaiting_body then
                break
            end
            local body_text = ffi.string(self.read_buf + self.read_head, self.awaiting_body)
            self.read_head = self.read_head + self.awaiting_body
            self.read_unread = self.read_total - self.read_head
            self.awaiting_body = nil
            local parsed, derr = json.decode(body_text)
            if parsed then
                ---@cast parsed table
                self:_dispatch(parsed, body_text)
            end
        else
            local crlf_pos = -1
            local bp = self.read_buf + self.read_head
            local ur = self.read_unread
            for i = 0, ur - 4 do
                if bp[i] == 13 and bp[i + 1] == 10 and bp[i + 2] == 13 and bp[i + 3] == 10 then
                    crlf_pos = i
                    break
                end
            end

            if crlf_pos < 0 then
                break
            end

            self.read_head = self.read_head + crlf_pos + 4
            self.read_unread = self.read_total - self.read_head
            local hdr_text = ffi.string(self.read_buf + self.read_head - crlf_pos - 4, crlf_pos)

            local cl = 0
            for line in hdr_text:gmatch("[^\r\n]+") do
                local name, value = line:match("^([%w-_]+):%s*(.-)$")
                if name and name:lower() == "content-length" then
                    cl = tonumber(value) or 0
                end
            end

            if cl <= 0 then
                break
            end

            if self.read_unread < cl then
                self.awaiting_body = cl
                break
            end

            local body_text = ffi.string(self.read_buf + self.read_head, cl)
            self.read_head = self.read_head + cl
            self.read_unread = self.read_total - self.read_head
            local parsed, derr = json.decode(body_text)
            if parsed then
                ---@cast parsed table
                self:_dispatch(parsed, body_text)
            end
        end

        if
            self.read_unread > 0
            and self.read_unread < self.buffer_capacity / 4
            and self.read_head > 4096
        then
            self:_compact()
        end
    end

    if self.read_unread == 0 then
        self.read_head = 0
        self.read_total = 0
    end

    return self.running
end

--- Inbound message dispatch. Decode is done; here we route. The
--- initialize response → MSG_LSP_HANDSHAKE (initialized=1). All other
--- messages are decoded + logged + dropped — each gets its own packed
--- C struct + main-side consumer as its feature lands (extension point).
--- @param msg table parsed JSON-RPC message
function LSPClient:_dispatch(msg, body_text)
    -- A response (id set, method nil). id == 1 is the lane-owned
    -- initialize handshake; anything else is a main-owned request whose
    -- result we relay back generically so the lane stays shape-agnostic
    -- (TextEdit[] today, completions/hover tomorrow) — main re-emits
    -- on its event bus keyed by id.
    if msg.id ~= nil and msg.method == nil then
        if tonumber(msg.id) == 1 then
            -- initialize response → READY. Mark + relay before the
            -- `initialized` notification so the modeline flips on the
            -- next frame.
            self.status = STATUS.READY
            -- Pull completionProvider.triggerCharacters out of the
            -- serverCapabilities; relay via the handshake so main can
            -- drive the immediate-on-trigger-char completion fast-path.
            pcall(function()
                local caps = msg.result and msg.result.capabilities
                local cp = caps and caps.completionProvider
                local tc = cp and cp.triggerCharacters
                if type(tc) == "table" then
                    local s = {}
                    for _, c in ipairs(tc) do
                        if type(c) == "string" and #c >= 1 then
                            s[#s + 1] = c:sub(1, 1)
                        end
                    end
                    local joined = table.concat(s)
                    if joined ~= (self.trigger_chars or "") then
                        self.trigger_chars = joined
                        log.info("lsp_lane", "captured trigger chars", {
                            exe = self.exe_name,
                            chars = joined,
                        })
                    end
                end
            end)
            send_handshake(self)
            -- Send `initialized` notification as the handshake's second leg.
            pcall(function()
                self:notify("initialized", {})
            end)
        else
            if (tonumber(msg.id) or 0) > 1 and msg.method == nil then
                log.info("lsp_complete", "lane_inbound_response_from_server", {
                    client_id = self.client_id,
                    id = msg.id,
                    has_result = msg.result ~= nil,
                    has_error = msg.error ~= nil,
                })
            end
            relay_response(self, msg, body_text)
        end
        return
    end

    -- Notifications (msg.method set, no id): route generically. Every
    -- inbound notification flows through relay_notification →
    -- MSG_LSP_NOTIFICATION → apply_notification → main's event-bus emit
    -- `"lsp_notification:" .. method`. New notifications (window/
    -- showMessage, $/progress, ...) need no lane changes — only a
    -- main-side subscriber on the event bus.
    -- Server-initiated requests (method + id) carry a JSON-RPC response
    -- expectation. Relay them to main via MSG_LSP_SERVER_REQUEST so the
    -- editor can apply edits (workspace/applyEdit) and respond. Requests
    -- for methods main doesn't handle are acknowledged with a no-op
    -- success response rather than timing out the server.
    if msg.method and msg.id == nil then
        relay_notification(self, msg, body_text)
        return
    end
    if msg.method and msg.id ~= nil then
        relay_request(self, msg, body_text)
        return
    end
end

----------------------------------------------------------------------------------------------------
-- Spawn (fork/exec) on the lane. Resolves the first matching exe on PATH.
----------------------------------------------------------------------------------------------------

local function find_executable(cands)
    local path = os.getenv("PATH")
    if not path then
        return nil
    end
    for _, c in ipairs(cands) do
        for segment in path:gmatch("[^:]+") do
            local candidate = segment .. "/" .. c.bin
            if pffi.C.access(candidate, pffi.X_OK) == 0 then
                return candidate, c
            end
        end
    end
    return nil
end

--- @param cands table[] normalized candidates (each {bin,args,env})
--- @param workspace_dir string
--- @param client_id integer
--- @return LSPClient|nil
local function spawn(cands, workspace_dir, client_id)
    local found, cand = find_executable(cands)
    if not found or cand == nil then
        return nil
    end

    local stdin_pipe = ffi.new("int[2]")
    local stdout_pipe = ffi.new("int[2]")
    assert(pffi.C.pipe(stdin_pipe) == 0, "pipe(stdin) failed")
    assert(pffi.C.pipe(stdout_pipe) == 0, "pipe(stdout) failed")

    local pid = ffi.C.fork()
    assert(pid >= 0, "fork() failed")

    if pid == 0 then
        ffi.C.close(tonumber(stdin_pipe[1]))
        ffi.C.close(tonumber(stdout_pipe[0]))
        ffi.C.dup2(tonumber(stdin_pipe[0]), 0)
        ffi.C.dup2(tonumber(stdout_pipe[1]), 1)
        ffi.C.close(tonumber(stdin_pipe[0]))
        ffi.C.close(tonumber(stdout_pipe[1]))

        -- Env: the workspace hint + the candidate's declared env vars.
        -- putenv takes a `KEY=VAL` C string it keeps in environ; we
        -- malloc each (never freed — the child either execs or _exits).
        local ws = ("LSP_WORKSPACE=%s"):format(workspace_dir)
        local wbuf = ffi.cast("char *", ffi.C.malloc(#ws + 1))
        ffi.copy(wbuf, ws)
        wbuf[#ws] = 0
        ffi.C.putenv(wbuf)
        for k, v in pairs(cand.env) do
            local pair = k .. "=" .. v
            local pbuf = ffi.cast("char *", ffi.C.malloc(#pair + 1))
            ffi.copy(pbuf, pair)
            pbuf[#pair] = 0
            ffi.C.putenv(pbuf)
        end

        -- argv: { bin_name, args..., NULL }. The buffers are kept
        -- rooted in a Lua array so the GC can't reclaim them before
        -- execvp runs (raw C pointer arrays aren't traced).
        local nargs = #cand.args
        local argv = ffi.new("char *[?]", nargs + 2)
        local roots = {}
        local arg0 = ffi.new("char[?]", #cand.bin + 1)
        ffi.copy(arg0, cand.bin)
        argv[0] = arg0
        roots[1] = arg0
        for i, a in ipairs(cand.args) do
            local ab = ffi.new("char[?]", #a + 1)
            ffi.copy(ab, a)
            argv[i] = ab
            roots[i + 1] = ab
        end
        argv[nargs + 1] = nil
        ffi.C.execvp(found, argv)
        ffi.C._exit(127)
    end

    pffi.C.close(tonumber(stdin_pipe[0]))
    pffi.C.close(tonumber(stdout_pipe[1]))

    local child_stdout_fd = tonumber(stdout_pipe[0])
    local child_stdin_fd = tonumber(stdin_pipe[1])
    ---@cast child_stdout_fd integer
    ---@cast child_stdin_fd integer
    ---@cast pid integer

    -- Non-blocking stdout: F_GETFL=3, F_SETFL=4, O_NONBLOCK=4
    local flags = ffi.C.fcntl(child_stdout_fd, 3)
    ffi.C.fcntl(child_stdout_fd, 4, bit.bor(flags, 4))

    local client = new_client(child_stdout_fd, child_stdin_fd, pid, client_id, cand.bin)
    _clients_by_fd[client.stdout_fd] = client
    _clients_by_id[client_id] = client

    -- Register stdout on the lane's kq for EVFILT_READ.
    lsp_kq:add_fd(child_stdout_fd)

    -- Send initialize (id == 1). The response → _dispatch → handshake.
    client:request("initialize", {
        processId = pid,
        rootUri = "file://" .. workspace_dir,
        capabilities = {
            offsetEncoding = "utf-8",
            general = {
                positionEncodings = { "utf-8" },
            },
            textDocument = {
                synchronization = {
                    didSave = false,
                },
                completion = {
                    completionItem = {
                        snippetSupport = false,
                        documentationFormat = { "plaintext" },
                    },
                },
                hover = {
                    contentFormat = { "plaintext" },
                },
                definition = {},
                rename = {
                    prepareSupport = false,
                },
                codeAction = {},
                formatting = {},
                publishDiagnostics = {},
            },
            workspace = {
                applyEdit = true,
                workspaceEdit = {
                    documentChanges = true,
                },
            },
        },
    })

    -- Relay "running, not yet initialized" so the modeline can show the
    -- declared server immediately even before the response lands.
    send_handshake(client)

    return client
end

----------------------------------------------------------------------------------------------------
-- Kill
----------------------------------------------------------------------------------------------------

local function kill_client(client, signal)
    if client.pid == 0 or not client.running then
        return
    end
    local sig = signal == "KILL" and 9 or 15
    ffi.C.kill(client.pid, sig)

    local ws = ffi.new("int[1]")
    for _ = 1, 50 do
        local rv = ffi.C.waitpid(client.pid, ws, 0x1) -- WNOHANG
        if rv == client.pid then
            break
        end
        ffi.C.usleep(1000)
    end

    ffi.C.free(client.read_buf)
    client.read_buf = nil
    -- Mark KILLED before teardown (distinguishes from a DEAD crash in
    -- the relayed handshake).
    client.status = STATUS.KILLED
    client:_teardown_dead()
    send_handshake(client)
end

----------------------------------------------------------------------------------------------------
-- outboxes[LANE_IDX_LSP] handlers (main → lane)
----------------------------------------------------------------------------------------------------

local function handle_spawn(msg)
    if msg.ptr == nil then
        return
    end
    local req = ffi.cast("struct LspSpawnReq *", msg.ptr)
    local spec_len = tonumber(req.spec_len)
    local workspace_len = tonumber(req.workspace_len)
    local client_id = tonumber(req.client_id)
    ---@cast spec_len integer
    ---@cast workspace_len integer
    ---@cast client_id integer
    local base = ffi.cast("const char *", req) + ffi.sizeof("struct LspSpawnReq")
    local spec_json = ffi.string(base, spec_len)
    local workspace = ffi.string(base + spec_len, workspace_len)
    ffi.C.free(req)

    -- spec_json is a JSON array of candidates {bin, args?, env?}.
    local cands, derr = json.decode(spec_json)
    if type(cands) ~= "table" then
        log.warn("lsp_lane", "spawn spec decode failed", { error = derr })
        return
    end
    -- Normalize: args/env are optional in the wire form.
    for _, c in ipairs(cands) do
        c.args = (type(c.args) == "table") and c.args or {}
        c.env = (type(c.env) == "table") and c.env or {}
    end
    if #cands == 0 then
        return
    end

    -- Dedup by client_id: if a client already exists for this id and is
    -- running, just re-handshake (main may re-issue SPAWN for the same
    -- id after a mode switch). Main is responsible for not re-spawning
    -- the same binary under a fresh id.
    local existing = _clients_by_id[client_id]
    if existing and existing.running then
        send_handshake(existing)
        return
    end

    local client = spawn(cands, workspace, client_id)
    if client == nil then
        log.info("lsp_lane", "executable not found on PATH", { candidates = #cands })
        -- Relay MISSING so main moves its provisional entry → missing
        -- (and the modeline shows srv— instead of hanging in spawning).
        send_handshake({
            client_id = client_id,
            exe_name = cands[1].bin,
            status = constants.LSP_STATUS_MISSING,
        })
        return
    end
end

local function handle_send(msg)
    if msg.ptr == nil then
        return
    end
    local req = ffi.cast("struct LspSendReq *", msg.ptr)
    local method_len = tonumber(req.method_len)
    local params_len = tonumber(req.params_len)
    local id = tonumber(req.id)
    local client_id = tonumber(req.client_id)
    ---@cast method_len integer
    ---@cast params_len integer
    ---@cast id integer
    ---@cast client_id integer
    local base = ffi.cast("const char *", req) + ffi.sizeof("struct LspSendReq")
    local method = ffi.string(base, method_len)
    local params = nil
    if params_len > 0 then
        local params_json = ffi.string(base + method_len, params_len)
        local parsed, derr = json.decode(params_json)
        if parsed then
            params = parsed
        end
    end
    ffi.C.free(req)

    -- Route by client_id (main tells us which server this is for).
    local client = _clients_by_id[client_id]
    if client == nil or not client.running then
        log.warn(
            "lsp_lane",
            "SEND for unknown/dead client",
            { method = method, client_id = client_id }
        )
        return
    end
    if method == "__response" then
        -- Response to a server-initiated request (e.g. workspace/applyEdit).
        -- Construct {"jsonrpc": "2.0", id, result} without a method.
        client:send_frame({
            jsonrpc = "2.0",
            id = id,
            result = params,
        })
        return
    end
    if id ~= 0 then
        if method == "textDocument/completion" then
            log.info("lsp_complete", "lane_sending_request_to_server", {
                client_id = client_id,
                id = id,
                line = params and params.position and params.position.line,
                character = params and params.position and params.position.character,
            })
        end
        client:request(method, params)
    else
        client:notify(method, params)
    end
end

--- MSG_LSP_DOC_SYNC: document synchronization so the server's view of
--- the buffer matches main's. Main hands the full buffer text as a
--- malloc'd pointer (write_text_direct) — NO JSON encode happens on
--- main; we build the didOpen/didChange/didClose notification here
--- (heavy work stays off-main). We free text_ptr + the struct.
local function handle_doc_sync(msg)
    if msg.ptr == nil then
        return
    end
    local d = ffi.cast("struct LspDocSync *", msg.ptr)
    local client_id = tonumber(d.client_id)
    ---@cast client_id integer
    local version = tonumber(d.version)
    ---@cast version integer
    local kind = tonumber(d.kind)
    ---@cast kind integer
    local uri = ffi.string(d.uri)
    local language_id = ffi.string(d.language_id)
    local client = _clients_by_id[client_id]
    if client == nil or not client.running then
        log.warn("lsp_lane", "DOC_SYNC for unknown/dead client", { client_id = client_id })
        if d.text_ptr ~= nil then
            ffi.C.free(d.text_ptr)
        end
        ffi.C.free(d)
        return
    end
    if kind == constants.LSP_DOC_OPEN then
        local text = ""
        if d.text_ptr ~= nil then
            text = ffi.string(d.text_ptr, tonumber(d.text_len))
        end
        client:notify("textDocument/didOpen", {
            textDocument = {
                uri = uri,
                languageId = language_id,
                version = version,
                text = text,
            },
        })
    elseif kind == constants.LSP_DOC_CHANGE then
        local text = ""
        if d.text_ptr ~= nil then
            text = ffi.string(d.text_ptr, tonumber(d.text_len))
        end
        client:notify("textDocument/didChange", {
            textDocument = { uri = uri, version = version },
            contentChanges = { { text = text } },
        })
    elseif kind == constants.LSP_DOC_CLOSE then
        client:notify("textDocument/didClose", {
            textDocument = { uri = uri },
        })
    else
        log.warn("lsp_lane", "unknown DOC_SYNC kind", { kind = kind })
    end
    if d.text_ptr ~= nil then
        ffi.C.free(d.text_ptr)
    end
    ffi.C.free(d)
end

local function handle_kill(msg)
    if msg.ptr == nil then
        return
    end
    local req = ffi.cast("struct LspKillReq *", msg.ptr)
    local client_id = tonumber(req.client_id)
    ---@cast client_id integer
    ffi.C.free(req)
    local client = _clients_by_id[client_id]
    if client then
        kill_client(client, "TERM")
    end
end

----------------------------------------------------------------------------------------------------
-- Main loop: block on the lane kq; dispatch outbox messages + fd drains.
----------------------------------------------------------------------------------------------------

while ss:running() do
    ss:heartbeat_set(constants.LANE_IDX_LSP)
    local events, n = lsp_kq:wait(1000)
    for i = 0, n - 1 do
        local ev = events[i]
        local f = tonumber(ev.filter)
        if f == kq_ffi.EVFILT_USER then
            -- outboxes[LANE_IDX_LSP] wake: drain all queued messages.
            local msg = ss:pop(ss._ptr.outboxes[constants.LANE_IDX_LSP])
            while msg ~= nil do
                local _, err = xpcall(function()
                    if msg.type == constants.MSG_LSP_SPAWN then
                        handle_spawn(msg)
                    elseif msg.type == constants.MSG_LSP_SEND then
                        handle_send(msg)
                    elseif msg.type == constants.MSG_LSP_KILL then
                        handle_kill(msg)
                    elseif msg.type == constants.MSG_LSP_DOC_SYNC then
                        handle_doc_sync(msg)
                    elseif msg.type == constants.MSG_SHUTDOWN then
                        log.info("lsp_lane", "shutdown received")
                        -- Kill every live client on the way out.
                        for _, c in pairs(_clients_by_id) do
                            kill_client(c, "TERM")
                        end
                        return
                    else
                        log.warn("lsp_lane", "unknown message type", { type = msg.type })
                    end
                end, function(e)
                    log.error("lsp_lane", "unhandled error", {
                        type = msg.type,
                        error = tostring(e),
                    })
                end)
                if not _ and err then
                    -- xpcall error; payload may leak. Keep the lane alive.
                end
                msg = ss:pop(ss._ptr.outboxes[constants.LANE_IDX_LSP])
            end
        elseif f == kq_ffi.EVFILT_READ then
            local fd = tonumber(ev.ident)
            ---@cast fd integer
            local client = _clients_by_fd[fd]
            if client then
                local ok, err = pcall(function()
                    client:drain()
                end)
                if not ok then
                    log.error(
                        "lsp_lane",
                        "drain threw",
                        { fd = fd, exe = client.exe_name, error = tostring(err) }
                    )
                end
            end
        end
    end
end
