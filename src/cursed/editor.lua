--- Editor: orchestration layer — rendering, keybinding dispatch, multi-view.
---
--- The Editor holds a list of Views, tracks the active view, and renders
--- it to the terminal. Keybinding functions receive (view, editor).

local tb = require("cursed.tb")
local ColorScheme = require("cursed.colorscheme")
local bit = require("bit")
local ffi = require("ffi")
local pffi = require("cursed.posix_ffi")
local c = pffi.C
local View = require("cursed.view").View
local Buffer = require("cursed.buffer").Buffer
local Minibuffer = require("cursed.minibuffer").Minibuffer
local EventSystem = require("cursed.event_system")
local shared = require("cursed.shared")
local find_file = require("cursed.find_file")
local kill_ring = require("cursed.kill_ring")
local completers = require("cursed.completers")
local log = require("cursed.log")

--- Resolve a UI chrome color from the active colorscheme.
--- UI concepts (line_number, modeline_fg, cursor_bg, …) live in the
--- same CONCEPT_SLOTS table as syntax concepts, so `:color()` resolves
--- them (with no style bits, since they have no CONCEPT_STYLE entry).
--- Falls back to `tb.color_default` (terminal default) when no scheme
--- is active yet, so the editor still renders during early startup.
--- @param name string  UI concept key in CONCEPT_SLOTS
--- @return integer color
local function ui(name)
    local scheme = ColorScheme.active
    if scheme == nil then
        return tb.color_default
    end
    return scheme:color(name)
end

--- Display width (cell count) of a UTF-8 string. `#s` counts BYTES,
--- but termbox x/y are CELL columns — so any modeline math involving
--- unicode glyphs (◆ ▤ ⌖ ◣ ◢ …, all 1 cell but ≥2 bytes) must use this
--- instead or the column offsets drift and leave visible gaps. Counts
--- UTF-8 codepoints; assumes no double-wide CJK (true for our chrome).
---@param s string
---@return integer cells
local function cell_len(s)
    local _, n = s:gsub("[^\128-\191]", "")
    return n
end

--- Truncate `s` to at most `max` display cells, never splitting a
--- multibyte codepoint. ASCII `:sub` would slice a ◆/▤ mid-byte.
---@param s string
---@param max integer max cells
---@return string
local function truncate_cells(s, max)
    if cell_len(s) <= max then
        return s
    end
    local out, n = {}, 0
    for seq in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
        if n >= max then
            break
        end
        out[#out + 1] = seq
        n = n + 1
    end
    return table.concat(out)
end

----------------------------------------------------------------------------------------------------
-- Pretty printer for eval output
----------------------------------------------------------------------------------------------------

local function pprint(val, depth)
    depth = depth or 0
    if depth > 4 then
        return "..."
    end
    local t = type(val)
    if t == "nil" then
        return "nil"
    elseif t == "boolean" then
        return tostring(val)
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        if depth == 0 then
            -- Top-level: no quotes (user typed a string expression)
            return val
        end
        return string.format("%q", val)
    elseif t == "table" then
        local parts = {}
        for k, v in pairs(val) do
            local ks
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                ks = k
            else
                ks = "[" .. pprint(k, depth + 1) .. "]"
            end
            parts[#parts + 1] = ks .. " = " .. pprint(v, depth + 1)
        end
        if #parts == 0 then
            return "{}"
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    elseif t == "function" then
        return "<function>"
    elseif t == "cdata" then
        return tostring(val)
    else
        return "<" .. t .. ">"
    end
end

---@class Editor
---@field drain_hl_inbox fun()|nil inline inbox_hl drain (attached by main.lua) for the zero-flash sync-wait path
---@field views View[] list of open views
---@field active_view integer 1-based index into views
---@field term Term
---@field status_message string|nil
---@field minibuffer Minibuffer
---@field _isearch_origin_line integer|nil saved cursor line before isearch
---@field _isearch_origin_col integer|nil saved cursor col before isearch
---@field _isearch_direction integer 1=forward, -1=backward
---@field _isearch_regex boolean|nil true when active isearch is a regex search
---@field _eval_result string|nil pretty-printed eval result to show in minibuffer area
---@field _quit_requested boolean set by M-x to signal quit from async callback
---@field _wake_main function? callback to wake the main select() loop from async context
---@field _background_tasks fun(): boolean?[] incremental main-thread tasks
---@field _universal_active boolean true when C-u argument collection is in progress
---@field _universal_count integer number of times C-u was pressed in current collection
---@field universal_args table|nil universal argument list for the next command dispatch
---@field _recording boolean true when kmacro recording is active
---@field _recorded_commands table[] stack of recorded {name, universal_args} commands
---@field _recorded_mb_inputs string[] minibuffer inputs captured during kmacro recording
---@field _kmacros table<string, { commands: table[], mb_inputs: string[] }> saved keyboard macros
---@field _mb_input_stack string[] minibuffer inputs popped during kmacro replay
---@field _mb_just_closed integer? count of stale Enter/Tab events to suppress after minibuffer closes
---@field _base_trie table the base keybind trie (no mode overlays)
---@field _base_keybindings table<string, string|function> flat chord→action map (base only)
---@field _active_trie table the current keybind trie (base + active mode overlay)
---@field _chord_for_command table<string, string>|nil reverse map command_name→formatted chord
---@field _trie_changed boolean? set when active_trie was rebuilt (main loop resets chord state)
---@field _digit_active boolean true when M-digit/M-- argument accumulation is in progress
---@field _digit_value integer accumulated digit value (starts at 0)
---@field _digit_negative boolean true when M-- was pressed (negate the arg)
---@field _last_was_kill boolean true when the most recent dispatched command was a kill (for consecutive-kill merging)
---@field _kill_called boolean true when push_kill was called during the current command dispatch
---@field _printable_fn function? the __printable handler
---@field _read_char_cb function|nil active callback for read-char (one-shot)
---@field _read_char_prompt string the prompt shown during read-char
---@field _config Config the loaded user configuration
---@field _blink_on boolean caret visible (drawn) this blink phase
---@field _blink_next_us integer deadline (us) of next on/off toggle; 0 = uninitialized
---@field event_system EventSystem central event hub (pre/post-command, mode_enter/exit, ring-buffer, ...)
---@field _last_command string|nil name of the most recently dispatched command (Emacs `last-command`)
---@field _command_before_this string|nil the command before the most recent one (Emacs `command-before-this`)
---@field _last_complex_command { name: string, universal_args: table }|nil most recent command invoked with universal args (for repeat-complex-command)
local Editor = {}
Editor.__index = Editor

----------------------------------------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------------------------------------

--- Create a new Editor with an empty view list.
---@param term Term
---@return Editor
function Editor.new(term)
    local editor = setmetatable({
        views = {},
        active_view = 0,
        term = term,
        status_message = nil,
        minibuffer = Minibuffer.new(),
        _isearch_origin_line = nil,
        _isearch_origin_col = nil,
        _isearch_direction = 1,
        _isearch_regex = nil,
        _eval_result = nil,
        _quit_requested = false,
        _background_tasks = {},
        _hl_idle_last = nil,
        _wake_main = function() end,
        _universal_active = false,
        _universal_count = 0,
        universal_args = nil,
        _recording = false,
        _recorded_commands = {},
        _recorded_mb_inputs = {},
        _kmacros = {},
        _mb_input_stack = {},
        _base_trie = nil,
        _base_keybindings = {},
        _active_trie = nil,
        _chord_for_command = {},
        _digit_active = false,
        _digit_value = 0,
        _digit_negative = false,
        _last_was_kill = false,
        _kill_called = false,
        _printable_fn = nil,
        _read_char_cb = nil,
        _read_char_prompt = "",
        _config = nil,
        _blink_on = true, -- caret visible (drawn) this phase
        _blink_next_us = 0, -- deadline (us) of next on/off toggle; 0 = uninitialized
        _last_command = nil, -- most recent dispatched command name
        _command_before_this = nil, -- command before the most recent
        _last_complex_command = nil, -- most recent command-with-args, for repeat-complex-command
    }, Editor)
    editor.event_system = EventSystem.new(editor)
    return editor
end

--- Signal the main loop to exit. Sets the quit flag and wakes select()
--- via the kqueue so it doesn't block until the next keypress.
function Editor:request_quit()
    self._quit_requested = true
    self._wake_main()
end

----------------------------------------------------------------------------------------------------
-- Cursor blink
----------------------------------------------------------------------------------------------------

-- The real (hardware) terminal caret is always hidden; the caret is
-- drawn by render() as a reverse-video cell and toggled on/off here by
-- a timer advanced from the main select() loop. The phase is reset to
-- "on" (and the next-toggle deadline pushed forward) whenever input is
-- processed, so the caret stays solid while the user is actively typing
-- and only blinks after a half-period of idleness.
local BLINK_HALF_US = 530000

local function now_us()
    local tv = ffi.new("struct timeval[1]")
    pffi.C.gettimeofday(tv, nil)
    return tonumber(tv[0].tv_sec) * 1000000 + tonumber(tv[0].tv_usec)
end

--- Advance the blink timer. Returns true if the on/off phase changed
--- since the last call (the caller re-renders regardless; this is mostly
--- informational). Lazily initializes the deadline on first call.
---@return boolean changed
function Editor:tick_blink()
    local now = now_us()
    if self._blink_next_us == 0 then
        self._blink_on = true
        self._blink_next_us = now + BLINK_HALF_US
        return false
    end
    local changed = false
    while now >= self._blink_next_us do
        self._blink_on = not self._blink_on
        self._blink_next_us = self._blink_next_us + BLINK_HALF_US
        changed = true
        -- Guard against clock jumps backwards in time leaving us stuck.
        if self._blink_next_us < now then
            self._blink_next_us = now + BLINK_HALF_US
            break
        end
    end
    return changed
end

--- Reset the blink to the "on" phase and push the next toggle deadline
--- forward. Called whenever input is processed so the caret stays solid
--- while the user is actively typing.
function Editor:reset_blink()
    self._blink_on = true
    self._blink_next_us = now_us() + BLINK_HALF_US
end

--- Rebuild the active keybind trie by merging the active view's mode
--- keybindings on top of the base trie. Called when the mode changes.
function Editor:rebuild_active_trie()
    local keybind = require("cursed.keybind")
    local view = self:focused_view()
    if view and #view._major_modes > 0 then
        -- Merge: start from a copy of base keybindings, then overlay each mode in order
        local merged = {}
        for k, v in pairs(self._base_keybindings) do
            merged[k] = v
        end
        for _, mode in ipairs(view._major_modes) do
            if next(mode.keybindings) then
                for k, v in pairs(mode.keybindings) do
                    merged[k] = v
                end
            end
        end
        self._active_trie = keybind.Trie.build(merged)
        -- Shortcuts shown in M-x reflect the active major mode's overrides.
        self._chord_for_command = keybind.build_chord_for_command(merged)
    else
        self._active_trie = self._base_trie
        -- Rebuild from base bindings so the map is fresh even with no modes.
        self._chord_for_command = keybind.build_chord_for_command(self._base_keybindings)
    end
    self._trie_changed = true
end

--- Schedule a function to run incrementally on the main thread.
--- The function is called once per main-loop iteration (round-robin
--- with other background tasks). If it returns true, it is removed
--- from the queue; false/nil means it will be called again next time.
---@param fn fun(): boolean?
function Editor:push_background_task(fn)
    self._background_tasks[#self._background_tasks + 1] = fn
end

--- Execute one step of a single background task per call (round-robin).
--- Call this once per main-loop iteration.
function Editor:tick_background_tasks()
    local tasks = self._background_tasks
    if #tasks == 0 then
        return
    end
    local fn = table.remove(tasks, 1)
    local done = fn()
    if not done then
        tasks[#tasks + 1] = fn -- re-queue at the end
    end
end

----------------------------------------------------------------------------------------------------
-- View management
----------------------------------------------------------------------------------------------------

--- Set the active view index and rebuild the keybind trie
--- if the new view has a different mode.
---@param idx integer 1-based index into self.views
function Editor:set_active_view(idx)
    self.active_view = idx
    self:rebuild_active_trie()
end

--- Get the active view.
---@return View|nil
function Editor:current_view()
    if self.active_view >= 1 and self.active_view <= #self.views then
        return self.views[self.active_view]
    end
    return nil
end

--- Add a view to the editor and make it active.
---@param view View
function Editor:add_view(view)
    view.editor = self
    table.insert(self.views, view)
    --    self.active_view = #self.views
    self:set_active_view(#self.views)
end

--- Close a view and fix up the active_view index.
--- If the closed view was active, selects the nearest neighbor.
---@param view View
function Editor:close_view(view)
    local idx = 0
    for i, v in ipairs(self.views) do
        if v == view then
            idx = i
            break
        end
    end
    if idx == 0 then
        return
    end
    table.remove(self.views, idx)
    if #self.views == 0 then
        self:set_active_view(0)
    elseif self.active_view > #self.views then
        self:set_active_view(#self.views)
    elseif idx <= self.active_view then
        self:set_active_view(math.max(1, self.active_view - 1))
    end
end

----------------------------------------------------------------------------------------------------
-- Keybinding-driven operations (delegate to active view + buffer)
----------------------------------------------------------------------------------------------------

-- Note: editing ops (insert_char, delete_char, insert_newline,
-- delete_selection) live on View and are called directly.
-- Editor keeps only genuinely editor-level orchestration below.

--- Undo the last edit.
function Editor:undo()
    local view = self:focused_view()
    if not view then
        return
    end
    if not view:undo() then
        self.status_message = "no further undo information"
    end
end

--- Redo the last undone edit.
function Editor:redo()
    local view = self:focused_view()
    if not view then
        return
    end
    if not view:redo() then
        self.status_message = "no further redo information"
    end
end

--- Open a file in a new view.
--- Expands ~ and $ENV in the path, creates a new Buffer + View,
--- and requests the IO lane to load the file contents.
---@param filepath string raw path from the user (may contain ~, $ENV)
function Editor:open_file(filepath)
    local expanded = find_file.expand_path(filepath)

    -- Refuse to open directories
    if find_file.is_directory(expanded) then
        self.status_message = "cannot open directory: " .. filepath
        return
    end

    local buf = Buffer.new()
    buf:set_filepath(expanded)
    local view = View.new(buf)
    self:add_view(view)

    -- Request IO lane to load the file
    local ss = shared.SharedState.from_global()
    ss:push(ss._ptr.outbox_io, { type = shared.MSG_FILE_LOAD, ptr = expanded })
end

--- Insert a file's contents at the cursor (async via IO lane).
---@param filepath string raw path from the user (may contain ~, $ENV)
function Editor:insert_file(filepath)
    local expanded = find_file.expand_path(filepath)

    if find_file.is_directory(expanded) then
        self.status_message = "cannot insert directory: " .. filepath
        return
    end

    local ss = shared.SharedState.from_global()
    ss:push(ss._ptr.outbox_io, { type = shared.MSG_INSERT_FILE, ptr = expanded })
end

--- Save the current buffer to its filepath (async via IO lane).
function Editor:save()
    local view = self:current_view()
    if not view then
        return
    end
    local buf = view.buffer
    local fp = buf:filepath()
    if fp == nil then
        self.status_message = "no file"
        return
    end
    self:_async_save(buf)
end

--- Save the current buffer to a new filepath (async via IO lane).
---@param filepath string raw path from the user (may contain ~, $ENV)
function Editor:save_as(filepath)
    local view = self:current_view()
    if not view then
        return
    end
    local expanded = find_file.expand_path(filepath)
    view.buffer:set_filepath(expanded)
    self:_async_save(view.buffer)
end

--- Internal: serialize buffer to mmap and dispatch to IO lane.
---@param buf Buffer
function Editor:_async_save(buf)
    local fp = buf:filepath()
    if fp == nil then
        self.status_message = "no file"
        return
    end

    local data, len, cap = buf:serialize_to_mmap()

    -- Allocate SaveRequest on the heap
    local req = ffi.cast("struct SaveRequest *", c.calloc(1, ffi.sizeof("struct SaveRequest")))
    if req == nil then
        ffi.C.munmap(data, cap)
        self.status_message = "save failed"
        return
    end
    req.data = data
    req.data_len = len
    req.data_cap = cap

    -- Copy filepath into heap C string
    local fp_buf = ffi.cast("char *", c.calloc(#fp + 1, 1))
    if fp_buf == nil then
        ffi.C.munmap(data, cap)
        c.free(req)
        self.status_message = "save failed"
        return
    end
    ffi.copy(fp_buf, fp)
    req.filepath = fp_buf

    local ss = shared.SharedState.from_global()
    ss:push(ss._ptr.outbox_io, {
        type = shared.MSG_FILE_SAVE,
        ptr = req,
    })
end

--- Quit the editor.
---@return string
function Editor:quit()
    return "quit"
end

----------------------------------------------------------------------------------------------------
-- Minibuffer
----------------------------------------------------------------------------------------------------

--- Activate the minibuffer to read a line of input from the user.
--- If `opts.value` is non-nil, short-circuits: calls on_submit(value) directly
--- without showing the minibuffer.
---@param opts { prompt: string?, on_submit: function?, on_cancel: function?, on_change: function?, initial: string?, completion: boolean?, completer: function?, value: any?, auto_accept: boolean?, palette: boolean? }
function Editor:read_from_minibuffer(opts)
    -- When replaying a kmacro, pop from the input stack to auto-submit.
    -- This lets commands like find_file, isearch, etc. skip the
    -- interactive minibuffer during replay.
    if #self._mb_input_stack > 0 then
        local value = table.remove(self._mb_input_stack, 1)
        -- Simulate the user typing the answer, then pressing Enter.
        if opts.on_change then
            opts.on_change(value)
        end
        if opts.on_submit then
            opts.on_submit(value)
        end
        return
    end
    if opts.value ~= nil then
        if opts.on_submit then
            opts.on_submit(opts.value)
        end
        return
    end
    self.minibuffer:activate(opts)
end

--- Submit the minibuffer: invoke on_submit with the input text and deactivate.
function Editor:minibuffer_submit()
    if not self.minibuffer or not self.minibuffer.active then
        return
    end
    local input_text = self.minibuffer:view_text()
    self.minibuffer:history_push(input_text)
    -- If recording a kmacro, push this input onto the stack
    if self._recording then
        local stack = self._recorded_mb_inputs
        if stack then
            stack[#stack + 1] = input_text
        end
    end
    local callback = self.minibuffer.on_submit
    self.minibuffer:deactivate()
    -- Flag that minibuffer just closed, so stale Enter/Tab events
    -- in the same drain batch don't dispatch to the main view.
    self._mb_just_closed = 1
    if callback then
        callback(input_text)
    end
end

--- Cancel the minibuffer: invoke on_cancel and deactivate.
function Editor:minibuffer_cancel()
    if not self.minibuffer or not self.minibuffer.active then
        return
    end
    local callback = self.minibuffer.on_cancel
    self.minibuffer:deactivate()
    self._mb_just_closed = 1
    if callback then
        callback()
    end
end

--- Fire minibuffer on_change if text has changed. Called from the main loop.
function Editor:minibuffer_notify_change()
    if self.minibuffer then
        self.minibuffer:notify_change()
    end
end

----------------------------------------------------------------------------------------------------
-- Read-char (one-shot single-key input)
----------------------------------------------------------------------------------------------------

--- Start a one-shot read-char interaction. The next key event's
--- character (or `nil` if the user cancels with C-g/Escape) is passed
--- to `callback`. Used by quoted-insert (C-q), zap-to-char (M-z),
--- and zap-up-to-char (M-Z).
---
--- The prompt is shown in the status area (left of the modeline)
--- so the user knows what is being read; the main loop checks
--- `editor:_read_char_consume(token, ch)` after every key event,
--- which returns true if the event was consumed.
---@param prompt string short prompt (e.g. "Zap to char: ")
---@param callback fun(ch: string|nil) called with the char (or nil on cancel)
function Editor:read_char(prompt, callback)
    self._read_char_cb = callback
    self._read_char_prompt = prompt
end

--- Try to consume a key event for an active read-char interaction.
--- Returns true if the event was consumed (the caller must not
--- dispatch it further). On consume, clears the one-shot callback.
--- C-g / Escape cancel (callback called with nil, returns true).
--- Any printable byte feeds the callback with that character.
--- Non-printable keys (arrows, function keys, chords) are ignored
--- so the user can still e.g. move the cursor; they return false
--- and dispatch normally. The read-char interaction stays active.
---@param token string|nil key token from event_to_token
---@param ch string|nil printable character (1 byte) if the event is printable
---@return boolean consumed
function Editor:_read_char_consume(token, ch)
    if self._read_char_cb == nil then
        return false
    end
    if token == "ctrl-g" or token == "escape" then
        local cb = self._read_char_cb
        self._read_char_cb = nil
        self._read_char_prompt = ""
        if cb then
            cb(nil)
        end
        return true
    end
    if ch and #ch == 1 then
        -- Avoid Control characters (the is_printable filter in main
        -- already excludes them, but guard anyway).
        local byte = ch:byte(1)
        if byte >= 32 then
            local cb = self._read_char_cb
            self._read_char_cb = nil
            self._read_char_prompt = ""
            if cb then
                cb(ch)
            end
            return true
        end
    end
    return false
end

--- Active read-char prompt for modeline display, or nil.
---@return string|nil
function Editor:read_char_status()
    if self._read_char_cb ~= nil then
        return self._read_char_prompt
    end
    return nil
end

----------------------------------------------------------------------------------------------------
-- Universal argument (C-u)
----------------------------------------------------------------------------------------------------

--- Start universal argument collection.
--- Activates the minibuffer with a C-u prompt. Printable characters
--- are collected as the argument text; chord keys terminate and
--- dispatch the command with the universal args.
---@param count integer? initial C-u count (default 1)
function Editor:start_universal_arg(count)
    self._universal_active = true
    self._universal_count = count or 1
    self.minibuffer:activate({
        prompt = self:_universal_prompt(),
        on_cancel = function()
            self:cancel_universal_arg()
        end,
    })
end

--- Toggle the universal flag (called when C-u is pressed during collection).
function Editor:toggle_universal_arg()
    self._universal_count = self._universal_count + 1
    self.minibuffer.prompt = self:_universal_prompt()
end

--- Build the prompt string showing the current C-u state.
---@return string
function Editor:_universal_prompt()
    local cu_str = string.rep("C-u", self._universal_count)
    return cu_str .. " "
end

--- Cancel universal argument collection.
function Editor:cancel_universal_arg()
    self._universal_active = false
    self._universal_count = 0
    self.universal_args = nil
end

--- Compute and store the universal argument list from current state.
--- Called when a command key is pressed during universal arg collection.
--- The args are stored on editor.universal_args for the command to read.
function Editor:get_universal_args()
    local universal_arg = require("cursed.universal_arg")
    local input = self.minibuffer:view_text()
    local args = universal_arg.build_universal_args(self._universal_count, input)
    self._universal_active = false
    self._universal_count = 0
    self.minibuffer:deactivate()
    self.universal_args = args
end

----------------------------------------------------------------------------------------------------
-- M-digit / M-- prefix argument
----------------------------------------------------------------------------------------------------

--- Start or continue digit argument accumulation from an M-digit key.
--- M-3 M-0 → value becomes 30.
---@param digit integer 0-9
function Editor:accumulate_digit(digit)
    if not self._digit_active then
        self._digit_active = true
        self._digit_value = digit
        self._digit_negative = false
    else
        self._digit_value = self._digit_value * 10 + digit
    end
    self.status_message =
        string.format("Arg: %d", self._digit_negative and -self._digit_value or self._digit_value)
end

--- Set the negative flag for M--.
function Editor:set_digit_negative()
    if not self._digit_active then
        self._digit_active = true
        self._digit_value = 0
    end
    self._digit_negative = true
    if self._digit_value == 0 then
        self.status_message = "Arg: -"
    else
        self.status_message = string.format("Arg: -%d", self._digit_value)
    end
end

--- Commit the accumulated digit argument into universal_args.
--- Called when a command key is pressed during digit accumulation.
--- Builds { flag, value } where flag is false when negative.
--- The value is always positive; direction is encoded in the flag
--- (consistent with C-u's flag semantics).
function Editor:commit_digit_arg()
    local flag = not self._digit_negative
    local value = self._digit_value
    log.info(
        "editor",
        "commit_digit_arg",
        { flag = flag, value = value, negative = self._digit_negative }
    )
    if value == 0 and not self._digit_negative then
        -- M-0 alone: numeric arg 0
        self.universal_args = { true, 0 }
    elseif value == 0 and self._digit_negative then
        -- M-- alone: flag=false (like bare C-u)
        self.universal_args = { false }
    else
        -- M-N or M-- M-N: value is positive, direction in flag
        self.universal_args = { flag, value }
    end
    self._digit_active = false
    self._digit_value = 0
    self._digit_negative = false
end

--- Cancel digit argument accumulation.
function Editor:cancel_digit_arg()
    self._digit_active = false
    self._digit_value = 0
    self._digit_negative = false
end

----------------------------------------------------------------------------------------------------
-- Kill ring (consecutive-kill merging)
----------------------------------------------------------------------------------------------------

--- Push killed text onto the kill ring, merging with the previous
--- entry if the last command was also a kill.
--- This implements Emacs' consecutive-kill merging: C-k C-k produces
--- one kill ring entry (the two kills appended), not two separate entries.
---@param text string killed text to push or append
function Editor:push_kill(text)
    if #text == 0 then
        return
    end
    if (self._last_was_kill or self._kill_called) and #kill_ring.ring > 0 then
        -- Append to the top entry (consecutive kill or multiple kills in one command)
        kill_ring.ring[1] = kill_ring.ring[1] .. text
    else
        kill_ring:push(text)
    end
    self._kill_called = true
end

--- Store a pretty-printed eval result to display in the minibuffer area.
---@param value any
function Editor:show_eval_result(value)
    self._eval_result = pprint(value)
end

----------------------------------------------------------------------------------------------------
-- Incremental search (isearch)
----------------------------------------------------------------------------------------------------

--- Start an incremental search from the current cursor position.
---@param direction integer 1=forward, -1=backward
function Editor:start_isearch(direction, initial_query, opts)
    opts = opts or {}
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end

    -- Use selection text as initial query if none provided
    if not initial_query and main_view:p().anchor_line then
        local sl, sc, el, ec = main_view:selection_range()
        if sl then
            ---@cast sc integer
            ---@cast el integer
            ---@cast ec integer
            initial_query = main_view:text_between(sl, sc, el, ec)
        end
    end

    -- Save original point for C-g cancel
    self._isearch_origin_line = main_view:p().line
    self._isearch_origin_col = main_view:p().col
    self._isearch_direction = direction
    self._isearch_regex = opts.regex == true

    local prompt
    if opts.regex then
        prompt = direction > 0 and "Search regexp: " or "Search backward regexp: "
    else
        prompt = direction > 0 and "Search: " or "Search backward: "
    end

    -- When replaying a kmacro, use 'value' to auto-submit the query
    -- instead of opening an interactive minibuffer.
    local mb_opts = {
        prompt = prompt,
        completion = true,
        on_change = function(query)
            self:_isearch_update(query)
        end,
        on_submit = function(_query)
            -- Keep cursor at match, mark stays for C-x C-x jump-back
            self._isearch_origin_line = nil
            self._isearch_origin_col = nil
        end,
        on_cancel = function()
            -- Restore original point
            local mv = self:current_view()
            if mv and self._isearch_origin_line then
                mv:p().line = self._isearch_origin_line
                mv:p().col = self._isearch_origin_col
                mv:_set_goal_col(mv:p().col)
                mv:unset_mark()
            end
            self._isearch_origin_line = nil
            self._isearch_origin_col = nil
            self._isearch_regex = nil
        end,
    }

    mb_opts.initial = initial_query

    self:read_from_minibuffer(mb_opts)
end

--- Build a search iterator for the active isearch mode (plain or
--- regexp) in the given direction.
---@param buf Buffer
---@param query string
---@param start table start point {line, offset}
---@param direction integer 1=forward, -1=backward
---@return function|nil iter
---@return string|nil errmsg
function Editor:_isearch_iter(buf, query, start, direction)
    if self._isearch_regex then
        -- POSIX extended regex via TRE (case-sensitive), reusing the
        -- same search_regex / search_regex_backward path as
        -- replace_regexp for consistency.
        local icase = false
        if direction > 0 then
            return buf:search_regex(query, start, icase)
        else
            return buf:search_regex_backward(query, start, icase)
        end
    end
    if direction > 0 then
        return buf:search_forward(query, start, true)
    else
        return buf:search_backward(query, start, true)
    end
end

--- Jump to the next isearch match (C-s while in isearch).
function Editor:isearch_next()
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end
    local query = self.minibuffer:view_text()
    if #query == 0 then
        return
    end

    local buf = main_view.buffer
    -- Search forward from end of current match
    local start = { line = main_view:p().line, offset = main_view:p().col }
    local iter, err = self:_isearch_iter(buf, query, start, 1)
    if not iter then
        self.status_message = "invalid regexp: " .. tostring(err)
        return
    end
    local match = iter()
    if match then
        main_view:p().anchor_line = match.line
        main_view:p().anchor_col = match.offset
        main_view:p().line = match.end_line
        main_view:p().col = match.end_offset
        main_view:_set_goal_col(main_view:p().col)
        self.status_message = nil
    else
        self.status_message = "failing search"
    end

    self._isearch_direction = 1
    self.minibuffer.prompt = self._isearch_regex and "Search regexp: " or "Search: "
end

--- Jump to the previous isearch match (C-r while in isearch).
function Editor:isearch_prev()
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end
    local query = self.minibuffer:view_text()
    if #query == 0 then
        return
    end

    local buf = main_view.buffer
    -- Search backward from start of current match
    local start
    if main_view:p().anchor_line then
        start = { line = main_view:p().anchor_line, offset = main_view:p().anchor_col }
    else
        start = { line = main_view:p().line, offset = main_view:p().col }
    end
    local iter, err = self:_isearch_iter(buf, query, start, -1)
    if not iter then
        self.status_message = "invalid regexp: " .. tostring(err)
        return
    end
    local match = iter()
    if match then
        main_view:p().anchor_line = match.line
        main_view:p().anchor_col = match.offset
        main_view:p().line = match.end_line
        main_view:p().col = match.end_offset
        main_view:_set_goal_col(main_view:p().col)
        self.status_message = nil
    else
        self.status_message = "failing search"
    end

    self._isearch_direction = -1
    self.minibuffer.prompt = self._isearch_regex and "Search backward regexp: "
        or "Search backward: "
end

--- Internal: run isearch from the saved origin for the given query.
---@param query string
function Editor:_isearch_update(query)
    if #query == 0 then
        return
    end
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end
    local buf = main_view.buffer
    local start = { line = self._isearch_origin_line, offset = self._isearch_origin_col }
    local iter, err = self:_isearch_iter(buf, query, start, self._isearch_direction)
    if not iter then
        self.status_message = "invalid regexp: " .. tostring(err)
        return
    end
    local match = iter()
    if match then
        main_view:p().anchor_line = match.line
        main_view:p().anchor_col = match.offset
        main_view:p().line = match.end_line
        main_view:p().col = match.end_offset
        main_view:_set_goal_col(main_view:p().col)
        self.status_message = nil
    end
end

----------------------------------------------------------------------------------------------------
-- Query replace
----------------------------------------------------------------------------------------------------

--- Start an incremental query-replace session.
--- Step 1: minibuffer for search string (incremental highlight like isearch)
--- Step 2: minibuffer for replacement string
--- Step 3: auto-accept minibuffer with yes/no/all to walk matches
---@param initial_query string? optional pre-fill from selection
function Editor:start_query_replace(initial_query)
    local main_view = self:current_view()
    if not main_view or not main_view.file_loaded then
        return
    end

    -- Use selection text as initial query if none provided
    if not initial_query and main_view:p().anchor_line then
        local sl, sc, el, ec = main_view:selection_range()
        if sl then
            ---@cast sc integer
            ---@cast el integer
            ---@cast ec integer
            initial_query = main_view:text_between(sl, sc, el, ec)
        end
    end

    -- Save point for C-g cancel
    local origin_line = main_view:p().line
    local origin_col = main_view:p().col

    self:read_from_minibuffer({
        prompt = "Query replace: ",
        initial = initial_query,
        on_change = function(query)
            if #query == 0 then
                return
            end
            local mv = self:current_view()
            if not mv then
                return
            end
            local buf = mv.buffer
            local start = { line = mv:p().line, offset = mv:p().col }
            local iter = buf:search_forward(query, start, true)
            local match = iter()
            if match then
                mv:p().anchor_line = match.line
                mv:p().anchor_col = match.offset
                mv:p().line = match.end_line
                mv:p().col = match.end_offset
                mv:_set_goal_col(mv:p().col)
            end
        end,
        on_submit = function(query)
            if #query == 0 then
                return
            end
            self:_query_replace_step2(query, origin_line, origin_col)
        end,
        on_cancel = function()
            local mv = self:current_view()
            if mv then
                mv:p().line = origin_line
                mv:p().col = origin_col
                mv:_set_goal_col(origin_col)
                mv:unset_mark()
            end
        end,
    })
end

--- Step 2 of query-replace: ask for the replacement string.
---@param query string the search string
---@param origin_line integer cursor line before the whole operation
---@param origin_col integer cursor col before the whole operation
function Editor:_query_replace_step2(query, origin_line, origin_col)
    self:read_from_minibuffer({
        prompt = "Query replace " .. query .. " with: ",
        on_submit = function(replacement)
            self:_query_replace_step3(query, replacement, origin_line, origin_col)
        end,
        on_cancel = function()
            local mv = self:current_view()
            if mv then
                mv:p().line = origin_line
                mv:p().col = origin_col
                mv:_set_goal_col(origin_col)
                mv:unset_mark()
            end
        end,
    })
end

--- Step 3 of query-replace: walk matches with yes/no/all auto-accept.
---@param query string
---@param replacement string
---@param origin_line integer
---@param origin_col integer
function Editor:_query_replace_step3(query, replacement, origin_line, origin_col)
    local main_view = self:current_view()
    if not main_view then
        return
    end

    -- Start search from the saved origin (before step 1 highlighting moved the cursor)
    main_view:p().line = origin_line
    main_view:p().col = origin_col
    main_view:unset_mark()

    -- Find the first match
    local buf = main_view.buffer
    local start = { line = origin_line, offset = origin_col }
    local iter = buf:search_forward(query, start, true)
    local match = iter()

    if not match then
        self.status_message = "no matches"
        -- Restore origin
        main_view:p().line = origin_line
        main_view:p().col = origin_col
        main_view:_set_goal_col(origin_col)
        return
    end

    -- Highlight the first match
    main_view:p().anchor_line = match.line
    main_view:p().anchor_col = match.offset
    main_view:p().line = match.end_line
    main_view:p().col = match.end_offset
    main_view:_set_goal_col(main_view:p().col)

    self:_query_replace_prompt(query, replacement)
end

--- Show the yes/no/all auto-accept prompt for the current match.
---@param query string
---@param replacement string
function Editor:_query_replace_prompt(query, replacement)
    self:read_from_minibuffer({
        prompt = "Replace? ",
        completion = true,
        auto_accept = true,
        completer = completers.yes_no_all(),
        on_submit = function(answer)
            log.info("replace", "on_submit", { answer = answer })
            answer = answer:lower()
            if answer == "y" then
                if self:_query_replace_one(query, replacement) then
                    if self:_query_replace_find_next(query) then
                        self:_query_replace_prompt(query, replacement)
                    end
                end
            elseif answer == "a" then
                self:_query_replace_all(query, replacement)
            else -- "n"
                if self:_query_replace_find_next(query) then
                    self:_query_replace_prompt(query, replacement)
                end
            end
        end,
        on_cancel = function()
            local mv = self:current_view()
            if mv then
                mv:unset_mark()
            end
        end,
    })
end

--- Replace the currently-highlighted match and return true if successful.
---@param query string
---@param replacement string
---@return boolean
function Editor:_query_replace_one(query, replacement)
    local main_view = self:current_view()
    if not main_view then
        return false
    end
    local buf = main_view.buffer

    if not main_view:p().anchor_line then
        return false
    end

    local sl, sc, el, ec = main_view:selection_range()
    if not sl then
        return false
    end
    ---@cast sc integer
    ---@cast el integer
    ---@cast ec integer

    local n = main_view:chars_between(sl, sc, el, ec)
    if n > 0 then
        buf:begin_edit()
        buf:delete_char(sl, sc, n)
        local rl, rc = buf:insert_char(sl, sc, replacement)
        buf:end_edit()
        main_view:p().line = rl
        main_view:p().col = rc
        main_view:_set_goal_col(rc)
    else
        main_view:p().line = sl
        main_view:p().col = sc
        main_view:_set_goal_col(sc)
    end
    main_view:unset_mark()
    return true
end

--- Find the next match and highlight it. Returns false if no more matches.
---@param query string
---@return boolean
function Editor:_query_replace_find_next(query)
    local main_view = self:current_view()
    if not main_view then
        return false
    end
    local buf = main_view.buffer
    local start = { line = main_view:p().line, offset = main_view:p().col }
    local iter = buf:search_forward(query, start, true)
    local match = iter()

    if not match then
        self.status_message = "no more matches"
        return false
    end

    main_view:p().anchor_line = match.line
    main_view:p().anchor_col = match.offset
    main_view:p().line = match.end_line
    main_view:p().col = match.end_offset
    main_view:_set_goal_col(main_view:p().col)
    return true
end

--- Replace all remaining matches by chaining through the minibuffer.
--- Each replacement yields back to the event loop, avoiding
--- long synchronous mutation chains that corrupt piece table state.
---@param query string
---@param replacement string
function Editor:_query_replace_all(query, replacement)
    local main_view = self:current_view()
    if not main_view then
        return
    end
    local buf = main_view.buffer

    -- Single edit group: one undo step for the entire replace-all.
    -- The group spans multiple main-loop iterations (funky but fine).
    buf:begin_edit()
    local count = 0
    self:push_background_task(function()
        if not self:_query_replace_one(query, replacement) then
            buf:end_edit()
            self.status_message = "replaced " .. count .. " occurrences"
            return true -- done
        end
        count = count + 1
        if count % 100 == 0 then
            log.info("replace", "progress", { count = count })
        end
        if not self:_query_replace_find_next(query) then
            buf:end_edit()
            self.status_message = "replaced " .. count .. " occurrences"
            return true -- done
        end
        return false -- more work
    end)
end

----------------------------------------------------------------------------------------------------
-- Convenience accessors (for keybindings that only have the editor)
----------------------------------------------------------------------------------------------------

--- Get the focused view (minibuffer view when active, otherwise main view).
---@return View|nil
function Editor:focused_view()
    if self.minibuffer and self.minibuffer.active and not self._universal_active then
        return self.minibuffer.view
    end
    return self:current_view()
end

--- Get the active view's buffer.
---@return Buffer|nil
function Editor:buffer()
    local view = self:current_view()
    return view and view.buffer
end

----------------------------------------------------------------------------------------------------
-- Scrolling
----------------------------------------------------------------------------------------------------

---@param height integer terminal height in rows
function Editor:scroll_to_cursor(height)
    local view = self:current_view()
    if view then
        view:scroll_to_cursor(height)
    end
end

--- Get the number of footer rows (modeline + minibuffer input rows + completions + eval).
---@return integer
function Editor:footer_rows()
    local mb = self.minibuffer
    local mb_rows = 0
    if mb and mb.active then
        -- Palette mode floats over the buffer (centered box), so it
        -- reserves NO bottom rows — only the modeline does.
        if not mb.palette then
            mb_rows = mb:input_rows()
        end
    elseif self._eval_result then
        mb_rows = 1
    end
    local comp_rows = (mb and mb.active and not mb.palette and mb.completion)
            and mb:comp_visible_rows()
        or 0
    return 1 + mb_rows + comp_rows
end

----------------------------------------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------------------------------------

--- Render the entire viewport.
function Editor:render()
    local term = self.term
    local w = term:width()
    local h = term:height()
    -- Defensive backstop: clamp all cursors before reading them for
    -- rendering so a stale past-eol position can never produce a broken
    -- caret / modeline. Motions/edits already clamp, but cursor state
    -- can also be set by undo/redo, file reload, or mode activation.
    for _, v in ipairs(self.views) do
        if v.file_loaded then
            v:_clamp_all_cursors()
        end
    end
    term:clear(ui("default_fg"), ui("default_bg"))
    -- The hardware terminal caret is always hidden; the caret is drawn
    -- as a reverse-video cell (toggled on/off by the blink timer)
    -- wherever it should appear (main view + minibuffer).
    term:hide_cursor()

    --- Paint a text chunk's base layer with syntax-highlight spans.
    --- Falls back to a single plain-default print when highlighting is off
    --- or the chunk has no spans. Overlays (selection/cursor/drops) are
    --- painted afterwards by the caller and override these segments.
    --- row_bg: background to paint text-region cells with, so the
    --- active-line highlight carries through the syntax spans (which
    --- would otherwise repaint with default_bg). Defaults to
    --- default_bg for non-active rows.
    local function paint_chunk(view, li, row, gutter_width, chunk, chunk_start, chunk_end, row_bg)
        local segs = view:highlight_segments(li, chunk_start, chunk_end)
        local dfg = ui("default_fg")
        local dbg = row_bg or ui("default_bg")
        if segs == nil or #segs == 0 then
            term:print(gutter_width, row, chunk, dfg, dbg)
            return
        end
        local painted = 0 -- byte offset within chunk already painted
        for _, s in ipairs(segs) do
            if s.cs > painted then
                term:print(gutter_width + painted, row, chunk:sub(painted + 1, s.cs), dfg, dbg)
            end
            if s.ce > s.cs then
                term:print(gutter_width + s.cs, row, chunk:sub(s.cs + 1, s.ce), s.fg, dbg)
            end
            if s.ce > painted then
                painted = s.ce
            end
        end
        if painted < #chunk then
            term:print(gutter_width + painted, row, chunk:sub(painted + 1), dfg, dbg)
        end
    end

    local view = self:current_view()
    local mb = self.minibuffer
    -- Footer rows: modeline + optional completions row + minibuffer/eval
    local footer_rows = self:footer_rows()
    local has_completions = mb and mb.active and mb.completion and #mb._completions > 0

    if not view or not view.file_loaded then
        local msg = "Loading..."
        local x = math.floor(w / 2) - math.floor(#msg / 2)
        local y = math.floor(h / 2)
        term:print(x, y, msg, ui("default_fg"), ui("default_bg"))
        term:present()
        return
    end

    local buf = view.buffer
    local line_count = buf:line_count()
    local max_y = h - footer_rows - 1

    -- Gutter width
    local gutter_width = math.max(3, #tostring(line_count) + 1)
    local text_width = w - gutter_width
    if text_width <= 0 then
        term:present()
        return
    end

    -- Soft wrapping: set wrap_width to the text area width
    -- so the cache stays consistent with the current window size.
    local reflowed = false
    if view.wrap_width ~= text_width then
        view.wrap_width = text_width
        view:invalidate_wrap_cache()
        reflowed = true
    else
        -- Invalidate if buffer has been edited since last cache build
        local gen = tonumber(view.buffer._ptr.undo.count) + tonumber(view.buffer._ptr.redo.count)
        if view._wrap_gen ~= gen then
            view:invalidate_wrap_cache()
            view._wrap_gen = gen
        end
    end
    -- A resize-driven reflow shifts the cursor's screen row even when
    -- its logical (line, col) is unchanged; force a same-frame re-scroll
    -- (the guard would otherwise skip it and we'd lag a frame behind).
    if reflowed then
        view:scroll_to_cursor(h - footer_rows + 1, true)
    end

    -- Render visible lines (screen-row based)
    -- Clamp scroll_y so we never start past the document
    local total_screen = view:total_screen_rows()
    local max_scroll = math.max(0, total_screen - (max_y + 1))
    if view.scroll_y > max_scroll then
        view.scroll_y = max_scroll
    end

    -- Notify the highlighter of the visible viewport's byte range so its
    -- lazy dispatcher (View:_hl_tick) can queue queries for absent buckets.
    do
        local vstart_li, _ = view:screen_row_to_line(view.scroll_y)
        local vend_li, _ =
            view:screen_row_to_line(math.min(view.scroll_y + max_y, math.max(total_screen - 1, 0)))
        local starts = view:_hl_line_starts()
        local vstart_byte = starts[vstart_li + 1] or 0
        local vend_byte = (starts[vend_li + 2] or starts[#starts] or 0)
        if vend_byte > 0 then
            vend_byte = vend_byte - 1 -- exclude trailing \n of last visible line
        end
        view:_hl_notify_viewport(vstart_byte, vend_byte)
    end

    local row = 0
    local li, sub_row = view:screen_row_to_line(view.scroll_y)
    while row <= max_y and li < line_count do
        local line_text = buf:line_text(li)
        local display_text = line_text
        if #display_text > 0 and display_text:byte(#display_text) == 10 then
            display_text = display_text:sub(1, #display_text - 1)
        end

        local content_len = #display_text
        local total_sub = view:wrap_rows(li)
        -- Indent-guide columns (text-relative, 0-based) for this line:
        -- one │ at the LAST whitespace cell of each indent level (i.e.
        -- at ts-1, 2·ts-1, …). Placing the guide on the boundary cell
        -- (ts, 2·ts, …) would paint over the first real character when
        -- lead_w is an exact multiple of ts; g-1 stays within the
        -- leading whitespace. Computed once per logical line; only the
        -- first sub-row actually paints them (indentation lives at col 0).
        local guide_cols = {}
        do
            local ts = view.tab_width
            if ts and ts > 0 then
                local lead_w, i = 0, 1
                while i <= #display_text do
                    local b = display_text:byte(i)
                    if b == 32 then
                        lead_w = lead_w + 1
                    elseif b == 9 then
                        lead_w = (math.floor(lead_w / ts) + 1) * ts
                    else
                        break
                    end
                    i = i + 1
                end
                local g = ts
                while g <= lead_w do
                    guide_cols[#guide_cols + 1] = g - 1
                    g = g + ts
                end
            end
        end

        -- Render sub-rows for this logical line
        while sub_row < total_sub and row <= max_y do
            local ok, err = pcall(function()
                -- Active-line highlight: tint the whole row (gutter→edge)
                -- when this logical line holds the primary cursor, and
                -- brighten its line number. The single biggest "modern
                -- editor" cue in a TUI.
                local is_active = (view:p().line == li)
                local row_bg = is_active and ui("active_line_bg") or ui("default_bg")
                local num_fg = is_active and ui("line_number_active") or ui("line_number")
                -- Pre-fill the entire row with row_bg so the active tint
                -- spans the gutter, the text region, and the trailing
                -- margin (paint_chunk + overlays paint on top of this).
                term:print(0, row, string.rep(" ", w), row_bg, row_bg)
                -- Gutter: line number on first sub-row, blank on wrapped
                -- continuation rows. Painted on row_bg so the active tint
                -- shows through the gutter.
                if sub_row == 0 then
                    local line_num = tostring(li + 1)
                    local num_pad = string.rep(" ", gutter_width - 1 - #line_num)
                    term:print(0, row, num_pad .. line_num .. " ", num_fg, row_bg)
                else
                    term:print(0, row, string.rep(" ", gutter_width), num_fg, row_bg)
                end

                -- Extract the sub-row's text chunk
                local chunk_start = sub_row * text_width
                local chunk_end = math.min(chunk_start + text_width, content_len)
                local chunk = display_text:sub(chunk_start + 1, chunk_end)
                if chunk_start < content_len then
                    -- Selection rendering: build the union of selected
                    -- column ranges for THIS chunk across ALL cursors
                    -- (multi-cursor selections render together).
                    -- sel_runs: list of {cs, ce} clamped to this chunk,
                    -- then merged for overlapping spans.
                    local sel_runs = {}
                    for rsl, rsc, rel, rec in view:selection_ranges() do
                        ---@cast rsl integer
                        ---@cast rsc integer
                        ---@cast rel integer
                        ---@cast rec integer
                        if li >= rsl and li <= rel then
                            local cs = (li == rsl) and math.max(rsc, 0) or 0
                            local ce = (li == rel) and math.min(rec, content_len) or content_len
                            local chunk_cs = math.max(cs, chunk_start)
                            local chunk_ce = math.min(ce, chunk_end)
                            if chunk_cs < chunk_ce then
                                sel_runs[#sel_runs + 1] = { chunk_cs, chunk_ce }
                            end
                        end
                    end
                    table.sort(sel_runs, function(a, b)
                        return a[1] < b[1]
                    end)
                    -- Merge overlapping/adjacent runs
                    local merged = {}
                    for _, r in ipairs(sel_runs) do
                        if #merged > 0 and r[1] <= merged[#merged][2] then
                            merged[#merged][2] = math.max(merged[#merged][2], r[2])
                        else
                            merged[#merged + 1] = { r[1], r[2] }
                        end
                    end

                    if #merged == 0 then
                        -- Base layer only: syntax-highlighted spans.
                        paint_chunk(
                            view,
                            li,
                            row,
                            gutter_width,
                            chunk,
                            chunk_start,
                            chunk_end,
                            row_bg
                        )
                    else
                        -- Base layer (highlight) first, then overlay each
                        -- selection run in reverse-video on top.
                        paint_chunk(
                            view,
                            li,
                            row,
                            gutter_width,
                            chunk,
                            chunk_start,
                            chunk_end,
                            row_bg
                        )
                        for _, r in ipairs(merged) do
                            local rel_cs = r[1] - chunk_start
                            local rel_ce = r[2] - chunk_start
                            if rel_cs < 0 then
                                rel_cs = 0
                            end
                            if rel_ce > #chunk then
                                rel_ce = #chunk
                            end
                            if rel_ce > rel_cs then
                                -- Whitespace visualization inside the
                                -- selection: spaces → middle dot (·),
                                -- tabs → arrow (→), and a ↵ (U+21B5)
                                -- shown at end-of-line when the
                                -- selection reaches the line's trailing
                                -- newline. Makes trailing/leading
                                -- whitespace and line-spanning
                                -- selections visible exactly where the
                                -- user is operating. Buffer is untouched.
                                local sel_text =
                                    chunk:sub(rel_cs + 1, rel_ce):gsub(" ", "·"):gsub("\t", "→")
                                term:print(
                                    gutter_width + rel_cs,
                                    row,
                                    sel_text,
                                    ui("cursor_fg"),
                                    ui("selection_bg")
                                )
                                -- Newline marker: this run reaches the
                                -- last cell of the line's last sub-row
                                -- AND the original line had a trailing
                                -- newline → the selection includes EOL,
                                -- so draw ↵ one cell past content.
                                if
                                    rel_ce == #chunk
                                    and chunk_end >= content_len
                                    and #line_text > 0
                                    and line_text:byte(#line_text) == 10
                                then
                                    local nl_x = gutter_width + rel_ce
                                    if nl_x < w then
                                        term:print(
                                            nl_x,
                                            row,
                                            "↵",
                                            ui("cursor_fg"),
                                            ui("selection_bg")
                                        )
                                    end
                                end
                            end
                        end
                    end
                end

                -- Indent guides: faint │ at tab-stop boundaries inside
                -- leading whitespace. Painted AFTER the text layer (which
                -- would otherwise overwrite them with blank space cells)
                -- but BEFORE the cursor overlay. Only on the first sub-row
                -- (the only place indentation lives), and only for guides
                -- that fall within this chunk's range.
                if sub_row == 0 and #guide_cols > 0 then
                    local guide_fg = ui("indent_guide")
                    for _, g in ipairs(guide_cols) do
                        if g >= chunk_start and g < chunk_end then
                            term:print(
                                gutter_width + (g - chunk_start),
                                row,
                                "│",
                                guide_fg,
                                row_bg
                            )
                        end
                    end
                end

                -- Cursor overlay: paint every cursor whose position
                -- falls in THIS sub-row as a reverse-video cell of the
                -- underlying character (or a blank when the cursor is at
                -- end-of-content or on an empty line). Runs OUTSIDE the
                -- chunk-content guard so a cursor on an empty line (no
                -- chunk text) still renders. Symmetric across primary and
                -- secondary cursors.
                for _, c in ipairs(view.cursors) do
                    if self._blink_on and c.line == li then
                        -- Only the sub_row is needed from wrap math to
                        -- decide WHICH row this cursor paints on; the
                        -- column must be the ABSOLUTE byte offset
                        -- (c.col), not the relative sub-col, because
                        -- chunk_start/chunk_end/rel below all work in
                        -- absolute line bytes. Using the sub-col here
                        -- (#0: the cursor vanished on every wrapped,
                        -- non-first sub-row because sub-col <
                        -- chunk_start failed the range guard).
                        local csub_row = select(1, view:wrap_sub_position(li, c.col))
                        if csub_row == sub_row then
                            local ccs = c.col
                            -- Allow the cursor to sit at chunk_end (one
                            -- past the last char of the chunk/line) for
                            -- end-of-content cursors.
                            if ccs >= chunk_start and ccs <= chunk_end then
                                local rel = ccs - chunk_start
                                local ch = chunk:sub(rel + 1, rel + 1)
                                if #ch == 0 then
                                    ch = " "
                                end
                                term:print(
                                    gutter_width + rel,
                                    row,
                                    ch,
                                    ui("cursor_fg"),
                                    ui("cursor_bg")
                                )
                            end
                        end
                    end
                end

                -- Pending-drop markers (drop mode staged by
                -- add_cursor_here before commit_pending_cursors).
                -- Painted with a yellow BACKGROUND so the user can see
                -- where the staged drops are while the primary caret
                -- moves around to drop more. Also runs on empty lines
                -- (see cursor overlay above).
                for _, c in ipairs(view.pending_cursors) do
                    if c.line == li then
                        -- See the active-cursor overlay above: use c.col
                        -- (absolute) not the relative sub-col.
                        local csub_row = select(1, view:wrap_sub_position(li, c.col))
                        if csub_row == sub_row then
                            local ccs = c.col
                            if ccs >= chunk_start and ccs <= chunk_end then
                                local rel = ccs - chunk_start
                                local ch = chunk:sub(rel + 1, rel + 1)
                                if #ch == 0 then
                                    ch = " "
                                end
                                term:print(
                                    gutter_width + rel,
                                    row,
                                    ch,
                                    ui("cursor_fg"),
                                    ui("drop_bg")
                                )
                            end
                        end
                    end
                end
            end)
            if not ok then
                log.error(
                    "editor",
                    "render row failed",
                    { row = row, li = li, sub_row = sub_row, error = tostring(err) }
                )
                break
            end

            sub_row = sub_row + 1
            row = row + 1
        end

        li = li + 1
        sub_row = 0
    end

    -- Cursor (only in main view when minibuffer is inactive)
    if not (mb and mb.active) then
        -- The visible caret is drawn as a reverse-video cell in the
        -- per-chunk loop above (toggled by the blink timer). The
        -- hardware terminal caret is always hidden (see term:hide_cursor
        -- at the top of render), so there is nothing to position here.
    end

    -- Modeline (at row h - footer_rows).
    -- Segmented layout: three colored blocks separated by triangle
    -- separators (◣ ◢, U+25E3 / U+25E2), palette-driven so every theme
    -- recolors it for free. Each section carries a single-cell unicode
    -- icon: ◆ mode, ▤ file, ⌖ position. Transient status (read-char /
    -- search / arg / status_message) replaces the middle section,
    -- keeping mode + pos. Pure core unicode — no Nerd Font required.
    local modeline_y = h - footer_rows
    local dirty = buf:is_dirty()
    --  (Unicode " BALL" U+25CF) is a cleaner "modified" mark than "*".
    local modified = dirty and " ●" or ""
    local path = buf:filepath() or "[no file]"
    local rc_status = self:read_char_status()

    -- Resolve the active major-mode name (top of the view's mode stack).
    local mode_name = "fundamental"
    if #view._major_modes > 0 then
        mode_name = view._major_modes[#view._major_modes].name or mode_name
    end

    -- Colors.
    local mode_fg = ui("modeline_mode_fg")
    local mode_bg = ui("modeline_mode_bg")
    local pos_fg = ui("modeline_pos_fg")
    local pos_bg = ui("modeline_pos_bg")
    local mid_fg = ui("modeline_fg")
    local mid_bg = ui("modeline_bg")

    -- Section icons (single-cell, widely-supported unicode — no Nerd
    -- Font required). ◆ U+25C6, ▤ U+25A4, ⌖ U+2316.
    local ICON_MODE = "◆"
    local ICON_FILE = "▤"
    local ICON_POS = "⌖"

    -- Right segment: position + percentage, with a location icon.
    local pct = math.floor(view:p().line / math.max(1, line_count - 1) * 100)
    local pos_str =
        string.format(" %s %d:%d  %d%% ", ICON_POS, view:p().line + 1, view:p().col + 1, pct)

    -- Middle segment: transient status, else filepath + modified (with
    -- a file icon on the path so it reads as a distinct section).
    local mid_str = rc_status or self.status_message or (ICON_FILE .. " " .. path .. modified)

    -- Pre-fill the row with mid_bg so the gap between mode and pos
    -- blocks (and any trailing margin) is the modeline bg.
    term:print(0, modeline_y, string.rep(" ", w), mid_fg, mid_bg)

    -- Left block: " ◆ mode " in the mode accent, followed by a
    -- triangle separator (◣ U+25E3) whose fg is the mode bg and
    -- whose bg is the mid bg — so the accent edge visibly "bleeds"
    -- into the middle. Core unicode (Geometric Shapes): no Nerd Font.
    local mode_text = " " .. ICON_MODE .. " " .. mode_name .. " "
    local mode_w = cell_len(mode_text)
    term:print(0, modeline_y, mode_text, mode_fg, mode_bg)
    term:print(mode_w, modeline_y, "◣", mode_bg, mid_bg)

    -- Middle block: transient status or filepath+modified. Truncated
    -- to the space between the left separator and the right block.
    local right_w = cell_len(pos_str) + 1 -- +1 for the leading separator
    local mid_max = w - mode_w - 1 - right_w
    if mid_max > 0 then
        mid_str = truncate_cells(mid_str, mid_max)
        term:print(mode_w + 1, modeline_y, mid_str, mid_fg, mid_bg)
    end

    -- Right block: a leading triangle separator (◢ U+25E2, fg =
    -- pos_bg / bg = mid_bg) followed by the position text in the pos
    -- accent. Same core-unicode-only constraint.
    local pos_x = w - cell_len(pos_str)
    term:print(pos_x - 1, modeline_y, "◢", pos_bg, mid_bg)
    term:print(pos_x, modeline_y, pos_str, pos_fg, pos_bg)

    -- Minibuffer — inline bottom strip (search, find-file, read-char,
    -- query-replace, …). NOT used for M-x, which renders as a centered
    -- floating palette (see the `mb.palette` branch below). The
    -- modeline's accent bg already separates the inline strip from the
    -- buffer; no spare row for a border rule (footer_rows accounts for
    -- exactly modeline + minibuffer + completions).
    if mb and mb.active and not mb.palette then
        local mb_view = mb.view
        local mb_buf = mb_view.buffer
        local prompt = mb.prompt
        local line_count = mb_buf:line_count()
        local line_offset = modeline_y + 1

        for li = 0, line_count - 1 do
            local line_text = mb_buf:line_text(li)
            -- Strip trailing newline for display
            if #line_text > 0 and line_text:byte(#line_text) == 10 then
                line_text = line_text:sub(1, #line_text - 1)
            end
            local row = line_offset + li
            if li == 0 then
                -- First line: prompt + text
                term:print(0, row, prompt, ui("minibuffer_prompt"), ui("default_bg"))
                term:print(#prompt, row, line_text, ui("minibuffer_text"), ui("default_bg"))
            else
                -- Subsequent lines: full width
                term:print(0, row, line_text, ui("minibuffer_text"), ui("default_bg"))
            end
        end

        -- Cursor position: the hardware caret is hidden (see top of
        -- render), so we draw the caret as a reverse-video cell, gated
        -- on the blink phase, just like the main view.
        local cursor_row = line_offset + mb_view:p().line
        local cursor_col
        if mb_view:p().line == 0 then
            cursor_col = #prompt + mb_view:p().col
        else
            cursor_col = mb_view:p().col
        end
        if self._blink_on and cursor_col < w then
            local lt = mb_buf:line_text(mb_view:p().line)
            if #lt > 0 and lt:byte(#lt) == 10 then
                lt = lt:sub(1, #lt - 1)
            end
            local bcol = mb_view:p().col
            local ch = lt:sub(bcol + 1, bcol + 1)
            if #ch == 0 then
                ch = " "
            end
            -- Mode-aware caret: the minibuffer uses an underline BAR
            -- (char in the cursor accent color + underline style bit)
            -- so input contexts read distinctly from the main view's
            -- reverse-video block caret.
            local bar_fg = bit.bor(ui("cursor_bg"), tb.underline)
            term:print(cursor_col, cursor_row, ch, bar_fg, ui("default_bg"))
        end

        -- Completions (below minibuffer input, vertical, max 5 visible)
        if has_completions then
            local selected = mb._comp_index or 0
            local scroll = mb._comp_scroll or 0
            local comp_start = line_offset + line_count
            local n = math.min(#mb._completions - scroll, 5)

            -- Compute the metadata column once per render pass: the
            -- longest displayed completion text + a 2-space gap. If the
            -- chord column wouldn't fit at all, skip metadata entirely.
            local max_text = 0
            for i = 1, n do
                local item = mb._completions[scroll + i]
                local tlen = #completers.comp_text(item)
                if tlen > max_text then
                    max_text = tlen
                end
            end
            local meta_col = max_text + 2
            local show_meta = meta_col + 4 <= w
            local meta_fg = ui("minibuffer_metadata")
            local meta_bg = ui("default_bg")

            for i = 1, n do
                local ci = scroll + i
                local row = comp_start + i - 1
                local item = mb._completions[ci]
                local text = completers.comp_text(item)
                local meta = show_meta and completers.comp_meta(item) or nil
                if #text > w then
                    text = text:sub(1, w)
                end
                if ci == selected then
                    -- Selected: reverse-video bar spans the full row.
                    -- Pad text out to the metadata column (or full width
                    -- when metadata won't be drawn) so the highlight is
                    -- contiguous, then print metadata in gray on the
                    -- reverse bg, then fill the remainder.
                    local text_pad_to = (meta and #meta > 0) and meta_col or w
                    if #text < text_pad_to then
                        text = text .. string.rep(" ", text_pad_to - #text)
                    end
                    local cur_fg = ui("cursor_fg")
                    local cur_bg = ui("cursor_bg")
                    term:print(0, row, text, cur_fg, cur_bg)
                    if meta and #meta > 0 and meta_col + #meta <= w then
                        term:print(meta_col, row, meta, cur_fg, cur_bg)
                    end
                    -- Fill remainder of the row with the reverse bg.
                    local filled = (meta and #meta > 0 and meta_col + #meta <= w)
                            and (meta_col + #meta)
                        or text_pad_to
                    if filled < w then
                        term:print(filled, row, string.rep(" ", w - filled), cur_fg, cur_bg)
                    end
                else
                    term:print(0, row, text, ui("minibuffer_prompt"), ui("default_bg"))
                    if meta and #meta > 0 and meta_col + #meta <= w then
                        term:print(meta_col, row, meta, meta_fg, meta_bg)
                    end
                end
            end
        end
    elseif mb and mb.active and mb.palette then
        -- Command-palette mode (M-x): render the minibuffer as a
        -- centered floating box over the buffer, with rounded borders
        -- and the completions listed inside. Width and height are
        -- derived from the content + viewport, clamped to safe bounds.
        -- Painted ON TOP of already-rendered buffer rows (a solid bg
        -- box overwrites whatever was there), so footer_rows doesn't
        -- need to reserve space for it.
        local mb_view = mb.view
        local mb_buf = mb_view.buffer
        local prompt = mb.prompt
        local prompt_w = cell_len(prompt)

        -- Box dimensions.
        local box_w = math.min(math.max(48, prompt_w + 24), w - 4)
        local box_x = math.floor((w - box_w) / 2)
        -- Rows: top border + input + (completions) + bottom border.
        local n_comp = 0
        if has_completions then
            n_comp = math.min(#mb._completions - (mb._comp_scroll or 0), 5)
        end
        local box_h = 2 + 1 + n_comp + 1
        local box_y = math.floor((h - box_h) / 2)

        local border_fg = ui("border")
        local bg = ui("default_bg")
        local prompt_fg = ui("minibuffer_prompt")
        local text_fg = ui("minibuffer_text")
        local meta_fg = ui("minibuffer_metadata")

        -- Clear the box interior with default_bg so it floats over the
        -- buffer cleanly.
        for r = 0, box_h - 1 do
            term:print(box_x, box_y + r, string.rep(" ", box_w), bg, bg)
        end

        -- Top border: ╭─...─╮
        term:print(box_x, box_y, "╭" .. string.rep("─", box_w - 2) .. "╮", border_fg, bg)

        -- Input row: prompt + text.
        local input_y = box_y + 1
        term:print(box_x + 1, input_y, prompt, prompt_fg, bg)
        do
            local lt = mb_buf:line_text(0)
            if #lt > 0 and lt:byte(#lt) == 10 then
                lt = lt:sub(1, #lt - 1)
            end
            local max_text = box_w - 2 - prompt_w
            term:print(box_x + 1 + prompt_w, input_y, truncate_cells(lt, max_text), text_fg, bg)
        end

        -- Caret (underline bar, same as inline minibuffer).
        if self._blink_on then
            local lt = mb_buf:line_text(0)
            if #lt > 0 and lt:byte(#lt) == 10 then
                lt = lt:sub(1, #lt - 1)
            end
            local bcol = mb_view:p().col
            local cursor_col = box_x + 1 + prompt_w + bcol
            if cursor_col < box_x + box_w - 1 then
                local ch = lt:sub(bcol + 1, bcol + 1)
                if #ch == 0 then
                    ch = " "
                end
                local bar_fg = bit.bor(ui("cursor_bg"), tb.underline)
                term:print(cursor_col, input_y, ch, bar_fg, bg)
            end
        end

        -- Completions inside the box.
        if has_completions and n_comp > 0 then
            local selected = mb._comp_index or 0
            local scroll = mb._comp_scroll or 0
            local comp_start = input_y + 1
            local comp_w = box_w - 2 -- interior width
            -- Metadata column: longest displayed text + 2-space gap.
            local max_text = 0
            for i = 1, n_comp do
                local item = mb._completions[scroll + i]
                local tlen = cell_len(completers.comp_text(item))
                if tlen > max_text then
                    max_text = tlen
                end
            end
            local meta_col = max_text + 2
            local show_meta = meta_col + 4 <= comp_w

            for i = 1, n_comp do
                local ci = scroll + i
                local row = comp_start + i - 1
                local item = mb._completions[ci]
                local text = completers.comp_text(item)
                local meta = show_meta and completers.comp_meta(item) or nil
                text = truncate_cells(text, comp_w)
                if ci == selected then
                    local cur_fg = ui("cursor_fg")
                    local cur_bg = ui("cursor_bg")
                    local pad_to = (meta and #meta > 0) and math.min(meta_col, comp_w) or comp_w
                    text = text .. string.rep(" ", math.max(0, pad_to - cell_len(text)))
                    term:print(box_x + 1, row, text, cur_fg, cur_bg)
                    if meta and #meta > 0 and meta_col + #meta <= comp_w then
                        term:print(box_x + 1 + meta_col, row, meta, cur_fg, cur_bg)
                    end
                    local filled = (meta and #meta > 0 and meta_col + #meta <= comp_w)
                            and (meta_col + #meta)
                        or cell_len(text)
                    if filled < comp_w then
                        term:print(
                            box_x + 1 + filled,
                            row,
                            string.rep(" ", comp_w - filled),
                            cur_fg,
                            cur_bg
                        )
                    end
                else
                    term:print(box_x + 1, row, text, prompt_fg, bg)
                    if meta and #meta > 0 and meta_col + #meta <= comp_w then
                        term:print(box_x + 1 + meta_col, row, meta, meta_fg, bg)
                    end
                end
            end
        end

        -- Bottom border: ╰─...─╯
        term:print(
            box_x,
            box_y + box_h - 1,
            "╰" .. string.rep("─", box_w - 2) .. "╯",
            border_fg,
            bg
        )
    -- Eval result (in minibuffer row when not active)
    elseif self._eval_result then
        local eval_row = modeline_y + 1
        term:print(0, eval_row, "=> " .. self._eval_result, ui("status_message"), ui("default_bg"))
    end

    term:present()
end

return Editor
