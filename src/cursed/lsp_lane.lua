--- LSP Lane — owns all language-server subprocess management and all
--- JSON-RPC framing + JSON decode/encode, off the main thread.
---
--- Runs in its own pthread + lua_State (spawned from main.c::lsp_lane_thread).
--- Two event sources on its kqueue (lsp_kq_fd):
---   1. EVFILT_USER (ident 1) — main pushed a message to outbox_lsp
---      (SPAWN / SEND / KILL / SHUTDOWN). Ring_push triggers it.
---   2. EVFILT_READ — a child server's stdout became readable. We drain,
---      frame, and decode here; heavy JSON never touches the main loop.
---
--- Main relays outbound requests as messages to this lane and receives
--- inbound (decoded + packed into bespoke C structs per message type)
--- via inbox_lsp. v1 relays only the initialize handshake
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

local lsp_kq = Kqueue.wrap(ss._ptr.lsp_kq_fd)
lsp_kq:add_wake(assert(tonumber(ss._ptr.outbox_lsp.wake_ident)))

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
    ffi.copy(hs.exe_name, client.exe_name, math.min(#client.exe_name, 63))
    hs.client_id = client.client_id
    hs.status = client.status
    ss:push(ss._ptr.inbox_lsp, { type = constants.MSG_LSP_HANDSHAKE, ptr = hs })
end

--- Relay a MISSING status for a client_id whose binary wasn't on PATH.
--- No client object exists (spawn never succeeded), so build the
--- handshake directly. Lets main move its provisional entry → missing.
local function send_missing(client_id, exe_name)
    local hs = ffi.cast("struct LspHandshake *", ffi.C.calloc(1, ffi.sizeof("struct LspHandshake")))
    if exe_name ~= nil then
        ffi.copy(hs.exe_name, exe_name, math.min(#exe_name, 63))
    end
    hs.client_id = client_id
    hs.status = constants.LSP_STATUS_MISSING
    ss:push(ss._ptr.inbox_lsp, { type = constants.MSG_LSP_HANDSHAKE, ptr = hs })
end

----------------------------------------------------------------------------------------------------
-- Framing + send
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
                self:_dispatch(parsed)
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
                self:_dispatch(parsed)
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
function LSPClient:_dispatch(msg)
    -- initialize response (id-matched). The request was sent at spawn.
    if msg.id ~= nil and msg.method == nil then
        -- A response. For v1 the only request we own is initialize
        -- (id == 1); mark initialized + relay handshake.
        if tonumber(msg.id) == 1 then
            -- initialize response → READY. Mark + relay before the
            -- `initialized` notification so the modeline flips on the
            -- next frame.
            self.status = STATUS.READY
            send_handshake(self)
            -- Send `initialized` notification as the handshake's second leg.
            pcall(function()
                self:notify("initialized", {})
            end)
        end
        return
    end

    -- Notifications / server-initiated requests: v1 just logs.
    if msg.method then
        log.debug("lsp_lane", "inbound message dropped (no struct yet)", {
            exe = self.exe_name,
            method = msg.method,
            id = msg.id,
        })
    end
end

----------------------------------------------------------------------------------------------------
-- Spawn (fork/exec) on the lane. Resolves the first matching exe on PATH.
----------------------------------------------------------------------------------------------------

local function find_executable(names)
    local path = os.getenv("PATH")
    if not path then
        return nil
    end
    for _, name in ipairs(names) do
        for segment in path:gmatch("[^:]+") do
            local candidate = segment .. "/" .. name
            local f = io.open(candidate, "r")
            if f then
                f:close()
                return candidate, name
            end
        end
    end
    return nil
end

--- @param exe_names string[] first-wins list
--- @param workspace_dir string
--- @return LSPClient|nil
local function spawn(exe_names, workspace_dir, client_id)
    local found, short = find_executable(exe_names)
    if not found or short == nil then
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

        local envstr = ("LSP_WORKSPACE=%s"):format(workspace_dir)
        local envbuf = ffi.cast("char *", ffi.C.malloc(#envstr + 1))
        ffi.copy(envbuf, envstr)
        envbuf[#envstr] = 0
        ffi.C.putenv(envbuf)

        local cstr = ffi.new("char[?]", #found + 1)
        ffi.copy(cstr, found)
        local argv = ffi.new("char *[2]")
        argv[0] = cstr
        argv[1] = nil
        ffi.C.execvp(cstr, argv)
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

    local client = new_client(child_stdout_fd, child_stdin_fd, pid, client_id, short)
    _clients_by_fd[client.stdout_fd] = client
    _clients_by_id[client_id] = client

    -- Register stdout on the lane's kq for EVFILT_READ.
    lsp_kq:add_fd(child_stdout_fd)

    -- Send initialize (id == 1). The response → _dispatch → handshake.
    client:request("initialize", {
        processId = pid,
        rootUri = "file://" .. workspace_dir,
        capabilities = {},
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
-- outbox_lsp handlers (main → lane)
----------------------------------------------------------------------------------------------------

local function handle_spawn(msg)
    if msg.ptr == nil then
        return
    end
    local req = ffi.cast("struct LspSpawnReq *", msg.ptr)
    local exe_names_len = tonumber(req.exe_names_len)
    local workspace_len = tonumber(req.workspace_len)
    local client_id = tonumber(req.client_id)
    ---@cast exe_names_len integer
    ---@cast workspace_len integer
    ---@cast client_id integer
    local base = ffi.cast("const char *", req) + ffi.sizeof("struct LspSpawnReq")
    local exe_blob = ffi.string(base, exe_names_len)
    local workspace = ffi.string(base + exe_names_len, workspace_len)
    ffi.C.free(req)

    -- exe_blob is NUL-separated short names.
    local names = {}
    for name in exe_blob:gmatch("[^%z]+") do
        names[#names + 1] = name
    end
    if #names == 0 then
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

    local client = spawn(names, workspace, client_id)
    if client == nil then
        log.info("lsp_lane", "executable not found on PATH", { names = #names })
        -- Relay MISSING so main moves its provisional entry → missing
        -- (and the modeline shows srv— instead of hanging in spawning).
        send_missing(client_id, names[1])
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
    if id ~= 0 then
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
    local events, n = lsp_kq:wait(-1)
    for i = 0, n - 1 do
        local ev = events[i]
        local f = tonumber(ev.filter)
        if f == kq_ffi.EVFILT_USER then
            -- outbox_lsp wake: drain all queued messages.
            local msg = ss:pop(ss._ptr.outbox_lsp)
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
                msg = ss:pop(ss._ptr.outbox_lsp)
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
