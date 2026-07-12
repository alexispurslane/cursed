--- Spell client: drives a long-lived `enchant-2 -a` process via the
--- proc lane, parses the ispell-pipe protocol, and delivers results to
--- the spell store.
---
--- Wire protocol (one result line per checked word, as emitted by
--- aspell/hunspell/enchant in `-a` mode):
---   `*`                            — word is correct
---   `& word count offset: s1, s2` — misspelled, `count` suggestions,
---                                    `offset` = 0-based *codepoint*
---                                    offset into the SENT input line
---                                    (which includes our leading `^`
---                                    escape)
---   `# word offset`                — misspelled, no suggestions
---   blank line                     — end of this input line's results
---
--- Lifecycle:
---   • One proc per active buffer (lazy spawn on first check).
---   • We send each masked buffer line prefixed with `^` (the ispell
---     "escape" char). It prevents lines starting with protocol control
---     chars (`#`, `*`, `-`) from being swallowed as directives —
---     critical for markdown (`# heading`, `* bullet`, `- list`).
---     enchant reports offsets as 0-based *codepoint* positions, so
---     we subtract 1 to cancel the leading `^` and then convert the
---     codepoint column to a buffer byte offset.
---   • We accumulate stdout in a buffer; a blank line delimits the end
---     of results for one input line. On that boundary, we parse the
---     accumulated result lines, build entries, and add them to the
---     store for `buf` keyed by the in-flight request's line number.
---   • On exit (crash, EOF), the proc is marked dead and the driver
---     will respawn on next check cycle.

---@diagnostic disable: no-unknown

local proc = require("cursed.proc_client")
local log = require("cursed.log")
local utf8 = require("cursed.utf8")

local M = {}

---@class SpellClient
---@field _editor table owning editor
---@field _store SpellStore
---@field _procs table<string, integer> bufkey → procid
---@field _out_bufs table<integer, string> procid → pending stdout bytes
---@field _inflight table<integer, table[]> procid → FIFO queue of pending requests
---@field _langs table<string, string> bufkey → language tag
local SpellClient = {}
SpellClient.__index = SpellClient

function M.new(editor, store)
    return setmetatable({
        _editor = editor,
        _store = store,
        _procs = {},
        _out_bufs = {},
        _inflight = {},
        _langs = {},
    }, SpellClient)
end

local function bufkey(buf)
    if buf == nil then
        return nil
    end
    local p = buf._ptr
    if p == nil then
        return nil
    end
    return tostring(p)
end

--- Discover the enchant binary (prefers `enchant-2`, falls back to
--- `enchant`). Returns nil if none found.
local function enchant_bin()
    local handle = io.popen("command -v enchant-2 2>/dev/null || command -v enchant 2>/dev/null")
    if handle == nil then
        return nil
    end
    local out = handle:read("*l")
    handle:close()
    if out == nil or out == "" then
        return nil
    end
    return out
end

--- Cached enchant binary path.
M._cached_bin = nil

--- Spawn a persistent enchant process for `buf` running in language
--- `lang`. Returns procid or nil on failure. Idempotent: if a proc
--- for this buffer is already live, returns it.
---@param buf table
---@param lang string|nil BCP-47 tag like "en_US"; nil → enchant default
---@return integer|nil procid
function SpellClient:_ensure_proc(buf, lang)
    local k = bufkey(buf)
    if k == nil then
        return nil
    end
    if M._cached_bin == nil then
        M._cached_bin = enchant_bin()
    end
    if M._cached_bin == nil then
        log.warn("spell_client", "enchant_not_found")
        return nil
    end
    if self._procs[k] ~= nil then
        return self._procs[k]
    end
    local argv = { M._cached_bin, "-a" }
    if lang ~= nil and lang ~= "" then
        argv[3] = "-l"
        argv[4] = lang
    end
    local pid = proc.spawn(argv, { buffer_bytes = 0 })
    self._procs[k] = pid
    self._langs[k] = lang
    -- Register an output + lifecycle listener. The event bus calls
    -- listeners in registration order; we register one handler that
    -- dispatches on stream/kind.
    local es = self._editor.event_system
    local function on_out(_ed, stream, bytes)
        ---@diagnostic disable-next-line: unused-local
        _ed = _ed
        if stream == "stdout" then
            self:_on_stdout(pid, buf, bytes)
        end
    end
    local function on_exit(_ed, kind, code)
        ---@diagnostic disable-next-line: unused-local
        _ed = _ed
        if kind ~= "stdout" and kind ~= "stderr" then
            self:_on_exit(pid, k, kind, code)
        end
    end
    es:on("process_out:" .. tostring(pid), on_out)
    es:on("process_out:" .. tostring(pid), on_exit)
    -- enchant prints a banner line on startup like `@(#) International
    -- Ispell ...`. Discard it; we only care about result lines.
    -- We can't predict when the banner arrives; rely on the
    -- newline-delineated protocol below to ignore it (the banner
    -- doesn't match `*`, `&`, or `#`).
    return pid
end

--- Parse a single ispell result line into an entry, if it matches the
--- protocol. Returns `{word, s_col, suggestions}` where `s_col` is the
--- RAW 0-based *codepoint* offset reported by enchant (into the sent
--- line, which includes our leading `^`); callers MUST subtract 1 and
--- convert to a buffer byte col before using it. Returns nil when not
--- a result line.
local function parse_result_line(line)
    if line == nil or line == "" then
        return nil
    end
    local c = line:byte(1)
    -- `*` correct — no entry (we only track misspellings)
    if c == 42 then
        return { word = nil }
    end
    -- `& word count offset: sug1, sug2, ...`
    if c == 38 then
        ---@diagnostic disable-next-line: unused-local
        local word, _count_s, off_s, rest = line:match("^& (%S+) (%d+) (%d+): (.*)$")
        if word == nil then
            return nil
        end
        local suggestions = {}
        if rest ~= nil and rest ~= "" then
            for sug in rest:gmatch("([^,]+)") do
                sug = sug:gsub("^%s+", "")
                if sug ~= "" then
                    suggestions[#suggestions + 1] = sug
                end
            end
        end
        local off = tonumber(off_s) or 0
        -- RAW enchant offset: 0-based codepoint offset into the sent
        -- line (which includes our leading `^`). Caller subtracts 1
        -- and converts to a byte offset.
        return { word = word, s_col = off, suggestions = suggestions }
    end
    -- `# word offset` — misspelled, no suggestions
    if c == 35 then
        local word, off_s = line:match("^# (%S+) (%d+)$")
        if word == nil then
            return nil
        end
        local off = tonumber(off_s) or 0
        return { word = word, s_col = off, suggestions = {} }
    end
    -- Anything else (banner, comments) — ignore.
    return nil
end

--- Handle a chunk of stdout for `buf`. Delineated by newlines; a blank
--- line terminates the result block for one input line.
---
--- Per-proc in-flight tracking is a FIFO queue: each `check_line` pushes
--- a request to the back; results arrive in order (the pipe is FIFO);
--- a blank line commits the FRONT request and pops it. This correctly
--- attributes multi-line batches to their respective buffer lines.
---@param pid integer
---@param buf table
---@param bytes string
function SpellClient:_on_stdout(pid, buf, bytes)
    local buf_str = (self._out_bufs[pid] or "") .. bytes
    -- Walk complete lines (terminated by \n).
    while true do
        local nl = buf_str:find("\n", 1, true)
        if nl == nil then
            break
        end
        local line = buf_str:sub(1, nl - 1)
        buf_str = buf_str:sub(nl + 1)
        if line == "" then
            -- Blank line = end of results for the FRONT request.
            self:_commit_front(pid, buf)
        else
            local parsed = parse_result_line(line)
            if parsed ~= nil and parsed.word ~= nil then
                -- Accumulate onto the front request's entries.
                local q = self._inflight[pid]
                if q ~= nil and q[1] ~= nil then
                    local req = q[1]
                    req.entries = req.entries or {}
                    req.entries[#req.entries + 1] = parsed
                end
            end
        end
    end
    self._out_bufs[pid] = buf_str
end

--- Convert a 0-based codepoint column on `line_text` to a 0-based byte
--- offset. Returns 0 for `cp_col <= 0` and clamps past-end columns to
--- the string length.
---@param line_text string
---@param cp_col integer 0-based codepoint offset
---@return integer byte_offset 0-based byte offset
local function codepoint_to_byte(line_text, cp_col)
    if cp_col <= 0 then
        return 0
    end
    local i = 1
    local n = #line_text
    local cp = 0
    while i <= n do
        local _, ni = utf8.decode(line_text, i)
        if ni <= i then
            return n
        end
        cp = cp + 1
        if cp >= cp_col then
            return ni - 1
        end
        i = ni
    end
    return n
end

--- Commit the FRONT request's accumulated entries into the store, then
--- pop it from the per-proc FIFO. We send each line prefixed with `^`
--- to escape protocol control chars. enchant reports a 0-based
--- *codepoint* offset, so we subtract 1 to cancel `^` and then convert
--- the codepoint column to a buffer byte offset.
---@param pid integer
---@param buf table
function SpellClient:_commit_front(pid, buf)
    local q = self._inflight[pid]
    if q == nil or q[1] == nil then
        return -- banner line or spurious blank line
    end
    local req = q[1]
    local entries = req.entries or {}
    local line = req.line
    local line_text = buf:line_text(line)
    if #line_text > 0 and line_text:byte(#line_text) == 10 then
        line_text = line_text:sub(1, #line_text - 1)
    end
    for _, e in ipairs(entries) do
        -- Subtract 1 to undo the leading `^` we prepend on send.
        local cp_col = e.s_col - 1
        if cp_col < 0 then
            cp_col = 0
        end
        local s_col = codepoint_to_byte(line_text, cp_col)
        local e_col = s_col + #e.word
        self._store:add(buf, {
            line = line,
            s_col = s_col,
            e_col = e_col,
            word = e.word,
            suggestions = e.suggestions,
        })
    end
    -- Pop the front of the FIFO.
    table.remove(q, 1)
end

--- Called when a check request batch starts: resets the store for `buf`
--- to accumulate fresh results against `gen`. The caller must call
--- this BEFORE sending any lines for this cycle.
---@param buf table
---@param gen integer
function SpellClient:begin_batch(buf, gen)
    self._store:clear(buf)
    self._store._stores[tostring(buf._ptr)] = { version = gen, items = {} }
end

--- Send a masked line to enchant for checking. The `line_text` param
--- is the masked line text (non-checkable bytes replaced with spaces,
--- preserving byte offsets). aspell's reported offsets are absolute
--- within the masked line we send, which already matches the buffer's
--- byte layout — no col_offset translation.
---
--- The request is pushed to the BACK of the per-proc FIFO so results
--- are attributed to the correct buffer line when multiple lines are
--- in flight.
---@param buf table
---@param line integer 0-based buffer line index
---@param line_text string masked line text
---@param _col_offset integer unused (kept for API symmetry with mask.mask_line)
---@param gen integer the buf._words_gen this batch is checking
function SpellClient:check_line(buf, line, line_text, _col_offset, gen)
    ---@diagnostic disable-next-line: unused-local
    _col_offset = _col_offset
    local pid = self:_ensure_proc(buf, self._langs[tostring(buf._ptr)])
    if pid == nil then
        return
    end
    -- Push to the back of the per-proc FIFO.
    local q = self._inflight[pid]
    if q == nil then
        q = {}
        self._inflight[pid] = q
    end
    q[#q + 1] = { buf = buf, line = line, gen = gen, entries = {} }
    -- Send the masked line text prefixed with `^` (ispell-pipe escape
    -- char) so leading protocol control chars (`#`, `*`, `-`) aren't
    -- swallowed as directives. Without `^`, markdown headings (`# foo`)
    -- and bullets (`* foo`) return NO results from enchant. The `^`
    -- inflates every reported offset by +1; _commit_front undoes it.
    local data = "^" .. line_text .. "\n"
    proc.send_stdin(pid, data)
end

--- Called after the driver has sent all lines for a batch — the blank
--- line delimiter from the last line's results triggers a final commit.
--- This is mostly a hook for the driver to know it's done.
function SpellClient:end_batch()
    -- Nothing to send; the newline-terminated protocol handles it.
    -- The store was populated incrementally; versions are already
    -- stamped via begin_batch.
end

--- Mark the proc dead on exit and clear inflight.
function SpellClient:_on_exit(pid, k, kind, code)
    self._procs[k] = nil
    self._out_bufs[pid] = nil
    self._inflight[pid] = nil
    if kind ~= "exited" then
        log.warn("spell_client", "proc_exit", { kind = kind, code = code })
    end
end

--- Kill all live spell procs (shutdown hook).
function SpellClient:shutdown()
    for k, pid in pairs(self._procs) do
        proc.kill(pid, 15)
        self._procs[k] = nil
    end
end

return M
