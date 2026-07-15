--- Proc Lane — general subprocess control off the main thread.
---
--- Owns arbitrary child processes (fork/exec with stdin/stdout/stderr
--- pipes). Runs in its own pthread + lua_State (spawned from
--- main.c::proc_lane_thread). Two event sources on its kqueue
--- (proc_kq_fd):
---   1. EVFILT_USER (ident 1) — main pushed a message to outbox_proc
---      (SPAWN / STDIN / KILL / SHUTDOWN). Ring_push triggers it.
---   2. EVFILT_READ — a child's stdout OR stderr became readable. We
---      drain, frame as a ProcOutput chunk, and ship to inbox_proc.
---
--- Main relays outbound control through outbox_proc and receives
--- process output + lifecycle (exit/killed/signaled/failed/kill_sent)
--- via inbox_proc, re-emitting each as a `process_out:<procid>` event
--- on the editor event bus. STDIN flows the other way: callers emit
--- `process_in:<procid>` events, the proc_client facade forwards them
--- here as MSG_PROC_STDIN.
---
--- This module is loaded as a top-level chunk (twin of io_lane.lua /
--- highlight_lane.lua / lsp_lane.lua): its body is the lane's main
--- loop, not a library.

local ffi = require("ffi")
local bit = require("bit")
local log = require("cursed.log")
local ss = require("cursed.shared").SharedState.from_global()
local constants = require("cursed.shared")
local json = require("cursed.json_ffi")
local Kqueue = require("cursed.kqueue").Kqueue
local kq_ffi = require("cursed.kqueue_ffi")
local pffi = require("cursed.posix_ffi")

local proc_kq = Kqueue.wrap(ss._ptr.lane_kq_fds[constants.LANE_IDX_PROC])
proc_kq:add_wake(assert(tonumber(ss._ptr.outboxes[constants.LANE_IDX_PROC].wake_ident)))

-- Mirror main lane's log config. All lanes write to the same file.
log.configure({ level = "info", output = "/tmp/cursed.log" })
log.info("proc_lane", "started")

----------------------------------------------------------------------------------------------------
-- Process record (one per spawned child). Indexed by procid AND by
-- each read fd (stdout_fd + stderr_fd) for kq dispatch.
----------------------------------------------------------------------------------------------------

--- @class Proc
--- @field procid integer main-assigned; echoed in every report
--- @field pid integer child pid (0/invalid after reap)
--- @field stdin_fd integer write end of child's stdin pipe (-1 after EOF/close)
--- @field stdout_fd integer read end of child's stdout pipe (-1 after EOF)
--- @field stderr_fd integer read end of child's stderr pipe (-1 after EOF)
--- @field stdout_eof boolean stdout drained to EOF
--- @field stderr_eof boolean stderr drained to EOF
--- @field reported boolean a terminal EXIT (exited/signaled/failed) already pushed
--- @field buffer_bytes integer flush a stream's accumulator once it reaches this many bytes (0 = flush every read)
--- @field stdout_acc table accumulator for buffered stdout: {parts=string[], total=int}
--- @field stderr_acc table accumulator for buffered stderr: {parts=string[], total=int}
local Proc = {}
Proc.__index = Proc

local _procs_by_id = {} ---@type table<integer, Proc>
local _procs_by_fd = {} ---@type table<integer, Proc>

--- Default per-stream flush threshold. Each read() can return up to
--- 8KB; without buffering, a chatty program flooding stdout would push
--- one MSG_PROC_OUTPUT per read, hammering the main kq + event bus. The
--- accumulator coalesces reads until this many bytes accumulate (then
--- flushes), or until the stream EOFs (final flush). Overridable per
--- spawn via spec.buffer_bytes (0 = no buffering / flush every read).
local DEFAULT_BUFFER_BYTES = 8192

--- Stream tags carried in ProcOutput.stream.
local STREAM_STDOUT = 1
local STREAM_STDERR = 2

--- Lifecycle kinds carried in ProcExit.kind (mirror shared_state.h).
local KIND_EXITED = 0
local KIND_SIGNALED = 1
local KIND_FAILED = 2

--- waitpid status macros (BSD/macOS layout). Evaluated inline so we
--- don't need <sys/wait.h> macros through FFI.
local WNOHANG = 1
local function status_exited(s)
    return bit.band(s, 0x7f) == 0
end
local function status_exitcode(s)
    return bit.band(bit.rshift(s, 8), 0xff)
end
local function status_signaled(s)
    local low = bit.band(s, 0x7f)
    return low ~= 0 and low ~= 0x7f
end
local function status_termsig(s)
    return bit.band(s, 0x7f)
end

local function new_acc()
    return { parts = {}, total = 0 }
end

local function new_proc(procid, pid, stdin_fd, stdout_fd, stderr_fd, buffer_bytes)
    return setmetatable({
        procid = procid,
        pid = pid,
        stdin_fd = stdin_fd,
        stdout_fd = stdout_fd,
        stderr_fd = stderr_fd,
        stdout_eof = stdout_fd < 0,
        stderr_eof = stderr_fd < 0,
        reported = false,
        buffer_bytes = buffer_bytes or DEFAULT_BUFFER_BYTES,
        stdout_acc = new_acc(),
        stderr_acc = new_acc(),
    }, Proc)
end

----------------------------------------------------------------------------------------------------
-- Inbound reports (lane → main). Lane allocates; main frees after pop.
----------------------------------------------------------------------------------------------------

--- Ship a stdout/stderr chunk to main. ptr is malloc'd bytes; ownership
--- transfers to main (it frees after copying to a Lua string). len==0
--- is allowed (a zero-byte read slipped through) — main just ignores it.
---@param proc Proc
---@param stream integer STREAM_STDOUT | STREAM_STDERR
---@param ptr any uint8_t* (malloc'd) or nil
---@param len integer byte count
local function send_output(proc, stream, ptr, len)
    local out = ffi.cast("struct ProcOutput *", ffi.C.calloc(1, ffi.sizeof("struct ProcOutput")))
    out.procid = proc.procid
    out.stream = stream
    out.len = len
    out.ptr = ptr
    ss:push(ss._ptr.inboxes[constants.LANE_IDX_PROC], { type = constants.MSG_PROC_OUTPUT, ptr = out })
end

--- Ship a lifecycle report (terminal or advisory) to main. Main frees.
---@param proc Proc
---@param kind integer KIND_*
---@param code integer exit status | signal | errno
local function send_exit(proc, kind, code)
    local e = ffi.cast("struct ProcExit *", ffi.C.calloc(1, ffi.sizeof("struct ProcExit")))
    e.procid = proc.procid
    e.kind = kind
    e.code = code
    ss:push(ss._ptr.inboxes[constants.LANE_IDX_PROC], { type = constants.MSG_PROC_EXIT, ptr = e })
end

----------------------------------------------------------------------------------------------------
-- Teardown
----------------------------------------------------------------------------------------------------

--- Close a child read fd + drop its kq watch. Idempotent.
local function close_read_fd(fd)
    if fd == nil or fd < 0 then
        return
    end
    proc_kq:del_fd(fd)
    pcall(function()
        ffi.C.close(fd)
    end)
end

--- Close the child stdin write end. Idempotent.
local function close_write_fd(fd)
    if fd == nil or fd < 0 then
        return
    end
    pcall(function()
        ffi.C.close(fd)
    end)
end

--- Remove a Proc from the dispatch tables. Does NOT free (Lua GC owns
--- the table). Called once a terminal EXIT has been pushed (or on
--- spawn failure / shutdown).
---@param proc Proc
local function forget_proc(proc)
    _procs_by_id[proc.procid] = nil
    if proc.stdout_fd >= 0 then
        _procs_by_fd[proc.stdout_fd] = nil
    end
    if proc.stderr_fd >= 0 then
        _procs_by_fd[proc.stderr_fd] = nil
    end
end

--- Reap (non-blocking) + report a terminal EXIT for a proc whose
--- stdout+stderr have both EOF'd. If waitpid returns 0 (child still
--- alive — e.g. a daemon that closed its pipes), do NOT report: leave
--- the proc resident for a future MSG_PROC_KILL to reap. Sets
--- `reported` so a later KILL path doesn't double-report.
---@param proc Proc
local function reap_if_done(proc)
    if proc.reported then
        return
    end
    if not (proc.stdout_eof and proc.stderr_eof) then
        return
    end
    if proc.pid <= 0 then
        return
    end
    local ws = ffi.new("int[1]")
    local rv = ffi.C.waitpid(proc.pid, ws, WNOHANG)
    rv = tonumber(rv) or 0
    if rv == 0 then
        -- Child alive but pipes closed. Leave resident; KILL will reap.
        return
    end
    if rv < 0 then
        -- ECHILD (already reaped?) — treat as exited 0 so main retires the id.
        log.warn("proc", "waitpid failed", {
            pid = proc.pid,
            errno = kq_ffi.errno(),
        })
        proc.reported = true
        send_exit(proc, KIND_EXITED, 0)
        forget_proc(proc)
        return
    end
    local s = tonumber(ws[0]) or 0
    ---@cast s integer
    proc.reported = true
    if status_signaled(s) then
        send_exit(proc, KIND_SIGNALED, status_termsig(s))
    else
        send_exit(proc, KIND_EXITED, status_exitcode(s))
    end
    forget_proc(proc)
end

----------------------------------------------------------------------------------------------------
-- Drain: read up to 8KB from a child fd, ship as OUTPUT, and on EOF
-- close the fd + attempt the terminal reap.
---------------------------------------------------------------------------------------------------

--- Ship a stream's accumulated bytes to main. Concatenates the
--- accumulated parts, mallocs one buffer, copies, and pushes a single
--- MSG_PROC_OUTPUT. Resets the accumulator. No-op if nothing buffered.
--- ptr is malloc'd bytes; ownership transfers to main.
---@param proc Proc
---@param stream integer STREAM_STDOUT | STREAM_STDERR
local function flush_acc(proc, stream)
    local acc = (stream == STREAM_STDERR) and proc.stderr_acc or proc.stdout_acc
    if acc.total == 0 then
        return
    end
    local s = table.concat(acc.parts)
    local n = #s
    local copy = ffi.C.malloc(n)
    if copy ~= nil then
        ffi.C.memcpy(copy, s, n)
        send_output(proc, stream, ffi.cast("uint8_t *", copy), n)
    else
        log.warn("proc_lane", "malloc failed for flushed chunk", {
            procid = proc.procid,
            stream = stream,
            len = n,
        })
    end
    acc.parts = {}
    acc.total = 0
end

--- Drain: read up to 8KB from a child fd, accumulate into the stream's
--- buffer, flush when the buffer reaches the threshold, and on EOF do a
--- final flush + close the fd + attempt the terminal reap. With
--- buffer_bytes == 0 the accumulator flushes every read (unbuffered).
--- @param fd integer
--- @param stream integer STREAM_*
--- @return boolean alive (true while the proc may still produce more)
function Proc:_drain_fd(fd, stream)
    local buf = ffi.new("uint8_t[8192]")
    local n = tonumber(ffi.C.read(fd, buf, 8192)) or 0

    if n > 0 then
        local acc = (stream == STREAM_STDERR) and self.stderr_acc or self.stdout_acc
        acc.parts[#acc.parts + 1] = ffi.string(buf, n)
        ---@cast acc table
        acc.total = acc.total + n
        -- Threshold flush. buffer_bytes==0 → flush immediately (every
        -- read becomes its own MSG_PROC_OUTPUT, the unbuffered path).
        if self.buffer_bytes == 0 or acc.total >= self.buffer_bytes then
            flush_acc(self, stream)
        end
        return true
    end

    -- n <= 0: EOF or error. Either way this fd is done.
    flush_acc(self, stream) -- final flush of anything buffered
    if stream == STREAM_STDOUT then
        self.stdout_eof = true
    else
        self.stderr_eof = true
    end
    _procs_by_fd[fd] = nil
    close_read_fd(fd)
    if stream == STREAM_STDOUT then
        self.stdout_fd = -1
    else
        self.stderr_fd = -1
    end
    reap_if_done(self)
    return not self.reported
end

----------------------------------------------------------------------------------------------------
-- Spawn (fork/exec). spec is a decoded JSON table {argv, env?, cwd?}.
----------------------------------------------------------------------------------------------------

--- Build argv + env in the child. On execvp failure, _exit(127) so the
--- parent's waitpid sees a clean exit (the lane will report this via
--- the normal EOF+reap path as EXITED 127). Workaround: we also push a
--- FAILED report from the parent when fork itself fails.
---@param spec table {argv: string[], env?: table, cwd?: string}
---@return integer pid, integer stdout_fd, integer stderr_fd, integer stdin_fd
---@return string|nil errmsg
local function spawn_child(spec)
    local argv = spec.argv
    if type(argv) ~= "table" or #argv == 0 then
        return -1, -1, -1, -1, "spec.argv missing/empty"
    end

    local stdin_pipe = ffi.new("int[2]")
    local stdout_pipe = ffi.new("int[2]")
    local stderr_pipe = ffi.new("int[2]")
    if pffi.C.pipe(stdin_pipe) ~= 0 then
        return -1, -1, -1, -1, "pipe(stdin) failed"
    end
    if pffi.C.pipe(stdout_pipe) ~= 0 then
        close_write_fd(tonumber(stdin_pipe[1]))
        close_read_fd(tonumber(stdin_pipe[0]))
        return -1, -1, -1, -1, "pipe(stdout) failed"
    end
    if pffi.C.pipe(stderr_pipe) ~= 0 then
        close_write_fd(tonumber(stdin_pipe[1]))
        close_read_fd(tonumber(stdin_pipe[0]))
        close_read_fd(tonumber(stdout_pipe[0]))
        close_write_fd(tonumber(stdout_pipe[1]))
        return -1, -1, -1, -1, "pipe(stderr) failed"
    end

    local pid = ffi.C.fork()
    if pid < 0 then
        close_read_fd(tonumber(stdin_pipe[0]))
        close_write_fd(tonumber(stdin_pipe[1]))
        close_read_fd(tonumber(stdout_pipe[0]))
        close_write_fd(tonumber(stdout_pipe[1]))
        close_read_fd(tonumber(stderr_pipe[0]))
        close_write_fd(tonumber(stderr_pipe[1]))
        ---@cast pid integer
        return pid, -1, -1, -1, "fork() failed"
    end

    if pid == 0 then
        -- Child. Wire stdio: read[0] end of each pipe to the child's fds.
        ffi.C.close(tonumber(stdin_pipe[1]))
        ffi.C.close(tonumber(stdout_pipe[0]))
        ffi.C.close(tonumber(stderr_pipe[0]))
        ffi.C.dup2(tonumber(stdin_pipe[0]), 0)
        ffi.C.dup2(tonumber(stdout_pipe[1]), 1)
        ffi.C.dup2(tonumber(stderr_pipe[1]), 2)
        ffi.C.close(tonumber(stdin_pipe[0]))
        ffi.C.close(tonumber(stdout_pipe[1]))
        ffi.C.close(tonumber(stderr_pipe[1]))

        -- cwd (best-effort; ignore failure — exec still attempted).
        if type(spec.cwd) == "string" and #spec.cwd > 0 then
            pcall(function()
                ffi.C.chdir(spec.cwd)
            end)
        end

        -- env: putenv each KEY=VAL (malloc'd, never freed in child).
        if type(spec.env) == "table" then
            for k, v in pairs(spec.env) do
                if type(k) == "string" and type(v) == "string" then
                    local pair = k .. "=" .. v
                    local pbuf = ffi.cast("char *", ffi.C.malloc(#pair + 1))
                    ffi.copy(pbuf, pair)
                    pbuf[#pair] = 0
                    ffi.C.putenv(pbuf)
                end
            end
        end

        -- argv: { argv[0], args..., NULL }. Each arg buffer rooted in a
        -- Lua table so the GC can't reclaim it before execvp runs.
        local nargs = #argv
        local cargv = ffi.new("char *[?]", nargs + 1)
        local roots = {}
        for i = 1, nargs do
            local a = argv[i]
            if type(a) ~= "string" then
                a = tostring(a)
            end
            local ab = ffi.new("char[?]", #a + 1)
            ffi.copy(ab, a)
            cargv[i - 1] = ab
            roots[i] = ab
        end
        cargv[nargs] = nil
        ffi.C.execvp(cargv[0], cargv)
        -- exec failed. _exit(127) — parent sees this via waitpid later.
        ffi.C._exit(127)
    end

    ---@cast pid integer
    -- Parent: keep the write end of stdin + read ends of stdout/stderr.
    close_read_fd(tonumber(stdin_pipe[0]))
    close_write_fd(tonumber(stdout_pipe[1]))
    close_write_fd(tonumber(stderr_pipe[1]))

    local child_stdin_fd = tonumber(stdin_pipe[1])
    local child_stdout_fd = tonumber(stdout_pipe[0])
    local child_stderr_fd = tonumber(stderr_pipe[0])
    ---@cast child_stdin_fd integer
    ---@cast child_stdout_fd integer
    ---@cast child_stderr_fd integer

    -- Non-blocking reads so a slow child can't stall the lane in read().
    local function set_nonblock(fd)
        if fd < 0 then
            return
        end
        -- F_GETFL=3, F_SETFL=4, O_NONBLOCK=0x4
        local flags = ffi.C.fcntl(fd, 3)
        if flags >= 0 then
            ffi.C.fcntl(fd, 4, bit.bor(flags, 0x4))
        end
    end
    set_nonblock(child_stdout_fd)
    set_nonblock(child_stderr_fd)

    return pid, child_stdout_fd, child_stderr_fd, child_stdin_fd, nil
end

----------------------------------------------------------------------------------------------------
-- outbox_proc handlers (main → lane)
----------------------------------------------------------------------------------------------------

--- MSG_PROC_SPAWN: fork/exec a child, register its stdout+stderr on the
--- kq. On fork/pipe failure, push a FAILED exit so main retires the id.
--- execvp failure surfaces later as EXITED 127 when the pipes EOF.
local function handle_spawn(msg)
    if msg.ptr == nil then
        return
    end
    local req = ffi.cast("struct ProcSpawnReq *", msg.ptr)
    local procid = tonumber(req.procid)
    ---@cast procid integer
    local spec_len = tonumber(req.spec_len)
    ---@cast spec_len integer
    local base = ffi.cast("const char *", req) + ffi.sizeof("struct ProcSpawnReq")
    local spec_json = ffi.string(base, spec_len)
    ffi.C.free(req)

    local spec, derr = json.decode(spec_json)
    if type(spec) ~= "table" then
        log.warn("proc_lane", "spawn spec decode failed", { procid = procid, error = derr })
        -- Fabricate a FAILED report so main drops the id.
        local dummy = new_proc(procid, 0, -1, -1, -1)
        dummy.reported = true
        send_exit(dummy, KIND_FAILED, 0)
        return
    end

    local pid, out_fd, err_fd, in_fd, serr = spawn_child(spec)
    if pid < 0 then
        log.warn("proc_lane", "spawn failed", { procid = procid, error = serr })
        local dummy = new_proc(procid, 0, -1, -1, -1)
        dummy.reported = true
        send_exit(dummy, KIND_FAILED, 0)
        return
    end

    local proc = new_proc(procid, pid, in_fd, out_fd, err_fd, spec.buffer_bytes)
    _procs_by_id[procid] = proc
    _procs_by_fd[out_fd] = proc
    if err_fd ~= out_fd then
        _procs_by_fd[err_fd] = proc
    end
    proc_kq:add_fd(out_fd)
    if err_fd >= 0 and err_fd ~= out_fd then
        proc_kq:add_fd(err_fd)
    end
    log.info("proc_lane", "spawned", {
        procid = procid,
        pid = pid,
        argv0 = (spec.argv and spec.argv[1]) or "?",
    })
end

--- MSG_PROC_STDIN: write bytes to the child's stdin. len==0 → close
--- stdin (EOF). Ownership of ptr → lane.
local function handle_stdin(msg)
    if msg.ptr == nil then
        return
    end
    local req = ffi.cast("struct ProcStdinReq *", msg.ptr)
    local procid = tonumber(req.procid)
    local len = tonumber(req.len)
    local ptr = req.ptr
    ffi.C.free(req)
    ---@cast procid integer
    ---@cast len integer

    local proc = _procs_by_id[procid]
    if proc == nil then
        log.warn("proc_lane", "STDIN for unknown procid", { procid = procid })
        if ptr ~= nil then
            ffi.C.free(ptr)
        end
        return
    end
    if proc.stdin_fd < 0 then
        -- stdin already closed; drop the bytes.
        if ptr ~= nil then
            ffi.C.free(ptr)
        end
        return
    end

    if len == 0 then
        -- EOF: close the child's stdin.
        close_write_fd(proc.stdin_fd)
        proc.stdin_fd = -1
        return
    end

    -- Blocking write loop. A full pipe would stall the lane briefly;
    -- acceptable for v1 (callers feed modest chunks). Retries on EINTR.
    local write_ptr = ffi.cast("uint8_t *", ptr)
    local written = 0
    while written < len do
        local n = ffi.C.write(proc.stdin_fd, write_ptr + written, len - written)
        local nn = tonumber(n)
        if nn == nil or nn < 0 then
            -- EINTR (4) → retry; anything else → bail (pipe closed/EPIPE).
            local errn = kq_ffi.errno()
            if errn == 4 then
                -- retry the same write
            else
                log.warn("proc_lane", "stdin write failed", {
                    procid = procid,
                    errno = errn,
                    written = written,
                    len = len,
                })
                break
            end
        else
            written = written + nn
        end
    end
    ffi.C.free(ptr)
end

--- MSG_PROC_KILL: deliver a signal to the live child, then immediately
--- ack with KILL_SENT. The authoritative death notice arrives later
--- via the pipe-EOF + reap path (SIGNALED/EXITED). Fire-and-forget.
local function handle_kill(msg)
    if msg.ptr == nil then
        return
    end
    local req = ffi.cast("struct ProcKillReq *", msg.ptr)
    local procid = tonumber(req.procid)
    local signal = tonumber(req.signal)
    ffi.C.free(req)
    ---@cast procid integer
    ---@cast signal integer

    local proc = _procs_by_id[procid]
    if proc == nil then
        log.warn("proc_lane", "KILL for unknown procid", { procid = procid })
        return
    end
    if proc.pid <= 0 then
        return
    end
    ffi.C.kill(proc.pid, signal)
    -- Don't reap here; the pipe-EOF path will. If the proc ignores
    -- the signal, nothing else fires — that's the v1 contract (KILL
    -- is advisory; main retires the id only on a terminal EXIT).
end

----------------------------------------------------------------------------------------------------
-- Main loop: block on the lane kq; dispatch outbox messages + fd drains.
----------------------------------------------------------------------------------------------------

while ss:running() do
    ss:heartbeat_set(constants.LANE_IDX_PROC)
    local events, n = proc_kq:wait(1000)
    for i = 0, n - 1 do
        local ev = events[i]
        local f = tonumber(ev.filter)
        if f == kq_ffi.EVFILT_USER then
            -- outbox_proc wake: drain all queued messages.
            local msg = ss:pop(ss._ptr.outboxes[constants.LANE_IDX_PROC])
            while msg ~= nil do
                local _, err = xpcall(function()
                    if msg.type == constants.MSG_PROC_SPAWN then
                        handle_spawn(msg)
                    elseif msg.type == constants.MSG_PROC_STDIN then
                        handle_stdin(msg)
                    elseif msg.type == constants.MSG_PROC_KILL then
                        handle_kill(msg)
                    elseif msg.type == constants.MSG_SHUTDOWN then
                        log.info("proc_lane", "shutdown received")
                        -- SIGTERM every live proc on the way out. Lane
                        -- doesn't wait for reaping; the OS reaps orphans.
                        for _, proc in pairs(_procs_by_id) do
                            if proc.pid > 0 then
                                pcall(function()
                                    ffi.C.kill(proc.pid, 15)
                                end)
                            end
                            close_write_fd(proc.stdin_fd)
                            proc.stdin_fd = -1
                            if proc.stdout_fd >= 0 then
                                _procs_by_fd[proc.stdout_fd] = nil
                                close_read_fd(proc.stdout_fd)
                                proc.stdout_fd = -1
                            end
                            if proc.stderr_fd >= 0 then
                                _procs_by_fd[proc.stderr_fd] = nil
                                close_read_fd(proc.stderr_fd)
                                proc.stderr_fd = -1
                            end
                        end
                        return
                    else
                        log.warn("proc_lane", "unknown message type", { type = msg.type })
                    end
                end, function(e)
                    log.error("proc_lane", "unhandled error", {
                        type = msg.type,
                        error = tostring(e),
                    })
                end)
                if not _ and err then
                    -- xpcall error; payload may leak. Keep the lane alive.
                end
                msg = ss:pop(ss._ptr.outboxes[constants.LANE_IDX_PROC])
            end
        elseif f == kq_ffi.EVFILT_READ then
            local fd = tonumber(ev.ident)
            ---@cast fd integer
            local proc = _procs_by_fd[fd]
            if proc then
                local stream = (fd == proc.stderr_fd) and STREAM_STDERR or STREAM_STDOUT
                local ok, e = pcall(function()
                    proc:_drain_fd(fd, stream)
                end)
                if not ok then
                    log.error("proc_lane", "drain threw", {
                        fd = fd,
                        procid = proc.procid,
                        error = tostring(e),
                    })
                end
            end
        end
    end
end
