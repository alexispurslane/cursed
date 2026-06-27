--- Buffer: the core text data model.
---
--- Owns a per-line piece table with an mmap'd orig buffer, an append-only
--- add buffer, and an mmap'd undo/redo log. Provides all text mutation,
--- extraction, undo/redo, and search operations.
---
--- Memory is managed by the Lua GC via wrap_gc (finalizer calls buffer_free).

local ffi = require("ffi")
local bit = require("bit")
local bffi = require("cursed.buffer_ffi")
local c = bffi.C
local pffi = require("cursed.posix_ffi")
local gc = require("cursed.gc")

----------------------------------------------------------------------------------------------------
-- Buffer class
----------------------------------------------------------------------------------------------------

---@class Buffer
---@field _ptr any struct Buffer *
---@field _munmapped boolean true after explicit munmap; prevents GC double-free
local Buffer = {}
Buffer.__index = Buffer

----------------------------------------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------------------------------------

--- Free all C resources owned by a Buffer (lines, pieces, add, undo/redo, orig, filepath).
--- Must be called before the struct itself is freed.
---@param self Buffer
local function buffer_cleanup(self)
    local p = self._ptr
    if p == nil then
        return
    end
    for i = 0, tonumber(p.count) - 1 do
        c.free(p.lines[i].pieces)
    end
    c.free(p.lines)
    c.free(p.add.data)
    if p.undo.data ~= nil then
        c.munmap(p.undo.data, p.undo.cap)
    end
    if p.redo.data ~= nil then
        c.munmap(p.redo.data, p.redo.cap)
    end
    if p.orig.data ~= nil and p.orig.cap > 0 and not self._munmapped then
        c.munmap(p.orig.data, p.orig.cap)
    end
    c.free(p.filepath)
    c.free(p)
end

--- Create a new empty Buffer.
---@return Buffer
function Buffer.new()
    local ptr = ffi.cast("struct Buffer *", c.calloc(1, ffi.sizeof("struct Buffer")))
    if ptr == nil then
        error("cursed: failed to allocate Buffer", 2)
    end
    ptr.lines = ffi.cast("struct Line *", c.calloc(64, ffi.sizeof("struct Line")))
    if ptr.lines == nil then
        c.free(ptr)
        error("cursed: failed to allocate Buffer lines", 2)
    end
    ptr.cap = 64
    ptr.count = 0

    local self = setmetatable({
        _ptr = ptr,
        _munmapped = false,
        _gc_guard = nil,
    }, Buffer)

    -- Seed exactly one empty line: every line in this model carries a
    -- trailing '\n' (content length = line_len - 1). A buffer with zero
    -- lines violates the editor invariant and crashes on first edit
    -- (line_len: index 0 out of range [0,0)). This covers both the
    -- no-file path and the loaded-empty-file path, since main.lua keeps
    -- this Buffer (rather than calling from_mmap) for 0-byte files.
    local nl_off = self:append_add("\n")
    self:grow_lines(1)
    self:init_line(0, 1, nl_off, 1)
    ptr.count = 1

    -- GC finalizer: cleanup then free (guard must stay alive as long as self)
    self._gc_guard = gc.wrap_gc(ffi.new("uint8_t[1]"), function()
        buffer_cleanup(self)
    end)

    return self
end

--- Create a Buffer from an mmap'd orig region (IO lane handoff).
--- Takes ownership of the mmap'd data — caller must NOT munmap it.
---@param data any mmap'd pointer
---@param len integer File size in bytes
---@param cap integer Capacity (page-rounded) in bytes
---@return Buffer
function Buffer.from_mmap(data, len, cap)
    local self = Buffer.new()
    local b = self._ptr

    -- Transfer ownership of the mmap'd region (cast void* → uint8_t*)
    b.orig.data = ffi.cast("uint8_t *", data)
    b.orig.len = len
    b.orig.cap = cap

    -- Set up GC guard for auto-munmap
    self._munmapped = false
    -- Build per-line piece tables from the mmap'd content
    self:build_lines_from_orig()

    return self
end

----------------------------------------------------------------------------------------------------
-- OrigBuf access
----------------------------------------------------------------------------------------------------

--- Get the orig buffer's data pointer.
---@return any
function Buffer:orig_data()
    return self._ptr.orig.data
end

--- Get the orig buffer's file length.
---@return integer
function Buffer:orig_len()
    return self._ptr.orig.len
end

--- Get a pointer into orig data at the given byte offset.
---@param offset integer Byte offset
---@return any
function Buffer:orig_ptr(offset)
    return self._ptr.orig.data + offset
end

--- Explicitly munmap the orig buffer and clear fields.
function Buffer:munmap_orig()
    local o = self._ptr.orig
    if o.cap > 0 and o.data ~= nil then
        c.munmap(o.data, o.cap)
    end
    self._munmapped = true
    o.data = nil
    o.len = 0
    o.cap = 0
end

----------------------------------------------------------------------------------------------------
-- AddBuf access
----------------------------------------------------------------------------------------------------

--- Get the add buffer's current length.
---@return integer
function Buffer:add_len()
    return self._ptr.add.len
end

----------------------------------------------------------------------------------------------------
-- Line array access
----------------------------------------------------------------------------------------------------

--- Get the number of lines.
---@return integer
function Buffer:line_count()
    return self._ptr.count
end

--- Get the number of pieces in a line.
---@param line_idx integer 0-based line index
---@return integer
function Buffer:piece_count(line_idx)
    return self._ptr.lines[line_idx].count
end

--- Get the total line length in bytes (including trailing \n).
---@param line_idx integer 0-based line index
---@return integer
function Buffer:line_len(line_idx)
    if line_idx < 0 or line_idx >= tonumber(self._ptr.count) then
        error(
            "line_len: index "
                .. tostring(line_idx)
                .. " out of range [0,"
                .. tonumber(self._ptr.count)
                .. ")"
        )
    end
    local line = self._ptr.lines[line_idx]
    local count = tonumber(line.count)
    ---@cast count integer
    local total = 0
    for i = 0, count - 1 do
        total = total + tonumber(line.pieces[i].len)
    end
    return total
end

----------------------------------------------------------------------------------------------------
-- Filepath
----------------------------------------------------------------------------------------------------

--- Get the source filepath.
---@return string|nil
function Buffer:filepath()
    local fp = self._ptr.filepath
    if fp == nil then
        return nil
    end
    return ffi.string(fp)
end

--- Set the source filepath.
---@param path string|nil
function Buffer:set_filepath(path)
    -- Free old filepath
    if self._ptr.filepath ~= nil then
        c.free(self._ptr.filepath)
        self._ptr.filepath = nil
    end
    if path ~= nil and #path > 0 then
        local buf = ffi.cast("char *", c.calloc(#path + 1, 1))
        ffi.copy(buf, path)
        self._ptr.filepath = buf
    end
end

----------------------------------------------------------------------------------------------------
-- Add buffer mutation (internal)
----------------------------------------------------------------------------------------------------

--- Grow the add buffer to at least the given capacity.
---@param min_cap integer Minimum capacity in bytes
function Buffer:grow_add(min_cap)
    local add = self._ptr.add
    if min_cap <= tonumber(add.cap) then
        return
    end

    local new_cap = math.max(tonumber(add.cap) * 2, min_cap, 64)
    local new_data = ffi.cast("uint8_t *", c.realloc(add.data, new_cap))
    if new_data == nil then
        error("cursed: failed to realloc add buffer", 2)
    end

    add.data = new_data
    add.cap = new_cap
end

--- Append a Lua string to the add buffer.
---@param s string
---@return integer offset Byte offset where the string starts in add buffer
function Buffer:append_add(s)
    local add = self._ptr.add
    local add_len = tonumber(add.len)
    ---@cast add_len integer
    local needed = add_len + #s

    if needed > tonumber(add.cap) then
        self:grow_add(needed)
    end

    ffi.copy(add.data + add_len, s, #s)
    add.len = needed

    return add_len
end

----------------------------------------------------------------------------------------------------
-- Lines array growth (internal)
----------------------------------------------------------------------------------------------------

--- Grow the lines array to at least the given capacity.
---@param min_cap integer Minimum number of line entries
function Buffer:grow_lines(min_cap)
    local b = self._ptr
    if min_cap <= tonumber(b.cap) then
        return
    end

    local new_cap = math.max(tonumber(b.cap) * 2, min_cap, 64)
    local new_lines =
        ffi.cast("struct Line *", c.realloc(b.lines, new_cap * ffi.sizeof("struct Line")))
    if new_lines == nil then
        error("cursed: failed to realloc lines array", 2)
    end

    -- Zero-initialize new entries (realloc doesn't guarantee it)
    if tonumber(b.count) < new_cap then
        ffi.fill(
            new_lines + tonumber(b.count),
            (new_cap - tonumber(b.count)) * ffi.sizeof("struct Line"),
            0
        )
    end
    b.lines = new_lines
    b.cap = new_cap
end

--- Shift lines in the range [from, count) right by n positions.
---@param from integer Starting line index (0-based)
---@param count integer Total number of lines before shift
---@param n integer Number of positions to shift right
function Buffer:shift_lines_right(from, count, n)
    local b = self._ptr
    for i = count - 1, from, -1 do
        b.lines[i + n] = b.lines[i]
    end
end

----------------------------------------------------------------------------------------------------
-- Per-line pieces array growth (internal)
----------------------------------------------------------------------------------------------------

--- Grow a line's pieces array to at least the given capacity.
---@param line_idx integer 0-based line index
---@param min_cap integer Minimum number of piece entries
function Buffer:grow_pieces(line_idx, min_cap)
    local line = self._ptr.lines[line_idx]
    if min_cap <= tonumber(line.cap) then
        return
    end

    local new_cap = math.max(tonumber(line.cap) * 2, min_cap, 4)
    local new_pieces =
        ffi.cast("struct Piece *", c.realloc(line.pieces, new_cap * ffi.sizeof("struct Piece")))
    if new_pieces == nil then
        error("cursed: failed to realloc pieces array", 2)
    end

    if tonumber(line.count) < new_cap then
        ffi.fill(
            new_pieces + tonumber(line.count),
            (new_cap - tonumber(line.count)) * ffi.sizeof("struct Piece"),
            0
        )
    end
    line.pieces = new_pieces
    line.cap = new_cap
end

----------------------------------------------------------------------------------------------------
-- Per-line piece access
----------------------------------------------------------------------------------------------------

--- Set a piece at the given index in a line.
---@param line_idx integer 0-based line index
---@param piece_idx integer 0-based piece index
---@param buf_id integer 0 = orig, 1 = add
---@param off integer Byte offset into buffer
---@param len integer Length in bytes
function Buffer:set_piece(line_idx, piece_idx, buf_id, off, len)
    local r = self._ptr.lines[line_idx].pieces[piece_idx]
    r.buf_id = buf_id
    r.off = off
    r.len = len
end

--- Get a piece at the given index in a line.
---@param line_idx integer 0-based line index
---@param piece_idx integer 0-based piece index
---@return integer buf_id
---@return integer off
---@return integer len
function Buffer:get_piece(line_idx, piece_idx)
    local r = self._ptr.lines[line_idx].pieces[piece_idx]
    return r.buf_id, r.off, r.len
end

--- Set the piece count for a line.
---@param line_idx integer 0-based line index
---@param n integer
function Buffer:set_piece_count(line_idx, n)
    self._ptr.lines[line_idx].count = n
end

----------------------------------------------------------------------------------------------------
-- Line initialization
----------------------------------------------------------------------------------------------------

--- Initialize a line at the given index with a single piece.
---@param line_idx integer 0-based line index
---@param buf_id integer 0 = orig, 1 = add
---@param off integer Byte offset in buffer
---@param len integer Length in bytes
function Buffer:init_line(line_idx, buf_id, off, len)
    local line = self._ptr.lines[line_idx]
    if line.pieces == nil or tonumber(line.cap) == 0 then
        line.pieces = ffi.cast("struct Piece *", c.realloc(nil, 4 * ffi.sizeof("struct Piece")))
        if line.pieces == nil then
            error("cursed: failed to alloc pieces for line " .. line_idx, 2)
        end
        line.cap = 4
    end
    line.count = 1
    line.pieces[0].buf_id = buf_id
    line.pieces[0].off = off
    line.pieces[0].len = len
end

--- Add an empty line at the given index.
---@param line_idx integer 0-based line index to insert at
---@param buf_id integer 0 = orig, 1 = add
---@param off integer Byte offset in buffer
---@param len integer Length in bytes
function Buffer:insert_line(line_idx, buf_id, off, len)
    local b = self._ptr
    local count = tonumber(b.count)
    ---@cast count integer
    self:grow_lines(count + 1)
    if line_idx < count then
        self:shift_lines_right(line_idx, count, 1)
    end
    b.lines[line_idx].pieces = nil
    b.lines[line_idx].cap = 0
    b.lines[line_idx].count = 0
    self:init_line(line_idx, buf_id, off, len)
    b.count = count + 1
end

----------------------------------------------------------------------------------------------------
-- File loading
----------------------------------------------------------------------------------------------------

--- Build per-line piece tables from the mmap'd orig buffer.
function Buffer:build_lines_from_orig()
    local b = self._ptr
    local orig = b.orig
    local file_len = tonumber(orig.len)
    ---@cast file_len integer

    -- Ensure add buffer has a \n for empty/trailing lines
    local nl_off = self:append_add("\n")

    if file_len == 0 then
        self:grow_lines(1)
        self:init_line(0, 1, nl_off, 1)
        b.count = 1
        return
    end

    -- Count newlines to pre-allocate
    local line_count = 1
    local data = orig.data
    for i = 0, file_len - 1 do
        if data[i] == 10 then
            line_count = line_count + 1
        end
    end

    self:grow_lines(line_count)

    -- Build pieces — each line includes its trailing \n
    local line_start = 0
    local line_idx = 0
    for i = 0, file_len - 1 do
        if data[i] == 10 then
            self:init_line(line_idx, 0, line_start, i - line_start + 1)
            line_idx = line_idx + 1
            line_start = i + 1
        end
    end

    -- Last line
    if line_start <= file_len then
        local last_len = file_len - line_start
        if last_len > 0 then
            self:grow_lines(line_idx + 1)
            self:init_line(line_idx, 0, line_start, last_len)
            self:grow_pieces(line_idx, 2)
            b.lines[line_idx].pieces[1].buf_id = 1
            b.lines[line_idx].pieces[1].off = nl_off
            b.lines[line_idx].pieces[1].len = 1
            b.lines[line_idx].count = 2
        else
            self:grow_lines(line_idx + 1)
            self:init_line(line_idx, 1, nl_off, 1)
        end
        line_idx = line_idx + 1
    end

    b.count = line_idx
end

----------------------------------------------------------------------------------------------------
-- Per-line piece table editing
----------------------------------------------------------------------------------------------------

--- Find the piece index and offset within that piece for a byte position.
---@param line_idx integer 0-based line index
---@param pos integer Byte position within the line (0-based)
---@return integer piece_idx
---@return integer offset Byte offset within the piece
function Buffer:find_piece(line_idx, pos)
    local line = self._ptr.lines[line_idx]
    local count = tonumber(line.count)
    ---@cast count integer
    local byte_pos = 0

    for i = 0, count - 1 do
        local p_len = tonumber(line.pieces[i].len)
        ---@cast p_len integer
        if byte_pos + p_len > pos then
            return i, pos - byte_pos
        end
        byte_pos = byte_pos + p_len
    end

    return count, 0
end

--- Insert a string at the given byte position within a line.
---@param line_idx integer 0-based line index
---@param pos integer Byte position within the line (0-based)
---@param str string String to insert
function Buffer:insert(line_idx, pos, str)
    if #str == 0 then
        return
    end

    local b = self._ptr

    -- If the string contains newlines, split the line
    local nl = string.find(str, "\n", 1, true)
    if nl ~= nil then
        local before_nl = str:sub(1, nl - 1)
        local after_nl = str:sub(nl + 1)

        if #before_nl > 0 then
            self:insert(line_idx, pos, before_nl)
        end

        self:split_line(line_idx, pos + #before_nl)

        if #after_nl > 0 then
            self:insert(line_idx + 1, 0, after_nl)
        end

        return
    end

    -- No newlines — insert within the single line
    local line = b.lines[line_idx]
    b.dirty = true
    local count = tonumber(line.count)
    ---@cast count integer

    local display_len = self:line_len(line_idx) - 1
    pos = math.max(0, math.min(pos, display_len))

    local add_off = self:append_add(str)

    local piece_idx, offset = self:find_piece(line_idx, pos)

    if count == 0 or piece_idx >= count then
        self:grow_pieces(line_idx, count + 1)
        self:set_piece(line_idx, count, 1, add_off, #str)
        self:set_piece_count(line_idx, count + 1)
    elseif offset == 0 then
        self:grow_pieces(line_idx, count + 1)
        for i = count - 1, piece_idx, -1 do
            line.pieces[i + 1] = line.pieces[i]
        end
        self:set_piece(line_idx, piece_idx, 1, add_off, #str)
        self:set_piece_count(line_idx, count + 1)
    elseif offset == tonumber(line.pieces[piece_idx].len) then
        self:grow_pieces(line_idx, count + 1)
        for i = count - 1, piece_idx + 1, -1 do
            line.pieces[i + 1] = line.pieces[i]
        end
        self:set_piece(line_idx, piece_idx + 1, 1, add_off, #str)
        self:set_piece_count(line_idx, count + 1)
    else
        local old_buf_id, old_off, old_len = self:get_piece(line_idx, piece_idx)
        self:grow_pieces(line_idx, count + 2)

        for i = count - 1, piece_idx + 1, -1 do
            line.pieces[i + 2] = line.pieces[i]
        end

        line.pieces[piece_idx].len = offset
        self:set_piece(line_idx, piece_idx + 1, 1, add_off, #str)
        line.pieces[piece_idx + 2].buf_id = old_buf_id
        line.pieces[piece_idx + 2].off = old_off + offset
        line.pieces[piece_idx + 2].len = old_len - offset

        self:set_piece_count(line_idx, count + 2)
    end
end

--- Delete n bytes starting at the given byte position within a line.
---@param line_idx integer 0-based line index
---@param pos integer Byte position to start deletion (0-based)
---@param n integer Number of bytes to delete
function Buffer:delete(line_idx, pos, n)
    if n <= 0 then
        return
    end

    local b = self._ptr
    b.dirty = true
    local line = b.lines[line_idx]
    local display_len = self:line_len(line_idx) - 1
    if pos >= display_len then
        return
    end
    pos = math.max(0, pos)
    n = math.min(n, display_len - pos)

    local remaining = n
    local piece_idx, offset = self:find_piece(line_idx, pos)

    while remaining > 0 and piece_idx < tonumber(line.count) do
        local p_buf_id, p_off, p_len = self:get_piece(line_idx, piece_idx)
        local available = p_len - offset
        local to_delete = math.min(remaining, available)

        if offset == 0 and to_delete == p_len then
            local count = tonumber(line.count)
            ---@cast count integer
            for i = piece_idx, count - 2 do
                line.pieces[i] = line.pieces[i + 1]
            end
            self:set_piece_count(line_idx, count - 1)
        elseif offset == 0 then
            line.pieces[piece_idx].off = p_off + to_delete
            line.pieces[piece_idx].len = p_len - to_delete
            piece_idx = piece_idx + 1
            offset = 0
        elseif to_delete == available then
            line.pieces[piece_idx].len = p_len - to_delete
            piece_idx = piece_idx + 1
            offset = 0
        else
            local count = tonumber(line.count)
            ---@cast count integer
            self:grow_pieces(line_idx, count + 1)

            for i = count - 1, piece_idx + 1, -1 do
                line.pieces[i + 1] = line.pieces[i]
            end

            line.pieces[piece_idx].len = offset
            line.pieces[piece_idx + 1].buf_id = p_buf_id
            line.pieces[piece_idx + 1].off = p_off + offset + to_delete
            line.pieces[piece_idx + 1].len = p_len - offset - to_delete

            self:set_piece_count(line_idx, count + 1)
            remaining = remaining - to_delete
            break
        end

        remaining = remaining - to_delete
    end
end

--- Join line_idx with line_idx+1.
---@param line_idx integer 0-based line index
function Buffer:join_lines(line_idx)
    local b = self._ptr
    b.dirty = true
    local count = tonumber(b.count)
    ---@cast count integer
    if line_idx >= count - 1 then
        return
    end

    local cur_line = b.lines[line_idx]
    local cur_count = tonumber(cur_line.count)
    ---@cast cur_count integer

    local last_len = tonumber(cur_line.pieces[cur_count - 1].len)
    ---@cast last_len integer
    if last_len == 1 then
        cur_count = cur_count - 1
        cur_line.count = cur_count
    else
        cur_line.pieces[cur_count - 1].len = last_len - 1
    end

    local next_line = b.lines[line_idx + 1]
    local next_count = tonumber(next_line.count)
    ---@cast next_count integer

    self:grow_pieces(line_idx, cur_count + next_count)
    for i = 0, next_count - 1 do
        cur_line.pieces[cur_count + i] = next_line.pieces[i]
    end
    cur_line.count = cur_count + next_count

    c.free(next_line.pieces)
    next_line.pieces = nil
    next_line.cap = 0
    next_line.count = 0

    for i = line_idx + 2, count - 1 do
        b.lines[i - 1] = b.lines[i]
    end
    b.lines[count - 1].pieces = nil
    b.lines[count - 1].cap = 0
    b.lines[count - 1].count = 0
    b.count = count - 1
end

--- Split line_idx at the given byte position.
---@param line_idx integer 0-based line index
---@param pos integer Byte position within the line (0-based)
function Buffer:split_line(line_idx, pos)
    local b = self._ptr
    b.dirty = true
    local count = tonumber(b.count)
    ---@cast count integer

    local nl_off = self:append_add("\n")

    local line = b.lines[line_idx]
    local piece_count = tonumber(line.count)
    ---@cast piece_count integer

    local byte_pos = 0
    local split_idx = piece_count
    for i = 0, piece_count - 1 do
        local p_len = tonumber(line.pieces[i].len)
        ---@cast p_len integer
        if byte_pos + p_len > pos then
            split_idx = i
            break
        end
        byte_pos = byte_pos + p_len
    end

    local offset_in_piece = pos - byte_pos

    self:grow_lines(count + 1)
    self:shift_lines_right(line_idx + 1, count, 1)
    b.count = count + 1

    b.lines[line_idx + 1].pieces = nil
    b.lines[line_idx + 1].cap = 0
    b.lines[line_idx + 1].count = 0

    if offset_in_piece == 0 then
        local head_count = split_idx
        local tail_count = piece_count - split_idx

        local new_line = b.lines[line_idx + 1]
        new_line.pieces = ffi.cast(
            "struct Piece *",
            c.realloc(nil, math.max(tail_count, 4) * ffi.sizeof("struct Piece"))
        )
        new_line.cap = math.max(tail_count, 4)

        for i = 0, tail_count - 1 do
            new_line.pieces[i] = line.pieces[split_idx + i]
        end
        new_line.count = tail_count

        if head_count > 0 then
            self:grow_pieces(line_idx, head_count + 1)
            line.pieces[head_count].buf_id = 1
            line.pieces[head_count].off = nl_off
            line.pieces[head_count].len = 1
            line.count = head_count + 1
        else
            self:init_line(line_idx, 1, nl_off, 1)
        end
    else
        local p_buf_id, p_off, p_len = self:get_piece(line_idx, split_idx)
        local before_len = offset_in_piece
        local after_buf_id = p_buf_id
        local after_off = p_off + before_len
        local after_len_p = p_len - before_len

        local head_count = split_idx
        local tail_count = piece_count - split_idx - 1
        local new_line_count = 1 + tail_count

        local new_line = b.lines[line_idx + 1]
        new_line.pieces = ffi.cast(
            "struct Piece *",
            c.realloc(nil, math.max(new_line_count, 4) * ffi.sizeof("struct Piece"))
        )
        new_line.cap = math.max(new_line_count, 4)

        new_line.pieces[0].buf_id = after_buf_id
        new_line.pieces[0].off = after_off
        new_line.pieces[0].len = after_len_p

        for i = 0, tail_count - 1 do
            new_line.pieces[1 + i] = line.pieces[split_idx + 1 + i]
        end
        new_line.count = new_line_count

        self:grow_pieces(line_idx, split_idx + 2)
        line.pieces[split_idx].len = before_len
        line.pieces[split_idx + 1].buf_id = 1
        line.pieces[split_idx + 1].off = nl_off
        line.pieces[split_idx + 1].len = 1
        line.count = split_idx + 2
    end
end

----------------------------------------------------------------------------------------------------
-- Piece-table compaction
----------------------------------------------------------------------------------------------------

--- Coalesce adjacent pieces within a single line when they reference
--- contiguous regions of the same underlying buffer (orig or add).
--- Compaction preserves the exact logical text and line length; it only
--- reduces piece count, which speeds up subsequent line_text/extract
--- walks and lowers per-render overhead. Because the add buffer is
--- append-only and orig is immutable, two pieces can merge iff they
--- share buf_id and `left.off + left.len == right.off`.
---@param line_idx integer 0-based line index
function Buffer:compact_line(line_idx)
    local line = self._ptr.lines[line_idx]
    local count = tonumber(line.count)
    ---@cast count integer
    if count <= 1 then
        return
    end
    local write = 0
    for read = 0, count - 1 do
        local p = line.pieces[read]
        if write == 0 then
            line.pieces[0] = p
            write = 1
        else
            local w = line.pieces[write - 1]
            if p.buf_id == w.buf_id and tonumber(p.off) == tonumber(w.off) + tonumber(w.len) then
                w.len = w.len + p.len
            else
                if write ~= read then
                    line.pieces[write] = p
                end
                write = write + 1
            end
        end
    end
    line.count = write
end

--- Compact every line in the inclusive range [start_idx, end_idx].
--- Clamps to the document bounds. Safe to call during navigation; it
--- does not mutate logical text or the dirty flag.
---@param start_idx integer 0-based start line index (inclusive)
---@param end_idx integer 0-based end line index (inclusive)
function Buffer:compact_lines(start_idx, end_idx)
    local lc = self:line_count()
    if lc == 0 then
        return
    end
    if start_idx < 0 then
        start_idx = 0
    end
    if end_idx >= lc then
        end_idx = lc - 1
    end
    if end_idx < start_idx then
        return
    end
    for li = start_idx, end_idx do
        self:compact_line(li)
    end
end

----------------------------------------------------------------------------------------------------
-- Text extraction
----------------------------------------------------------------------------------------------------

--- Extract the text of a single line as a Lua string.
---@param line_idx integer 0-based line index
---@return string
function Buffer:line_text(line_idx)
    if line_idx < 0 or line_idx >= tonumber(self._ptr.count) then
        error(
            "line_text: index "
                .. tostring(line_idx)
                .. " out of range [0,"
                .. tonumber(self._ptr.count)
                .. ")"
        )
    end
    local b = self._ptr
    local line = b.lines[line_idx]
    local count = tonumber(line.count)
    ---@cast count integer
    local parts = {}

    for i = 0, count - 1 do
        local p = line.pieces[i]
        if p.buf_id == 0 then
            if b.orig.data == nil then
                error(("line_text: orig.data is nil (line=%d piece=%d)"):format(line_idx, i))
            end
            local ptr = b.orig.data + p.off
            table.insert(parts, ffi.string(ptr, tonumber(p.len)))
        else
            if b.add.data == nil then
                error(("line_text: add.data is nil (line=%d piece=%d)"):format(line_idx, i))
            end
            local ptr = b.add.data + p.off
            table.insert(parts, ffi.string(ptr, tonumber(p.len)))
        end
    end

    return table.concat(parts)
end

--- Extract a substring of a single line.
---@param line_idx integer 0-based line index
---@param pos integer Byte offset within the line (0-based)
---@param len integer Number of bytes
---@return string
function Buffer:line_text_range(line_idx, pos, len)
    local b = self._ptr
    local line = b.lines[line_idx]
    local count = tonumber(line.count)
    ---@cast count integer
    local parts = {}
    local byte_pos = 0
    local remaining = len

    for i = 0, count - 1 do
        if remaining <= 0 then
            break
        end
        local p = line.pieces[i]
        local p_len = tonumber(p.len)
        ---@cast p_len integer
        local piece_end = byte_pos + p_len

        if piece_end > pos then
            local read_start = math.max(pos, byte_pos)
            local read_end = math.min(pos + len, piece_end)
            local read_len = read_end - read_start

            if read_len > 0 then
                local src_off = p.off + (read_start - byte_pos)
                local ptr
                if p.buf_id == 0 then
                    ptr = b.orig.data + src_off
                else
                    ptr = b.add.data + src_off
                end
                table.insert(parts, ffi.string(ptr, read_len))
                remaining = remaining - read_len
            end
        end

        byte_pos = piece_end
    end

    return table.concat(parts)
end

--- Extract text from a range of lines, joined with \n.
---@param start_line integer 0-based start line index (inclusive)
---@param end_line integer 0-based end line index (exclusive)
---@return string
function Buffer:text_range(start_line, end_line)
    local b = self._ptr
    local count = tonumber(b.count)
    ---@cast count integer
    end_line = math.min(end_line, count)

    local parts = {}
    for i = start_line, end_line - 1 do
        table.insert(parts, self:line_text(i))
    end

    return table.concat(parts)
end

--- Reconstruct the full document text.
---@return string
function Buffer:text()
    local b = self._ptr
    local count = tonumber(b.count)
    ---@cast count integer

    local parts = {}
    for i = 0, count - 1 do
        table.insert(parts, self:line_text(i))
    end

    return table.concat(parts)
end

--- Serialize the piece table directly into a freshly-calloc'd byte buffer,
--- returning the raw pointer + length. Used by the highlighter snapshot
--- path: writes each piece via memcpy straight into the destination,
--- skipping the per-line Lua string alloc + table.concat that made
--- Buffer:text() ~7ms on a 1.18MB / 16k-line doc. The caller owns the
--- allocation and is responsible for freeing it (typically the lane,
--- via its ffi.gc-wrapped last_text).
---
--- Mirrors serialize_to_mmap's write loop but uses calloc (exact size,
--- no page rounding, no mmap syscall) instead of mmap, since the lane
--- needs a heap allocation it can retain + free independently.
---@return any cdata char* (caller frees via ffi.C.free)
---@return integer total_len
function Buffer:write_text_direct()
    local b = self._ptr
    local count = tonumber(b.count)
    ---@cast count integer
    local C = ffi.C

    -- Pass 1: total byte length (sum of all piece lens across all lines).
    local total_len = 0
    for i = 0, count - 1 do
        local line = b.lines[i]
        local pc = tonumber(line.count)
        ---@cast pc integer
        for j = 0, pc - 1 do
            total_len = total_len + tonumber(line.pieces[j].len)
        end
    end

    if total_len == 0 then
        return nil, 0
    end

    local ptr = C.calloc(1, total_len)
    if ptr == nil then
        error("cursed: calloc failed in write_text_direct", 2)
    end

    -- Pass 2: memcpy each piece into the buffer. Cast to uint8_t* for
    -- pointer arithmetic (void* doesn't support + in plain Lua).
    local write_ptr = ffi.cast("uint8_t *", ptr)
    local offset = 0
    local orig_data = b.orig.data
    local add_data = b.add.data
    for i = 0, count - 1 do
        local line = b.lines[i]
        local pc = tonumber(line.count)
        ---@cast pc integer
        local pieces = line.pieces
        for j = 0, pc - 1 do
            local p = pieces[j]
            local p_len = tonumber(p.len)
            ---@cast p_len integer
            if p_len > 0 then
                local src
                if p.buf_id == 0 then
                    src = orig_data + p.off
                else
                    src = add_data + p.off
                end
                C.memcpy(write_ptr + offset, src, p_len)
                offset = offset + p_len
            end
        end
    end

    return ptr, total_len
end

----------------------------------------------------------------------------------------------------
-- Dirty flag
----------------------------------------------------------------------------------------------------

--- Check if the document is dirty.
---@return boolean
function Buffer:is_dirty()
    return self._ptr.dirty
end

--- Clear the dirty flag.
function Buffer:clear_dirty()
    self._ptr.dirty = false
end

--- Serialize the piece table into an mmap'd anonymous buffer.
--- Writes each piece's content directly into the mmap via ffi.copy,
--- avoiding any Lua string allocation.
---@return any mmap_ptr
---@return integer total_len
---@return integer mmap_cap (page-rounded)
function Buffer:serialize_to_mmap()
    local b = self._ptr
    local count = tonumber(b.count)
    ---@cast count integer

    -- Compute total size
    local total_len = 0
    for i = 0, count - 1 do
        local line = b.lines[i]
        local pc = tonumber(line.count)
        ---@cast pc integer
        for j = 0, pc - 1 do
            total_len = total_len + tonumber(line.pieces[j].len)
        end
    end

    -- Allocate mmap'd buffer
    local psize = tonumber(ffi.C.sysconf(pffi._SC_PAGESIZE))
    ---@cast psize integer
    local cap = bit.band(total_len + psize - 1, bit.bnot(psize - 1))
    if cap == 0 then
        cap = psize
    end
    local prot = bit.bor(pffi.PROT_READ, pffi.PROT_WRITE)
    local data = ffi.C.mmap(nil, cap, prot, bit.bor(pffi.MAP_PRIVATE, pffi.MAP_ANONYMOUS), -1, 0)
    if data == pffi.MAP_FAILED then
        error("cursed: failed to mmap for save serialization", 2)
    end

    -- Cast to uint8_t* so pointer arithmetic works (void* doesn't support it)
    local write_ptr = ffi.cast("uint8_t *", data)

    -- Copy piece data directly into the mmap'd buffer
    local offset = 0
    for i = 0, count - 1 do
        local line = b.lines[i]
        local pc = tonumber(line.count)
        ---@cast pc integer
        for j = 0, pc - 1 do
            local p = line.pieces[j]
            local p_len = tonumber(p.len)
            ---@cast p_len integer
            if p_len > 0 then
                local src
                if p.buf_id == 0 then
                    src = b.orig.data + p.off
                else
                    src = b.add.data + p.off
                end
                ffi.copy(write_ptr + offset, src, p_len)
                offset = offset + p_len
            end
        end
    end

    return data, total_len, cap
end

----------------------------------------------------------------------------------------------------
-- High-level text editing (cursor-aware, returns resulting position)
----------------------------------------------------------------------------------------------------

--- Check if a string should break the current edit group.
--- Non-alphanumeric characters and newlines break; alphanumeric continues.
---@param str string
---@return boolean
function Buffer:should_break_edit(str)
    return str:find("[^%w_]") ~= nil
end

--- Insert a string at the given cursor position.
--- Handles newlines (splits lines) and returns the resulting cursor
--- position. Does NOT manage edit grouping — callers (View:batch_edit,
--- query-replace, undo_in_selection) own begin_edit/end_edit around
--- this so multi-step inserts coalesce into one undo group.
---@param line integer 0-based line index
---@param col integer 0-based byte offset within line
---@param str string string to insert
---@return integer result_line
---@return integer result_col
function Buffer:insert_char(line, col, str)
    if #str == 0 then
        return line, col
    end
    return self:_insert_char_impl(line, col, str)
end

function Buffer:_insert_char_impl(line, col, str)
    local nl = str:find("\n", 1, true)
    if nl == nil then
        self:insert(line, col, str)
        return line, col + #str
    end

    -- Split at newline
    local before = str:sub(1, nl - 1)
    local rest = str:sub(nl + 1)

    if #before > 0 then
        self:insert(line, col, before)
        col = col + #before
    end

    -- Capture the line length at the split point (after any `before`
    -- insertion, before split_line reshuffles pieces). This decides
    -- where the cursor lands: splitting at col==0 of a NON-empty line
    -- pushes the existing content onto the new line below, leaving a
    -- fresh blank line at `line` (VSCode/Vim want the cursor to stay on
    -- that blank, above the pushed text). Splitting an empty line (or
    -- at col>0) creates the new line at `line+1` and the cursor moves
    -- down to it.
    --
    -- Every line in this buffer model carries a trailing "\n" (len 1)
    -- as its final byte, so an empty line has line_len==1. "had trailing
    -- content" therefore means line_len > col + 1 (bytes beyond the
    -- mandatory newline terminator).
    local had_trailing = self:line_len(line) > col + 1

    self:split_line(line, col)

    local result_line, result_col
    if col == 0 and had_trailing then
        result_line = line
        result_col = 0
    else
        result_line = line + 1
        result_col = 0
    end

    if #rest > 0 then
        return self:_insert_char_impl(result_line, result_col, rest)
    end

    return result_line, result_col
end

--- Delete n characters from the given cursor position.
--- Handles line joins and returns the resulting position. Does NOT
--- manage edit grouping — callers own begin_edit/end_edit around this
--- so multi-step deletions coalesce into one undo group.
---@param line integer 0-based line index
---@param col integer 0-based byte offset
---@param n integer signed character count
---@return integer result_line
---@return integer result_col
function Buffer:delete_char(line, col, n)
    if n == 0 then
        return line, col
    end
    return self:_delete_char_impl(line, col, n)
end

function Buffer:_delete_char_impl(line, col, n)
    local forward = n > 0
    local remaining = forward and n or -n

    while remaining > 0 do
        local content_len = self:line_len(line) - 1

        if forward then
            local available = content_len - col
            if available > 0 then
                local to_delete = math.min(remaining, available)
                self:delete(line, col, to_delete)
                remaining = remaining - to_delete
            end
        else
            if col > 0 then
                local to_delete = math.min(remaining, col)
                self:delete(line, col - to_delete, to_delete)
                col = col - to_delete
                remaining = remaining - to_delete
            end
        end

        if remaining > 0 then
            if forward and line < self:line_count() - 1 then
                self:join_lines(line)
                remaining = remaining - 1
            elseif not forward and line > 0 then
                line = line - 1
                col = self:line_len(line) - 1
                self:join_lines(line)
                remaining = remaining - 1
            else
                return line, col
            end
        end
    end

    return line, col
end

--- Insert a newline at the given cursor position.
---@param line integer
---@param col integer
---@return integer result_line
---@return integer result_col
function Buffer:insert_newline(line, col)
    return self:insert_char(line, col, "\n")
end

----------------------------------------------------------------------------------------------------
-- Undo/redo (mmap'd packed log)
----------------------------------------------------------------------------------------------------

--- Grow an UndoLog's mmap buffer.
local function log_grow(log)
    local old_cap = tonumber(log.cap)
    ---@cast old_cap integer
    local new_cap = math.max(old_cap * 2, 4 * 1024 * 1024)

    local new_data = c.mmap(
        nil,
        new_cap,
        bit.bor(pffi.PROT_READ, pffi.PROT_WRITE),
        bit.bor(pffi.MAP_ANONYMOUS, pffi.MAP_PRIVATE),
        -1,
        0
    )
    if new_data == pffi.MAP_FAILED then
        error("cursed: failed to mmap undo log", 2)
    end

    if old_cap > 0 and log.data ~= nil then
        ffi.copy(new_data, log.data, tonumber(log.pos))
        c.munmap(log.data, old_cap)
    end

    log.data = new_data
    log.cap = new_cap
end

--- Ensure the log has room for at least `needed` more bytes at `pos`.
local function log_ensure(log, needed)
    local pos = tonumber(log.pos)
    ---@cast pos integer
    local cap = tonumber(log.cap)
    ---@cast cap integer
    while pos + needed > cap do
        log_grow(log)
        cap = tonumber(log.cap)
    end
end

--- Pack the current piece table state into the undo log.
local function log_pack(b, log)
    local piece_size = ffi.sizeof("struct Piece")
    local line_count = tonumber(b.count)
    ---@cast line_count integer

    local entry_size = 4
    for i = 0, line_count - 1 do
        local pc = tonumber(b.lines[i].count)
        ---@cast pc integer
        entry_size = entry_size + 4 + pc * piece_size
    end
    entry_size = entry_size + 4

    log_ensure(log, entry_size)

    local pos = tonumber(log.pos)
    ---@cast pos integer
    local buf = log.data

    ffi.cast("uint32_t *", buf + pos)[0] = line_count
    pos = pos + 4

    for i = 0, line_count - 1 do
        local pc = tonumber(b.lines[i].count)
        ---@cast pc integer
        ffi.cast("uint32_t *", buf + pos)[0] = pc
        pos = pos + 4
        if pc > 0 then
            ffi.copy(buf + pos, b.lines[i].pieces, pc * piece_size)
            pos = pos + pc * piece_size
        end
    end

    ffi.cast("uint32_t *", buf + pos)[0] = entry_size
    pos = pos + 4

    log.pos = pos
    log.count = tonumber(log.count) + 1
end

--- Apply the last entry in the log to the piece table.
local function log_apply_last(b, log)
    local pos = tonumber(log.pos)
    ---@cast pos integer
    local buf = log.data

    local entry_size = tonumber(ffi.cast("uint32_t *", buf + pos - 4)[0])
    ---@cast entry_size integer
    local entry_start = pos - entry_size

    -- Free current line pieces
    local old_count = tonumber(b.count)
    ---@cast old_count integer
    for i = 0, old_count - 1 do
        if b.lines[i].pieces ~= nil then
            c.free(b.lines[i].pieces)
            b.lines[i].pieces = nil
            b.lines[i].cap = 0
            b.lines[i].count = 0
        end
    end

    local rpos = entry_start
    local snap_count = tonumber(ffi.cast("uint32_t *", buf + rpos)[0])
    rpos = rpos + 4
    ---@cast snap_count integer

    if snap_count > tonumber(b.cap) then
        c.free(b.lines)
        b.cap = snap_count + 16
        b.lines = ffi.cast("struct Line *", c.calloc(b.cap, ffi.sizeof("struct Line")))
    end

    b.count = snap_count
    local piece_size = ffi.sizeof("struct Piece")

    for i = 0, snap_count - 1 do
        local pc = tonumber(ffi.cast("uint32_t *", buf + rpos)[0])
        rpos = rpos + 4
        ---@cast pc integer
        b.lines[i].count = pc
        b.lines[i].cap = pc > 0 and pc or 4
        b.lines[i].pieces = ffi.cast("struct Piece *", c.calloc(b.lines[i].cap, piece_size))
        if pc > 0 then
            ffi.copy(b.lines[i].pieces, buf + rpos, pc * piece_size)
            rpos = rpos + pc * piece_size
        end
    end
end

--- Pop the last entry from an undo log.
local function log_pop(log)
    local pos = tonumber(log.pos)
    ---@cast pos integer
    if pos == 0 then
        return
    end
    local buf = log.data
    local entry_size = tonumber(ffi.cast("uint32_t *", buf + pos - 4)[0])
    ---@cast entry_size integer
    log.pos = pos - entry_size
    log.count = tonumber(log.count) - 1
end

--- Reset an undo log (discard all entries, keep the mapping).
local function log_reset(log)
    log.pos = 0
    log.count = 0
end

----------------------------------------------------------------------------------------------------
-- Snapshot text extraction (for undo-in-selection)
----------------------------------------------------------------------------------------------------

--- Walk the undo/redo log to find the byte offset of entry `entry_idx`.
--- Entries are packed sequentially; we walk forward reading headers.
---@param log any UndoLog cdata
---@param entry_idx integer 0-based entry index
---@return integer byte_offset
local function log_entry_offset(log, entry_idx)
    local buf = log.data
    local piece_size = ffi.sizeof("struct Piece")
    local pos = 0

    for _ = 0, entry_idx - 1 do
        -- Read line_count
        local line_count = tonumber(ffi.cast("uint32_t *", buf + pos)[0])
        pos = pos + 4
        -- Skip per-line data
        for _ = 0, line_count - 1 do
            local pc = tonumber(ffi.cast("uint32_t *", buf + pos)[0])
            pos = pos + 4 + pc * piece_size
        end
        -- Skip entry_size footer
        pos = pos + 4
    end

    return pos
end

--- Extract text from a specific range in a packed undo/redo log entry,
--- without disturbing the live piece table.
---
--- The log entries reference orig (buf_id=0) and add (buf_id=1) buffers,
--- both of which remain valid since orig is immutable and add is append-only.
---
---@param log any UndoLog cdata
---@param entry_idx integer 0-based entry index
---@param start_line integer 0-based line index (in snapshot coordinates)
---@param start_col integer 0-based byte offset within start_line
---@param end_line integer 0-based line index (inclusive)
---@param end_col integer 0-based byte offset within end_line (exclusive)
---@return string
function Buffer:snapshot_text_range(log, entry_idx, start_line, start_col, end_line, end_col)
    local buf = log.data
    local piece_size = ffi.sizeof("struct Piece")
    local pos = log_entry_offset(log, entry_idx)

    local snap_line_count = tonumber(ffi.cast("uint32_t *", buf + pos)[0])
    pos = pos + 4

    -- Clamp to snapshot's line count
    if start_line >= snap_line_count then
        return ""
    end
    local effective_end_line = math.min(end_line, snap_line_count - 1)

    local b = self._ptr
    local parts = {}

    for li = 0, snap_line_count - 1 do
        local pc = tonumber(ffi.cast("uint32_t *", buf + pos)[0])
        local line_data_pos = pos + 4
        pos = line_data_pos + pc * piece_size

        if li < start_line then
            -- Skip: already past pos
        elseif li > effective_end_line then
            -- No need to keep scanning
            break
        else
            -- Extract full line text from this snapshot's pieces
            local line_parts = {}
            for pi = 0, pc - 1 do
                local p = ffi.cast("struct Piece *", buf + line_data_pos + pi * piece_size)
                local p_buf_id = p.buf_id
                local p_off = tonumber(p.off)
                local p_len = tonumber(p.len)
                if p_len > 0 then
                    local ptr
                    if p_buf_id == 0 then
                        ptr = b.orig.data + p_off
                    else
                        ptr = b.add.data + p_off
                    end
                    table.insert(line_parts, ffi.string(ptr, p_len))
                end
            end
            local line_text = table.concat(line_parts)

            -- Strip trailing newline for col-boundary slicing consistency
            local has_trailing_nl = #line_text > 0 and line_text:byte(#line_text) == 10
            local content_text = line_text
            if has_trailing_nl then
                content_text = line_text:sub(1, #line_text - 1)
            end

            -- Clip to the appropriate column range
            if li == start_line and li == effective_end_line then
                content_text = content_text:sub(start_col + 1, end_col)
            elseif li == start_line then
                content_text = content_text:sub(start_col + 1)
            elseif li == effective_end_line then
                content_text = content_text:sub(1, end_col)
            end

            -- Re-add newline for non-last lines in the range
            if li ~= effective_end_line and has_trailing_nl then
                content_text = content_text .. "\n"
            end

            table.insert(parts, content_text)
        end
    end

    return table.concat(parts)
end

--- Begin an edit group. Snapshots the piece table on the first call.
function Buffer:begin_edit()
    local b = self._ptr
    if tonumber(b.in_edit) > 0 then
        b.in_edit = tonumber(b.in_edit) + 1
        return
    end

    log_pack(b, b.undo)
    log_reset(b.redo)

    b.in_edit = 1
end

--- End an edit group.
function Buffer:end_edit()
    local b = self._ptr
    local ie = tonumber(b.in_edit)
    if ie == 0 then
        return
    end
    b.in_edit = ie - 1
end

--- Check if an edit group is currently active.
---@return boolean
function Buffer:in_edit()
    return tonumber(self._ptr.in_edit) > 0
end

--- Close the current edit group if one is open.
function Buffer:close_edit()
    local b = self._ptr
    if tonumber(b.in_edit) > 0 then
        b.in_edit = 0
    end
end

--- Undo the last edit group.
---@return boolean
function Buffer:undo()
    local b = self._ptr

    if tonumber(b.in_edit) > 0 then
        b.in_edit = 0
    end

    local undo_count = tonumber(b.undo.count)
    ---@cast undo_count integer
    if undo_count == 0 then
        return false
    end

    log_pack(b, b.redo)
    log_apply_last(b, b.undo)
    log_pop(b.undo)

    return true
end

--- Redo the last undone edit group.
---@return boolean
function Buffer:redo()
    local b = self._ptr

    if tonumber(b.in_edit) > 0 then
        b.in_edit = 0
    end

    local redo_count = tonumber(b.redo.count)
    ---@cast redo_count integer
    if redo_count == 0 then
        return false
    end

    log_pack(b, b.undo)
    log_apply_last(b, b.redo)
    log_pop(b.redo)

    return true
end

----------------------------------------------------------------------------------------------------
-- Search (exact string)
----------------------------------------------------------------------------------------------------

---@class Point
---@field line integer 0-based line index (match start)
---@field offset integer 0-based byte offset within the line (match start)
---@field end_line integer 0-based line index (match end)
---@field end_offset integer 0-based byte offset within end_line (character AFTER the match)

--- Create a forward search iterator for an exact string.
---@param query string exact string or Lua pattern to search for
---@param start Point|nil starting position
---@param plain boolean|nil true for literal match (default), false for Lua patterns
---@return function iterator
function Buffer:search_forward(query, start, plain)
    if #query == 0 then
        return function() end
    end

    if plain == nil then
        plain = true
    end

    local line_count = self:line_count()
    local has_newlines = query:find("\n", 1, true) ~= nil

    local getter, point_from_offset

    if not has_newlines then
        getter = function(li)
            return self:line_text(li)
        end

        point_from_offset = function(li, off, end_off)
            local text = self:line_text(li)
            local content_len = #text
            if content_len > 0 and text:byte(content_len) == 10 then
                content_len = content_len - 1
            end
            local start_off = math.min(off - 1, content_len)
            local end_off2 = end_off or start_off
            return { line = li, offset = start_off, end_line = li, end_offset = end_off2 }
        end
    else
        local span = 1
        for _ in query:gmatch("\n") do
            span = span + 1
        end

        getter = function(li)
            return self:text_range(li, math.min(li + span, line_count))
        end

        point_from_offset = function(li, off, end_off)
            local text = getter(li)
            local line = li
            local col = 0
            local byte = 1
            while byte < off do
                if text:byte(byte) == 10 then
                    line = line + 1
                    col = 0
                else
                    col = col + 1
                end
                byte = byte + 1
            end
            local end_line = li
            local end_col = 0
            if end_off then
                local end_byte = end_off + 1
                byte = 1
                while byte < end_byte do
                    if text:byte(byte) == 10 then
                        end_line = end_line + 1
                        end_col = 0
                    else
                        end_col = end_col + 1
                    end
                    byte = byte + 1
                end
            end
            return { line = line, offset = col, end_line = end_line, end_offset = end_col }
        end
    end

    local cur_line = (start and start.line) or 0
    local cur_offset = (start and start.offset) or 0

    return function()
        while cur_line < line_count do
            local text = getter(cur_line)
            local search_start = cur_offset + 1 + 1

            local s, e = text:find(query, search_start, plain)
            if s then
                local pt = point_from_offset(cur_line, s, e)
                if not has_newlines then
                    cur_offset = pt.offset + (e - s + 1)
                else
                    ---@cast e integer
                    cur_offset = e
                end
                return pt
            end

            cur_line = cur_line + 1
            cur_offset = 0
        end
        return nil
    end
end

--- Create a backward search iterator for an exact string.
---@param query string
---@param start Point|nil
---@param plain boolean|nil true for literal match (default), false for Lua patterns
---@return function iterator
function Buffer:search_backward(query, start, plain)
    if #query == 0 then
        return function() end
    end

    if plain == nil then
        plain = true
    end

    local line_count = self:line_count()
    local cur_line = (start and start.line) or (line_count - 1)
    local cur_offset
    if start then
        cur_offset = start.offset
    else
        cur_offset = self:line_len(cur_line) - 1
    end

    return function()
        while cur_line >= 0 do
            local text = self:line_text(cur_line)
            local content_len = #text
            if content_len > 0 and text:byte(content_len) == 10 then
                content_len = content_len - 1
            end

            local pos = 1
            local last_s, last_e
            while true do
                local s, e = text:find(query, pos, plain)
                if not s then
                    break
                end
                if s - 1 > cur_offset then
                    break
                end
                last_s = s
                last_e = e
                pos = e + 1
            end

            if last_s then
                local pt = {
                    line = cur_line,
                    offset = last_s - 1,
                    end_line = cur_line,
                    end_offset = last_e,
                }
                cur_offset = pt.offset - 1
                if cur_offset < 0 then
                    cur_line = cur_line - 1
                    if cur_line >= 0 then
                        cur_offset = self:line_len(cur_line) - 1
                    end
                end
                return pt
            end

            cur_line = cur_line - 1
            if cur_line >= 0 then
                cur_offset = self:line_len(cur_line) - 1
            end
        end
        return nil
    end
end

----------------------------------------------------------------------------------------------------
-- Search (regex — vendored TRE)
----------------------------------------------------------------------------------------------------

local tre_ffi = require("cursed.tre_ffi")
local tre_c = tre_ffi.C
local tre_constants = tre_ffi

--- Create a forward regex search iterator.
---@param pattern string POSIX extended regex
---@param start Point|nil
---@param icase boolean|nil
---@return function|nil iterator
---@return string|nil errmsg
function Buffer:search_regex(pattern, start, icase)
    local regex, err = tre_ffi.compile_regex(pattern, icase)
    if not regex then
        return nil, err
    end

    local line_count = self:line_count()
    local match = ffi.new(tre_ffi.regmatch_type)

    local cur_line = (start and start.line) or 0
    local cur_offset = (start and start.offset) or 0
    local freed = false

    return function()
        while cur_line < line_count do
            local text = self:line_text(cur_line)
            local text_len = #text

            while cur_offset < text_len do
                local remaining = text_len - cur_offset
                local rc = tre_c.tre_regnexec(
                    regex,
                    ffi.cast("const char *", text) + cur_offset,
                    remaining,
                    1,
                    match,
                    0
                )
                if rc ~= 0 then
                    break
                end

                local so = tonumber(match[0].rm_so)
                ---@cast so integer
                local eo = tonumber(match[0].rm_eo)
                ---@cast eo integer

                if so >= 0 then
                    local offset = so + cur_offset
                    local end_offset = eo + cur_offset
                    cur_offset = cur_offset + eo

                    return {
                        line = cur_line,
                        offset = offset,
                        end_line = cur_line,
                        end_offset = end_offset,
                    }
                end

                cur_offset = cur_offset + 1
            end

            cur_line = cur_line + 1
            cur_offset = 0
        end

        if not freed then
            ffi.C.tre_regfree(regex)
            freed = true
        end
        return nil
    end
end

--- Create a backward regex search iterator.
---@param pattern string POSIX extended regex
---@param start Point|nil
---@param icase boolean|nil
---@return function|nil iterator
---@return string|nil errmsg
function Buffer:search_regex_backward(pattern, start, icase)
    local regex, err = tre_ffi.compile_regex(pattern, icase)
    if not regex then
        return nil, err
    end

    local line_count = self:line_count()
    local match_buf = ffi.new(tre_ffi.regmatch_type)

    local cur_line = (start and start.line) or (line_count - 1)
    local cur_offset
    if start then
        cur_offset = start.offset
    else
        cur_offset = self:line_len(cur_line) - 1
    end
    local freed = false

    return function()
        while cur_line >= 0 do
            local text = self:line_text(cur_line)
            local text_len = #text

            local off = 0
            local last_so, last_eo
            while off < text_len do
                local remaining = text_len - off
                local rc = tre_c.tre_regnexec(
                    regex,
                    ffi.cast("const char *", text) + off,
                    remaining,
                    1,
                    match_buf,
                    0
                )
                if rc ~= 0 then
                    break
                end

                local so = tonumber(match_buf[0].rm_so)
                ---@cast so integer
                local eo = tonumber(match_buf[0].rm_eo)
                ---@cast eo integer

                if so < 0 then
                    break
                end

                local abs_so = so + off
                if abs_so > cur_offset then
                    break
                end

                last_so = abs_so
                last_eo = eo + off
                off = off + eo
            end

            if last_so then
                local pt =
                    { line = cur_line, offset = last_so, end_line = cur_line, end_offset = last_eo }
                cur_offset = pt.offset - 1
                if cur_offset < 0 then
                    cur_line = cur_line - 1
                    if cur_line >= 0 then
                        cur_offset = self:line_len(cur_line) - 1
                    end
                end
                return pt
            end

            cur_line = cur_line - 1
            if cur_line >= 0 then
                cur_offset = self:line_len(cur_line) - 1
            end
        end

        if not freed then
            ffi.C.tre_regfree(regex)
            freed = true
        end
        return nil
    end
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    Buffer = Buffer,
}
