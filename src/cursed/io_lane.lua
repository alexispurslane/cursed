--- IO Lane — loads files via mmap on request from main lane,
--- sends the mmap pointer and file size through the ring buffer.
---
--- Runs in its own pthread + lua_State.
--- On MSG_FILE_LOAD: mmaps the file, pushes MSG_FILE_LOADED_V2 with
---   a FileLoadReply struct (req_id, file_size, mmap_ptr).
--- Main lane constructs a Buffer from the reply data.

local ffi = require("ffi")
local bit = require("bit")
local log = require("cursed.log")
local ss = require("cursed.shared").SharedState.from_global()
local constants = require("cursed.shared")
local Kqueue = require("cursed.kqueue").Kqueue

-- Wrap the IO lane's kqueue. Main pushes to outbox_io and ring_push
-- triggers EVFILT_USER here; we block until that fires, then drain.
local io_kq = Kqueue.wrap(ss._ptr.lane_kq_fds[constants.LANE_IDX_IO])
io_kq:add_wake(assert(tonumber(ss._ptr.outboxes[constants.LANE_IDX_IO].wake_ident)))

-- Mirror main lane's log config. Both lanes write to the same file.
-- io.open(path, "a") opens with O_APPEND on POSIX, so concurrent writes
-- from both lua_States don't tear (each write(2) atomically seeks to EOF).
log.configure({ level = "info", output = "/tmp/cursed.log" })
log.info("io_lane", "started")

----------------------------------------------------------------------------------------------------
-- File loading
----------------------------------------------------------------------------------------------------

--- mmap a file and push it back as MSG_FILE_LOADED_V2 (or MSG_FILE_INSERTED
--- when `insert` is true). The reply carries a FileLoadReply struct
--- with req_id + file_size + mmap_ptr, routed through the event bus
--- as file_op:<req_id>. All callers must mint a req_id via
--- editor:_next_file_op_id(). The mmap ownership transfers to main on push.
---@param filepath string absolute file path
---@param req_id integer|nil main-assigned request id, echoed in the reply's arg
---@param insert boolean|nil if true, push MSG_FILE_INSERTED (no View attach)
---@return boolean success (false if the syscall chain failed and an error was sent)
local function load_file(filepath, req_id, insert)
    req_id = req_id or 0
    local bench = require("cursed.bench")
    local t0 = bench.now_us()
    log.info("io_lane", "load_file begin", { path = filepath, req_id = req_id })
    local f = io.open(filepath, "rb")
    if f == nil then
        log.error("io_lane", "io.open failed", { path = filepath })
        ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], { type = constants.MSG_FILE_ERROR, arg = req_id })
        return false
    end
    local file_size = f:seek("end")
    f:close()

    if file_size == 0 then
        log.info("io_lane", "empty file", { path = filepath, req_id = req_id })
        if not insert then
            local reply = ffi.C.malloc(ffi.sizeof("struct FileLoadReply"))
            if reply ~= nil then
                local hdr = ffi.cast("struct FileLoadReply *", reply)
                hdr.req_id = req_id
                hdr.file_size = 0
                hdr.mmap_ptr = nil
            end
            ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], {
                type = constants.MSG_FILE_LOADED_V2,
                ptr = reply,
                arg = 0,
            })
        else
            ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], {
                type = constants.MSG_FILE_INSERTED,
                ptr = nil,
                arg = req_id,
            })
        end
        return true
    end

    local fd = ffi.C.open(filepath, constants.O_RDONLY)
    if fd < 0 then
        log.error("io_lane", "open() failed", { path = filepath, fd = fd })
        ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], { type = constants.MSG_FILE_ERROR, arg = req_id })
        return false
    end

    local psize = tonumber(ffi.C.sysconf(constants._SC_PAGESIZE))
    local cap = bit.band(file_size + psize - 1, bit.bnot(psize - 1))
    local prot = bit.bor(constants.PROT_READ, constants.PROT_WRITE)
    local data = ffi.C.mmap(nil, cap, prot, constants.MAP_PRIVATE, fd, 0)

    ffi.C.close(fd)

    if data == constants.MAP_FAILED then
        log.error("io_lane", "mmap failed", { path = filepath, cap = cap })
        ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], { type = constants.MSG_FILE_ERROR, arg = req_id })
        return false
    end

    -- Build a FileLoadReply struct on the heap so we can ship
    -- req_id + file_size + mmap_ptr in one reply. Main reads the
    -- struct, passes {mmap_ptr, file_size} to on_done, then frees it.
    -- This eliminates main's need to re-stat the file.
    local reply_type = insert and constants.MSG_FILE_INSERTED or constants.MSG_FILE_LOADED_V2
    if not insert then
        local reply = ffi.C.malloc(ffi.sizeof("struct FileLoadReply"))
        if reply == nil then
            ffi.C.munmap(data, cap)
            ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], { type = constants.MSG_FILE_ERROR, arg = req_id })
            return false
        end
        local hdr = ffi.cast("struct FileLoadReply *", reply)
        hdr.req_id = req_id
        hdr.file_size = file_size
        hdr.mmap_ptr = data
        ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], {
            type = reply_type,
            ptr = reply,
            arg = 0,
        })
    else
        -- MSG_FILE_INSERTED: keep old format (no FileLoadReply needed)
        ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], {
            type = reply_type,
            ptr = data,
            arg = req_id,
        })
    end
    bench.span(
        "io_lane",
        "load_file mmap+send",
        t0,
        { path = filepath, size = file_size, req_id = req_id }
    )
    log.info("io_lane", "load_file done", { path = filepath, size = file_size, req_id = req_id })

    return true
end

----------------------------------------------------------------------------------------------------
-- File ops (delete / create / mkdir / chmod / rename / dirlist)
--
-- Each op pushes MSG_FILE_ERROR on failure with the original arg =
-- req_id so main can correlate the failure back to the editor op.
-- On success, plain ops are silent; dirlist pushes a structured
-- MSG_FILE_DIRLIST_RESP reply carrying the entries.
-- The lane allocates the error string with malloc; main ffi.string()s
-- it then calls ffi.C.free(ptr).
----------------------------------------------------------------------------------------------------

--- Push a malloc'd error string back to main.
---@param req_id integer main-assigned request id (echoes to editor._pending_file_ops)
---@param op string pretty op name for logging only
---@param err string short error message
local function report_error(req_id, op, err)
    log.error("io_lane", op .. " failed", { err = err, req_id = req_id })
    -- malloc'd; main must ffi.C.free after ffi.string.
    local bytes = err .. "\0"
    local ptr = ffi.C.malloc(#bytes)
    ffi.copy(ffi.cast("char *", ptr), bytes, #bytes)
    ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], {
        type = constants.MSG_FILE_ERROR,
        arg = req_id,
        ptr = ptr,
    })
end

--- POSIX 0644 file creation. Calls open(O_WRONLY|O_CREAT|O_EXCL) so
--- failure on an existing file is informative (EEXIST) rather than
--- silent overwrite. MSG_FILE_CREATE matches the editor's "new file"
--- intent; if it exists the user wanted to write that's SAVE_AS.
local function create_file(filepath)
    local mode = ffi.new("int", 0x1A4) -- 0o644
    local fd =
        ffi.C.open(filepath, bit.bor(constants.O_WRONLY, constants.O_CREAT, constants.O_EXCL), mode)
    if fd < 0 then
        return false, ffi.string(ffi.C.strerror(ffi.C.errno))
    end
    ffi.C.close(fd)
    return true, nil
end

local function delete_file(filepath)
    if ffi.C.unlink(filepath) ~= 0 then
        return false, ffi.string(ffi.C.strerror(ffi.C.errno))
    end
    return true, nil
end

local function mkdir_one(dirpath)
    -- single-level mkdir(2); the editor encodes "make a dir or its
    -- parents" as a chain of one-level mkdir calls if it needs -p.
    if ffi.C.mkdir(dirpath, tonumber(0x1FF)) ~= 0 then -- 0o777
        return false, ffi.string(ffi.C.strerror(ffi.C.errno))
    end
    return true, nil
end

local function chmod_file(filepath, mode)
    if ffi.C.chmod(filepath, tonumber(mode)) ~= 0 then
        return false, ffi.string(ffi.C.strerror(ffi.C.errno))
    end
    return true, nil
end

--- Write a byte buffer (src_len bytes at src_ptr) to filepath (no
--- NUL on the path). Truncates if the file exists. Returns true on
--- success or (false, strerror_string) on failure.
---@param src_ptr userdata uint8_t* bytes to write (a malloc'd or in-struct ptr)
---@param src_len integer byte count
---@param filepath string absolute target path
local function write_file(src_ptr, src_len, filepath)
    local mode = ffi.new("int", 0x1A4) -- 0o644
    local fd = ffi.C.open(
        filepath,
        bit.bor(constants.O_WRONLY, constants.O_CREAT, constants.O_TRUNC),
        mode
    )
    if fd < 0 then
        return false, ffi.string(ffi.C.strerror(ffi.C.errno))
    end
    local written = 0
    if src_len > 0 then
        while written < src_len do
            local n = ffi.C.write(fd, src_ptr + written, src_len - written)
            if n < 0 then
                break
            end
            ---@cast n integer
            written = written + n
        end
    end
    ffi.C.close(fd)
    if written == src_len then
        return true, nil
    end
    return false, ffi.string(ffi.C.strerror(ffi.C.errno))
end

local function rename_paths(src, dst)
    if ffi.C.rename(src, dst) ~= 0 then
        return false, ffi.string(ffi.C.strerror(ffi.C.errno))
    end
    return true, nil
end

--- Walk a directory and pack entries into one malloc'd buffer.
--- Layout: struct FileDirListResp{count} + count × struct FileDirEntry
--- (each followed by its own name bytes, NOT NUL-terminated). The
--- whole buffer is one malloc so main can ffi.C.free it after walking
--- the entries once to copy them into Lua tables.
---@param dirpath string absolute path
---@return integer|nil count count of entries (0 on success-but-empty), or nil on failure
---@return string|nil err error string on failure
---@return userdata|nil buf malloc'd packed buffer on success (ownership → main)
local function dirlist_pack(dirpath)
    local DIR = ffi.C.opendir(dirpath)
    if DIR == nil then
        return nil, ffi.string(ffi.C.strerror(ffi.C.errno))
    end

    -- Two-pass: first count + compute total size, then allocate and
    -- pack. Avoids realloc as we add entries and keeps the lane on a
    -- single malloc. Cheap because we only stat-lite via DT_DIR /
    -- DT_REG (or a follow-up opendir for DT_LNK/DT_UNKNOWN).
    local COUNT_MAX = 16384 -- sanity cap on giant directories
    local entries = ffi.new("struct dirent *[?]", COUNT_MAX)
    local count = 0
    local total_name_bytes = 0
    while true do
        if count >= COUNT_MAX then
            break
        end
        local ent = ffi.C.readdir(DIR)
        if ent == nil then
            break
        end
        local name = ffi.string(ent.d_name)
        -- skip "." and ".."
        if name ~= "." and name ~= ".." then
            -- Open the entry with opendir to determine is_dir
            -- (catches symlinks and unknown DT_* values that DT_REG
            -- alone would misclassify).
            local full_path = dirpath .. "/" .. name
            local test_dir = ffi.C.opendir(full_path)
            local is_dir = test_dir ~= nil
            if test_dir ~= nil then
                ffi.C.closedir(test_dir)
            end
            entries[count] = ent -- keep ent alive only for the duration of this call; we extract name eagerly below
            count = count + 1
            total_name_bytes = total_name_bytes + #name
        end
    end
    ffi.C.closedir(DIR)

    -- Layout size: header(sizeof(FileDirListResp)) + N *
    -- (sizeof(FileDirEntry) + name_len bytes)
    local header_size = ffi.sizeof("struct FileDirListResp")
    local entry_size = ffi.sizeof("struct FileDirEntry")
    local total = header_size + count * entry_size + total_name_bytes

    local buf = ffi.C.malloc(total)
    if buf == nil then
        return nil, "malloc failed"
    end
    local buf_u8 = ffi.cast("uint8_t *", buf)
    local hdr_ptr = ffi.cast("struct FileDirListResp *", buf_u8)
    hdr_ptr.count = count

    local cursor = buf_u8 + header_size
    -- Re-walk: we need to extract names again (the dirent pointers
    -- in `entries` are now invalid because closedir invalidated them).
    DIR = ffi.C.opendir(dirpath)
    if DIR == nil then
        ffi.C.free(buf)
        return nil, "opendir on second pass failed"
    end
    local written = 0
    local ent = ffi.C.readdir(DIR)
    while ent ~= nil and written < count do
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." then
            local full_path = dirpath .. "/" .. name
            local test_dir = ffi.C.opendir(full_path)
            local is_dir = test_dir ~= nil
            if test_dir ~= nil then
                ffi.C.closedir(test_dir)
            end

            local entry_ptr = ffi.cast("struct FileDirEntry *", cursor)
            entry_ptr.is_dir = is_dir and 1 or 0
            local nlen = #name
            entry_ptr.name_len = nlen
            -- copy name bytes AFTER the struct
            local name_dst = ffi.cast("char *", cursor) + entry_size
            ffi.copy(name_dst, name, nlen)

            cursor = cursor + (entry_size + nlen)
            written = written + 1
        end
        ent = ffi.C.readdir(DIR)
    end
    ffi.C.closedir(DIR)

    return count, nil, buf -- caller convention: 3rd value is the allocated buffer
end

--- Send a packed dirlist back to main. 3-tuple convention from
--- dirlist_pack: (count, nil, buf).
local function send_dirlist_ok(req_id, count, buf)
    ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], {
        type = constants.MSG_FILE_DIRLIST_RESP,
        arg = req_id,
        ptr = buf, -- ownership → main; main walks plus ffi.C.free
    })
    log.info("io_lane", "dirlist done", { req_id = req_id, count = count })
end

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

    ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], {
        type = success and constants.MSG_FILE_SAVED or constants.MSG_FILE_ERROR,
        ptr = req,
    })

    return true
end

----------------------------------------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------------------------------------

while ss:running() do
    ss:heartbeat_set(constants.LANE_IDX_IO)
    -- Block until main lane pushes a message. ring_push on outbox_io
    -- triggers EVFILT_USER on this kq, which wakes this kevent().
    io_kq:wait(ss:has_overflow(ss._ptr.inboxes[constants.LANE_IDX_IO]) and 10 or 1000)

    local msg = ss:pop(ss._ptr.outboxes[constants.LANE_IDX_IO])
    while msg ~= nil do
        ss:heartbeat_set(constants.LANE_IDX_IO) -- alive while processing
        local ok, err = xpcall(function()
            log.info("io_lane", "got message", { type = msg.type, ptr = tostring(msg.ptr) })
            if msg.type == constants.MSG_FILE_LOAD then
                local ok2, filepath = pcall(ffi.string, msg.ptr)
                if ok2 and filepath ~= nil and #filepath > 0 then
                    load_file(filepath, tonumber(msg.arg))
                else
                    log.error("io_lane", "bad filepath from ptr", { ok = tostring(ok2) })
                    local req_id3 = tonumber(msg.arg) or 0
                    ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], { type = constants.MSG_FILE_ERROR, arg = req_id3 })
                end
            elseif msg.type == constants.MSG_FILE_SAVE then
                if msg.ptr ~= nil then
                    save_file(ffi.cast("struct SaveRequest *", msg.ptr))
                else
                    log.error("io_lane", "MSG_FILE_SAVE with nil ptr")
                    ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], { type = constants.MSG_FILE_ERROR, arg = 4 })
                end
            elseif msg.type == constants.MSG_INSERT_FILE then
                local ok2, filepath = pcall(ffi.string, msg.ptr)
                if ok2 and filepath ~= nil and #filepath > 0 then
                    load_file(filepath, tonumber(msg.arg), true)
                else
                    log.error("io_lane", "bad insert filepath from ptr", { ok = tostring(ok2) })
                    local req_id3 = tonumber(msg.arg) or 0
                    ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], { type = constants.MSG_FILE_ERROR, arg = req_id3 })
                end
            elseif msg.type == constants.MSG_FILE_DELETE then
                local req_id = tonumber(msg.arg)
                ---@cast req_id integer
                local ok2, filepath = pcall(ffi.string, msg.ptr)
                if ok2 and filepath ~= nil and #filepath > 0 then
                    local ok3, err = delete_file(filepath)
                    if not ok3 then
                        ---@cast err string
                        report_error(req_id, "delete", err)
                    end
                else
                    report_error(req_id, "delete", "bad filepath")
                end
            elseif msg.type == constants.MSG_FILE_CREATE then
                local req_id = tonumber(msg.arg)
                ---@cast req_id integer
                local ok2, filepath = pcall(ffi.string, msg.ptr)
                if ok2 and filepath ~= nil and #filepath > 0 then
                    local ok3, err = create_file(filepath)
                    if not ok3 then
                        ---@cast err string
                        report_error(req_id, "create", err)
                    end
                else
                    report_error(req_id, "create", "bad filepath")
                end
            elseif msg.type == constants.MSG_FILE_MKDIR then
                local req_id = tonumber(msg.arg)
                ---@cast req_id integer
                local ok2, dirpath = pcall(ffi.string, msg.ptr)
                if ok2 and dirpath ~= nil and #dirpath > 0 then
                    local ok3, err = mkdir_one(dirpath)
                    if not ok3 then
                        ---@cast err string
                        report_error(req_id, "mkdir", err)
                    end
                else
                    report_error(req_id, "mkdir", "bad filepath")
                end
            elseif msg.type == constants.MSG_FILE_CHMOD then
                -- mode is packed in the LOW 9 bits of arg; req_id is
                -- shifted up to slot the mode in. main encodes this.
                local mode = bit.band(tonumber(msg.arg), 0x1FF)
                local req_id_only = bit.rshift(tonumber(msg.arg), 9)
                ---@cast req_id_only integer
                local ok2, filepath = pcall(ffi.string, msg.ptr)
                if ok2 and filepath ~= nil and #filepath > 0 then
                    local ok3, err = chmod_file(filepath, mode)
                    if not ok3 then
                        ---@cast err string
                        report_error(req_id_only, "chmod", err)
                    end
                else
                    report_error(req_id_only, "chmod", "bad filepath")
                end
            elseif msg.type == constants.MSG_FILE_RENAME then
                local req_id = tonumber(msg.arg)
                ---@cast req_id integer
                if msg.ptr == nil then
                    report_error(req_id, "rename", "null ptr")
                else
                    local req = ffi.cast("struct FileMoveReq *", msg.ptr)
                    local struct_size = ffi.sizeof("struct FileMoveReq")
                    local src = ffi.string(ffi.cast("uint8_t *", req) + struct_size, req.src_len)
                    local dst = ffi.string(
                        ffi.cast("uint8_t *", req) + struct_size + req.src_len,
                        req.dst_len
                    )
                    local ok3, err = rename_paths(src, dst)
                    ffi.C.free(req) -- always: lane owns the malloc'd struct
                    if not ok3 then
                        ---@cast err string
                        report_error(req_id, "rename", err)
                    end
                end
            elseif msg.type == constants.MSG_FILE_DIRLIST then
                local req_id = tonumber(msg.arg)
                ---@cast req_id integer
                local ok2, dirpath = pcall(ffi.string, msg.ptr)
                if ok2 and dirpath ~= nil and #dirpath > 0 then
                    -- dirlist_pack returns (count, err, buf) on failure
                    -- or (count, nil, buf) on success.
                    local n, err, buf = dirlist_pack(dirpath)
                    if not n then
                        report_error(req_id, "dirlist", err or "pack failed")
                    else
                        send_dirlist_ok(req_id, n, buf)
                    end
                else
                    report_error(req_id, "dirlist", "bad filepath")
                end
            elseif msg.type == constants.MSG_FILE_WRITE then
                local req_id = tonumber(msg.arg)
                ---@cast req_id integer
                if msg.ptr == nil then
                    report_error(req_id, "write", "null ptr")
                else
                    local req = ffi.cast("struct FileWriteReq *", msg.ptr)
                    local struct_size = ffi.sizeof("struct FileWriteReq")
                    local src_len = req.src_len
                    ---@cast src_len integer
                    local filepath_len = req.filepath_len
                    ---@cast filepath_len integer
                    local src_ptr = ffi.cast("uint8_t *", req) + struct_size
                    local filepath =
                        ffi.string(ffi.cast("uint8_t *", req) + struct_size + src_len, filepath_len)
                    local ok3, err = write_file(src_ptr, src_len, filepath)
                    ffi.C.free(req) -- lane owns the malloc'd struct
                    if not ok3 then
                        ---@cast err string
                        report_error(req_id, "write", err)
                    end
                end
            elseif msg.type == constants.MSG_SHUTDOWN then
                log.info("io_lane", "shutdown received")
                return
            end
        end, function(err)
            log.error("io_lane", "unhandled error", { error = tostring(err) })
        end)
        if not ok then
            ss:push(ss._ptr.inboxes[constants.LANE_IDX_IO], { type = constants.MSG_FILE_ERROR, arg = 5 })
        end
        msg = ss:pop(ss._ptr.outboxes[constants.LANE_IDX_IO])
    end
    -- After draining outbox messages, flush any overflow to the inbox.
    ss:flush_overflow(ss._ptr.inboxes[constants.LANE_IDX_IO])
end
