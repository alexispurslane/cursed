--- LSP client: subprocess management and JSON-RPC over stdin/stdout.
---
--- Each client owns a spawned language server process with stdin/stdout
--- pipes. The main loop registers stdout on the central kqueue for
--- EVFILT_READ; when readable, main calls `client:drain()` to parse and
--- dispatch incoming messages.
---
--- JSON-RPC framing: LSP uses Content-Length header lines over stdio:
---   Content-Length: 64\r\n\r\n{"jsonrpc":"2.0","id":1,...}

local ffi = require("ffi")
local bit = require("bit")
local pffi = require("cursed.posix_ffi")

--- Module exports table.
--- @class LSPModule
local M = {}

--- LSP clients keyed by executable path. One per mode.
--- Used for dedup when multiple views enter the same mode.
--- @type table<string, LSPClient>
M.active_clients = {}

--- Module-level LSP handler that receives messages from all clients.
--- Stores the last message so the editor can inspect it.
M.current_message = nil

--- Register LSP handlers on a mode's LSP client.
--- Called after spawn_or_get to set up dispatch.
--- @param client LSPClient
--- @param view any the view that owns this client
local function register_client_handlers(client, view)
    client.on_message = function(msg)
        -- Store for editor inspector
        M.current_message = msg
        -- Dispatch to the view's lsp_handlers if available
        if view._lsp_handlers and view._lsp_handlers then
            local kind = msg.method and (msg.id and "request" or "notification")
                or (msg.id and "response" or "unknown")
            local handler = view._lsp_handlers[kind]
            if handler then
                pcall(handler, view, msg)
            end
        end
    end
    client.on_exit = function(code)
        -- Clean up from active_clients
        for exe, c in pairs(M.active_clients) do
            if c == client then
                M.active_clients[exe] = nil
                break
            end
        end
    end
end

--- Registered LSP clients keyed by executable path.
--- Used for dedup when multiple views enter the same mode.
--- @type table<string, LSPClient>
M.active_clients = {}

--- LSPClient prototype for instance methods.
--- @class LSPClient
--- @field stdout_fd integer
--- @field stdin_fd integer
--- @field pid integer
--- @field running boolean
--- @field exe_name string|nil short name of the spawned binary (set by spawn_or_get; basename of the resolved path)
--- @field on_message function|nil
--- @field on_exit function|nil
--- @field kqueue table|nil the editor's main kqueue (set by spawn; used to delete the read watch on EOF)
--- @field pending table
--- @field next_id number
--- @field read_buf integer malloc'd buffer pointer
--- @field read_total number total bytes written
--- @field read_head number oldest unconsumed byte offset
--- @field read_unread number read_total - read_head  -- cached
--- @field awaiting_body number|nil body bytes still needed
--- @field buffer_capacity number
local LSPClient = {}

local _clients_by_fd = {}

--- Find executable on PATH.
--- @param names string[]
--- @return string|nil
function M.find_executable(names)
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
                return candidate
            end
        end
    end
    return nil
end

--- @param v any
--- @return string
function M.json_encode(v)
    if v == nil then
        return "null"
    elseif type(v) == "boolean" then
        return v and "true" or "false"
    elseif type(v) == "number" then
        return tostring(v)
    elseif type(v) == "string" then
        return '"'
            .. v:gsub("\\", "\\")
                :gsub('"', "\\")
                :gsub("\n", "\\n")
                :gsub("\r", "\\r")
                :gsub("\t", "\\t")
            .. '"'
    elseif type(v) == "table" then
        local is_array = true
        for k in pairs(v) do
            if type(k) ~= "number" or k < 1 or k ~= math.floor(k) or k > #v then
                is_array = false
                break
            end
        end
        if is_array and #v > 0 then
            local parts = {}
            for i = 1, #v do
                parts[i] = M.json_encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = M.json_encode(tostring(k)) .. ":" .. M.json_encode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

--- Minimal JSON decode.
--- @param s string
--- @return any
function M.json_decode(s)
    local pos = { 1 }
    --- Declare all functions for mutual recursion, then assign
    local skip_ws, parse_value, parse_literal, parse_string, parse_object, parse_array, parse_number

    skip_ws = function()
        while pos[1] <= #s do
            local c = s:sub(pos[1], pos[1])
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos[1] = pos[1] + 1
            else
                break
            end
        end
    end

    parse_number = function()
        local start = pos[1]
        while pos[1] <= #s and s:sub(pos[1], pos[1]):match("[-+0-9.eE]") do
            pos[1] = pos[1] + 1
        end
        local num = tonumber(s:sub(start, pos[1] - 1))
        if not num then
            error("Invalid number")
        end
        return num
    end

    parse_literal = function()
        local start = pos[1]
        local t4 = s:sub(start, start + 3)
        if t4 == "true" then
            pos[1] = pos[1] + 4
            return true
        end
        if t4 == "null" then
            pos[1] = pos[1] + 4
            return nil
        end
        local t5 = s:sub(start, start + 4)
        if t5 == "false" then
            pos[1] = pos[1] + 5
            return false
        end
        return nil
    end

    parse_string = function()
        pos[1] = pos[1] + 1
        local out = {}
        while pos[1] <= #s do
            local ch = s:sub(pos[1], pos[1])
            if ch == "\\" then
                pos[1] = pos[1] + 1
                local esc = s:sub(pos[1], pos[1])
                if esc == '"' then
                    out[#out + 1] = '"'
                elseif esc == "\\" then
                    out[#out + 1] = "\\"
                elseif esc == "n" then
                    out[#out + 1] = "\n"
                elseif esc == "r" then
                    out[#out + 1] = "\r"
                elseif esc == "t" then
                    out[#out + 1] = "\t"
                elseif esc == "u" then
                    out[#out + 1] = "\\u" .. s:sub(pos[1] + 1, pos[1] + 4)
                    pos[1] = pos[1] + 4
                else
                    out[#out + 1] = esc
                end
                pos[1] = pos[1] + 1
            elseif ch == '"' then
                pos[1] = pos[1] + 1
                return table.concat(out)
            else
                out[#out + 1] = ch
                pos[1] = pos[1] + 1
            end
        end
        error("Unterminated string")
    end

    parse_object = function()
        pos[1] = pos[1] + 1
        local t = {}
        while true do
            skip_ws()
            if s:sub(pos[1], pos[1]) == "}" then
                pos[1] = pos[1] + 1
                return t
            end
            if not s:sub(pos[1], pos[1]):match('"') then
                error("Expected string key")
            end
            local key = parse_string()
            skip_ws()
            if s:sub(pos[1], pos[1]) == ":" then
                pos[1] = pos[1] + 1
            end
            t[key] = parse_value()
            skip_ws()
            if s:sub(pos[1], pos[1]) == "," then
                pos[1] = pos[1] + 1
            else
                pos[1] = pos[1] + 1
                break
            end
        end
        return t
    end

    parse_array = function()
        pos[1] = pos[1] + 1
        local t = {}
        local i = 1
        while true do
            skip_ws()
            if s:sub(pos[1], pos[1]) == "]" then
                pos[1] = pos[1] + 1
                return t
            end
            t[i] = parse_value()
            i = i + 1
            skip_ws()
            if s:sub(pos[1], pos[1]) == "," then
                pos[1] = pos[1] + 1
            else
                pos[1] = pos[1] + 1
                break
            end
        end
        return t
    end

    parse_value = function()
        skip_ws()
        if pos[1] > #s then
            return nil
        end
        local ch = s:sub(pos[1], pos[1])
        if ch == '"' then
            return parse_string()
        end
        if ch == "{" then
            return parse_object()
        end
        if ch == "[" then
            return parse_array()
        end
        if
            s:sub(pos[1], pos[1] + 3) == "true"
            or s:sub(pos[1], pos[1] + 4) == "false"
            or s:sub(pos[1], pos[1] + 3) == "null"
        then
            return parse_literal()
        end
        return parse_number()
    end

    skip_ws()
    if pos[1] > #s then
        return nil
    end
    return parse_value()
end

-- Reassign new_client to local var so we can expose create_raw.
local new_client

--- @param stdout_fd integer
--- @param stdin_fd integer
--- @param pid integer
--- @return LSPClient
new_client = function(stdout_fd, stdin_fd, pid)
    return setmetatable({
        stdout_fd = stdout_fd,
        stdin_fd = stdin_fd,
        pid = pid,
        running = true,
        exe_name = nil,
        on_message = nil,
        on_exit = nil,
        pending = {},
        next_id = 1,
        read_buf = ffi.cast("uint8_t *", ffi.C.malloc(65536)),
        read_total = 0,
        read_head = 0,
        read_unread = 0,
        awaiting_body = nil,
        buffer_capacity = 65536,
    }, { __index = LSPClient })
end

--- @param msg table
function LSPClient:send_frame(msg)
    local body = M.json_encode(msg)
    local header = ("Content-Length: %d\r\n\r\n"):format(#body)
    ffi.C.write(self.stdin_fd, header, #header)
    ffi.C.write(self.stdin_fd, body, #body)
end

--- @param method string
--- @param params table
--- @return number
function LSPClient:request(method, params)
    local id = self.next_id
    self.next_id = id + 1
    self.pending[id] = {}
    self:send_frame({
        jsonrpc = "2.0",
        id = id,
        method = method,
        params = params,
    })
    return id
end

--- @param method string
--- @param params table
function LSPClient:notify(method, params)
    self:send_frame({
        jsonrpc = "2.0",
        method = method,
        params = params,
    })
end

--- @param id number
--- @param result any
function LSPClient:response(id, result)
    self:send_frame({
        jsonrpc = "2.0",
        id = id,
        result = result,
    })
end

--- Tear down a dead client's fd bookkeeping. Called from `drain` on EOF
--- (n <= 0) so the kqueue read watch for a closed/EOF'd stdoutPIPE does
--- not keep select() busy-spinning. Idempotent.
function LSPClient:_teardown_dead()
    if self._dead then
        return
    end
    self._dead = true
    self.running = false
    local fd = self.stdout_fd
    _clients_by_fd[fd] = nil
    -- Drop from active_clients so server_status_for reflects "off" and a
    -- later spawn_or_get re-spawns instead of returning this corpse.
    for exe, c in pairs(M.active_clients) do
        if c == self then
            M.active_clients[exe] = nil
        end
    end
    if self.kqueue then
        self.kqueue:del_fd(fd)
    end
    pcall(function()
        ffi.C.close(fd)
    end)
end

--- @return boolean alive
function LSPClient:drain()
    local buf = ffi.new("uint8_t[8192]")
    -- Max 8192 bytes/block (`read(2)` returns chunk size, syscall
    -- size limit). 0+chucks would be lazy/buffered: process is fine.
    local fd = self.stdout_fd
    local n = tonumber(ffi.C.read(fd, buf, 8192)) or 0

    if n <= 0 then
        -- EOF or read error on the child's stdout. The kqueue
        -- EVFILT_READ filter reports a pipe EOF as a PERSISTENT ready
        -- condition — EV_CLEAR does not auto-clear it — so unless we
        -- explicitly delete the watch here, select() would wake every
        -- loop iteration (busy-spin, thousands of renders/sec). Tear
        -- the fd down fully: delete the kevent, drop it from the
        -- fd→client map and active_clients, close the fd.
        self:_teardown_dead()
        if self.on_exit ~= nil and not self._exit_fired then
            self._exit_fired = true
            self.on_exit(0)
        end
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
            local ok, parsed = pcall(M.json_decode, body_text)
            if ok and parsed then
                self:_dispatch(parsed)
            end
        else
            -- Find \r\n\r\n
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
            local ok, parsed = pcall(M.json_decode, body_text)
            if ok and parsed then
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

--- Compact unread bytes to front of buffer.
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

--- @param msg table
function LSPClient:_dispatch(msg)
    if msg.id ~= nil then
        local pending = self.pending[msg.id]
        if pending then
            self.pending[msg.id] = nil
            if msg.error ~= nil then
                if pending.reject then
                    pcall(pending.reject, msg.error)
                end
            elseif pending.resolve then
                pcall(pending.resolve, msg.result)
            end
        end
    end
    if self.on_message ~= nil then
        pcall(self.on_message, msg)
    end
end

--- @param signal string "TERM" or "KILL"
function LSPClient:kill(signal)
    if self.pid == 0 or not self.running then
        return
    end
    local sig = signal == "KILL" and 9 or 15
    ffi.C.kill(self.pid, sig)

    local ws = ffi.new("int[1]")
    for _ = 1, 50 do
        local rv = ffi.C.waitpid(self.pid, ws, 0x1) -- WNOHANG
        if rv == self.pid then
            break
        end
        ffi.C.usleep(1000)
    end

    ffi.C.free(self.read_buf)
    self.read_buf = nil
    -- Close the stdout fd + drop the kqueue watch + remove from the
    -- fd→client map (shares the EOF-teardown path so a killed client
    -- doesn't leave a perpetually-ready kevent busy-spinning select()).
    self:_teardown_dead()
    if self.on_exit ~= nil and not self._exit_fired then
        self._exit_fired = true
        self.on_exit(sig == 9 and -1 or 0)
    end
end

--- Spawn a language server subprocess.
---
--- Registers stdout on the provided kqueue for EVFILT_READ.
--- Automatically sends the `initialize` request and `initialized` notification.
--- @param main_kqueue table the editor's main kqueue instance
--- @param executable string absolute path to LSP binary
--- @param workspace_dir string workspace root directory
--- @param on_message function|nil notification callback: fn(msg)
--- @param on_exit function|nil exit callback: fn(exit_code)
--- @return LSPClient
function M.spawn(main_kqueue, executable, workspace_dir, on_message, on_exit)
    ---@type integer[2]
    local stdin_pipe = ffi.new("int[2]")
    assert(pffi.C.pipe(stdin_pipe) == 0, "pipe(stdin) failed")

    ---@type integer[2]
    local stdout_pipe = ffi.new("int[2]")
    assert(pffi.C.pipe(stdout_pipe) == 0, "pipe(stdout) failed")

    local pid = ffi.C.fork()
    assert(pid >= 0, "fork() failed")

    if pid == 0 then
        -- Child process
        ffi.C.close(tonumber(stdin_pipe[1]))
        ffi.C.close(tonumber(stdout_pipe[0]))
        ffi.C.dup2(tonumber(stdin_pipe[0]), 0)
        ffi.C.dup2(tonumber(stdout_pipe[1]), 1)
        ffi.C.close(tonumber(stdin_pipe[0]))
        ffi.C.close(tonumber(stdout_pipe[1]))

        -- putenv(3) takes a mutable `char *` and keeps the pointer (no
        -- copy); a Lua string is immutable const char[] and FFI rejects
        -- it ("cannot convert 'string' to 'char *'"). Build a writable
        -- C buffer. It only needs to live until execvp() (which replaces
        -- the image) — but execvp can fail, so stack-scope is incorrect;
        -- heap-allocate and leak on the exec-fail _exit(127) path.
        local envstr = ("LSP_WORKSPACE=%s"):format(workspace_dir)
        local envbuf = ffi.cast("char *", ffi.C.malloc(#envstr + 1))
        ffi.copy(envbuf, envstr)
        envbuf[#envstr] = 0
        ffi.C.putenv(envbuf)

        local cstr = ffi.new("char[?]", #executable + 1)
        ffi.copy(cstr, executable)
        local argv = ffi.new("char *[2]")
        argv[0] = cstr
        argv[1] = nil
        ffi.C.execvp(cstr, argv)
        ffi.C._exit(127)
    end

    -- Parent process
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

    local client = new_client(child_stdout_fd, child_stdin_fd, pid)
    client.on_message = on_message
    client.on_exit = on_exit
    ---@diagnostic disable-next-line: inject-field
    client.kqueue = main_kqueue

    -- Register stdout on main kqueue
    main_kqueue:add_fd(child_stdout_fd)

    _clients_by_fd[client.stdout_fd] = client

    -- Send initialize
    client:request("initialize", {
        processId = pid,
        rootUri = "file://" .. workspace_dir,
        capabilities = {},
    })

    return client
end

--- Clean up all LSP clients.
function M.shutdown()
    -- Notify all active clients
    for exe, client in pairs(M.active_clients) do
        client:kill("TERM")
        M.active_clients[exe] = nil
    end
    for _, client in pairs(_clients_by_fd) do
        client:kill("TERM")
    end
    _clients_by_fd = {}
end

--- Get or spawn an LSP client for a mode.
--- First-wins: tries each executable name and returns the first match.
--- If a client for one of these executables is already running, returns it.
--- Registers stdout on the provided kqueue.
--- @param main_kqueue table Kqueue instance (has add_fd)
--- @param exe_names string[] first-wins list of executable names
--- @param workspace_dir string workspace root directory
--- @param on_message function|nil optional callback for incoming messages
--- @param on_exit function|nil optional callback for process exit
--- @return LSPClient|nil
function M.spawn_or_get(main_kqueue, exe_names, workspace_dir, on_message, on_exit)
    -- Check for already-running client
    for _, exe in ipairs(exe_names) do
        local c = M.active_clients[exe]
        if c and c.running then
            return c
        end
    end

    -- Find first matching executable on PATH
    local found = M.find_executable(exe_names)
    if not found then
        return nil
    end

    -- Spawn new client
    local client = M.spawn(main_kqueue, found, workspace_dir, on_message, on_exit)
    client.exe_name = found:match("([^/]+)$")
    M.active_clients[found] = client
    return client
end

--- Status of the first server (running or not) among the given
--- (short) executable names. Used by the editor's modeline and any
--- status lookup that wants to answer "is the LSP for this mode up?".
--- Spawns nothing; reflects current state of `active_clients`.
--- @param exe_names string[] first-wins list of executable names
--- @return string|nil name short name of the matching server
--- @return boolean running whether that server's client is alive
function M.server_status_for(exe_names)
    for _, name in ipairs(exe_names) do
        for _, client in pairs(M.active_clients) do
            if client.exe_name == name then
                return name, client.running
            end
        end
    end
    -- Declared in the mode spec but not spawned (typically: binary
    -- not found on PATH). Surface the first declared name so the
    -- modeline can show "declared, off" rather than silently empty.
    if exe_names[1] then
        return exe_names[1], false
    end
    return nil, false
end

--- Main loop dispatcher. Called on kqueue EVFILT_READ.
--- @param fd integer
--- @return boolean alive
function M.on_kqueue_read(fd)
    local client = _clients_by_fd[fd]
    if not client then
        return true
    end
    return client:drain()
end

--- Lightweight client factory for standalone / non-editor use.
--- Does NOT register stdout on any kqueue. Callers must use poll()/select()
--- to discover readability and then call `client:drain()`.
---
--- Also does NOT send `initialize` — callers decide what to do.
--- @param child_stdout_fd integer parent's read-end fd for child stdout
--- @param child_stdin_fd integer parent's write-end fd for child stdin
--- @param pid integer child process ID
--- @param on_message function|nil
--- @param on_exit function|nil
--- @return LSPClient
function M.create_raw(child_stdout_fd, child_stdin_fd, pid, on_message, on_exit)
    ---@cast child_stdout_fd integer
    ---@cast child_stdin_fd integer
    ---@cast pid integer
    local client = new_client(child_stdout_fd, child_stdin_fd, pid)
    client.on_message = on_message
    client.on_exit = on_exit
    return client
end

return M
