--- IO Lane — loads files via mmap on request from main lane,
--- sends the mmap pointer and file size through the ring buffer.
---
--- Runs in its own pthread + lua_State.
--- On MSG_FILE_LOAD: mmaps the file, pushes MSG_FILE_LOADED with
---   ptr = mmap'd data and arg = file_size.
--- Main lane constructs a Buffer from these.

local ffi = require("ffi")
local bit = require("bit")
local log = require("cursed.log")
local ss = require("cursed.shared").SharedState.from_global()
local constants = require("cursed.shared")
local Kqueue = require("cursed.kqueue").Kqueue

-- Wrap the IO lane's kqueue. Main pushes to outbox_io and ring_push
-- triggers EVFILT_USER here; we block until that fires, then drain.
local io_kq = Kqueue.wrap(ss._ptr.io_kq_fd)
io_kq:add_wake(assert(tonumber(ss._ptr.outbox_io.wake_ident)))

-- Mirror main lane's log config. Both lanes write to the same file.
-- io.open(path, "a") opens with O_APPEND on POSIX, so concurrent writes
-- from both lua_States don't tear (each write(2) atomically seeks to EOF).
log.configure({ level = "info", output = "/tmp/cursed.log" })
log.info("io_lane", "started")

----------------------------------------------------------------------------------------------------
-- File loading
----------------------------------------------------------------------------------------------------

local function load_file(filepath, insert)
    local bench = require("cursed.bench")
    local t0 = bench.now_us()
    log.info("io_lane", "load_file begin", { path = filepath })
    local f = io.open(filepath, "rb")
    if f == nil then
        log.error("io_lane", "io.open failed", { path = filepath })
        ss:push(ss._ptr.inbox_io, { type = constants.MSG_FILE_ERROR, arg = 1 })
        return false
    end
    local file_size = f:seek("end")
    f:close()

    if file_size == 0 then
        log.info("io_lane", "empty file", { path = filepath })
        ss:push(ss._ptr.inbox_io, {
            type = insert and constants.MSG_FILE_INSERTED or constants.MSG_FILE_LOADED,
            ptr = nil,
            arg = 0,
        })
        return true
    end

    local fd = ffi.C.open(filepath, constants.O_RDONLY)
    if fd < 0 then
        log.error("io_lane", "open() failed", { path = filepath, fd = fd })
        ss:push(ss._ptr.inbox_io, { type = constants.MSG_FILE_ERROR, arg = 2 })
        return false
    end

    local psize = tonumber(ffi.C.sysconf(constants._SC_PAGESIZE))
    local cap = bit.band(file_size + psize - 1, bit.bnot(psize - 1))
    local prot = bit.bor(constants.PROT_READ, constants.PROT_WRITE)
    local data = ffi.C.mmap(nil, cap, prot, constants.MAP_PRIVATE, fd, 0)

    ffi.C.close(fd)

    if data == constants.MAP_FAILED then
        log.error("io_lane", "mmap failed", { path = filepath, cap = cap })
        ss:push(ss._ptr.inbox_io, { type = constants.MSG_FILE_ERROR, arg = 3 })
        return false
    end

    -- Send the mmap pointer directly through the ring buffer
    ss:push(ss._ptr.inbox_io, {
        type = insert and constants.MSG_FILE_INSERTED or constants.MSG_FILE_LOADED,
        ptr = data,
        arg = file_size,
    })
    bench.span("io_lane", "load_file mmap+send", t0, { path = filepath, size = file_size })
    log.info("io_lane", "load_file done", { path = filepath, size = file_size })

    return true
end

----------------------------------------------------------------------------------------------------
-- File saving
----------------------------------------------------------------------------------------------------

local function save_file(req)
    local filepath = ffi.string(req.filepath)
    local data_len = tonumber(req.data_len)
    ---@cast data_len integer

    log.info("io_lane", "save_file begin", { path = filepath, size = data_len })

    local success = false

    -- Pass the mode as an int32 cdata: `open()` is cdef'd variadic,
    -- so a bare Lua number is passed as a double and mode_t reads the
    -- low 16 bits of its bit-pattern (== 0), yielding mode-0000 files.
    -- 0x1B6 == 0o666; umask (e.g. 022) applies → typically 0644.
    local mode = ffi.new("int", 0x1B6)
    local fd = ffi.C.open(
        filepath,
        bit.bor(constants.O_WRONLY, constants.O_CREAT, constants.O_TRUNC),
        mode
    )
    if fd >= 0 then
        local write_ptr = ffi.cast("uint8_t *", req.data)
        local written = 0
        while written < data_len do
            local n = ffi.C.write(fd, write_ptr + written, data_len - written)
            if n < 0 then
                break
            end
            ---@cast n integer
            written = written + n
        end
        ffi.C.close(fd)
        success = written == data_len
    end

    if success then
        log.info("io_lane", "save_file done", { path = filepath, size = data_len })
    else
        log.error("io_lane", "save_file failed", { path = filepath })
    end

    ss:push(ss._ptr.inbox_io, {
        type = success and constants.MSG_FILE_SAVED or constants.MSG_FILE_ERROR,
        ptr = req,
    })

    return true
end

----------------------------------------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------------------------------------

while ss:running() do
    -- Block until main lane pushes a message. ring_push on outbox_io
    -- triggers EVFILT_USER on this kq, which wakes this kevent().
    io_kq:wait(-1)

    local msg = ss:pop(ss._ptr.outbox_io)
    while msg ~= nil do
        local ok, err = xpcall(function()
            log.info("io_lane", "got message", { type = msg.type, ptr = tostring(msg.ptr) })
            if msg.type == constants.MSG_FILE_LOAD then
                local ok2, filepath = pcall(ffi.string, msg.ptr)
                if ok2 and filepath ~= nil and #filepath > 0 then
                    load_file(filepath)
                else
                    log.error("io_lane", "bad filepath from ptr", { ok = tostring(ok2) })
                    ss:push(ss._ptr.inbox_io, { type = constants.MSG_FILE_ERROR, arg = 1 })
                end
            elseif msg.type == constants.MSG_FILE_SAVE then
                if msg.ptr ~= nil then
                    save_file(ffi.cast("struct SaveRequest *", msg.ptr))
                else
                    log.error("io_lane", "MSG_FILE_SAVE with nil ptr")
                    ss:push(ss._ptr.inbox_io, { type = constants.MSG_FILE_ERROR, arg = 4 })
                end
            elseif msg.type == constants.MSG_INSERT_FILE then
                local ok2, filepath = pcall(ffi.string, msg.ptr)
                if ok2 and filepath ~= nil and #filepath > 0 then
                    load_file(filepath, true)
                else
                    log.error("io_lane", "bad insert filepath from ptr", { ok = tostring(ok2) })
                    ss:push(ss._ptr.inbox_io, { type = constants.MSG_FILE_ERROR, arg = 1 })
                end
            elseif msg.type == constants.MSG_SHUTDOWN then
                log.info("io_lane", "shutdown received")
                return
            end
        end, function(err)
            log.error("io_lane", "unhandled error", { error = tostring(err) })
        end)
        if not ok then
            ss:push(ss._ptr.inbox_io, { type = constants.MSG_FILE_ERROR, arg = 5 })
        end
        msg = ss:pop(ss._ptr.outbox_io)
    end
end
