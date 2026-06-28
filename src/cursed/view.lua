--- View: pure viewport — cursor, scroll, mark/selection.
---
--- A View holds a reference to a Buffer (shared, not owned) and tracks
--- a list of cursors, the scroll offset, and per-cursor mark/selection state.
--- It does NOT mutate the buffer. Editing goes through Buffer methods,

local ffi = require("ffi")
local utf8 = require("cursed.utf8")
local profile = require("cursed.profile")
local log = require("cursed.log")
local IH = require("cursed.input_hook")
--- which return the resulting cursor position; the View owns the
--- forwarding to each cursor.
---
--- Multi-cursor model: a View owns `cursors: Cursor[]` (almost always
--- length 1). The "primary" cursor (cursors[1]) drives scroll and is
--- the focus of mouse/caret rendering and completion. Every motion runs
--- across all cursors via View:each_cursor (order-independent, closes
--- any open edit group). Mutating ops run across all cursors via
--- View:batch_edit (sort bottom-up/right-to-left, dedupe coincident,
--- fixup unprocessed cursors via a returned translator) — implemented
--- in step 2.

----------------------------------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------------------------------

---@class Pos
---@field line integer 0-based line index
---@field col integer 0-based byte offset within line

---@class Cursor
---@field line integer 0-based line index
---@field col integer 0-based byte offset within line
---@field goal_col integer remembered col for vertical nav (byte offset within logical line); was last_cursor_col
---@field visual_col integer|nil remembered visual column for vertical nav when wrapping; was last_visual_col
---@field anchor_line integer|nil 0-based line index of selection anchor (was mark_line); nil = no selection
---@field anchor_col integer|nil 0-based byte offset of selection anchor (was mark_col)
---@field anchor_transient boolean|nil true when the anchor was initiated by a shift+motion (shift-select); a plain motion drops it. nil/false = a sticky mark (set via set_mark / C-space) that survives plain motions.
---@field yank_line integer|nil start line of last yank (for yank-pop); was _yank_line
---@field yank_col integer|nil start col of last yank (for yank-pop); was _yank_col
---@field shadow_undo integer|nil undo.count at anchor creation time (for undo-in-selection)
---@field shadow_redo integer|nil redo.count at anchor creation time (for undo-in-selection)

----------------------------------------------------------------------------------------------------
-- View class
----------------------------------------------------------------------------------------------------

---@class View
---@field buffer Buffer shared reference (not owned)
---@field editor Editor|nil back-reference for keybindings that need it
---@field cursors Cursor[] active cursors; cursors[1] is the primary
---@field pending_cursors Cursor[] positions staged by add-cursor-here before "go" promotes them
---@field scroll_li integer 0-based logical line index at the top of the viewport (anchor)
---@field scroll_sub_row integer 0-based sub-row within scroll_li shown at the viewport top
---  Line-anchored scroll model: the viewport is positioned by which
---  (line, sub_row) sits at its top, NOT by an absolute screen-row
---  offset. This avoids building the entire wrap-cache prefix to
---  position the viewport anywhere in the document (which made
---  jump-to-EOF cost ~240ms on 37k-line files). All positioning is
---  O(viewport) local walks via the _viewport_* helpers below.
---@field _recenter_state integer 0=middle, 1=top, 2=bottom (cycles on C-l)
---@field _scroll_guard_line integer|nil primary-cursor line last auto-scrolled for; nil = force next
---@field _scroll_guard_col integer|nil primary-cursor col last auto-scrolled for; nil = force next
---@field file_loaded boolean whether the initial file has been loaded
---@field _major_modes MajorModeInstance[] active major mode instances (ordered, later overrides earlier)
---@field tab_width integer visual width of a tab stop
---@field expand_tab boolean if true, Tab inserts spaces instead of \t
---@field indent_width integer number of columns for auto-indent
---@field wrap_width integer|nil when set, soft-wrap lines at this width
---@field margin integer|nil max text render width; when the window is wider, the text column (gutter + text) is centered within it
---@field _wrap_rows integer[]|nil cache: _wrap_rows[li+1] = number of screen rows for logical line li
---@field _wrap_cum integer[]|nil cache: _wrap_cum[li+1] = screen row where logical line li starts (0-based)
---@field _wrap_built integer|nil count of lines (1-based) built into the wrap cache so far (lazy forward build)
---@field _wrap_end integer|nil total screen rows of all built lines (start row of the first unbuilt line)
---@field _wrap_total integer|nil cached total screen rows once the cache is fully built (nil otherwise)
---@field _wrap_gen integer|nil cache generation counter (undo.count + redo.count)
---@field _graph_cache table[]|nil cache: _graph_cache[li+1] = {byte_starts, widths, prefix, line_len} (parsed grapheme skeleton, stripped-of-newline text)
---@field _graph_line_text string[]|nil cache: _graph_cache's source text (line w/o trailing newline) for slice-on-boundary rendering; nil if LRU-evicted while skeleton retained
---@field _graph_gen integer|nil cache generation counter for the grapheme cache (mirrors _wrap_gen)
---@field _hl_lang string|nil currently configured language (intent only)
---@field _hl_query string|nil current query source (intent only)
---@field _hl_injection_query string|nil injection query source, for languages that inject other grammars into regions of the block tree (intent only)
---@field _hl_view_id integer this View's monotonic id (assigned once at View
---                           creation; uniqueness across Views is what lets the lane
---                           keep separate old_trees per document)
---@field _hl_gen integer monotonic counter for this (View, language).
---                       Incremented on every query dispatched. The lane echoes
---                       it back; responses whose gen isn't the last we sent are
---                       stale and dropped on receipt.
---@field _hl_bucket_cache table<integer, {start_byte:integer, end_byte:integer, fg:integer}[]> cache: bucket_idx → spans (absolute byte offsets, fg resolved)
---@field _hl_names table<integer, string[]> cache: gen → capture-name table for fg resolution
---@field _hl_in_flight table|nil {gen, bucket_start, bucket_end} of the outstanding query, if any
---@field _hl_pending table|nil {bucket_start, bucket_end, has_edit, edit} next query to dispatch after in_flight lands
---@field _hl_sync_stalls integer consecutive sync-wait timeouts; circuit breaker for the zero-flash path
---@field _hl_total_bytes integer mirrors buffer text length, for bucket count math
---@field _hl_starts_cache integer[]|nil cached 1-indexed line start offsets + total; invalidated on gen change
---@field _hl_starts_gen integer|nil gen the line_starts cache was built for
---@field _hl_enabled boolean|nil false when no mode language (skip dispatch entirely)
---@field _hl_scheme_gen integer|nil colorscheme generation the cache was built under; mismatch → clear cache
---@field _hl_last_vstart integer|nil last viewport start byte we dispatched for
---@field _hl_last_vend integer|nil last viewport end byte we dispatched for
---@field _hl_last_gen integer|nil last buffer gen we dispatched an edit for (avoids repeat dispatch on every render when the edit was already sent)
---@field _bench_open_t0 integer|nil wall-clock us at Editor:open_file() start; instrumentation for file-open latency (cleared on load)
---@field _indent_query_cache table|nil {lang,src,query} lazily-compiled indent query for syntax-aware Return; rebuilt when the active language or `indent_queries` source changes
local View = {}
View.__index = View

-- Monotonic counter for assigning unique _hl_view_id values. The
-- highlight lane keys per-document old_tree on (language, view_id), so
-- each View must have a globally unique id.
local _next_hl_view_id = 1

----------------------------------------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------------------------------------

--- Create a new View for the given Buffer.
---@param buffer Buffer
---@return View
function View.new(buffer)
    local view_id = _next_hl_view_id
    _next_hl_view_id = _next_hl_view_id + 1
    local cursor = {
        line = 0,
        col = 0,
        goal_col = 0,
        visual_col = nil,
        anchor_line = nil,
        anchor_col = nil,
        anchor_transient = nil,
        yank_line = nil,
        yank_col = nil,
        shadow_undo = nil,
        shadow_redo = nil,
    }
    return setmetatable({
        buffer = buffer,
        editor = nil,
        cursors = { cursor },
        pending_cursors = {},
        scroll_li = 0,
        scroll_sub_row = 0,
        _recenter_state = 0,
        _scroll_guard_line = nil,
        _scroll_guard_col = nil,
        file_loaded = false,
        _major_modes = {},
        tab_width = 8,
        expand_tab = false,
        indent_width = 8,
        wrap_width = nil,
        margin = nil,
        _wrap_rows = nil,
        _wrap_cum = nil,
        _wrap_built = nil,
        _wrap_end = nil,
        _wrap_total = nil,
        _wrap_gen = nil,
        _graph_cache = nil,
        _graph_line_text = nil,
        _graph_gen = nil,
        _hl_lang = nil,
        _hl_query = nil,
        _hl_view_id = view_id,
        _hl_gen = 0,
        _hl_bucket_cache = {},
        _hl_names = {},
        _hl_in_flight = nil,
        _hl_pending = nil,
        _hl_sync_stalls = 0,
        _hl_total_bytes = 0,
        _hl_starts_cache = nil,
        _hl_starts_gen = nil,
        _hl_enabled = false,
        _hl_scheme_gen = nil,
        _hl_last_vstart = nil,
        _hl_last_vend = nil,
        _hl_last_gen = nil,
        _indent_query_cache = nil,
    }, View)
end

----------------------------------------------------------------------------------------------------
-- Buffer attachment
----------------------------------------------------------------------------------------------------

--- Swap the buffer this view displays. Centralizes what was a raw
--- `view.buffer = buf` assignment so the swap can fire
--- `view_attach_buffer` (always, for every reassignment) and
--- `buffer_open` (when the caller flags this as a freshly-loaded
--- content buffer). Emits BEFORE swapping in `opts.silent=false` (the
--- default) so handlers run against the still-current old buffer; the
--- new buffer is the second payload.
---
--- Lifecycle mapping:
---   view_attach_buffer  — fires on every swap (view, new_buf, old_buf)
---   buffer_open         — fires only when opts.loaded == true (the
---                         new buffer carries freshly-arriving file
---                         content); payload (new_buf, view)
---@param buf Buffer the buffer to attach
---@param opts { loaded?: boolean, silent?: boolean }|nil
function View:set_buffer(buf, opts)
    opts = opts or {}
    local es = self.editor and self.editor.event_system
    local old = self.buffer
    if buf == old then
        return
    end
    if es and not opts.silent then
        es:emit("view_attach_buffer", self, buf, old)
    end
    self.buffer = buf
    if self.editor then
        self.editor:request_full_damage()
    end
    if es and not opts.silent then
        if opts.loaded then
            es:emit("buffer_open", buf, self)
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Cursor access
----------------------------------------------------------------------------------------------------

--- Get the primary cursor (mutable reference).
--- The primary cursor drives scroll, caret rendering, mouse focus,
--- and completion scope. Almost all call sites operate on the primary;
--- code that must visit every cursor uses each_cursor / batch_edit.
---@return Cursor
function View:p()
    return self.cursors[1]
end

--- Construct a fresh Cursor table at the given position.
--- Used by add-cursor operations (mouse Alt-click, select-next-match, etc.)
--- to append a new cursor with default per-cursor state.
---@param line integer
---@param col integer
---@return Cursor
function View:make_cursor(line, col)
    return {
        line = line,
        col = col,
        goal_col = self:byte_to_col(line, col),
        visual_col = nil,
        anchor_line = nil,
        anchor_col = nil,
        anchor_transient = nil,
        yank_line = nil,
        yank_col = nil,
        shadow_undo = nil,
        shadow_redo = nil,
    }
end

--- Append a new cursor at the given position and make it primary.
---@param line integer
---@param col integer
---@return Cursor the newly-added cursor (now primary)
function View:add_cursor(line, col)
    local c = self:make_cursor(line, col)
    -- Insert as primary (index 1) so it becomes the scroll/mouse focus;
    -- the previously-primary cursor shifts to index 2.
    table.insert(self.cursors, 1, c)
    self:_clamp_cursor(c)
    return c
end

--- Collapse to a single cursor at the given position (drop all others).
---@param line integer
---@param col integer
function View:set_single_cursor(line, col)
    self.cursors = { self:make_cursor(line, col) }
    self.pending_cursors = {}
    self:_clamp_cursor(self.cursors[1])
end

--- Drop a pending cursor at the given position (does NOT yet make it
--- active). The primary cursor stays where it is and may move freely
--- via normal motions, so the user can stage several drop points
--- across the buffer. commit_pending_cursors() promotes them all at
--- once so subsequent motions move every cursor in unison.
---@param line integer
---@param col integer
function View:drop_cursor(line, col)
    local c = self:make_cursor(line, col)
    self.pending_cursors[#self.pending_cursors + 1] = c
end

--- Promote all pending drops to active cursors. The primary cursor is
--- kept in place; drops are appended after it. After this call,
--- motions/edits apply to all cursors in unison.
function View:commit_pending_cursors()
    for i = 1, #self.pending_cursors do
        self.cursors[#self.cursors + 1] = self.pending_cursors[i]
    end
    self.pending_cursors = {}
end

--- Cancel drop mode: discard any pending drops without promoting them.
--- The primary cursor is unaffected.
function View:cancel_pending_cursors()
    self.pending_cursors = {}
end

--- True if there are pending (staged) drops awaiting commit.
---@return boolean
function View:has_pending_cursors()
    return #self.pending_cursors > 0
end

--- Set the goal column for vertical navigation on the primary cursor.
--- Call this after any horizontal movement or edit so that
--- subsequent vertical moves reseed the visual column from
--- the current position (rather than using a stale goal).
--- The wrap path of move_line is the only code that intentionally
--- preserves visual_col — it does NOT call this setter.
--- Also cancels any in-progress yank-pop cycle on the primary cursor.
---@param col integer 0-based byte offset
function View:_set_goal_col(col)
    local c = self.cursors[1]
    c.goal_col = self:byte_to_col(c.line, col)
    c.visual_col = nil
    c.yank_line = nil
    c.yank_col = nil
end

--- Set the goal column on every cursor (used when a motion/edit
--- applies uniformly to all cursors, e.g. clamp_cursor after undo).
---@param col integer 0-based byte offset
function View:_set_goal_col_all(col)
    for _, c in ipairs(self.cursors) do
        c.goal_col = self:byte_to_col(c.line, col)
        c.visual_col = nil
        c.yank_line = nil
        c.yank_col = nil
    end
end

----------------------------------------------------------------------------------------------------
-- Cursor primitives
----------------------------------------------------------------------------------------------------

--- Clamp a cursor's (line, col) to valid document bounds so no code
--- path can ever leave the caret past end-of-line or end-of-document.
--- Defensive guard: motion/edit code already clamps, but this is the
--- single backstop that guarantees the invariant `0 <= c.line <
--- line_count` and `0 <= c.col <= content_len(c.line)` holds for every
--- cursor the renderer / modeline / scan code observes. col may equal
--- content_len (the end-of-line virtual position, like C-e), which is
--- valid; only values BEYOND it are clamped down.
---@param c Cursor
function View:_clamp_cursor(c)
    local lc = self:line_count()
    if lc <= 0 then
        c.line = 0
        c.col = 0
        return
    end
    if c.line < 0 then
        c.line = 0
    elseif c.line >= lc then
        c.line = lc - 1
    end
    local clen = self:content_len(c.line)
    if c.col < 0 then
        c.col = 0
    elseif c.col > clen then
        c.col = clen
    end
end

--- Clamp every cursor (primary + secondaries + pending drops).
function View:_clamp_all_cursors()
    for _, c in ipairs(self.cursors) do
        self:_clamp_cursor(c)
    end
    for _, c in ipairs(self.pending_cursors) do
        self:_clamp_cursor(c)
    end
end

--- Close any open edit group on the buffer before a motion.
--- Motions are order-independent across cursors (moving one cursor
--- never affects another's position), so the motion primitive does not
--- sort/dedupe the way batch_edit does — it just closes the group once
--- and cancels yank-pop cycles on every cursor.
local function close_edit_for_motion(view)
    if view.buffer:in_edit() then
        view.buffer:end_edit()
    end
    for _, c in ipairs(view.cursors) do
        -- A plain motion ends an active shift-select gesture: drop any
        -- TRANSIENT anchor so the cursor stops extending the selection.
        -- Skipped when `editor._extend` is set (a `*_select` command is
        -- running its motion — the anchor it just placed must survive
        -- and extend). A STICKY anchor (set_mark / C-space) is always
        -- kept so the Emacs C-space -> move -> kill flow still works.
        -- This guarded drop is the ONLY selection logic a plain motion
        -- performs — it never initializes or extends.
        local editor = view.editor
        if not (editor and editor._extend) and c.anchor_line ~= nil and c.anchor_transient then
            c.anchor_line = nil
            c.anchor_col = nil
            c.anchor_transient = nil
            c.shadow_undo = nil
            c.shadow_redo = nil
        end
        c.yank_line = nil
        c.yank_col = nil
    end
end

--- Compute the PRE-edit region end for a signed delete_char at
--- (line, col) with magnitude n. The deleted region is [start, end)
--- half-open, where start = (line, col) for forward deletes or
--- (line, col-n) for backward deletes. This mirrors the buffer's
--- _delete_char_impl walking logic so the translator math matches.
--- Returns (el, ec) the end of the deletion in pre-edit coordinates.
local function delete_region_end(buf, line, col, n)
    local forward = n > 0
    local remaining = forward and n or -n
    local cl = line
    local cc = col
    while remaining > 0 do
        local content_len = buf:line_len(cl) - 1
        if forward then
            local available = content_len - cc
            if available > 0 then
                local to_delete = math.min(remaining, available)
                cc = cc + to_delete
                remaining = remaining - to_delete
            end
        else
            if cc > 0 then
                local to_delete = math.min(remaining, cc)
                cc = cc - to_delete
                remaining = remaining - to_delete
            end
        end
        if remaining > 0 then
            if forward and cl < buf:line_count() - 1 then
                -- The newline being consumed bridges to the next line:
                -- end advances to the start of the next line in pre-edit
                -- coords. remaining consumes the newline.
                cl = cl + 1
                cc = 0
                remaining = remaining - 1
            elseif not forward and cl > 0 then
                cl = cl - 1
                cc = buf:line_len(cl) - 1
                remaining = remaining - 1
            else
                break
            end
        end
    end
    return cl, cc
end

--- Begin a shift-select motion: for every cursor, decide whether to
--- EXTEND an existing selection or RESET the anchor to the cursor:
---   • no anchor           → drop a TRANSIENT one at the cursor (start)
---   • TRANSIENT anchor    → RESET it to the cursor (each shifted motion
---                           selects only its own range — no cross-motion
---                           extension between shift gestures)
---   • STICKY anchor       → KEEP it (a manually-set mark / C-space is
---                           extended by the shift+motion, so the user's
---                           explicit mark is honored as the selection
---                           origin and the move grows it)
--- `_extend` (set true by the calling command) then suppresses the
--- transient-anchor drop in close_edit_for_motion for this one gesture
--- so a just-set/re-set anchor survives the move. A plain motion (no
--- _extend) drops a transient selection (but keeps a sticky mark).
--- Called ONLY by the `*_select` commands; plain motions never EXTEND
--- or INIT a selection (they only DROP a transient one).
function View:_begin_shift_select()
    local u = tonumber(self.buffer._ptr.undo.count)
    local r = tonumber(self.buffer._ptr.redo.count)
    for _, c in ipairs(self.cursors) do
        -- Keep a STICKY (manually-set) anchor so the shift+motion extends
        -- the existing selection from it. Otherwise (no anchor, or a
        -- transient one from a prior shift gesture) (re-)anchor at the
        -- cursor so this motion selects exactly [cursor, landing].
        local extend = c.anchor_line ~= nil and not c.anchor_transient
        if not extend then
            c.anchor_line = c.line
            c.anchor_col = c.col
            c.anchor_transient = true
            c.shadow_undo = u
            c.shadow_redo = r
        end
    end
end

--- Iterate a motion over every cursor.
--- A motion is order-independent (moving every cursor by +1 line
--- doesn't depend on neighbors) and does not touch the buffer, so this
--- primitive is a plain map with no sort/dedupe/fixup. It owns the
--- motion grouping contract: close any open edit group once (do NOT
--- reopen — motions terminate an edit group, they don't start one),
--- then call `fn(cur)` for each cursor.
---
--- `fn` may return (true|nil) or (nil, errmsg); the last non-nil
--- errmsg across all cursors is returned to the caller for status.
--- fn must not mutate the buffer; mutating ops use batch_edit (step 2).
---@param fn fun(c: Cursor): boolean?, string?
---@return boolean ok true if all succeeded
---@return string|nil err last error message, if any
function View:each_cursor(fn)
    close_edit_for_motion(self)
    local last_err
    for _, c in ipairs(self.cursors) do
        local _, err = fn(c)
        if err then
            last_err = err
        end
        -- Defensive: guarantee the cursor sits on a valid (line, col)
        -- no matter what the motion returned.
        self:_clamp_cursor(c)
    end
    return last_err == nil, last_err
end

------------------------------------------------------------------------------------------------------ Mutating primitive: batch_edit
----------------------------------------------------------------------------------------------------

--- Apply a mutating op to every cursor as ONE undo group.
---
--- Owns the edit-grouping decision for the whole keystroke (so typing
--- across N cursors yields one undo step, not N). `breaks_group` is the
--- boolean the caller computes once: for inserts it's
--- `buffer:should_break_edit(str)` (content-based, uniform across
--- cursors); for deletes it's the OR of each cursor's will_join test
--- (positional, see View:delete_char).
---
--- Grouping contract: if breaks_group, end any open group then begin a
--- fresh one; otherwise ensure a group is open (begin if none). The
--- group is left OPEN afterwards — persistent across consecutive
--- non-breaking keystrokes, exactly like single-cursor typing. A motion
--- or a breaking keystroke closes/restarts it, via this same function
--- or via each_cursor's close_edit_for_motion.
---
--- Cursor application order: TOP-DOWN, LEFT-TO-RIGHT (document order).
--- This is the only order that composes correctly with NEWLINE-CREATING
--- edits (an insert at line L that splits the line shifts cursors below
--- L down; if we'd already processed a later cursor, its coordinates
--- would be stale). Processing forward means each edit only needs to
--- translate cursors that come AFTER it in document order.
---
--- Coincident cursors (same line+col) collapse to one edit; the
--- duplicates are translated onto the same result (they share the
--- editing cursor's outcome).
---
--- fn(cur) is called for each cursor with the cursor to mutate. It
--- must perform the raw buffer mutation at cur's position and return
--- (rl, rc) — the buffer's reported result coordinates — so batch_edit
--- can: (a) move THIS cursor to (rl, rc), and (b) build a unified
--- translator that adjusts not-yet-processed cursors whose document
--- position is at-or-after the edit point.
---
--- The translator is built by batch_edit from the edit's (line, col)
--- BEFORE the call and the returned (rl, rc), using one of two
--- formulas depending on whether the edit inserted text (grow) or
--- deleted a region (shrink). Callers report grow vs shrink via the
--- third return value: "insert" or a `[el, ec]` deleted-region end.
--- This keeps the translator math in one place rather than duplicated
--- across insert_char/delete_char/insert_newline.
---
---@param breaks_group boolean caller's once-computed break decision
---@param fn fun(c: Cursor): integer, integer, integer, integer, any, integer?, integer? (sl, sc, rl, rc, kind, [el, ec])
function View:batch_edit(breaks_group, fn)
    local buf = self.buffer
    -- Group decision, once per keystroke
    if breaks_group then
        if buf:in_edit() then
            buf:end_edit()
        end
        buf:begin_edit()
    elseif not buf:in_edit() then
        buf:begin_edit()
    end

    local n = #self.cursors
    -- Snapshot each cursor's PRE-edit position and sort top-down,
    -- left-to-right (document order). We mutate the real cursor tables
    -- in place but compare against the snapshot so translations stay
    -- grounded in pre-edit coordinates. `entry.line/col` is also the
    -- cursor's OLD-frame (pre-batch) position, which the highlighter
    -- uses to build the composite TSInputEdit spanning first→last cursor.
    local starts_pre = self._hl_enabled and self:_hl_line_starts() or nil
    local ordered = {}
    for i = 1, n do
        local c = self.cursors[i]
        ordered[i] = { cursor = c, line = c.line, col = c.col, skip = false }
    end
    table.sort(ordered, function(a, b)
        if a.line ~= b.line then
            return a.line < b.line -- top-down
        end
        return a.col < b.col -- left-to-right within a line
    end)

    -- Dedupe: cursors that share their PRE-edit (line, col) with an
    -- earlier-sorted cursor collapse onto it. The later one is skipped
    -- (the edit is applied once), and after the edit it is moved to the
    -- source cursor's result position so duplicates stay together.
    for i = 1, n do
        if not ordered[i].skip then
            for j = i + 1, n do
                local o = ordered[j]
                if not o.skip and o.line == ordered[i].line and o.col == ordered[i].col then
                    o.skip = true
                    o.collapse_source = ordered[i]
                end
            end
        end
    end

    -- For the composite TSInputEdit we need line_starts in three frames:
    --   starts_pre        : before the batch (first edit's region start A)
    --   starts_before_last: right before the LAST non-skip edit (its
    --                       region end B in pre-last frame)
    --   starts_post       : after the batch (last result C)
    -- cum_delta = total_before_last - total_pre converts B from pre-last
    -- to pre-batch frame. Only one extra snapshot (before the last edit)
    -- is needed regardless of cursor count.
    local last_edit_idx ---@type integer|nil
    for i = n, 1, -1 do
        if not ordered[i].skip then
            last_edit_idx = i
            break
        end
    end
    local starts_pre_total ---@type integer|nil
    if starts_pre then
        starts_pre_total = starts_pre[#starts_pre] or 0
    end
    local starts_before_last ---@type integer[]|nil
    local starts_before_last_total ---@type integer|nil

    -- Unified INSERT translator: insert at (line,col), result (rl,rc),
    -- K = rl - line (number of new lines created).
    --   o before the edit point (earlier line, or same line + col<col): unchanged.
    --   o on the same line with col >= col: -> (line+K, (col - col) + rc)
    --   o on a later line: -> (line + K, col)   [only K changes]
    local function insert_translator(line, col, rl, rc)
        local K = rl - line
        if K == 0 and rc == col then
            return nil -- no-op insert, no cursor needs moving
        end
        return function(o)
            if o.line < line or (o.line == line and o.col < col) then
                return
            end
            if o.line == line then
                o.line = line + K
                o.col = (o.col - col) + rc
            else
                o.line = o.line + K
            end
        end
    end

    -- Unified DELETE translator for region [start=(sl,sc), end=(el,ec))
    -- (half-open), result (rl,rc) = (sl,sc), dl = el - sl.
    --   o before start: unchanged.
    --   o AFTER end (later line, or same line + col>=ec): pull up to sl,
    --     keeping the post-end column: (sl, sc + (col - ec)) if same end
    --     line, else (line - dl, col).
    --   o INSIDE the deleted region (start..end, inclusive of start,
    --     exclusive of end): collapse to the deletion result (sl, sc).
    local function delete_translator(sl, sc, el, ec)
        local dl = el - sl
        return function(o)
            if o.line < sl or (o.line == sl and o.col < sc) then
                return
            end
            -- strictly after the deleted region
            if o.line > el or (o.line == el and o.col >= ec) then
                if o.line == el then
                    o.line = sl
                    o.col = sc + (o.col - ec)
                else
                    o.line = o.line - dl
                end
                return
            end
            -- inside the deleted region
            o.line = sl
            o.col = sc
        end
    end

    -- Track edit info for the highlight lane. We capture EVERY
    -- non-skipped cursor's edit (in document order) so multi-cursor
    -- edits can translate the cache per-cursor (top→bottom, left→right)
    -- and keep off-screen spans byte-correct as a bridge. The lane is
    -- then re-queried only for viewport ± margin; off-screen translated
    -- spans are good-enough until scrolled into view. `crossed_newline`
    -- is true if ANY edit split/joined a line, which means downstream
    -- buckets' line mappings are stale.
    local hl_edits = {} ---@type table[]
    local hl_crossed_newline = false
    local hl_edit_count = 0

    -- Apply edits in document order. For each non-skipped cursor: run
    -- the caller's fn, move THIS cursor to the result, build a
    -- translator, and apply it to every not-yet-processed (sorted later)
    -- cursor — including coincident-dedupe-skipped ones that come after,
    -- so they land on the same translated coordinate as their source.
    for i = 1, n do
        local entry = ordered[i]
        if not entry.skip then
            local cur = entry.cursor
            -- The caller reports (sl, sc) = the actual region START in
            -- pre-edit coordinates (for inserts == cursor's pre-edit
            -- position; for backward deletes it's below the cursor).
            -- batch_edit's snapshot of cur.line/col is the CURSOR
            -- position, which for backward deletes is NOT the region
            -- start — so the translator must key off (sl, sc),
            -- reported by the caller, not the stale snapshot.
            -- For "replace" the caller also returns the deleted-region
            -- end as trailing values (e1, e2).
            -- Snapshot starts_before_last BEFORE fn(cur) mutates the
            -- buffer. (Previously this ran AFTER fn(cur), capturing the
            -- POST-edit state — which made cum_delta = post-total -
            -- pre-total instead of 0 on single-edit batches, driving
            -- b_byte negative and forcing every insert into the degenerate
            -- fallback → cold reparse instead of incremental.)
            if last_edit_idx == i and starts_pre then
                self._hl_starts_cache = nil
                self._hl_starts_gen = nil
                starts_before_last = self:_hl_line_starts()
                starts_before_last_total = starts_before_last[#starts_before_last] or 0
            end
            local sl, sc, rl, rc, kind, e1, e2 = fn(cur)
            ---@cast rl integer
            ---@cast rc integer
            -- Capture for the highlighter (every edit). `orig_*` is the
            -- cursor's pre-batch (OLD-frame) position from the snapshot;
            -- the highlighter builds a composite TSInputEdit spanning
            -- first→last cursor using these for correct OLD-frame coords.
            hl_edits[#hl_edits + 1] = {
                sl = sl,
                sc = sc,
                rl = rl,
                rc = rc,
                kind = kind,
                e1 = e1,
                e2 = e2,
                orig_line = entry.line,
                orig_col = entry.col,
            }
            hl_edit_count = hl_edit_count + 1
            if (kind == "insert" or kind == "insert_relocate") and rl ~= sl then
                hl_crossed_newline = true
            elseif kind == "replace" or type(kind) == "table" then
                local el, ec = e1, e2
                if el ~= nil and el ~= sl then
                    hl_crossed_newline = true
                end
            end
            -- Move the editing cursor to the buffer-reported result,
            -- UNLESS the caller asked for a relocate (electric block
            -- openers insert multi-line text but want the cursor on the
            -- mid-insert body line, not at the buffer's reported end).
            if kind == "insert_relocate" then
                ---@cast e1 integer
                ---@cast e2 integer
                cur.line = e1
                cur.col = e2
                cur.goal_col = e2
            else
                cur.line = rl
                cur.col = rc
                cur.goal_col = rc
            end
            cur.visual_col = nil

            local tr
            if kind == "insert" or kind == "insert_relocate" then
                tr = insert_translator(sl, sc, rl, rc)
            elseif kind == "replace" then
                -- kind "replace": caller also returned the PRE-edit
                -- deleted-region end (e1, e2). The net coordinate
                -- effect is delete-then-insert at the same start, so
                -- we compose the delete translator (collapses/pulls
                -- in- and post-region cursors) with the insert
                -- translator (shifts by the replacement's line delta).
                local el, ec = e1, e2
                local dt = delete_translator(sl, sc, el, ec)
                local it = insert_translator(sl, sc, rl, rc)
                tr = function(o)
                    dt(o)
                    if it then
                        it(o)
                    end
                end
            elseif type(kind) == "table" then
                -- kind = { el, ec } deleted region end; region [start, end)
                -- with start = (sl, sc).
                local el, ec = kind[1], kind[2]
                tr = delete_translator(sl, sc, el, ec)
            end
            if tr then
                for j = i + 1, n do
                    tr(ordered[j].cursor)
                end
            end
        end
    end

    -- Move each skipped (coincident-dedupe) cursor to its collapse
    -- source's final position so the duplicate tracks the result rather
    -- than stranding at a stale coordinate. (The translator above may
    -- also have touched skipped cursors whose pre-edit positions were
    -- after the edit point; for coincident ones, snapping to the source
    -- is the precise outcome.)
    for i = 1, n do
        local entry = ordered[i]
        if entry.skip and entry.collapse_source then
            local src = entry.collapse_source.cursor
            entry.cursor.line = src.line
            entry.cursor.col = src.col
            entry.cursor.goal_col = src.col
            entry.cursor.visual_col = nil
        end
    end

    -- Cancel yank-pop on every cursor (an edit breaks the cycle)
    for _, c in ipairs(self.cursors) do
        c.yank_line = nil
        c.yank_col = nil
    end

    -- Defensive: guarantee every cursor sits on a valid (line, col)
    -- after the edit + translator pass, regardless of what the buffer
    -- reported or the translator computed. This is the single backstop
    -- that prevents a cursor from ever being left past end-of-line.
    self:_clamp_all_cursors()

    -- Notify the highlight lane. Each edit (single or multi) translates
    -- the cache so off-screen spans stay byte-correct as a bridge; the
    -- lane is then re-queried only for viewport ± margin (the visible
    -- truth). Single-cursor gets a real TSInputEdit for incremental
    -- parsing; multi-cursor can't compose disjoint edits into one
    -- TSInputEdit, so the lane cold-reparses just the viewport margin.
    if hl_edit_count > 0 and self._hl_enabled then
        local starts_post = self:_hl_line_starts()
        ---@cast starts_pre integer[]
        ---@cast starts_pre_total integer
        local frames = {
            starts_pre = starts_pre,
            starts_pre_total = starts_pre_total,
            starts_before_last = starts_before_last,
            starts_before_last_total = starts_before_last_total,
            starts_post = starts_post,
        }
        self:_hl_record_edit(hl_edits, hl_crossed_newline, frames)
    end

    -- The renderer reads line text + grapheme runs from the per-line
    -- grapheme cache (even in no-wrap mode). The cache's own staleness
    -- guard keys off (undo.count + redo.count), which is INVARIANT
    -- across keystrokes in an open edit group — so without this explicit
    -- invalidate, the rendered text would lag the cursor mid-group.
    self:invalidate_graph_cache()
end

----------------------------------------------------------------------------------------------------
-- Major mode management (unchanged contract)
----------------------------------------------------------------------------------------------------

--- Emit a mode lifecycle event ("mode_enter" / "mode_exit") through
--- the editor's central event hub. Payload is the mode instance and
--- this view. No-op when the view has no editor yet (listeners are
--- only meaningful once the editor + event hub exist).
---
--- TWO events are emitted for each transition so consumers don't
--- have to if/else dispatch on the mode name:
---   `name`             — generic, fires for every mode (cross-cutting
---                       concerns: logging, statistics, …)
---   `name..":"..mode.name` — specific, e.g. `mode_enter:lua` /
---                       `mode_exit:rust`. Per-mode handlers (LSP
---                       boot, per-instance state) register for these
---                       directly.
---@param name string event name ("mode_enter" or "mode_exit")
---@param instance MajorModeInstance the mode instance being entered/exited
function View:_emit_mode_event(name, instance)
    if self.editor and self.editor.event_system then
        local es = self.editor.event_system
        es:emit(name, instance, self)
        es:emit(name .. ":" .. instance.name, instance, self)
    end
end

--- Set the major mode instances for this view, applying indent settings.
--- Later modes override earlier ones. Pass an empty table to clear.
--- Does NOT emit mode_enter/mode_exit (use activate_major_mode /
--- deactivate_major_mode for that).
---@param modes MajorModeInstance[]
function View:set_major_modes(modes)
    self._major_modes = modes
    -- Last mode wins for indent settings
    if #modes > 0 then
        local last = modes[#modes]
        self.tab_width = last.tab_width
        self.expand_tab = last.expand_tab
        self.indent_width = last.indent_width
        -- margin is an OPTIONAL override of the global config margin:
        -- a mode that sets it wins; a mode that omits it falls back to
        -- editor.margin (the global baseline), NOT a hardcoded constant
        -- (unlike tab_width/indent_width, which have no global source).
        self.margin = last.margin ~= nil and last.margin or (self.editor and self.editor.margin)
    else
        self.tab_width = 8
        self.expand_tab = false
        self.indent_width = 8
        -- No active mode: restore the global config margin.
        self.margin = self.editor and self.editor.margin
    end
    -- Rebuild the syntax highlighter from the highest-precedence mode
    -- that declares a tree-sitter language.
    self:_rebuild_highlighter()
    -- Rebuild the active trie if this view is currently focused
    if self.editor then
        self.editor:rebuild_active_trie()
    end
end

--- Activate a major mode in this view: create an instance, emit
--- mode_enter, and add it to the mode list.
---@param template MajorMode the mode template (from config.modes)
function View:activate_major_mode(template)
    -- Check if already active (avoid duplicates)
    for _, m in ipairs(self._major_modes) do
        if m._base == template then
            return
        end
    end
    local instance = template:instantiate()
    self:_emit_mode_event("mode_enter", instance)
    local modes = {}
    for i, m in ipairs(self._major_modes) do
        modes[i] = m
    end
    modes[#modes + 1] = instance
    self:set_major_modes(modes)
end

--- Deactivate a major mode in this view: emit mode_exit, remove it,
--- and rebuild.
---@param template MajorMode the mode template to remove
function View:deactivate_major_mode(template)
    local idx = nil
    local instance = nil
    for i, m in ipairs(self._major_modes) do
        if m._base == template then
            idx = i
            instance = m
            break
        end
    end
    if idx == nil then
        return
    end
    ---@cast instance MajorModeInstance
    self:_emit_mode_event("mode_exit", instance)
    local modes = {}
    for i, m in ipairs(self._major_modes) do
        if i ~= idx then
            modes[#modes + 1] = m
        end
    end
    self:set_major_modes(modes)
end

--- Check if a major mode template is active in this view.
---@param template MajorMode
---@return boolean
function View:has_major_mode(template)
    for _, m in ipairs(self._major_modes) do
        if m._base == template then
            return true
        end
    end
    return false
end

--- Activate the matching major modes for a filepath.
---@param filepath string
---@param config Config
function View:activate_mode_for_filepath(filepath, config)
    local templates = config:find_modes(filepath)
    -- Emit mode_exit for all currently active modes first
    for _, instance in ipairs(self._major_modes) do
        self:_emit_mode_event("mode_exit", instance)
    end
    -- Instantiate and emit mode_enter for each matched template
    local instances = {}
    for _, template in ipairs(templates) do
        local instance = template:instantiate()
        self:_emit_mode_event("mode_enter", instance)
        instances[#instances + 1] = instance
    end
    self:set_major_modes(instances)
end

----------------------------------------------------------------------------------------------------
-- Async syntax highlighting
--
-- The TSParser/TSQuery/old_tree live in the highlight LANE (another
-- pthread + lua_State). This View only records intent (language + query
-- string + a monotonic view id) and dispatches bucket-granular query
-- requests via the outbox_hl ring. The lane parses, queries the bucket's
-- byte range, and returns absolute-byte spans + a capture-name table;
-- main resolves fg from capture name at render time (so a theme switch
-- is just a cache clear) and maps spans to lines via a cached
-- line_starts table.
--
-- Two tables, no state machine: `cache: {[bucket_idx] = spawns}` and
-- `in_flight: {gen, bucket_idx}|nil`. Fire-and-forget, last-wins: a
-- fresh query superseding an in-flight one is remembered as `pending`
-- and dispatched when the in-flight one lands. Stale spans in the cache
-- are shown until a fresh response arrives; absolute byte offsets make
-- this safe (same-line edits stay exact; downstream bytes briefly
-- mis-color by the edit size for the response window — imperceptible).
----------------------------------------------------------------------------------------------------

local BUCKET_BYTES = 8192

--- How many extra buckets (each BUCKET_BYTES) to re-query above/below the
--- viewport on an edit. Covers error-recovery effects that leak just
--- outside the visible window (e.g. an unclosed string) while keeping
--- edit re-queries bounded regardless of document size.
local HL_MARGIN_BUCKETS = 1

--- Synchronous-wait cap for the zero-flash on-screen parse path
--- (View:_hl_wait_response). After dispatching an edit query, block the
--- keyloop polling the lane's inbox_hl for this many ms before giving
--- up and rendering the translated cache for a frame. Tree-sitter
--- incremental parse of a viewport±margin is sub-ms, so this is a
--- generous margin; the cap bounds worst-case added input latency.
local HL_SYNC_WAIT_MS = 10

--- Circuit-breaker threshold: after this many consecutive sync-wait
--- timeouts, disable the sync path so a slow/dead lane can't lag-spam
--- the keyloop. Re-enabled when an async install lands (lane caught up).
local HL_SYNC_STALL_LIMIT = 5

--- Bucket index for a given absolute byte offset.
---@param byte integer
---@return integer
local function bucket_of(byte)
    return math.floor(byte / BUCKET_BYTES)
end

--- Lazy handle to SharedState (avoids requiring it at module load —
--- the view module is loaded in both lanes via preload, but SharedState
--- is main-lane-only from the view's perspective).
local function ss()
    return require("cursed.shared").SharedState.from_global()
end

--- Pick the highest-precedence mode declaring a tree-sitter language.
--- Returns (language, query_source, injection_query) where
--- injection_query is nil for single-parser (non-injecting) languages.
---@return string|nil
---@return string|nil
---@return string|nil
local function active_hl_mode(modes)
    local lang, query, inj_query
    for _, m in ipairs(modes) do
        if m.language ~= nil then
            lang = m.language
            query = m.highlight_query
            inj_query = m.injection_query
        end
    end
    return lang, query, inj_query
end

--- Build the bundle of injected grammars the lane must be able to parse.
--- For an injecting language (e.g. markdown), the injection query can
--- reference any of the OTHER bundled grammars by name (markdown_inline,
--- plus any language named by a `````-fence label). To stay simple and
--- correct, we send EVERY mode that declares a `language` +
--- `highlight_query`, so a `````lua`` fence resolves to the lua grammar's
--- query without the view having to predict which labels appear — PLUS
--- the active mode's `extra_injected_grammars` (grammars the injection
--- query references that have no MajorMode of their own, e.g.
--- markdown_inline).
--- Returns a list of {language=string, query_src=string}.
---@param modes table[] active major modes (to pull extra_injected_grammars from)
---@return table[]
local function build_injected_langs(modes)
    local mods = require("cursed.modes")
    local out = {}
    local seen = {}
    for _, name in ipairs(mods.order) do
        local m = mods.modes[name]
        if m.language ~= nil and m.highlight_query ~= nil and not seen[m.language] then
            seen[m.language] = true
            out[#out + 1] = { language = m.language, query_src = m.highlight_query }
        end
    end
    -- Extra grammars declared by the active injecting mode (name→query).
    for _, m in ipairs(modes) do
        if m.extra_injected_grammars ~= nil then
            for gname, qsrc in pairs(m.extra_injected_grammars) do
                if not seen[gname] then
                    seen[gname] = true
                    out[#out + 1] = { language = gname, query_src = qsrc }
                end
            end
        end
    end
    return out
end

--- Rebuild the view's highlight intent from the active major modes and
--- notify the lane of any language/query change. The lane owns its own
--- parser/query/old_tree; we just tell it which (language, query_source)
--- to build. A re-init with the SAME query source is a no-op on the lane.
function View:_rebuild_highlighter()
    local lang, query, inj_query = active_hl_mode(self._major_modes)
    if lang == nil or query == nil then
        self._hl_lang = nil
        self._hl_query = nil
        self._hl_injection_query = nil
        self._hl_enabled = false
        self._hl_bucket_cache = {}
        self._hl_names = {}
        self._hl_in_flight = nil
        self._hl_pending = nil
        return
    end
    self._hl_enabled = true
    if
        self._hl_lang == lang
        and self._hl_query == query
        and self._hl_injection_query == inj_query
    then
        -- No change; keep the lane state as-is. (A config-controlled
        -- query bump changes the string, so this branch only fires when
        -- the mode genuinely didn't change.)
        return
    end
    local prev_lang = self._hl_lang
    self._hl_lang = lang
    self._hl_query = query
    self._hl_injection_query = inj_query
    -- Language/query changed → drop everything. The lane keeps its
    -- parser per-language, but our cache + in-flight are stale.
    self._hl_bucket_cache = {}
    self._hl_names = {}
    self._hl_in_flight = nil
    self._hl_pending = nil
    self._hl_gen = self._hl_gen + 1
    -- Tell the lane to (re)build its parser+query for this language.
    -- For injecting languages (inj_query ~= nil), also send the bundle of
    -- every grammar the injection query may reference. It's a no-op if
    -- the query source string is unchanged.
    local injected_langs = (inj_query ~= nil) and build_injected_langs(self._major_modes) or nil
    local req = ss():make_hl_init_lang_req(lang, query, inj_query, injected_langs)
    ss():push(ss()._ptr.outbox_hl, {
        type = require("cursed.shared").MSG_HL_INITIALIZE_LANGUAGE,
        ptr = req,
    })
    -- NOTE: `req` (the malloc'd struct) is intentionally NOT wrapped in
    -- gc-wrap_gc here — ownership transfers to the lane, which frees it.
    -- We must prevent LuaJIT's GC from collecting the cdata before the
    -- push posts it; keeping a local ref through the push call suffices
    -- (ring_push copies the pointer into the ring, after which the
    -- cdata wrapper is irrelevant). Suppress the unused-local lint:
    local _keep = req
    if prev_lang ~= lang then
        local log = require("cursed.log")
        log.info("view", "hl language changed", { lang = lang, view_id = self._hl_view_id })
    end
end

--- Cold re-query of the viewport±margin after a wholesale buffer content
--- swap — undo, redo. Unlike an edit, there's NO TSInputEdit to give
--- the lane (the old_tree it retained is for pre-undo text and can't be
--- incrementally shifted to post-undo text), so we dispatch with
--- has_edit=false (cold parse of just the viewport margin buckets).
--- The lane replaces doc_state.old_tree with the fresh tree, so the
--- NEXT edit resumes incremental parsing as usual.
---
--- Clears the whole cache + in-flight + pending (all spans are stale
--- vs the swapped text), bumps _hl_gen so any in-flight async response
--- is treated as stale (gen mismatch → dropped), refreshes total bytes,
--- dispatches the cold viewport query, then sync-waits so post-undo render
--- shows correct spans (zero-flash) on files where the lane responds
--- within the cap; on large files it falls back to the translated-less
--- (here: empty) cache for a frame and the async install lands shortly.
---@param fallback_byte integer? cursor byte to anchor the viewport query on
function View:_hl_cold_requery(fallback_byte)
    if not self._hl_enabled then
        return
    end
    self._hl_bucket_cache = {}
    self._hl_names = {}
    self._hl_in_flight = nil
    self._hl_pending = nil
    self._hl_starts_cache = nil
    self._hl_starts_gen = nil
    self._hl_gen = self._hl_gen + 1
    self:_hl_refresh_total_bytes()
    local lo_b, hi_b = self:_hl_viewport_margin_bucket_range(fallback_byte)
    self:_hl_dispatch(lo_b, hi_b, false, nil, true)
    self:_hl_wait_response()
end

--- Compute the total document byte length and update bucket math.
--- Called from render before bucket dispatch.
function View:_hl_refresh_total_bytes()
    local b = self.buffer
    local total = 0
    local count = b:line_count()
    for i = 0, count - 1 do
        total = total + b:line_len(i)
    end
    self._hl_total_bytes = total
end

--- Number of buckets covering the current document.
---@return integer
function View:_hl_bucket_count()
    return math.floor((self._hl_total_bytes + BUCKET_BYTES - 1) / BUCKET_BYTES)
end

--- The editor calls this at the top of each render with the visible
--- window's absolute byte range. `_hl_tick` (called from
--- highlight_segments) uses it to decide which viewport buckets to query.
---@param start_byte integer
---@param end_byte integer
function View:_hl_notify_viewport(start_byte, end_byte)
    self._hl_last_vstart = start_byte
    self._hl_last_vend = end_byte
end

--- The bucket range covering viewport ± HL_MARGIN_BUCKETS. Edits only
--- re-query this bounded range (the visible truth + a safety margin so
--- error-recovery effects just outside the window are caught); the
--- translated cache serves as a good-enough color bridge for everything
--- off-screen until it scrolls into view. Falls back to the edit's own
--- bucket when no viewport has been notified yet (e.g. cold start).
---@param fallback_byte integer|nil start byte to anchor on if no viewport
---@return integer lo_b, integer hi_b
function View:_hl_viewport_margin_bucket_range(fallback_byte)
    local vstart = self._hl_last_vstart
    local vend = self._hl_last_vend
    local lo_b, hi_b
    if vstart == nil or vend == nil then
        local b = bucket_of(fallback_byte or 0)
        lo_b = b
        hi_b = b + 1
    else
        lo_b = bucket_of(vstart)
        hi_b = bucket_of(math.max(vend - 1, vstart)) + 1
    end
    lo_b = lo_b - HL_MARGIN_BUCKETS
    hi_b = hi_b + HL_MARGIN_BUCKETS
    if lo_b < 0 then
        lo_b = 0
    end
    local total = self:_hl_bucket_count()
    if hi_b > total then
        hi_b = total
    end
    if hi_b < lo_b then
        hi_b = lo_b
    end
    return lo_b, hi_b
end

--- Per-render query trigger. Called lazily from highlight_segments.
--- Fires dispatches for: (1) viewport buckets not yet cached, (2) any
--- pending edit query. Only one query is in flight at a time; a new
--- request supersedes `pending` (last-wins). The viewport fill covers
--- viewport ± HL_MARGIN_BUCKETS every render so scrolling into fresh
--- territory lights up without a frame of plain text; there is no
--- separate off-screen idle prefiller (it churned huge docs for no
--- visible benefit).
function View:_hl_tick()
    if not self._hl_enabled then
        return
    end
    -- Theme switch: the cached spans bake in resolved fg ints, so a
    -- colorscheme generation bump means they're stale. Clear the whole
    -- cache map; the lane re-emits capture names and we re-resolve fg
    -- as buckets come back. (line_starts also invalidate via _hl_generation.)
    local cs = require("cursed.colorscheme")
    local scheme_gen = cs.generation or 0
    if self._hl_scheme_gen ~= scheme_gen then
        self._hl_bucket_cache = {}
        self._hl_names = {}
        self._hl_in_flight = nil
        self._hl_pending = nil
        self._hl_scheme_gen = scheme_gen
    end
    self:_hl_refresh_total_bytes()

    -- Decide the next bucket to query. Priority:
    --   1. An edit that _hl_record_edit queued as `pending` (has_edit=true)
    --      wins — edit correctness outranks viewport fill.
    --   2. Otherwise, the first viewport±margin bucket not yet cached.
    --      On scroll into uncached territory this is what makes the
    --      newly-visible region light up ASAP (and prefetching ±margin
    --      means a small scroll is already cached).
    local pending = self._hl_pending
    local want_bucket ---@type integer|nil
    if pending ~= nil and pending.has_edit then
        -- An edit is waiting behind the in-flight request. Don't clobber
        -- it with a viewport fill — keep it as the next-to-fire.
        want_bucket = pending.bucket_start
    else
        local vstart = self._hl_last_vstart
        local vend = self._hl_last_vend
        if vstart ~= nil and vend ~= nil then
            want_bucket = self:_hl_next_viewport_absent_bucket(vstart, vend)
        end
    end

    if want_bucket == nil then
        return
    end

    if self._hl_in_flight ~= nil then
        -- Queue behind the in-flight request (last-wins for viewport
        -- fills, never clobber an edit-pending). When the viewport still
        -- has absent buckets this keeps them chaining back-to-back: as
        -- soon as one response lands, _hl_install_spans fires `pending`,
        -- the next render's _hl_tick repopulates pending with the next
        -- absent viewport bucket, and so on — so scrolling into a fresh
        -- region refills bucket-after-bucket instead of one per render
        -- with the viewport left default-colored in between.
        -- (Edit-pending is preserved by the priority branch above.)
        if pending == nil or not pending.has_edit then
            self._hl_pending = {
                bucket_start = want_bucket,
                bucket_end = want_bucket + 1,
                has_edit = false,
                edit = nil,
                from_edit = false, -- viewport fill; doc unchanged
            }
        end
        return
    end

    -- If the want came from an edit-pending, dispatch it WITH its edit so
    -- the lane does an incremental parse (not a cold one). This state is
    -- normally transient — _hl_install_spans fires edit-pending the
    -- instant the prior in-flight lands — but guarding here keeps _hl_tick
    -- correct if render interleaves before that fire runs, and prevents a
    -- cold re-query from clobbering the incremental edit path.
    if pending ~= nil and pending.has_edit then
        self._hl_pending = nil
        self:_hl_dispatch(pending.bucket_start, pending.bucket_end, true, pending.edit)
        return
    end

    self:_hl_dispatch(want_bucket, want_bucket + 1, false, nil)
end

--- First viewport-intersecting bucket still missing from the cache.
--- Scans the visible byte range (plus HL_MARGIN_BUCKETS on each side for
--- scroll prefetch) left→right. Returns nil when every viewport±margin
--- bucket is cached.
---@param vstart integer viewport start byte
---@param vend integer viewport end byte
---@return integer|nil
function View:_hl_next_viewport_absent_bucket(vstart, vend)
    -- Viewport ± HL_MARGIN_BUCKETS: prefetch the bucket(s) just outside
    -- the visible window so a small scroll (one row past a bucket
    -- boundary) is already cached by the time it scrolls in — no frame
    -- of plain-text. This is the ONLY fill path; off-screen buckets
    -- beyond the margin are left cold (queried on scroll-in).
    local first_b = bucket_of(vstart) - HL_MARGIN_BUCKETS
    local last_b = bucket_of(math.max(vend - 1, vstart)) + HL_MARGIN_BUCKETS
    if first_b < 0 then
        first_b = 0
    end
    local total = self:_hl_bucket_count()
    if last_b >= total then
        last_b = total - 1
    end
    -- Skip any bucket already covered by the in-flight request or by an
    -- edit-pending: re-querying it would just bump gen and force a
    -- redundant reparse, and the edit-pending one fires next anyway.
    local in_flight = self._hl_in_flight
    local pending = self._hl_pending
    local function covered(b)
        if in_flight ~= nil and b >= in_flight.bucket_start and b < in_flight.bucket_end then
            return true
        end
        if pending ~= nil and b >= pending.bucket_start and b < pending.bucket_end then
            return true
        end
        return false
    end
    for b = first_b, last_b do
        if self._hl_bucket_cache[b] == nil and not covered(b) then
            return b
        end
    end
    return nil
end

--- Translate every cached bucket's spans by an edit's byte delta, in
--- place. Spans entirely before `start_byte` are untouched; spans entirely
--- after `old_end_byte` shift by `delta = new_end_byte - old_end_byte`;
--- spans straddling the edited region [start_byte, old_end_byte) are
--- clipped to their still-valid tails (pre-edit head + shifted post-edit
--- tail) so non-edited text keeps its color across the async-lane
--- round-trip. This bridges the per-render gap between an edit and the
--- lane's incremental re-query, eliminating the full-bucket default-fg
--- flash that dropping the bucket caused.
---@param start_byte integer absolute byte offset where the edit begins
---@param old_end_byte integer absolute byte offset one past the edited region (pre-edit)
---@param new_end_byte integer absolute byte offset one past the edited region (post-edit)
function View:_hl_translate_cache(start_byte, old_end_byte, new_end_byte)
    local delta = new_end_byte - old_end_byte
    if delta == 0 then
        return
    end
    -- Rebuild into a fresh map keyed by the NEW bucket of each span's
    -- (possibly shifted) start_byte. highlight_segments reads only the
    -- buckets covering a line's byte range, so a span left in its OLD
    -- bucket row after a shift across a bucket boundary would vanish
    -- from rendering until the lane re-queries. Re-bucketing here keeps
    -- the translated bridge visibly correct off-screen.
    --
    -- Native cdata entries (from install) are read out here and placed
    -- into new_cache as Lua-table entries; translate is the off-screen
    -- bridge (the edited bucket is re-queried immediately, so its
    -- native entry is about to be replaced anyway). The per-bucket
    -- malloc'd keepalive ptr is freed via Lua GC when new_cache replaces
    -- the old cache (no manual free needed — ffi.gc owns it).
    local cache = self._hl_bucket_cache
    local new_cache = {}
    local function place(sb, eb, fg)
        local b = bucket_of(sb)
        local row = new_cache[b]
        if row == nil then
            row = {}
            new_cache[b] = row
        end
        row[#row + 1] = { start_byte = sb, end_byte = eb, fg = fg }
    end
    for b, entry in pairs(cache) do
        ---@type any
        local e = entry
        local is_native = e.lo ~= nil
        if not is_native and #entry == 0 then
            -- Preserve the "queried but empty" marker so an empty bucket
            -- isn't demoted back to absent (needlessly re-querying).
            local row = new_cache[b]
            if row == nil then
                new_cache[b] = {}
            end
        else
            -- Iterate this bucket's spans in either shape. For native
            -- cdata entries, lo/hi index into entry.spans (0-based) with
            -- entry.fgs[i+1] giving fg; for Lua-table entries, ipairs.
            local n
            local get
            if is_native then
                local sp = e.spans
                local fgs = e.fgs
                n = e.hi - e.lo
                local lo = e.lo
                get = function(i)
                    local s = sp[lo + i]
                    return tonumber(s.start_byte), tonumber(s.end_byte), fgs[lo + i + 1]
                end
            else
                n = #entry
                get = function(i)
                    local s = entry[i]
                    return s.start_byte, s.end_byte, s.fg
                end
            end
            for i = 1, n do
                local sb, eb, fg = get(i)
                if eb <= start_byte then
                    -- Entirely before the edit: keep unchanged.
                    place(sb, eb, fg)
                elseif sb >= old_end_byte then
                    -- Entirely after the edit: shift by delta.
                    place(sb + delta, eb + delta, fg)
                else
                    -- Overlaps the edited region. Keep the valid pre-edit
                    -- head [sb, start_byte) if it exists, and the shifted
                    -- post-edit tail [new_end_byte, eb+delta) if the span
                    -- extended past old_end_byte. The edited bytes
                    -- themselves are dropped (stale until the lane
                    -- repopulates); rendering falls back to default fg there
                    -- — only the actually-changed run, not the whole bucket.
                    if sb < start_byte then
                        place(sb, start_byte, fg)
                    end
                    if eb > old_end_byte then
                        place(new_end_byte, eb + delta, fg)
                    end
                end
            end
        end
    end
    -- A bucket whose spans were all inside the edited region simply
    -- isn't in new_cache (→ nil → re-queries lazily); acceptable because
    -- the whole bucket's text was edited (rare, e.g. bulk replace).
    self._hl_bucket_cache = new_cache
end

--- Called from batch_edit after every keystroke with EVERY edited
--- cursor's info (in document order) plus OLD-frame and NEW-frame
--- line_starts snapshots. Builds ONE composite TSInputEdit spanning
--- the first→last cursor so the lane does a single incremental parse
--- over the cursor span (bounded by cursor spread, NOT doc size), then
--- re-queries ONLY viewport ± margin. Re-querying the whole tail on
--- every keystroke was too slow on large documents.
---
--- Composite edit coordinates (all frame-correct, no per-cursor buffer
--- snapshots needed):
---   A = start_byte   (first cursor's pre-batch start, OLD frame)
---   B = old_end_byte (last cursor's old region-end, OLD frame)
---   C = new_end_byte (last cursor's result-end, NEW frame)
---   delta = C - B    (= total byte delta; shifts everything after B)
--- Tree-sitter keeps nodes before A and after B (shifted by delta),
--- and re-parses only [A, C) — which includes the unchanged intervening
--- text between cursors. That's a tiny, bounded cost (cursor spread).
---
--- A comes straight from the first cursor's pre-batch position; B from
--- the LAST cursor's pre-batch position (inserts: old_end == start) or
--- pre-batch start + deleted-region byte length (deletes); C from the
--- last cursor's (rl, rc) in the NEW frame. row/col POINTS are derived
--- from the byte offsets via starts_pre/starts_post (never via inverse
--- translator math, which is ambiguous for deletes).
---
--- A _single_ composite cache translate (not per-cursor) shifts
--- off-screen-after spans by the total delta and clips [A, B) — correct
--- because both A and B are in the OLD frame the cache currently lives
--- in. The bridge stays good-enough off-screen and gets refreshed when
--- scrolled into view.
---
--- Handles ALL edit kinds (insert, forward/backward delete, replace,
--- single- and multi-line) for both N==1 and multi-cursor, via three
--- line_starts snapshots plumbed from batch_edit:
---   starts_pre         : before the batch (first edit's region start A)
---   starts_before_last : right before the LAST non-skip edit (its
---                        region end B in pre-last frame)
---   starts_post        : after the batch (last result C)
--- cum_delta = total_before_last - total_pre converts B from pre-last
--- to pre-batch frame (one O(lines) snapshot before the last edit, no
--- per-cursor snapshots). The deletion byte length is implicit in B —
--- no extra plumbing needed beyond what the translator already tracks.
---@param edits table[] {sl,sc,rl,rc,kind,e1,e2,orig_line,orig_col} doc order
---@param crossed_newline boolean any edit split/joined a line
---@param frames table {starts_pre, starts_pre_total, starts_before_last,
---                    starts_before_last_total, starts_post}
function View:_hl_record_edit(edits, crossed_newline, frames)
    if not self._hl_enabled then
        return
    end
    self._hl_starts_cache = nil
    self._hl_starts_gen = nil
    self:_hl_refresh_total_bytes()

    local starts_pre = frames.starts_pre
    local starts_post = frames.starts_post
    local starts_before_last = frames.starts_before_last
    local first = edits[1]
    local last = edits[#edits]

    -- A: first edit's region START in pre-batch frame (first edit has no
    -- prior translator moves, so (sl,sc) IS pre-batch).
    local a_byte = (starts_pre[first.sl + 1] or 0) + first.sc
    -- C: last edit's result END in post-batch frame.
    local c_byte = (starts_post[last.rl + 1] or 0) + last.rc
    -- B: last edit's old region END, converted pre-last → pre-batch.
    -- For inserts the region is a point at (sl,sc); for delete/replace the
    -- region end is (el,ec). (el,ec)/(sl,sc) are in pre-last frame; the
    -- translator already moved the last cursor into that frame, and
    -- cum_delta undoes the earlier-edits shift to land in pre-batch.
    local region_end_pre_last
    if last.kind == "insert" then
        region_end_pre_last = (starts_before_last[last.sl + 1] or 0) + last.sc
    else
        local el, ec
        if type(last.kind) == "table" then
            el, ec = last.kind[1], last.kind[2]
        else
            el, ec = last.e1, last.e2
        end
        ---@cast el integer
        ---@cast ec integer
        region_end_pre_last = (starts_before_last[el + 1] or 0) + ec
    end
    local cum_delta = (frames.starts_before_last_total or 0) - (frames.starts_pre_total or 0)
    local b_byte = region_end_pre_last - cum_delta

    -- Re-query only viewport ± margin (bounded, fast).
    local lo_b, hi_b = self:_hl_viewport_margin_bucket_range(a_byte)

    require("cursed.log").info("view", "hl_edit branch", {
        gen = self._hl_gen + 1,
        n_edits = #edits,
        last_kind = type(last.kind) == "table" and "table" or last.kind,
        a_byte = a_byte,
        b_byte = b_byte,
        c_byte = c_byte,
        region_end_pre_last = region_end_pre_last,
        cum_delta = cum_delta,
        starts_pre_total = frames.starts_pre_total,
        starts_before_last_total = frames.starts_before_last_total,
        path = b_byte >= a_byte and "main" or "fallback",
        in_flight = self._hl_in_flight ~= nil,
    })

    if b_byte >= a_byte then
        -- Composite translate (one pass, OLD-frame A/B + NEW-frame C).
        -- Off-screen-after spans shift by total delta; [A, B) clipped.
        if c_byte ~= b_byte then
            self:_hl_translate_cache(a_byte, b_byte, c_byte)
        end
        local a_line, a_col = self:_hl_byte_to_point(starts_pre, a_byte)
        local b_line, b_col = self:_hl_byte_to_point(starts_pre, b_byte)
        local c_line, c_col = self:_hl_byte_to_point(starts_post, c_byte)
        local edit = {
            start_byte = a_byte,
            old_end_byte = b_byte,
            new_end_byte = c_byte,
            start_row = a_line,
            start_col = a_col,
            old_end_row = b_line,
            old_end_col = b_col,
            new_end_row = c_line,
            new_end_col = c_col,
        }
        _ = crossed_newline -- reserved for future line-mapping invalidation
        if self._hl_in_flight ~= nil then
            self._hl_pending = {
                bucket_start = lo_b,
                bucket_end = hi_b,
                has_edit = true,
                edit = edit,
                from_edit = true,
            }
            require("cursed.log").info("view", "hl_edit queued (in_flight non-nil)", {
                in_flight_gen = self._hl_in_flight.gen,
            })
            return
        end
        self:_hl_dispatch(lo_b, hi_b, true, edit)
        self:_hl_wait_response()
        return
    end

    -- Fallback (frames missing or degenerate range): cold reparse of
    -- viewport ± margin. Off-screen cache stays as-is and self-heals
    -- when scrolled into view.
    if self._hl_in_flight ~= nil then
        self._hl_pending = {
            bucket_start = lo_b,
            bucket_end = hi_b,
            has_edit = false,
            edit = nil,
            from_edit = true,
        }
        return
    end
    self:_hl_dispatch(lo_b, hi_b, false, nil)
    self:_hl_wait_response()
end

--- Map an absolute byte offset to (line, col) within a line_starts
--- prefix-sum array (1-indexed; starts[i] = byte offset of line i-1).
--- Used to derive TSInputEdit row/col points that are consistent with
--- the byte offsets (avoids inverse-translator ambiguity for deletes).
---@param starts integer[]
---@param byte integer
---@return integer line, integer col
function View:_hl_byte_to_point(starts, byte)
    -- Linear scan from the end is fine — calls are few per edit and the
    -- array is small relative to the per-render work. Binary search would
    -- be over-engineering here.
    local line = 0
    local col = byte
    for i = #starts, 2, -1 do
        if (starts[i] or 0) <= byte then
            line = i - 1
            col = byte - (starts[i] or 0)
            break
        end
    end
    return line, col
end

--- Build (or rebuild) the cached 1-indexed line start byte offsets.
--- Invalidated by any buffer gen bump (undo/redo count change). O(N)
--- on rebuild, amortized across many span→line lookups per render.
---@return integer[]
function View:_hl_line_starts()
    local gen = self:_hl_generation()
    if self._hl_starts_gen == gen and self._hl_starts_cache then
        ---@type integer[]
        return self._hl_starts_cache
    end
    local b = self.buffer
    local count = b:line_count()
    local starts = {} ---@type integer[]
    local acc = 0
    for i = 0, count - 1 do
        starts[i + 1] = acc
        acc = acc + b:line_len(i)
    end
    starts[count + 1] = acc
    self._hl_starts_cache = starts
    self._hl_starts_gen = gen
    ---@type integer[]
    return starts
end

--- Buffer generation counter (undo + redo count + colorscheme gen).
--- Folding the scheme gen in means a live theme switch invalidates the
--- cached line_starts (and, via _hl_theme_generation in the render
--- path, the whole bucket cache — since fg ints would otherwise be
--- stale; we resolve fg at render time so a theme switch is now free).
---@return integer
function View:_hl_generation()
    local cs = require("cursed.colorscheme")
    local scheme_gen = cs.generation or 0
    return tonumber(self.buffer._ptr.undo.count)
        + tonumber(self.buffer._ptr.redo.count)
        + scheme_gen * 1000000
end

--- Snapshot the buffer's full text as a (char* ptr, len) pair. The
--- pointer is a heap allocation the caller transfers to the lane via
--- `SharedState:make_hl_query_req` (no extra copy —
--- Buffer:write_text_direct already memcpy'd the piece table straight
--- into the calloc'd dest).
---@return any ptr
---@return integer len
function View:_hl_snapshot_text()
    -- Returns (char* ptr, integer len). The pointer is a heap allocation
    -- owned by the caller (transferred to the lane via make_hl_query_req).
    -- Direct piece-by-piece memcpy into the dest — no Lua string, no
    -- table.concat. ~7ms → <1ms on a 1.18MB / 16k-line doc.
    return self.buffer:write_text_direct()
end

--- Acquire the latest shared parse-tree snapshot for this view, published
--- by the highlight lane after its most recent successful parse.
--- Returns a read-only `ts.Tree` (RAII: ts_tree_delete on GC) plus the
--- lane gen that produced it, or (nil, nil) if no tree has been published
--- yet (e.g. before the first response lands).
---
--- The tree is a best-effort snapshot that may lag the latest keystroke
--- by one async round-trip: compare the returned `gen` against
--- `self._hl_gen` to decide staleness (gen < _hl_gen means a newer query
--- is in flight). NEVER call ts_tree_edit on the returned tree — main is
--- a read-only consumer; only the lane writes (under a mutex).
---
--- This is the #11 resolution (future-work report §4): a single shared
--- parse tree on main, mutex-guarded, instead of a second parse or a
--- sync ring query.
---@return any|nil tree ts.Tree (RAII), or nil if none published yet
---@return integer|nil gen lane-side gen that produced `tree`
function View:hl_tree()
    if not self._hl_enabled or self._hl_lang == nil or self._hl_view_id == 0 then
        return nil, nil
    end
    local ptr, gen = ss():acquire_tree(self._hl_view_id)
    if ptr == nil then
        return nil, nil
    end
    -- Wrap the fresh ts_tree_copy in an RAII Tree so ts_tree_delete runs
    -- on collection (main holds its own ref via the copy). Tree.new owns
    -- the pointer it's handed.
    local ts = require("cursed.ts")
    return ts.Tree.new(ptr), gen
end

--- Dispatch a query for a contiguous bucket range [bucket_start,
--- bucket_end) to the lane. Bumps gen, sends MSG_HL_QUERY with the
--- current text snapshot + (optional) edit. If a query is already in
--- flight, the new one clobbers `pending` (last wins).
---@param bucket_start integer first bucket (inclusive)
---@param bucket_end integer one past the last bucket (exclusive)
---@param has_edit boolean
---@param edit table? nil for viewport queries; TSLInputEdit fields for edit queries
function View:_hl_dispatch(bucket_start, bucket_end, has_edit, edit, force_cold)
    if not self._hl_enabled or self._hl_lang == nil then
        return
    end
    self._hl_gen = self._hl_gen + 1
    local pffi = require("cursed.posix_ffi")
    local tv = ffi.new("struct timeval[1]")
    pffi.C.gettimeofday(tv, nil)
    local t0 = tonumber(tv[0].tv_sec) * 1000000 + tonumber(tv[0].tv_usec)
    local text_ptr, text_len = self:_hl_snapshot_text()
    pffi.C.gettimeofday(tv, nil)
    local t1 = tonumber(tv[0].tv_sec) * 1000000 + tonumber(tv[0].tv_usec)
    local req = ss():make_hl_query_req(
        self._hl_lang,
        self._hl_view_id,
        bucket_start,
        bucket_end,
        self._hl_gen,
        has_edit,
        edit,
        text_ptr,
        text_len,
        force_cold
    )
    pffi.C.gettimeofday(tv, nil)
    local t2 = tonumber(tv[0].tv_sec) * 1000000 + tonumber(tv[0].tv_usec)
    self._hl_in_flight =
        { gen = self._hl_gen, bucket_start = bucket_start, bucket_end = bucket_end }
    ss():push(ss()._ptr.outbox_hl, {
        type = require("cursed.shared").MSG_HL_QUERY,
        ptr = req,
    })
    require("cursed.log").info("view", "hl_dispatch", {
        gen = self._hl_gen,
        has_edit = has_edit,
        text_len = text_len,
        buckets = bucket_end - bucket_start,
        snapshot_us = t1 - t0,
        makereq_us = t2 - t1,
    })
    local _keep = req -- prevent GC of the cdata wrapper before the push copies the pointer
end

--- Zero-flash on-screen path: synchronously wait (busy-poll the lane's
--- inbox_hl) for the just-dispatched query to land and be installed,
--- up to HL_SYNC_WAIT_MS. By installing the real spans BEFORE the
--- post-edit render, the user never sees the semantically-stale
--- translated cache for the edited region (translate only byte-shifts
--- existing spans — it can't know the new syntax).
---
--- The lane already owns the parser/query/old_tree (single source of
--- truth — no main-side parser duplication); we just wait for it, off
--- the keyloop, while it parses the viewport±margin incrementally.
--- Busy-polls the ring via editor:drain_hl_inbox rather than blocking
--- on the kqueue so we DON'T consume EVFILT_USER wakes that the main
--- loop's select() still needs to observe for inbox_io/resize — any
--- leftover inbox_hl wake is harmlessly re-drained by the main loop
--- after we've already popped the message.
---
--- Circuit breaker: HL_SYNC_STALL_LIMIT consecutive timeouts disable
--- the sync path so a slow/dead lane can't add latency on every
--- keystroke. Re-enabled when an async install lands (lane caught up).
---
--- Only called when _hl_record_edit actually dispatched (no in-flight
--- was pending). If a query was already in flight at edit time, the
--- edit is queued as pending and we can't wait for it (it hasn't been
--- sent yet) — that path falls back to the async translate bridge.
---@return boolean installed true if our response landed within the cap
function View:_hl_wait_response()
    local log = require("cursed.log")
    local in_flight = self._hl_in_flight
    if in_flight == nil then
        return true
    end
    -- Circuit breaker: too many consecutive timeouts → lane is too slow
    -- to keep up; stop blocking the keyloop. Async path still works.
    if (self._hl_sync_stalls or 0) >= HL_SYNC_STALL_LIMIT then
        log.info("view", "hl_wait skip (breaker)", { stalls = self._hl_sync_stalls })
        return false
    end
    local target_gen = in_flight.gen
    if not self.editor or not self.editor.drain_hl_inbox then
        log.warn("view", "hl_wait no drain", { has_editor = self.editor ~= nil })
        return false
    end
    local pffi = require("cursed.posix_ffi")
    local tv = ffi.new("struct timeval[1]")
    pffi.C.gettimeofday(tv, nil)
    local start_us = tonumber(tv[0].tv_sec) * 1000000 + tonumber(tv[0].tv_usec)
    local deadline_us = start_us + HL_SYNC_WAIT_MS * 1000
    local iters = 0
    while true do
        iters = iters + 1
        -- Drain whatever the lane has pushed so far (routes to ALL
        -- views via _hl_install_spans, frees buffers). If our gen
        -- lands, _hl_install_spans clears _hl_in_flight.
        self.editor:drain_hl_inbox()
        local cur = self._hl_in_flight
        if cur == nil or cur.gen ~= target_gen then
            -- Landed and installed (or superseded). Reset breaker.
            pffi.C.gettimeofday(tv, nil)
            local elapsed_us = tonumber(tv[0].tv_sec) * 1000000 + tonumber(tv[0].tv_usec) - start_us
            self._hl_sync_stalls = 0
            log.info(
                "view",
                "hl_wait ok",
                { gen = target_gen, elapsed_us = elapsed_us, iters = iters }
            )
            return true
        end
        pffi.C.gettimeofday(tv, nil)
        local now_us = tonumber(tv[0].tv_sec) * 1000000 + tonumber(tv[0].tv_usec)
        if now_us >= deadline_us then
            -- Timeout: fall back to the translated cache for this
            -- frame. Bump the breaker; async drain will install the
            -- real spans shortly and reset it.
            self._hl_sync_stalls = (self._hl_sync_stalls or 0) + 1
            log.warn("view", "hl_wait TIMEOUT", {
                gen = target_gen,
                elapsed_us = now_us - start_us,
                iters = iters,
                stalls = self._hl_sync_stalls,
            })
            return false
        end
        -- Yield the context switch briefly so we don't spin a core.
        -- 50µs poll granularity: a sub-ms lane response is caught within
        -- ~50µs of landing — negligible vs parse time.
        pffi.C.usleep(50)
    end
end

--- Install spans returned by the lane into the bucket cache.
--- The response covers a contiguous bucket range [bucket_start, bucket_end);
--- every bucket in the range is replaced with whatever came back (spans
--- grouped by start byte, empty {} for buckets the lane had no captures
--- for) so empty buckets are correctly marked "queried" and don't re-query.
--- Returns true if the response matched this view's in-flight request
--- (so main.lua can stop routing the buffer) AND ownership of the
--- response buffer was transferred to the cache (caller must NOT free).
--- On mismatch (stale gen) or skip-install (edit pending), returns true
--- but takes NO ownership — the caller frees the buffer in that case.
--- On `false` (no view claimed it) the caller also frees.
---@param gen integer
---@param bucket_start integer first bucket (inclusive) the response covers
---@param bucket_end integer one past the last bucket (exclusive)
---@param count integer
---@param msg_ptr any raw struct HlSpansHdr* (header; kept as ffi.gc keepalive)
---@param spans_ptr any struct HlSpan* (into msg_ptr + sizeof HlSpansHdr)
---@param name_count integer
---@param names_ptr any struct HlName*
---@return boolean claimed
function View:_hl_install_spans(
    gen,
    bucket_start,
    bucket_end,
    count,
    msg_ptr,
    spans_ptr,
    name_count,
    names_ptr
)
    if not self._hl_enabled then
        return false
    end
    -- Stale: a response for a gen we've since superseded. Drop it.
    if self._hl_in_flight == nil or self._hl_in_flight.gen ~= gen then
        -- claimed iff we have an in-flight to match the view; either way
        -- we don't retain the buffer — free it ourselves so the caller's
        -- contract stays "claimed == ownership transferred".
        ffi.C.free(msg_ptr)
        return self._hl_in_flight ~= nil
    end

    -- A pending edit means the document has advanced past this response
    -- (an edit landed while this query was in flight, queued by
    -- _hl_record_edit). The response's spans describe an OLDER document
    -- state; installing them would overlay misaligned colors for one or
    -- more frames — the visible "flash" while typing. Skip the install:
    -- the translated cache is forward-correct and only default-colors
    -- the edited run (strictly less wrong than a stale-state overlay),
    -- so let it serve the frame(s) until the now-current query lands.
    -- Clear in_flight and fire the pending edit query immediately.
    local pending = self._hl_pending
    if pending ~= nil and pending.from_edit then
        self._hl_in_flight = nil
        self._hl_pending = nil
        self:_hl_dispatch(pending.bucket_start, pending.bucket_end, pending.has_edit, pending.edit)
        ffi.C.free(msg_ptr) -- not installed; freed here (caller leaves alone)
        return true
    end

    -- Build the capture-name table for fg resolution.
    local names = {}
    for i = 0, name_count - 1 do
        names[i + 1] = ffi.string(names_ptr[i].name)
    end
    local ColorScheme = require("cursed.colorscheme")
    local scheme = ColorScheme.active

    -- Take OWNERSHIP of the lane's freshly-malloc'd buffer (header +
    -- spans + names are ONE allocation). Previously we copied every
    -- span into a per-bucket Lua table here and let the caller free
    -- the buffer — ~2700 per-span Lua allocations on a 2-bucket query,
    -- plus the same again at render. Now the cdata `spans_ptr` IS the
    -- cache: render iterates it directly (spans[i].start_byte etc.),
    -- and we resolve name→fg ONCE into a parallel Lua int array
    -- (fgs[i+1] aligns with spans[i]). The header ptr is the ffi.gc
    -- keepalive — its finalizer frees the spans too (same alloc).
    -- The caller (drain_hl_inbox) frees only when install returns
    -- false (stale/unclaimed).
    --
    -- First pass: resolve fgs for every span, counting survivors.
    -- Unresolvable-fg spans are dropped (same as before). We compact
    -- survivors into a tightly-packed cdata buffer so fgs[i] aligns
    -- with spans[i-1] without gaps.
    local fgs = {}
    local n_written = 0
    local HlSpan_size = ffi.sizeof("struct HlSpan")
    for i = 0, count - 1 do
        local s = spans_ptr[i]
        local cap_name = names[tonumber(s.cap_index) + 1]
        local fg = nil
        if scheme ~= nil and cap_name ~= nil then
            fg = scheme:resolve_capture(cap_name)
        end
        -- Need eb > sb too (matches the old `if fg ~= nil and eb > sb`);
        -- record as a survivor only if both hold.
        local eb = tonumber(s.end_byte)
        local sb = tonumber(s.start_byte)
        if fg ~= nil and eb > sb then
            n_written = n_written + 1
            fgs[n_written] = fg
        end
    end
    -- Build the compact spans buffer (survivors only, post-filter).
    local keep_ptr ---@type any ffi.gc'd char* keepalive (frees spans too)
    local keep_spans ---@type any struct HlSpan* into keep_ptr
    if n_written == count then
        -- Common case (everything resolved + valid): keep the lane's
        -- buffer wholesale, just attach the gc finalizer.
        keep_ptr = ffi.gc(ffi.cast("char *", msg_ptr), ffi.C.free)
        keep_spans = spans_ptr
    elseif n_written > 0 then
        -- Compact: malloc n_written spans, copy survivors in.
        local compact = ffi.C.calloc(1, n_written * HlSpan_size)
        local compact_spans = ffi.cast("struct HlSpan *", compact)
        local w = 0
        for i = 0, count - 1 do
            local s = spans_ptr[i]
            local cap_name = names[tonumber(s.cap_index) + 1]
            local fg = (scheme ~= nil and cap_name ~= nil) and scheme:resolve_capture(cap_name)
                or nil
            local eb = tonumber(s.end_byte)
            local sb = tonumber(s.start_byte)
            if fg ~= nil and eb > sb then
                compact_spans[w].start_byte = s.start_byte
                compact_spans[w].end_byte = s.end_byte
                compact_spans[w].cap_index = 0 -- unused post-install
                w = w + 1
            end
        end
        keep_ptr = ffi.gc(ffi.cast("char *", compact), ffi.C.free)
        keep_spans = compact_spans
        -- The lane's original buffer is no longer needed.
        ffi.C.free(msg_ptr)
    else
        keep_ptr = nil
        keep_spans = nil
        ffi.C.free(msg_ptr)
    end

    -- Initialize every bucket in the range to an empty marker so buckets
    -- with no captures are recorded as "queried" (won't re-query forever).
    local cache = self._hl_bucket_cache
    for b = bucket_start, bucket_end - 1 do
        cache[b] = {}
    end
    -- Partition survivors into per-bucket slices. The lane emits spans
    -- in start-byte order, so survivors are sorted by start_byte; bucket
    -- boundaries (8KB) thus partition them into contiguous slices. Each
    -- bucket entry holds {ptr=keepalive, spans=cdata, fgs=int[], lo, hi}
    -- where [lo, hi) is the index range into keep_spans/fgs for this
    -- bucket — render iterates keep_spans[lo..hi) and reads fgs[i+1].
    -- All buckets sharing a response point at the SAME keep_ptr (one
    -- ffi.gc, freed once when superseded).
    if n_written > 0 then
        local b_lo = bucket_start
        local i = 0
        while i < n_written do
            local sb = tonumber(keep_spans[i].start_byte)
            ---@cast sb integer
            local b = bucket_of(sb)
            -- Advance i while still in bucket b.
            local j = i
            while j < n_written do
                local sb2 = tonumber(keep_spans[j].start_byte)
                ---@cast sb2 integer
                if bucket_of(sb2) ~= b then
                    break
                end
                j = j + 1
            end
            -- Spans [i, j) belong to bucket b. lo/hi are 0-based into
            -- keep_spans; fgs is 1-based so fgs[i+1] aligns with span i.
            cache[b] = {
                ptr = keep_ptr,
                spans = keep_spans,
                fgs = fgs,
                lo = i,
                hi = j,
            }
            i = j
        end
    end
    self._hl_in_flight = nil

    -- Newly-installed spans change the colors of any visible rows in the
    -- installed bucket range. Damage tracking would otherwise skip
    -- repainting them (cursor/viewport didn't move), leaving stale
    -- plain-text on screen until the next keystroke. Force a full repaint
    -- when the installed range intersects the current viewport.
    if self.editor ~= nil then
        local vvstart = self._hl_last_vstart
        local vvend = self._hl_last_vend
        if vvstart ~= nil and vvend ~= nil then
            local a = bucket_of(vvstart)
            local b = bucket_of(math.max(vvend - 1, vvstart))
            if not (bucket_end <= a or bucket_start > b) then
                self.editor:request_full_damage()
            end
        else
            self.editor:request_full_damage()
        end
    end

    -- Lane responded successfully within its own async time → it's
    -- healthy. Reset the sync-wait circuit breaker so the zero-flash
    -- path re-engages (covers the case where a transient stall tripped
    -- it but the lane has since caught up).
    self._hl_sync_stalls = 0
    if self._hl_pending then
        local p = self._hl_pending
        ---@cast p table
        self._hl_pending = nil
        self:_hl_dispatch(p.bucket_start, p.bucket_end, p.has_edit, p.edit)
    end
    return true
end

--- Union all cached spans intersecting `[start_byte, end_byte)` and map
--- them to the visible line `li`, clamped to `[chunk_start, chunk_end)`.
--- Returns nil (→ plain default) when highlighting is off / no spans.
---@param li integer 0-based line index
---@param chunk_start integer byte offset within the line of the chunk start
---@param chunk_end integer byte offset within the line of the chunk end
---@return {cs: integer, ce: integer, fg: integer}[]|nil
function View:highlight_segments(li, chunk_start, chunk_end)
    if not self._hl_enabled then
        return nil
    end
    self:_hl_tick()
    local cache = self._hl_bucket_cache
    if next(cache) == nil then
        return nil
    end
    -- Compute this line's absolute byte range from line_starts.
    local starts = self:_hl_line_starts()
    local line_start_byte = starts[li + 1] or 0
    local next_start = starts[li + 2]
    local line_end_byte
    if next_start == nil then
        line_end_byte = starts[#starts] or 0
    else
        -- A line's content excludes its trailing \n (it's the last byte
        -- of the line's [start, next) range).
        line_end_byte = next_start - 1
    end
    local chunk_abs_start = line_start_byte + chunk_start
    local chunk_abs_end = math.min(line_start_byte + chunk_end, line_end_byte)

    -- Union every cached bucket intersecting this line's byte range.
    -- Buckets come in two shapes: native cdata entries from install
    -- ({ptr,spans,fgs,lo,hi} — iterate spans[lo..hi) + fgs[i+1], zero
    -- per-span Lua allocations) and Lua-table entries from translate
    -- ({{sb,eb,fg},...} — expected to be transient off-screen bridges;
    -- the edited bucket gets re-queried, so they're short-lived). The
    -- `{}` empty-queried marker has no spans and falls through.
    local first_b = bucket_of(line_start_byte)
    local last_b = bucket_of(math.max(line_end_byte - 1, line_start_byte))
    local spans = {} ---@type {start_byte:integer, end_byte:integer, fg:integer}[]
    for b = first_b, last_b do
        local bucket = cache[b]
        if bucket then
            ---@type any
            local bk = bucket
            local lo = bk.lo
            if lo ~= nil then
                -- Native cdata entry.
                local sp = bk.spans
                local fgs = bk.fgs
                local hi = bk.hi
                for i = lo, hi - 1 do
                    local sb = tonumber(sp[i].start_byte)
                    local eb = tonumber(sp[i].end_byte)
                    ---@cast sb integer
                    ---@cast eb integer
                    if eb > chunk_abs_start and sb < chunk_abs_end then
                        local fg = fgs[i + 1]
                        ---@cast fg integer
                        spans[#spans + 1] = { start_byte = sb, end_byte = eb, fg = fg }
                    end
                end
            else
                -- Lua-table entry (translate output) or empty marker.
                for _, s in ipairs(bucket) do
                    if s.end_byte > chunk_abs_start and s.start_byte < chunk_abs_end then
                        spans[#spans + 1] = s
                    end
                end
            end
        end
    end
    if #spans == 0 then
        return nil
    end
    -- Sort by start byte for contiguous paint.
    table.sort(spans, function(a, b)
        return a.start_byte < b.start_byte
    end)
    local out = {}
    for _, s in ipairs(spans) do
        local cs = math.max(s.start_byte, chunk_abs_start) - line_start_byte
        local ce = math.min(s.end_byte, chunk_abs_end) - line_start_byte
        if ce > cs then
            cs = cs - chunk_start
            ce = ce - chunk_start
            -- Fill any gap before this span with default (caller's job).
            out[#out + 1] = { cs = cs, ce = ce, fg = s.fg }
        end
    end
    return out
end

----------------------------------------------------------------------------------------------------
-- Line helpers (buffer-relative; unchanged contract)
----------------------------------------------------------------------------------------------------

--- Get the display length of a line (excluding trailing \n).
---@param li integer 0-based line index
---@return integer
function View:content_len(li)
    local ll = self.buffer:line_len(li)
    if ll > 0 then
        return ll - 1
    end
    return 0
end

--- Get the number of lines in the document.
---@return integer
function View:line_count()
    return self.buffer:line_count()
end

--- Compute the on-screen geometry of the text column for a given
--- terminal width, mirroring exactly what Editor:render paints. When
--- `view.margin` is set (and narrower than the available text area),
--- the gutter + text column is centered within the window; otherwise
--- the gutter sits at column 0 and text fills the rest. Centralized so
--- the mouse click→buffer-coordinate mapping can't drift from render.
---@param w integer terminal width (columns)
---@return integer gutter_width, integer text_x, integer text_width, integer block_x, integer block_w
function View:text_geometry(w)
    local line_count = self.buffer:line_count()
    local gutter_width = math.max(3, #tostring(line_count) + 3) -- 1-col left margin + number + 2-col right margin
    local avail_text = w - gutter_width
    if avail_text <= 0 then
        return gutter_width, 0, 0, 0, 0
    end
    local margin = self.margin
    local text_width, block_x, block_w
    if margin and margin > 0 and margin < avail_text then
        text_width = margin
        block_w = gutter_width + text_width
        block_x = math.floor((w - block_w) / 2)
    else
        text_width = avail_text
        block_w = w
        block_x = 0
    end
    local text_x = block_x + gutter_width
    return gutter_width, text_x, text_width, block_x, block_w
end

--- Count the number of characters between two positions.
---@param start_line integer
---@param start_col integer
---@param end_line integer
---@param end_col integer
---@return integer
function View:chars_between(start_line, start_col, end_line, end_col)
    if start_line == end_line then
        return end_col - start_col
    end
    local count = self:content_len(start_line) - start_col
    for li = start_line + 1, end_line - 1 do
        count = count + self:content_len(li) + 1
    end
    count = count + 1 + end_col
    return count
end

--- Extract text between two positions.
---@param start_line integer
---@param start_col integer
---@param end_line integer
---@param end_col integer
---@return string
function View:text_between(start_line, start_col, end_line, end_col)
    if start_line == end_line then
        local text = self.buffer:line_text(start_line)
        local len = #text
        if len > 0 and text:byte(len) == 10 then
            len = len - 1
        end
        return text:sub(start_col + 1, end_col)
    end
    local parts = {}
    do
        local text = self.buffer:line_text(start_line)
        parts[#parts + 1] = text:sub(start_col + 1)
    end
    for li = start_line + 1, end_line - 1 do
        parts[#parts + 1] = self.buffer:line_text(li)
    end
    if end_col > 0 then
        local text = self.buffer:line_text(end_line)
        parts[#parts + 1] = text:sub(1, end_col)
    end
    return table.concat(parts)
end

----------------------------------------------------------------------------------------------------
-- Soft line wrap (unchanged; view-global cache, cursor-independent)
----------------------------------------------------------------------------------------------------

--- Compute the number of screen rows a logical line occupies with soft wrapping.
--- Walks grapheme display widths (via the per-line grapheme cache) so wide
--- CJK/emoji glyphs consume 2 columns and zero-width combinings consume 0,
--- rather than the old `ceil(bytes / wrap_width)` which assumed 1 byte = 1 col.
---@param li integer 0-based line index
---@return integer
function View:wrap_rows(li)
    if not self.wrap_width or self.wrap_width <= 0 then
        return 1
    end
    local _, widths, _, _ = self:_graph(li)
    local w = self.wrap_width
    -- Count rows by tracking the running display column; each grapheme
    -- either fits on the current row (col + gw <= w) or starts a new row.
    -- A grapheme wider than `w` is forced onto its own row (it overflows
    -- but never wraps mid-glyph).
    if #widths == 0 then
        return 1
    end
    local rows, col = 1, 0
    for i = 1, #widths do
        local gw = widths[i]
        if col + gw > w then
            rows = rows + 1
            col = gw
            -- A grapheme wider than the wrap width still occupies one row
            -- of its own; col may exceed w but that's the degenerate case.
            if col > w then
                col = 0
                -- Leave the over-wide grapheme alone on its row; next one starts fresh.
            end
        else
            col = col + gw
        end
    end
    return rows
end

--- Invalidate the wrap cache (call when buffer content changes or wrap_width changes).
function View:invalidate_wrap_cache()
    self._wrap_rows = nil
    self._wrap_cum = nil
    self._wrap_built = nil
    self._wrap_end = nil
    self._wrap_total = nil
    self._graph_cache = nil
    self._graph_line_text = nil
    self._graph_gen = nil
    -- Invalidate the auto-scroll guard: a wrap reflow (resize or edit)
    -- can shift the cursor's screen row even though its logical (line,
    -- col) is unchanged, so the guard's stored position no longer proves
    -- the viewport is correctly positioned. Forcing the next
    -- scroll_to_cursor re-centers on the cursor after the reflow.
    self._scroll_guard_line = nil
    self._scroll_guard_col = nil
end

--- Invalidate ONLY the per-line grapheme cache (not the wrap cache).
--- Called after every buffer mutation (batch_edit) so the renderer —
--- which reads line text + grapheme runs from this cache even in
--- no-wrap mode — never displays pre-edit text. The staleness guard in
--- `ensure_graph_gen` keys off (undo.count + redo.count), but an open
--- edit group leaves that sum invariant across consecutive keystrokes,
--- so the cache would otherwise go stale mid-group and the rendered
--- text would lag the cursor. Cheap (just nils tables; rebuild is lazy).
function View:invalidate_graph_cache()
    self._graph_cache = nil
    self._graph_line_text = nil
    self._graph_gen = nil
end

----------------------------------------------------------------------------------------------------
-- Per-line grapheme cache
----------------------------------------------------------------------------------------------------
-- Mirrors _wrap_rows / _wrap_gen: lazily parses each line into a grapheme
-- skeleton (byte_starts / widths / prefix) on first access, invalidated on
-- the undo+redo generation counter. The skeleton is the View's single
-- source of truth for byte↔display-column and grapheme-cluster navigation
-- (cursor motion, wrap math, mouse clicks, render slicing all query it).
-- `line_len` is cached per line alongside the skeleton so past-end queries
-- don't re-call buffer:line_len().

--- Proactively drop the grapheme cache if the buffer was edited since the
--- last build. Called by every accessor before reading the cache.
local function ensure_graph_gen(view)
    local gen = tonumber(view.buffer._ptr.undo.count) + tonumber(view.buffer._ptr.redo.count)
    if view._graph_gen ~= gen then
        view._graph_cache = nil
        view._graph_line_text = nil
        view._graph_gen = gen
    end
end

--- Get (or build lazily) the parsed grapheme skeleton for logical line `li`.
--- The skeleton is computed from the line text WITHOUT its trailing newline
--- (the renderer/motion code never wants the newline in a cluster).
--- Returns `byte_starts, widths, prefix, line_len` — the three tables
--- documented in `cursed.utf8.parse_line`, plus `line_len` (byte length of
--- the stripped text) for past-end queries.
---@param li integer 0-based line index
---@return integer[] byte_starts
---@return integer[] widths
---@return integer[] prefix
---@return integer line_len
function View:_graph(li)
    ensure_graph_gen(self)
    local cache = self._graph_cache
    if cache == nil then
        cache = {}
        self._graph_cache = cache
    end
    local entry = cache[li + 1]
    if entry ~= nil then
        return entry.byte_starts, entry.widths, entry.prefix, entry.line_len
    end
    local text = self.buffer:line_text(li)
    -- Strip the trailing newline (every line carries one; see buffer model).
    if #text > 0 and text:byte(#text) == 10 then
        text = text:sub(1, #text - 1)
    end
    local bs, w, p = utf8.parse_line(text)
    entry = { byte_starts = bs, widths = w, prefix = p, line_len = #text }
    cache[li + 1] = entry
    -- Also retain the stripped text for the renderer (slice-on-grapheme).
    local tc = self._graph_line_text
    if tc == nil then
        tc = {}
        self._graph_line_text = tc
    end
    tc[li + 1] = text
    return bs, w, p, entry.line_len
end

--- Get the cached stripped line text (without trailing newline). This is
--- the same string the skeleton was parsed from, so byte offsets line up.
---@param li integer 0-based line index
---@return string
function View:_line_text_stripped(li)
    ensure_graph_gen(self)
    local tc = self._graph_line_text
    if tc == nil or tc[li + 1] == nil then
        -- Force the skeleton build, which also populates the text cache.
        self:_graph(li)
        tc = self._graph_line_text
    end
    return tc and tc[li + 1] or ""
end

--- Total display width of a line (column just past its last grapheme).
---@param li integer 0-based line index
---@return integer
function View:line_display_width(li)
    local _, w, p, _ = self:_graph(li)
    return utf8.line_width(p, w)
end

--- Display column (0-based) of a byte offset within a line.
--- A byte offset equal to the line's content length maps to the line's
--- total display width (past the last grapheme).
---@param li integer 0-based line index
---@param b integer 0-based byte offset
---@return integer
function View:byte_to_col(li, b)
    local bs, w, p, ll = self:_graph(li)
    return utf8.byte_to_col(bs, p, w, b, ll)
end

--- Byte offset (0-based) of a display column within a line.
--- Columns inside a wide grapheme snap to that grapheme's start byte
--- (so the cursor never lands mid-codepoint). Past-end columns clamp
--- to the line's content length.
---@param li integer 0-based line index
---@param col integer 0-based display column
---@return integer
function View:col_to_byte(li, col)
    local bs, w, p, ll = self:_graph(li)
    return utf8.col_to_byte(bs, p, w, col, ll)
end

--- Advance `n` graphemes from byte offset `b`, clamped to line bounds.
--- `n` may be negative. Returns the byte offset of the resulting boundary.
---@param li integer 0-based line index
---@param b integer 0-based starting byte offset
---@param n integer signed grapheme count
---@return integer
function View:advance_grapheme(li, b, n)
    local bs, _, _, ll = self:_graph(li)
    return utf8.advance_grapheme(bs, b, n, ll)
end

--- Ensure the wrap cache exists and is not stale, WITHOUT building it
--- forward. The cache is built lazily from line 0 by `extend_wrap_cache`
--- as queries demand it, so opening a 37k-line file and sitting at the
--- top parses only the ~viewport-depth of lines instead of all of them.
--- Proactively invalidates if the buffer's undo+redo generation changed
--- (an edit) so we never return stale cumulative offsets.
local function ensure_wrap_cache(view)
    if view._wrap_rows and view._wrap_gen then
        local gen = tonumber(view.buffer._ptr.undo.count) + tonumber(view.buffer._ptr.redo.count)
        if gen ~= view._wrap_gen then
            view._wrap_rows = nil
            view._wrap_cum = nil
            view._wrap_built = nil
            view._wrap_end = nil
            view._wrap_total = nil
        end
    end
    if view._wrap_rows then
        return
    end
    view._wrap_rows = {} -- rows[i] = screen rows for logical line (i-1)
    view._wrap_cum = {} -- cum[i] = screen row where logical line (i-1) starts
    view._wrap_built = 0 -- number of lines (1-based count) built so far
    view._wrap_end = 0 -- total screen rows of all built lines (start of first unbuilt)
    view._wrap_total = nil -- cached total once fully built
    view._wrap_gen = tonumber(view.buffer._ptr.undo.count) + tonumber(view.buffer._ptr.redo.count)
end

--- Extend the wrap cache forward so that line index `upto_li` (0-based)
--- is covered (i.e. build entries 1..upto_li+1). Builds incrementally
--- from the current `_wrap_built`; each new line calls `wrap_rows(li)`
--- (which is itself grapheme-cached). Cheap when extending by a few
--- lines (the common viewport/scroll case); only expensive when asked
--- to cover a near-EOF line from a cold cache (rare: goto-line / EOF
--- clamp), and even then it's amortized permanently into the cache.
---@param upto_li integer 0-based line index to cover
function View:_extend_wrap_to(upto_li)
    ensure_wrap_cache(self)
    if upto_li < 0 then
        return
    end
    local n = self:line_count()
    if upto_li >= n then
        upto_li = n - 1
    end
    local built = self._wrap_built or 0
    local target = upto_li + 1 -- 1-based index to cover
    if built >= target then
        return
    end
    local rows = self._wrap_rows
    local cum = self._wrap_cum
    local screen_row = self._wrap_end or 0
    local extend_t0 = profile.now_us()
    for li = built, upto_li do
        local r = self:wrap_rows(li)
        rows[li + 1] = r
        cum[li + 1] = screen_row
        screen_row = screen_row + r
    end
    self._wrap_built = upto_li + 1
    self._wrap_end = screen_row
    if self._wrap_built >= n then
        self._wrap_total = screen_row
    end
    profile.span("view", "wrap_cache_extend", extend_t0, { from = built, to = upto_li })
end

--- Return the screen row where logical line `li` starts (0-based).
---@param li integer 0-based line index
---@return integer
function View:line_to_screen_row(li)
    if not self.wrap_width or self.wrap_width <= 0 then
        return li
    end
    self:_extend_wrap_to(li)
    return self._wrap_cum[li + 1] or 0
end

--- Return the logical line index and sub-row offset for a given screen row.
---@param screen_row integer 0-based screen row
---@return integer li 0-based logical line index
---@return integer sub_row 0-based row within the wrapped line
function View:screen_row_to_line(screen_row)
    if not self.wrap_width or self.wrap_width <= 0 then
        return screen_row, 0
    end
    ensure_wrap_cache(self)
    -- Empty document guard
    if self:line_count() == 0 then
        return 0, 0
    end
    -- If the queried screen row is beyond what we've built, extend the
    -- cache forward until it's covered (or we hit EOF). This is the
    -- lazy path: scrolling down extends the cache only as far as needed.
    -- `_wrap_end` is the start row of the first unbuilt line, i.e. the
    -- first row NOT yet covered.
    -- Extend by a batch (up to the next 64 lines or EOF) to amortize
    -- the per-call overhead when scrolling far in one frame.
    local built = self._wrap_built or 0
    local n = self:line_count()
    local end_row = self._wrap_end or 0
    while built < n and screen_row >= end_row do
        local target = math.min(built + 64, n - 1)
        self:_extend_wrap_to(target)
        built = self._wrap_built
        end_row = self._wrap_end or 0
    end
    -- Binary search in cumulative table (the built prefix)
    local lo, hi = 1, built
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if self._wrap_cum[mid] <= screen_row then
            lo = mid
        else
            hi = mid - 1
        end
    end
    local li = lo - 1 -- back to 0-based
    local sub_row = screen_row - self._wrap_cum[lo]
    return li, sub_row
end

----------------------------------------------------------------------------------------------------
-- Viewport-local positioning (line-anchored scroll model)
--
-- These helpers reason about screen positions RELATIVE to the current
-- viewport anchor (scroll_li, scroll_sub_row). They walk only as far as
-- the viewport needs (~text_rows lines), never building the whole
-- wrap-cache prefix — so positioning the viewport anywhere in the file
-- is O(viewport), not O(document). The legacy absolute helpers above
-- (line_to_screen_row / screen_row_to_line / total_screen_rows) are kept
-- only for the no-wrap fast path and unit tests; the render + scroll
-- paths use these instead.
----------------------------------------------------------------------------------------------------

--- Return the row offset of a buffer position (li, sub) RELATIVE to
--- the viewport top anchor. Walks forward from scan_li accumulating
--- wrap_rows until li is reached; if (li,sub) is ABOVE the anchor,
--- walks backward up to `budget` rows and returns a negative row. For
--- positions far above the anchor (more than budget), clamps to the
--- top (returns 0) — callers that need a precise far-above row should
--- re-anchor first. Budget default ≫ viewport so normal above-viewport
--- cursor positions are exact.
---@param li integer 0-based line index
---@param sub integer 0-based sub-row within li
---@param budget integer? max backward rows to walk before clamping (default 10000)
---@return integer row viewport-relative row; 0 = top of viewport
function View:viewport_row_for_line(li, sub, budget)
    local n = self:line_count()
    if n == 0 or li < 0 then
        return 0
    end
    local a_li = self.scroll_li or 0
    local a_sub = self.scroll_sub_row or 0
    if li == a_li then
        return sub - a_sub
    elseif li > a_li then
        -- Forward: accumulate wrap_rows from a_li+1 .. li.
        local row = (self:wrap_rows(a_li) or 1) - a_sub
        for i = a_li + 1, li - 1 do
            row = row + (self:wrap_rows(i) or 1)
        end
        row = row + sub
        return row
    else
        -- Backward: accumulate wrap_rows from li+1 .. a_li.
        local lim = budget or 10000
        local row = sub - a_sub
        local i = a_li
        while i > li and lim > 0 do
            i = i - 1
            row = row - (self:wrap_rows(i) or 1)
            lim = lim - 1
        end
        if i > li then
            -- Ran out of budget: clamp to top.
            return 0
        end
        return row
    end
end

--- Set the viewport anchor so that (li, sub) sits at viewport row 0.
--- The cheapest positioning op: O(1), no walking. Used by jumps.
---@param li integer 0-based line index
---@param sub integer 0-based sub-row within li
function View:anchor_to_line(li, sub)
    local n = self:line_count()
    if n == 0 then
        self.scroll_li = 0
        self.scroll_sub_row = 0
        return
    end
    if li < 0 then
        li = 0
    end
    if li >= n then
        li = n - 1
    end
    if sub < 0 then
        sub = 0
    end
    local rows = self:wrap_rows(li) or 1
    if sub >= rows then
        sub = rows - 1
    end
    self.scroll_li = li
    self.scroll_sub_row = sub
end

--- Inverse of viewport_row_for_line: given a row RELATIVE to the anchor
--- (0 = top), return the (li, sub) at that row by walking forward from
--- the anchor. Negative rows are clamped to the anchor. O(|row|).
---@param rel_row integer viewport-relative row (0-based)
---@return integer li 0-based line index
---@return integer sub 0-based sub-row within li
function View:viewport_line_at_row(rel_row)
    local n = self:line_count()
    if n == 0 then
        return 0, 0
    end
    if rel_row <= 0 then
        return self.scroll_li or 0, self.scroll_sub_row or 0
    end
    local li = self.scroll_li or 0
    local sub = self.scroll_sub_row or 0
    local remaining = rel_row
    while remaining > 0 and li < n - 1 do
        local rows = self:wrap_rows(li) or 1
        local avail = rows - 1 - sub
        if remaining <= avail then
            sub = sub + remaining
            remaining = 0
        else
            remaining = remaining - avail - 1
            li = li + 1
            sub = 0
        end
    end
    return li, sub
end

--- Walk `delta` screen (sub) rows from (li, sub), independent of the
--- viewport anchor. Used by visual-line motion (C-n/C-p) which must
--- move the cursor by display rows regardless of where the viewport is
--- scrolled. O(|delta|) local walk from the cursor's own line; never
--- touches the wrap-cache prefix. Returns the destination (li, sub) and
--- a status: "ok", "start" (clamped to document start), or "end" (EOF).
---@param li integer 0-based starting line
---@param sub integer 0-based starting sub-row within li
---@param delta integer signed screen rows
---@return integer li destination
---@return integer sub destination
---@return string status "ok"|"start"|"end"
function View:walk_sub_rows(li, sub, delta)
    local n = self:line_count()
    if n == 0 then
        return 0, 0, "start"
    end
    if delta == 0 then
        return li, sub, "ok"
    end
    if delta > 0 then
        local remaining = delta
        while remaining > 0 and li < n - 1 do
            local rows = self:wrap_rows(li) or 1
            local avail = rows - 1 - sub
            if remaining <= avail then
                sub = sub + remaining
                remaining = 0
            else
                remaining = remaining - avail - 1
                li = li + 1
                sub = 0
            end
        end
        if li >= n - 1 then
            local last_rows = self:wrap_rows(n - 1) or 1
            if remaining > 0 and sub >= last_rows - 1 then
                sub = last_rows - 1
                return li, sub, "end"
            end
        end
        return li, sub, "ok"
    else
        local remaining = -delta
        while remaining > 0 and (li > 0 or sub > 0) do
            if sub > 0 then
                local take = math.min(sub, remaining)
                sub = sub - take
                remaining = remaining - take
            else
                li = li - 1
                local rows = self:wrap_rows(li) or 1
                local take = math.min(rows, remaining)
                sub = rows - take
                remaining = remaining - take
            end
        end
        if li <= 0 and sub <= 0 and remaining > 0 then
            return 0, 0, "start"
        end
        return li, sub, "ok"
    end
end

--- `target_row` (0 = top). Walks backward from li by `target_row` rows
--- to find the anchor line/sub. O(target_row) ≤ O(viewport). Used by
--- "cursor near bottom / center / top" positioning after a jump.
---@param li integer 0-based line index of the position to place
---@param sub integer 0-based sub-row within li
---@param target_row integer desired viewport row (0-based) for (li,sub)
function View:anchor_so_line_at_row(li, sub, target_row)
    if target_row <= 0 then
        self:anchor_to_line(li, sub)
        return
    end
    local n = self:line_count()
    if n == 0 then
        self.scroll_li = 0
        self.scroll_sub_row = 0
        return
    end
    if li < 0 then
        li = 0
    end
    if li >= n then
        li = n - 1
    end
    local remaining = target_row
    local cur_li = li
    local cur_sub = sub
    while remaining > 0 and cur_li > 0 do
        if cur_sub > 0 then
            -- Use up the sub-rows within the current line first.
            local take = math.min(cur_sub, remaining)
            cur_sub = cur_sub - take
            remaining = remaining - take
        else
            -- Move to the previous line, consuming its wrap rows.
            cur_li = cur_li - 1
            local rows = self:wrap_rows(cur_li) or 1
            local take = math.min(rows, remaining)
            cur_sub = rows - take
            remaining = remaining - take
        end
    end
    self:anchor_to_line(cur_li, cur_sub)
end

--- Clamp the anchor so the document's tail fits: if fewer than
--- `text_rows` rows remain below the anchor, slide the anchor up so
--- the last line's last sub-row sits at the viewport bottom. O(viewport)
--- walk forward from the anchor, never building the whole prefix.
---@param text_rows integer visible text rows
function View:clamp_anchor_to_eof(text_rows)
    local n = self:line_count()
    if n == 0 then
        return
    end
    -- Walk forward from the anchor counting how many rows remain below.
    local a_li = self.scroll_li or 0
    local a_sub = self.scroll_sub_row or 0
    local rows = self:wrap_rows(a_li) or 1
    local filled = rows - a_sub
    local li = a_li
    while filled < text_rows and li < n - 1 do
        li = li + 1
        filled = filled + (self:wrap_rows(li) or 1)
    end
    if filled >= text_rows then
        -- Enough rows below the anchor to fill the viewport: no clamp needed.
        return
    end
    -- EOF reached before filling (`filled < text_rows`). Two cases:
    --  (a) the whole document fits in text_rows → top should be line 0;
    --  (b) the anchor is simply too low → pull UP by the deficit so the
    --      last line's last sub-row sits at the viewport bottom.
    -- We distinguish by checking whether line 0 as top would fit the whole
    -- doc: if the anchor is already at (or would clamp to) line 0, case (a).
    -- Pulling up in case (a) is a no-op (anchor already at 0). So in BOTH
    -- cases the right move is: anchor so the LAST visible line's last row
    -- sits at viewport bottom (= text_rows-1). If that lands at line 0,
    -- so be it.
    local last_li = n - 1
    local last_sub = (self:wrap_rows(last_li) or 1) - 1
    self:anchor_so_line_at_row(last_li, last_sub, text_rows - 1)
end

--- Scroll the anchor by `delta` screen rows (signed). Walks forward or
--- backward from the current anchor, O(|delta|). Used by wheel/page.
---@param delta integer signed screen rows
function View:scroll_anchor(delta)
    if delta == 0 then
        return
    end
    local n = self:line_count()
    if n == 0 then
        return
    end
    local li = self.scroll_li or 0
    local sub = self.scroll_sub_row or 0
    if delta > 0 then
        local remaining = delta
        while remaining > 0 and li < n - 1 do
            local rows = self:wrap_rows(li) or 1
            local avail = rows - 1 - sub
            if remaining <= avail then
                sub = sub + remaining
                remaining = 0
            else
                remaining = remaining - avail - 1
                li = li + 1
                sub = 0
            end
        end
    else
        local remaining = -delta
        while remaining > 0 and (li > 0 or sub > 0) do
            if sub > 0 then
                local take = math.min(sub, remaining)
                sub = sub - take
                remaining = remaining - take
            else
                li = li - 1
                local rows = self:wrap_rows(li) or 1
                local take = math.min(rows, remaining)
                sub = rows - take
                remaining = remaining - take
            end
        end
        if li < 0 then
            li = 0
            sub = 0
        end
    end
    self.scroll_li = li
    self.scroll_sub_row = sub
end

--- Total number of screen rows for the entire document.
---@return integer
function View:total_screen_rows()
    if not self.wrap_width or self.wrap_width <= 0 then
        return self:line_count()
    end
    local n = self:line_count()
    if n == 0 then
        return 0
    end
    -- Cached total from a previous full build?
    if self._wrap_total ~= nil then
        return self._wrap_total
    end
    local tot_t0 = profile.now_us()
    -- Force a full forward build (sets _wrap_total on completion).
    self:_extend_wrap_to(n - 1)
    local total = self._wrap_total or 0
    profile.span("view", "total_screen_rows", tot_t0, { lines = n })
    return total
end

--- Compute the display width of the LAST sub-row of a wrapped line.
--- (The last row may be shorter than `wrap_width`; we need it to clamp
--- vertical-move targets so the cursor doesn't sit past line content.)
--- Walks grapheme widths; returns 0 for an empty line.
---@param li integer 0-based line index
---@param expected_sub_row integer sanity-check sub-row index (currently unused)
---@return integer
function View:_last_sub_row_width(li, expected_sub_row)
    local _, widths, _, _ = self:_graph(li)
    local w = self.wrap_width
    if #widths == 0 then
        return 0
    end
    local col = 0
    for i = 1, #widths do
        local gw = widths[i]
        if col + gw > w and col > 0 then
            -- This grapheme starts a new row. If it's over-wide, it gets
            -- its own row alone and the NEXT grapheme starts yet another
            -- fresh row; otherwise we just wrap normally.
            col = gw
        else
            col = col + gw
        end
    end
    return col
end

--- Return the byte offset within a logical line for a given sub-row and column.
--- Walks grapheme display widths: each sub-row holds as many graphemes as fit
--- in `wrap_width` display columns. `sub_col` is a display column WITHIN that
--- sub-row. Returns the byte offset of the grapheme boundary at or just
--- before `sub_col` (so a click inside a wide glyph snaps to its start byte).
---@param li integer 0-based line index
---@param sub_row integer 0-based sub-row within the wrapped line
---@param sub_col integer 0-based column within the sub-row
---@return integer byte_offset 0-based byte offset within the line
function View:wrap_byte_offset(li, sub_row, sub_col)
    if not self.wrap_width or self.wrap_width <= 0 then
        -- No wrap: a display column maps directly to a byte via the
        -- grapheme cache (wide-glyph mid-column snaps to start byte).
        return self:col_to_byte(li, sub_col)
    end
    local bs, widths, _, ll = self:_graph(li)
    local w = self.wrap_width
    local row, col = 0, 0
    for i = 1, #widths do
        local gw = widths[i]
        local over_wide = gw > w
        if col + gw > w and col > 0 then
            -- Wrap to the next row before this grapheme.
            row = row + 1
            col = 0
        end
        if row == sub_row and col + gw > sub_col then
            -- sub_col falls inside (or exactly at the start of) this grapheme.
            return bs[i] - 1
        end
        if row > sub_row then
            -- We've passed the target row without hitting sub_col; the
            -- target column sits past this row's content. Return the
            -- line's content length (end of the line).
            return ll
        end
        if over_wide then
            -- Over-wide grapheme occupies its row alone; next grapheme
            -- starts a fresh row.
            if row == sub_row then
                return bs[i] - 1
            end
            row = row + 1
            col = 0
        else
            col = col + gw
        end
    end
    return ll
end

--- Return the sub-row and sub-col for a byte offset within a wrapped line.
--- `sub_col` is a display column (0-based) within the sub-row; a byte offset
--- at a grapheme start maps to that grapheme's column. Past-end maps to the
--- last sub-row at the column just past the last grapheme that fits.
---@param li integer 0-based line index
---@param byte_offset integer 0-based byte offset
---@return integer sub_row
---@return integer sub_col
function View:wrap_sub_position(li, byte_offset)
    if not self.wrap_width or self.wrap_width <= 0 then
        -- No wrap: sub_col is the byte's DISPLAY column (not the byte itself,
        -- so wide glyphs report their start col and mid-cluster bytes snap to
        -- the containing grapheme's col).
        return 0, self:byte_to_col(li, byte_offset)
    end
    local bs, widths, _, _ = self:_graph(li)
    local w = self.wrap_width
    local ng = #bs
    if ng == 0 then
        return 0, 0
    end
    -- Locate the grapheme that contains `byte_offset`: the last grapheme
    -- whose 1-based start byte <= target (target = byte_offset + 1).
    local target = byte_offset + 1
    local lo, hi, gi = 1, ng, ng
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if bs[mid] <= target then
            gi = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    -- Walk to that grapheme, tracking sub-row and sub-col.
    local row, col = 0, 0
    for i = 1, gi do
        local gw = widths[i]
        local over_wide = gw > w
        if col + gw > w and col > 0 then
            row = row + 1
            col = 0
        end
        if i == gi then
            return row, col
        end
        if over_wide then
            row = row + 1
            col = 0
        else
            col = col + gw
        end
    end
    -- byte_offset is past the last grapheme: report the tail of the
    -- final row (the column just past the line's last grapheme).
    row, col = 0, 0
    for i = 1, ng do
        local gw = widths[i]
        if col + gw > w and col > 0 then
            row = row + 1
            col = 0
        end
        if gw > w then
            row = row + 1
            col = 0
        else
            col = col + gw
        end
    end
    return row, col
end

--- Enumerate the grapheme runs that make up a single screen sub-row.
--- Each entry is `{ byte_start, byte_end, col, width }` where:
---   * `byte_start`/`byte_end` are 1-based byte indices into the line's
---     stripped text suitable for `string.sub`;
---   * `col` is the 0-based DISPLAY column (within the sub-row) at which
---     the grapheme starts;
---   * `width` is the grapheme's display width (cells).
--- Used by the renderer to emit per-grapheme cells at correct columns
--- instead of indexing the line by byte offset.
---@param li integer 0-based line index
---@param sub_row integer 0-based sub-row
---@return table runs `{byte_start, byte_end, col, width}`
---@return integer row_width total display width consumed by this sub-row
function View:sub_row_runs(li, sub_row)
    local bs, widths, _, ll = self:_graph(li)
    local runs = {}
    if #widths == 0 then
        return runs, 0
    end
    local w = self.wrap_width or ll
    local row, col = 0, 0
    local row_w = 0
    for i = 1, #widths do
        local gw = widths[i]
        local over_wide = gw > w
        if col + gw > w and col > 0 then
            row = row + 1
            col = 0
        end
        if row == sub_row then
            local bstart = bs[i]
            local bend = (i + 1 <= #bs) and (bs[i + 1] - 1) or ll
            runs[#runs + 1] = {
                byte_start = bstart,
                byte_end = bend,
                col = col,
                width = gw,
            }
            row_w = col + gw
        elseif row > sub_row then
            break
        end
        if over_wide then
            row = row + 1
            col = 0
        else
            col = col + gw
        end
    end
    return runs, row_w
end

----------------------------------------------------------------------------------------------------
-- Mark / Selection
----------------------------------------------------------------------------------------------------

function View:set_mark()
    local c = self:p()
    c.anchor_line = c.line
    c.anchor_col = c.col
    -- C-space marks are sticky: they survive plain motions (which only
    -- drop a TRANSIENT shift-selection).
    c.anchor_transient = false
    -- Snapshot undo/redo counts for undo-in-selection
    c.shadow_undo = tonumber(self.buffer._ptr.undo.count)
    c.shadow_redo = tonumber(self.buffer._ptr.redo.count)
end

--- Set the mark on every cursor (e.g. select-all-on-all-cursors).
function View:set_mark_all()
    local u = tonumber(self.buffer._ptr.undo.count)
    local r = tonumber(self.buffer._ptr.redo.count)
    for _, c in ipairs(self.cursors) do
        c.anchor_line = c.line
        c.anchor_col = c.col
        c.anchor_transient = false
        c.shadow_undo = u
        c.shadow_redo = r
    end
end

--- Clear the mark on every cursor.
function View:unset_mark_all()
    for _, c in ipairs(self.cursors) do
        c.anchor_line = nil
        c.anchor_col = nil
        c.anchor_transient = nil
        c.shadow_undo = nil
        c.shadow_redo = nil
    end
end

function View:unset_mark()
    local c = self:p()
    c.anchor_line = nil
    c.anchor_col = nil
    c.anchor_transient = nil
    c.shadow_undo = nil
    c.shadow_redo = nil
end

---@return boolean
function View:has_selection()
    return self:p().anchor_line ~= nil
end

--- Selection range of the primary cursor.
--- Backward-compatible scalar form; callers that handle multiple
--- cursors use selection_ranges() instead.
---@return integer|nil start_line
---@return integer|nil start_col
---@return integer|nil end_line
---@return integer|nil end_col
function View:selection_range()
    local c = self:p()
    if not c.anchor_line then
        return nil
    end
    if c.anchor_line < c.line or (c.anchor_line == c.line and c.anchor_col < c.col) then
        return c.anchor_line, c.anchor_col, c.line, c.col
    else
        return c.line, c.col, c.anchor_line, c.anchor_col
    end
end

--- Return the normalized selection region of a single cursor,
--- or nil if it has no anchor.
---@param c Cursor
---@return integer|nil sl
---@return integer|nil sc
---@return integer|nil el
---@return integer|nil ec
function View:selection_ranges_one(c)
    if not c.anchor_line then
        return nil
    end
    if c.anchor_line < c.line or (c.anchor_line == c.line and c.anchor_col < c.col) then
        return c.anchor_line, c.anchor_col, c.line, c.col
    else
        return c.line, c.col, c.anchor_line, c.anchor_col
    end
end

--- Iterate every cursor's selection region as normalized (sl, sc, el, ec).
--- Returns a function iterator yielding (sl, sc, el, ec) for each cursor
--- that has an anchor set, in document order (top-down, left-to-right).
---@return function
function View:selection_ranges()
    local i = 0
    local n = #self.cursors
    return function()
        while i < n do
            i = i + 1
            local c = self.cursors[i]
            if c.anchor_line then
                if c.anchor_line < c.line or (c.anchor_line == c.line and c.anchor_col < c.col) then
                    return c.anchor_line, c.anchor_col, c.line, c.col
                else
                    return c.line, c.col, c.anchor_line, c.anchor_col
                end
            end
        end
        return nil
    end
end

function View:swap_mark_and_cursor()
    -- Swap on every cursor (primary's visual semantics preserved via goal_col).
    for _, c in ipairs(self.cursors) do
        if c.anchor_line then
            c.line, c.anchor_line = c.anchor_line, c.line
            c.col, c.anchor_col = c.anchor_col, c.col
        end
    end
    self:_set_goal_col(self:p().col)
end

--- Delete the selected text of EVERY cursor as one undo group.
--- Regions are assumed disjoint (overlapping multi-cursor selections
--- are a degenerate edge case, deferred). For each cursor that has a
--- selection: pre-compute its region's char count (using PRE-edit
--- buffer state), position the cursor at its region START, then issue
--- a single batch_edit where each cursor deletes its pre-computed n
--- forward. batch_edit's delete translator composes the cursor
--- coordinate adjustments across the batch for free.
---@return boolean
function View:delete_selection()
    -- Pre-compute per-cursor region data while the buffer is unmutated.
    -- n_by_cursor[c] = chars in this cursor's region (0 if no selection).
    local n_by_cursor = {}
    local any = false
    for _, c in ipairs(self.cursors) do
        if c.anchor_line then
            local sl, sc, el, ec = self:selection_ranges_one(c)
            ---@cast sl integer
            ---@cast sc integer
            ---@cast el integer
            ---@cast ec integer
            local n = self:chars_between(sl, sc, el, ec)
            n_by_cursor[c] = n
            -- Position the cursor at the region START so batch_edit sorts
            -- it correctly and issues the delete from the right point.
            c.line = sl
            c.col = sc
            any = true
        end
    end
    if not any then
        return false
    end
    local buf = self.buffer
    self:batch_edit(false, function(c)
        local nn = n_by_cursor[c] or 0
        if nn == 0 then
            -- No region for this cursor; identity edit (no translator).
            return c.line, c.col, c.line, c.col, { c.line, c.col }
        end
        local sl, sc = c.line, c.col
        local el, ec = delete_region_end(buf, sl, sc, nn)
        local rl, rc = buf:delete_char(sl, sc, nn)
        return sl, sc, rl, rc, { el, ec }
    end)
    self:unset_mark_all()
    self:_set_goal_col(self:p().col)
    return true
end

----------------------------------------------------------------------------------------------------
-- High-level edits (cursor-aware, grouped via batch_edit)
----------------------------------------------------------------------------------------------------

--- Insert a string at every cursor as one undo group.
--- `str` may contain newlines (each cursor's insertion handles its own
--- line split). Grouping is decided once from `should_break_edit(str)`
--- and shared across all cursors, so a single keystroke = one undo
--- step regardless of cursor count.
---
--- Returns (rl, rc, "insert") from fn; batch_edit advances THIS cursor
--- to (rl, rc) and builds the unified insert translator from the
--- pre-edit (line, col) and the result, handling both the fast
--- (same-line, no newline) and general (newline-split, multi-line)
--- paths uniformly.
---@param str string
function View:insert_char(str)
    if #str == 0 then
        return
    end
    local buf = self.buffer
    local breaks = buf:should_break_edit(str)
    self:batch_edit(breaks, function(c)
        local sl, sc = c.line, c.col
        local rl, rc = buf:insert_char(c.line, c.col, str)
        return sl, sc, rl, rc, "insert"
    end)
    self:_set_goal_col(self:p().col)
end

----------------------------------------------------------------------------------------------------
-- Syntax-aware indent (electric indent on Return)
--
-- A major mode may declare `indent_queries` — a predicate-free
-- tree-sitter query whose `@indent` captures mark nodes that should add
-- ONE extra indent level on the new line when Return is pressed inside
-- them. We query the shared parse tree (published by the highlight lane
-- via #11) for `@indent`-captured nodes containing the cursor; if the
-- cursor sits inside any, append one indent unit on top of the carried
-- line indent. Falls back to indent-carry-only when the mode declares no
-- `indent_queries`, the language/query is unavailable, or no parse tree
-- has been published yet (before the first highlight response lands).
--
-- The tree is a best-effort snapshot; in practice it is current at
-- Return time because each prior keystroke's edit query already landed
-- via the zero-flash sync-wait path (`_hl_record_edit` →
-- `_hl_wait_response`), which publishes a fresh tree.
----------------------------------------------------------------------------------------------------

--- One unit of indentation for the active view's settings: a tab when
--- `expand_tab` is false, otherwise `indent_width` spaces.
---@param view View
---@return string
local function indent_unit(view)
    if view.expand_tab then
        return string.rep(" ", view.indent_width)
    end
    return "\t"
end

--- Absolute document byte offset of a cursor (line, col), computed
--- directly from the buffer (`line_len` sums include the trailing newline,
--- matching the tree's byte space). O(line) per cursor — fine for a
--- non-hot path (Return), and correct mid-batch (unlike the cached
--- `_hl_line_starts`, which can't reflect an earlier cursor's edit in
--- the same `batch_edit`).
---@param buf Buffer
---@param c Cursor
---@return integer
local function cursor_byte_offset(buf, c)
    local off = c.col
    for i = 0, c.line - 1 do
        off = off + buf:line_len(i)
    end
    return off
end

--- Lazily build (or reuse) the compiled indent query for the active
--- major mode's `indent_queries` source + the view's `_hl_lang`. Returns
--- the ts.Query, or nil if no indent queries are declared, no language is
--- set, or the query failed to compile. Cached on
--- `self._indent_query_cache`; rebuilt when the language or source
--- changes (e.g. on mode switch).
---@return any|nil query
function View:_indent_query()
    local src = nil
    for _, m in ipairs(self._major_modes) do
        if m.indent_queries ~= nil then
            src = m.indent_queries
        end
    end
    if src == nil or self._hl_lang == nil then
        return nil
    end
    local cache = self._indent_query_cache
    if cache ~= nil and cache.lang == self._hl_lang and cache.src == src then
        return cache.query
    end
    local ts = require("cursed.ts")
    local lang_ptr, lerr = ts.lang_get(self._hl_lang)
    if not lang_ptr then
        log.warn("view", "indent query: language unavailable", {
            language = self._hl_lang,
            error = tostring(lerr),
        })
        return nil
    end
    local query, qerr = ts.Query.new(lang_ptr, src)
    if not query then
        log.warn("view", "indent query failed to compile", {
            language = self._hl_lang,
            error = tostring(qerr),
        })
        return nil
    end
    self._indent_query_cache = { lang = self._hl_lang, src = src, query = query }
    return query
end

--- Decide whether Return at this cursor should add ONE extra indent
--- level on top of the carried line indent. Queries the shared parse
--- tree for `@indent`-captured nodes containing the cursor (half-open
--- `[start_byte, end_byte)`). An @indent node only triggers the extra
--- indent when the cursor sits on the node's OPENER line (its start row):
--- that's the case where you just typed the block-opening construct
--- (`if x then<RET>`, `function f()<RET>`) and are about to write the
--- body. When the cursor is on a later line inside an enclosing block
--- (e.g. `return`/`local` as the last statement before `end`), no extra
--- level is added — Return keeps the body's current indent (carry).
--- This is the "right at the last character / just past" guard in
--- practice: a completed statement on its own line is never on the
--- block opener's line, so it never over-indents.
---@param c Cursor
---@return boolean
function View:_syntax_indent_extra(c)
    local query = self:_indent_query()
    if query == nil then
        return false
    end
    local tree = self:hl_tree() -- gen ignored; the tree is current at Return time
    if tree == nil then
        return false
    end
    local ts = require("cursed.ts")
    local root = tree:root()
    if ts.node_is_null(root) then
        return false
    end
    local byte = cursor_byte_offset(self.buffer, c)
    local cursor, cerr = ts.QueryCursor.new()
    if not cursor then
        return false
    end
    -- Restrict to matches intersecting a 1-byte window at the cursor so
    -- we don't walk every statement node in a huge document.
    cursor:set_byte_range(byte, byte + 1)
    cursor:exec(query, root)
    for match in cursor:matches() do
        for _, cap in ipairs(match.captures) do
            if cap.name == "indent" then
                local sb = ts.node_start_byte(cap.node)
                local eb = ts.node_end_byte(cap.node)
                -- Containing the cursor, half-open: covers the body up to
                -- (but not at) the node's end byte, so a cursor right after
                -- the closer (e.g. past `end`) is NOT contained → no extra.
                if sb <= byte and byte < eb then
                    local start_row = select(1, ts.node_point_range(cap.node))
                    if start_row == c.line then
                        return true
                    end
                end
            end
        end
    end
    return false
end
----------------------------------------------------------------------------------------------------
-- Input hooks (electric pairs + arbitrary pattern-callback hooks)
--
-- A major mode may declare `input_hooks`: a list of hook specs whose
-- `pattern` is matched as a SUFFIX of the text left of the cursor; the
-- moment the user finishes typing it (printable trigger) or hits Return
-- (return trigger), the hook's `fn` runs. Openers and closers are just
-- two higher-order builders over this generic hook, declared in
-- `cursed.input_hook`. Hooks run their OWN `batch_edit` (multi-cursor
-- coordination preserved within one hook's batch); cursors a hook
-- declines to handle fall through to the trigger site's default behaviour.
--
-- The block-opener block-text + tree-sitter body-indent fixup, the
-- closer structural-dedent, and the suffix-matching primitive all live
-- in `cursed.input_hook` now — View only supplies the generic trigger
-- dispatch (`_run_input_hooks`) and the default-newline carry-indent
-- fallback. Bridges into View's tree-sitter state go through the View
-- methods that stayed here (`_indent_query`, `hl_tree`).
----------------------------------------------------------------------------------------------------

--- Composite of all active major modes' `input_hooks`, flattening any
--- `_multi` block-opener builders into separate entries and reversing so
--- the last-declared hook (later mode / later in the mode's list) wins
--- on first-match. Mirrors the old `_electric_openers` reversal: a user
--- mode's hooks override the built-in defaults; within one mode,
--- later-listed wins. Built per call (small lists, no caching needed).
---@return table[]
function View:_input_hooks_composite()
    local out = {}
    local count = 0
    for _, m in ipairs(self._major_modes) do
        if m.input_hooks then
            for _, entry in ipairs(m.input_hooks) do
                if type(entry) == "table" and entry._multi then
                    for _, h in ipairs(entry.hooks) do
                        count = count + 1
                        out[count] = h
                    end
                else
                    count = count + 1
                    out[count] = entry
                end
            end
        end
    end
    local rev = {}
    for i = count, 1, -1 do
        rev[#rev + 1] = out[i]
    end
    return rev
end

--- Run the input hooks for `trigger` ("printable" or "return"). For
--- each cursor, prepare `left` — raw `line_text(c.line):sub(1, c.col)`
--- for printable; trailing-whitespace-stripped for return (so
--- `function f() <RET>` still completes a block opener whose pattern
--- is `function%s*[^%s]*%([^%)]*%)$`) — scan the composite in priority
--- order (last-declared first; first match wins per cursor), and
--- dispatch each cursor to its winning hook's `fn`. Each hook runs its
--- own `batch_edit` over its share of cursors. Returns the set of
--- cursors actually handled (a hook may decline — e.g. a closer whose
--- line isn't over-indented, or no parse tree available — leaving that
--- cursor to the trigger site's default). No-op (`_set_goal_col` only)
--- when no hooks / no matches.
---@param trigger "printable" | "return"
---@return table<Cursor,boolean>|nil cursor set actually handled
function View:_run_input_hooks(trigger)
    local hooks = self:_input_hooks_composite()
    if #hooks == 0 then
        return nil
    end
    local active = {}
    for _, h in ipairs(hooks) do
        if h.trigger == trigger then
            active[#active + 1] = h
        end
    end
    if #active == 0 then
        return nil
    end
    local buf = self.buffer
    local by_hook = {}
    local ordered = {}
    for _, c in ipairs(self.cursors) do
        local left = buf:line_text(c.line):sub(1, c.col)
        if trigger == "return" then
            left = left:gsub("%s+$", "")
        end
        for _, h in ipairs(active) do
            if IH.match_suffix(left, h) ~= nil then
                if not by_hook[h] then
                    by_hook[h] = {}
                    ordered[#ordered + 1] = h
                end
                local list = by_hook[h]
                list[#list + 1] = c
                break
            end
        end
    end
    if #ordered == 0 then
        return nil
    end
    local handled = {}
    for _, h in ipairs(ordered) do
        local handled_cursors = h.fn(self, by_hook[h])
        for _, c in ipairs(handled_cursors) do
            handled[c] = true
        end
    end
    self:_set_goal_col(self:p().col)
    return handled
end

--- Insert a newline at every cursor, with electric indent.
---
--- First the `return`-trigger input hooks fire (block-opener-on-return
--- pre-places the closer; closer-dedent snaps an over-indented closer
--- line one unit less). Each hook runs its own `batch_edit`; cursors a
--- hook actually handled skip the default batch below. The default
--- batch computes the leading-whitespace indent of each unhandled
--- cursor's line and inserts "\n" + indent, plus one extra indent unit
--- when the cursor sits inside a tree-sitter `@indent` node (per the
--- active mode's `indent_queries`) — so e.g. `if x then<RET>` indents
--- the body. The batch_edit insert translator handles same-line-newline
--- splits: a later cursor on the same line ends up in the new line at
--- the appropriate column.
function View:insert_newline()
    local buf = self.buffer
    local breaks = buf:should_break_edit("\n")
    local handled = self:_run_input_hooks("return")
    self:batch_edit(breaks, function(c)
        if handled ~= nil and handled[c] then
            -- Already edited by a hook (block opener inserted its body,
            -- closer dedented + created the new line). Identity insert
            -- → no-op translator; the cursor stays where the hook
            -- relocated it.
            return c.line, c.col, c.line, c.col, "insert"
        end
        local line = buf:line_text(c.line)
        local indent = line:match("^([ \t]*)") or ""
        if self.expand_tab then
            indent = indent:gsub("\t", string.rep(" ", self.tab_width))
        end
        if self:_syntax_indent_extra(c) then
            indent = indent .. indent_unit(self)
        end
        local sl, sc = c.line, c.col
        local rl, rc = buf:insert_char(c.line, c.col, "\n" .. indent)
        return sl, sc, rl, rc, "insert"
    end)
    self:_set_goal_col(self:p().col)
end

--- Delete n signed characters from every cursor as one undo group.
--- Grouping is decided once by OR-ing each cursor's will_join test
--- (a delete that joins lines is structural and breaks the group).

--- Replace each cursor's active selection with transformed text in
--- one undo group. The caller supplies `fn(text)` returning the new
--- string for that region; cursors without an active region are left
--- untouched (identity edit, no translator). The region is computed
--- in PRE-edit coordinates and consumed as a single delete-then-insert
--- so batch_edit's translator composes the cursor-coordinate fixups
--- across the batch for free via the "replace" kind.
---
--- Cursor application order and dedupe mirrors delete_selection /
--- batch_edit: top-down, left-to-right; coincident cursors collapse.
--- After the edit each cursor sits at the END of its inserted text,
--- with the mark cleared (no selection remains).
---@param fn fun(text: string): string transform applied to each region
---@return boolean true if any region was replaced
function View:replace_selections(fn)
    -- Pre-compute per-cursor region data while the buffer is unmutated.
    local data_by_cursor = {}
    local any = false
    for _, c in ipairs(self.cursors) do
        if c.anchor_line then
            local sl, sc, el, ec = self:selection_ranges_one(c)
            ---@cast sl integer
            ---@cast sc integer
            ---@cast el integer
            ---@cast ec integer
            local text = self:text_between(sl, sc, el, ec)
            local n = self:chars_between(sl, sc, el, ec)
            data_by_cursor[c] = { sl = sl, sc = sc, el = el, ec = ec, n = n, text = text }
            -- Position the cursor at the region START so batch_edit
            -- sorts it correctly and issues the replace from there.
            c.line = sl
            c.col = sc
            any = true
        end
    end
    if not any then
        return false
    end
    local buf = self.buffer
    self:batch_edit(false, function(c)
        local d = data_by_cursor[c]
        if not d or d.n == 0 then
            -- No region for this cursor; identity edit (no translator).
            return c.line, c.col, c.line, c.col, { c.line, c.col }
        end
        local sl, sc = c.line, c.col
        local replacement = fn(d.text)
        -- PRE-edit deleted-region end (for the translator).
        local el, ec = delete_region_end(buf, sl, sc, d.n)
        -- Delete then insert as one logical "replace".
        if d.n > 0 then
            buf:delete_char(sl, sc, d.n)
        end
        local rl, rc
        if #replacement > 0 then
            rl, rc = buf:insert_char(sl, sc, replacement)
        else
            rl, rc = sl, sc
        end
        return sl, sc, rl, rc, "replace", el, ec
    end)
    self:unset_mark_all()
    self:_set_goal_col(self:p().col)
    return true
end

--- Delete n signed characters from every cursor as one undo group.
--- Grouping is decided once by OR-ing each cursor's will_join test
--- (a delete that joins lines is structural and breaks the group).
---
--- Returns (rl, rc, { el, ec }) from fn: the buffer's post-edit result
--- for THIS cursor plus the PRE-edit end of the deleted region.
--- batch_edit then builds the unified delete translator that pulls
--- post-region cursors up and collapses in-region cursors to the
--- result. Handles single-line, cross-newline-join, and the
--- cursor-inside-a-deleted-span case uniformly.
---@param n integer signed character count
function View:delete_char(n)
    if n == 0 then
        return
    end
    local buf = self.buffer
    -- Grapheme-aware deletion for single-step deletes (the keystroke
    -- case): instead of deleting a fixed byte count, delete to the
    -- next/previous GRAPHENE boundary. This keeps multi-codepoint
    -- clusters (combining marks, ZWJ families, flag pairs) intact —
    -- backspacing over a base char also removes its combining marks,
    -- and a ZWJ family vanishes as one unit rather than leaving an
    -- orphaned ZWJ or trailing emoji behind. Larger magnitudes
    -- (universal-arg repeats, programmatic callers) keep byte-count
    -- semantics for back-compat with the existing delete translator.
    --
    -- Defensive snap: a cursor can end up mid-cluster via programmatic
    -- add_cursor / a stale byte offset (real motion always lands on
    -- boundaries). Snap the delete origin to a grapheme boundary in
    -- the direction of travel so the whole containing cluster is
    -- removed rather than split: forward for backspace (deletes the
    -- cluster the cursor sits inside), back to the cluster start for
    -- forward-delete (deletes the cluster ahead whole).
    local function snap_origin(c)
        if not (n == 1 or n == -1) then
            return c.col
        end
        local cluster_start = self:col_to_byte(c.line, self:byte_to_col(c.line, c.col))
        if cluster_start >= c.col then
            return c.col -- already on a boundary
        end
        if n < 0 then
            return self:advance_grapheme(c.line, cluster_start, 1) -- cluster end
        end
        return cluster_start -- cluster start
    end
    local function eff_n_for(c)
        if not (n == 1 or n == -1) then
            return n
        end
        local origin = snap_origin(c)
        local eff = self:advance_grapheme(c.line, origin, n) - origin
        if eff == 0 then
            -- We're sitting on a line boundary in the direction of
            -- travel (backspace at col 0, forward-delete at end of
            -- line): advance_grapheme clamps to the line and yields 0,
            -- which would turn this into a no-op and break cross-line
            -- deletion (joining with the neighbor line). Fall back to
            -- plain byte-count semantics so _delete_char_impl walks
            -- across the newline via join_lines.
            return n
        end
        return eff
    end
    -- Aggregate will_join across cursors: any structural delete breaks
    -- the group. Preserves single-cursor semantics exactly (N=1 →
    -- "any joins" == "the one joins").
    local any_join = false
    for _, c in ipairs(self.cursors) do
        local content_len = buf:line_len(c.line) - 1
        local eff_n = eff_n_for(c)
        local will_join
        if n > 0 then
            will_join = c.col + eff_n > content_len
        else
            will_join = c.col + eff_n < 0
        end
        if will_join then
            any_join = true
            break
        end
    end
    self:batch_edit(any_join, function(c)
        local eff_n = eff_n_for(c)
        local origin = snap_origin(c)
        -- Compute the pre-edit region end BEFORE the buffer mutates,
        -- since _delete_char_impl walks a changing line_count.
        local el, ec = delete_region_end(buf, c.line, origin, eff_n)
        local rl, rc = buf:delete_char(c.line, origin, eff_n)
        -- Normalize so the returned region is [start, end) half-open with
        -- start = min(cursor pre-edit point, region end) and end = the
        -- other. For forward deletes cursor pos is the start; for backward
        -- deletes the region end (below the cursor) is the start.
        local sl, sc
        if n > 0 then
            sl, sc = c.line, origin
        else
            sl, sc = el, ec
            el, ec = c.line, origin
        end
        return sl, sc, rl, rc, { el, ec }
    end)
    self:_set_goal_col(self:p().col)
end

----------------------------------------------------------------------------------------------------
-- Motions (close edit group, move cursor)
----------------------------------------------------------------------------------------------------

function View:move_char(n)
    if n == 0 then
        return true
    end

    return self:each_cursor(function(c)
        local buf = self.buffer
        local line = c.line
        local col = c.col
        local forward = n > 0
        local remaining = forward and n or -n

        while remaining > 0 do
            local content_len = buf:line_len(line) - 1
            local moved
            if forward then
                if col < content_len then
                    col = self:advance_grapheme(line, col, 1)
                    moved = 1
                else
                    moved = 0
                end
            else
                if col > 0 then
                    col = self:advance_grapheme(line, col, -1)
                    moved = 1
                else
                    moved = 0
                end
            end

            remaining = remaining - moved

            if remaining > 0 and moved == 0 then
                -- Cross a line boundary.
                if forward and line < buf:line_count() - 1 then
                    line = line + 1
                    col = 0
                    remaining = remaining - 1
                elseif not forward and line > 0 then
                    line = line - 1
                    col = buf:line_len(line) - 1
                    remaining = remaining - 1
                else
                    c.line = line
                    c.col = col
                    c.goal_col = self:byte_to_col(line, col)
                    c.visual_col = nil
                    c.yank_line = nil
                    c.yank_col = nil
                    return nil, forward and "end of document" or "start of document"
                end
            end
        end

        c.line = line
        c.col = col
        c.goal_col = self:byte_to_col(line, col)
        c.visual_col = nil
        c.yank_line = nil
        c.yank_col = nil
        return true
    end)
end

function View:move_line(n)
    if n == 0 then
        return true
    end

    if self.wrap_width and self.wrap_width > 0 then
        return self:each_cursor(function(c)
            local buf = self.buffer
            local line_count = buf:line_count()
            -- Move by screen rows: figure out current screen sub-row,
            -- move n screen rows, and figure out what logical line + col that maps to.
            -- Use visual_col (the column within the screen row) as the
            -- target, not goal_col (which is a byte offset in the
            -- logical line and would give the wrong visual position).
            local cur_sub_row, cur_visual_col = self:wrap_sub_position(c.line, c.col)
            -- On the first vertical move after a horizontal move,
            -- seed visual_col from the current position.
            if c.visual_col == nil then
                c.visual_col = cur_visual_col
            end
            local visual_goal = c.visual_col
            ---@cast visual_goal integer

            -- Walk `n` display rows from the cursor's OWN position
            -- (independent of the viewport anchor). Keeping this
            -- anchor-independent is what makes C-n/C-p correct after the
            -- viewport has been paged away from the cursor (wheel/page);
            -- viewport-relative math would mistake an above-viewport cursor
            -- for being near the document start and clamp wrongly.
            local nli, nsub, status = self:walk_sub_rows(c.line, cur_sub_row, n)
            if status == "start" then
                c.line = 0
                c.col = 0
                c.goal_col = 0
                c.visual_col = nil
                c.yank_line = nil
                c.yank_col = nil
                return nil, "start of document"
            end
            if status == "end" then
                c.line = line_count - 1
                local end_byte = buf:line_len(line_count - 1) - 1
                c.col = end_byte
                c.goal_col = self:byte_to_col(line_count - 1, end_byte)
                c.visual_col = nil
                c.yank_line = nil
                c.yank_col = nil
                return nil, "end of document"
            end
            local li, sub_row = nli, nsub
            c.line = li
            local content_len = self:content_len(li)
            -- Last sub-row? Compute its actual display width by walking
            -- grapheme widths (we can't subtract bytes from wrap_width —
            -- wide glyphs make bytes != columns).
            local total_sub = self:wrap_rows(li)
            local last_row_width
            if sub_row == total_sub - 1 then
                -- Width of the final sub-row = (line's total display width)
                -- minus the columns consumed by all earlier sub-rows. Walk
                -- the graphemes to find where sub_row starts.
                last_row_width = self:_last_sub_row_width(li, sub_row)
            else
                last_row_width = self.wrap_width
            end
            local sub_col = math.min(visual_goal, math.max(0, last_row_width))
            local byte_off = self:wrap_byte_offset(li, sub_row, sub_col)
            -- Clamp to actual content length
            c.col = math.min(byte_off, content_len)
            return true
        end)
    end

    -- No wrap: move by logical lines, preserving goal_col
    return self:each_cursor(function(c)
        local buf = self.buffer
        local line_count = buf:line_count()
        local target = c.line + n

        if target < 0 then
            c.line = 0
            c.col = 0
            c.goal_col = 0
            c.visual_col = nil
            c.yank_line = nil
            c.yank_col = nil
            return nil, "start of document"
        elseif target >= line_count then
            c.line = line_count - 1
            local end_byte = buf:line_len(line_count - 1) - 1
            c.col = end_byte
            c.goal_col = self:byte_to_col(line_count - 1, end_byte)
            c.visual_col = nil
            c.yank_line = nil
            c.yank_col = nil
            return nil, "end of document"
        end

        c.line = target
        -- goal_col is a display column; snap to a grapheme boundary
        -- on the target line via col_to_byte so we never land mid-codepoint.
        local line_len = buf:line_len(target) - 1
        local max_col = self:byte_to_col(target, line_len)
        local goal = math.min(c.goal_col, max_col)
        c.col = self:col_to_byte(target, goal)
        return true
    end)
end

function View:move_line_start()
    return self:each_cursor(function(c)
        c.col = 0
        c.goal_col = 0
        c.visual_col = nil
        c.yank_line = nil
        c.yank_col = nil
        return true
    end)
end

function View:move_line_end()
    return self:each_cursor(function(c)
        local content_len = self.buffer:line_len(c.line) - 1
        c.col = content_len
        c.goal_col = self:byte_to_col(c.line, content_len)
        c.visual_col = nil
        c.yank_line = nil
        c.yank_col = nil
        return true
    end)
end

--- Load text object definitions.
local function load_default_textobjects()
    return require("cursed.default_textobjects")
end

--- Get the textobjects for this view, merging mode-specific
--- definitions on top of the defaults. Entries may be EITHER a
--- boundary PATTERN string (legacy / user-friendlier: `"[^%w_]"`)
--- OR a function `fn(view, line, col) -> (sl,sc,el,ec,boundary_len)`.
--- Pattern strings are wrapped into functions lazily by
--- View:_textobject_fn when consumed, so the rest of the editor only
--- ever sees functions.
---@return table
function View:_get_textobjects()
    local defaults = load_default_textobjects()
    if #self._major_modes == 0 then
        return defaults
    end
    local merged = {}
    for k, v in pairs(defaults) do
        merged[k] = v
    end
    for _, mode in ipairs(self._major_modes) do
        for k, v in pairs(mode.textobjects) do
            merged[k] = v
        end
    end
    return merged
end

----------------------------------------------------------------------------------------------------
-- Text-object boundary queries (general-purpose utility)
--
-- These let any command — built-in or user-defined — find the
-- boundary matches of a named textobject ("word", "sentence",
-- "paragraph", mode-specific ones, …) around a point. They are the
-- foundation for sentence-region commands today and for an
-- expand-region facility later: expand-region can walk outward by
-- progressively widening the queried object / boundary.
--
-- A boundary match is the table returned by Buffer's search
-- iterators: { line, offset, end_line, end_offset }. "prev" = the
-- boundary at-or-before pt; "cur" = the next boundary after pt.
----------------------------------------------------------------------------------------------------

--- Compute the range of a boundary PATTERN text-object at point.
--- The range is [ after-prev-boundary's-gap , current-boundary's-
--- non-ws-prefix-end ); boundary_len is how many chars past (el,ec)
--- Dir semantics mirror sexp_range exactly:
---   * point inside a unit → return that unit (dir ignored);
---   * point on a boundary (the no-man's-land boundaries_pat excludes
---     from both sides):
---       dir == 0          → nil (containing-only, nothing to select),
---       dir == nil or > 0 → the NEXT unit forward (after this gap),
---       dir < 0           → the PREVIOUS unit (before this gap).
--- Land of `ec`/`sc` coincide with the match-table landing points the
--- old sentence commands computed (m.offset+1, _after_terminator), so
--- the range fully subsumes the match-table path.
---@param pat string boundary pattern
---@param line integer 0-based point line
---@param col integer 0-based point col
---@param dir integer|nil 0=containing-only, >0=forward, <0=backward
---@return integer|nil sl
---@return integer|nil sc
---@return integer|nil el
---@return integer|nil ec
---@return integer|nil boundary_len
function View:_pattern_range(pat, line, col, dir)
    local buf = self.buffer
    local pt = { line = line, offset = col }
    local prev_m, cur_m = self:boundaries_pat(pat, pt)
    -- Detect point sitting ON a boundary char. boundaries_pat excludes
    -- the boundary at pt from both prev and cur; an inclusive backward
    -- search from pt finds it. Point is "on" the boundary if it falls
    -- anywhere within the match span [offset, end_offset) — multi-char
    -- patterns like "[!%.%?][ \n]" span punct+space, so the space char
    -- is inside the match, not at its start.
    local binfo = buf:search_backward(pat, pt, false)()
    local on_boundary = binfo ~= nil
        and binfo.line == line
        and binfo.end_line >= line
        and not (binfo.end_line < line or (binfo.end_line == line and binfo.end_offset <= col))
        and not (binfo.line > line or (binfo.line == line and binfo.offset > col))
    if not on_boundary then
        -- Inside a unit (or before the first boundary): the span is
        -- [after-prev-gap, cur-boundary-prefix-end).
        local sl, sc = 0, 0
        if prev_m then
            sl = prev_m.end_line
            sc = self:_after_terminator(prev_m)
        end
        if not cur_m then
            local e = self:eof_pt()
            return sl, sc, e.line, e.offset, 0
        end
        local el, ec, tws = self:_boundary_prefix_end(cur_m)
        return sl, sc, el, ec, tws
    end
    -- On a boundary. Mirror sexp between-pairs semantics.
    if dir == 0 then
        return nil, nil, nil, nil, nil
    end
    if dir == nil or dir > 0 then
        -- Forward: the unit AFTER this gap.
        --   start = first char after this boundary's trailing ws,
        --   end   = prefix-end of the next boundary (cur_m).
        local sl = binfo.end_line
        local sc = self:_after_terminator(binfo)
        if not cur_m then
            local e = self:eof_pt()
            return sl, sc, e.line, e.offset, 0
        end
        local el, ec, tws = self:_boundary_prefix_end(cur_m)
        return sl, sc, el, ec, tws
    end
    -- Backward: the unit BEFORE this gap.
    --   end   = prefix-end of THIS boundary (the gap we're on),
    --   start = after the previous boundary's gap (or BOF).
    local el, ec, tws = self:_boundary_prefix_end(binfo)
    local sl, sc = 0, 0
    -- prev boundary strictly before binfo: query from binfo's start,
    -- which boundaries_pat excludes-from-cur so prev = the one before.
    local prev_prev = self:boundaries_pat(pat, { line = binfo.line, offset = binfo.offset })
    if prev_prev then
        sl = prev_prev.end_line
        sc = self:_after_terminator(prev_prev)
    end
    return sl, sc, el, ec, tws
end

--- Given a boundary match, return (el, ec, boundary_len) where (el,ec)
--- is the column just past the boundary's leading non-whitespace
--- (the punctuation char itself for sentence/word terminators) and
--- boundary_len is the trailing-whitespace run after it. Forward
--- motion lands at (el,ec); the next unit starts at (el,ec+boundary_len).
---@param m table a boundary match (has .line/.offset/.end_line/.end_offset)
---@return integer el
---@return integer ec
---@return integer boundary_len
function View:_boundary_prefix_end(m)
    local mtext = self:text_between(m.line, m.offset, m.end_line, m.end_offset)
    local nws = 0
    for i = 1, #mtext do
        local b = mtext:byte(i)
        if b == 32 or b == 9 or b == 10 then
            break
        end
        nws = nws + 1
    end
    return m.line, m.offset + nws, #mtext - nws
end

--- Wrap a boundary PATTERN string into a textobject FUNCTION. Legacy
--- path for bare-string registry entries (kept for backward compat
--- with users' existing `textobjects = { word = "[^%w_]" }` specs);
--- delegates to View:_pattern_range so there's one implementation.
---@param pat string boundary pattern
---@return function
function View.pattern_textobject_fn(pat)
    return function(view, line, col, dir)
        return view:_pattern_range(pat, line, col, dir)
    end
end

--- Find the boundary matches of a raw pattern string bracketing
--- `pt`: the previous boundary strictly before pt (end of the
--- preceding unit) and the next boundary strictly after pt (end of
--- the current unit). Either may be nil when pt sits before the first
--- / after the last boundary. The previous match excludes a terminator
--- that starts exactly at pt (so backward motions don't re-find the
--- boundary the cursor is sitting on). Used internally by
--- View:_pattern_range.
---@param pat string boundary pattern
---@param pt table {line, offset} search origin
---@return table|nil prev_match
---@return table|nil cur_match
function View:boundaries_pat(pat, pt)
    local buf = self.buffer
    local bl, bo = pt.line, pt.offset - 1
    if bo < 0 then
        if bl > 0 then
            bl = bl - 1
            bo = buf:line_len(bl) - 1
        else
            bl, bo = nil, nil
        end
    end
    local prev_m
    if bl then
        local start_pt = { line = bl, offset = bo }
        prev_m = buf:search_backward(pat, start_pt, false)()
    end
    local cur_m = buf:search_forward(pat, pt, false)()
    return prev_m, cur_m
end

--- End-of-document point (col == content length of the last line).
---@return table
function View:eof_pt()
    local lc = self:line_count() - 1
    return { line = lc, offset = self:content_len(lc) }
end

--- Given a boundary match (e.g. for "[!%.%?][ \n]"), return the
--- 0-based column of the FIRST non-whitespace char after the match's
--- trailing whitespace — i.e. the start of the next sentence/clause.
--- Used by View:_pattern_range to compute the unit start (right after
--- the previous terminator's gap). The match table's end_offset is the
--- raw 1-based `string.find` end (index of the last matched char);
--- converting it to the char after the match, then skipping
--- whitespace, yields the next unit's start.
---@param m table a boundary match table from View:boundaries_pat
---@return integer col 0-based column of the next unit's start
function View:_after_terminator(m)
    local buf = self.buffer
    local li = m.end_line
    local content_len = self:content_len(li)
    -- end_offset is 1-based (index of last matched char); the char
    -- immediately AFTER the match is at 0-based end_offset.
    local col = m.end_offset
    -- Skip any further trailing whitespace on this line.
    local text = buf:line_text(li)
    local tlen = #text
    if tlen > 0 and text:byte(tlen) == 10 then
        tlen = tlen - 1
    end
    while col < tlen do
        local b = text:byte(col + 1)
        if b ~= 32 and b ~= 9 then
            break
        end
        col = col + 1
    end
    return math.min(col, content_len + 1)
end

----------------------------------------------------------------------------------------------------
-- Unit ranges (proto expand-region foundation)
--
-- Each returns the (start_line, start_col, end_line, end_col) of the
-- FULL unit containing point, as a 0-based half-open [start, end)
-- range. mark_* commands select these ranges in both directions
-- (outward from the cursor), unlike Emacs' [point, unit-end).
-- A future expand-region command can call these progressively to
-- widen the selection (word → sentence → paragraph → buffer).
----------------------------------------------------------------------------------------------------

--- True if a line index holds only whitespace / is empty.
---@param li integer 0-based line index
---@return boolean
function View:is_blank_line(li)
    local t = self.buffer:line_text(li)
    local n = #t
    if n == 0 then
        return true
    end
    if t:byte(n) == 10 then
        n = n - 1
    end
    return n == 0 or t:match("^%s*$") ~= nil
end

--- Find the paragraph boundary line in direction `dir` (+1/-1)
--- starting from `line` (the blank separating line after/before the
--- current paragraph content run).
---@param line integer 0-based starting line
---@param dir integer +1 forward, -1 backward
---@return integer boundary line index
function View:paragraph_boundary(line, dir)
    local lc = self:line_count()
    local i = line + dir
    local in_blank = false
    while i >= 0 and i < lc do
        local blank = self:is_blank_line(i)
        if dir > 0 then
            if blank then
                in_blank = true
            elseif in_blank then
                return i
            end
        else
            if blank then
                in_blank = true
            elseif in_blank then
                -- walk up through content to the first blank above it
                local j = i
                while j >= 0 do
                    if self:is_blank_line(j) then
                        return math.min(j + 1, lc - 1)
                    end
                    j = j - 1
                end
                return 0
            end
        end
        i = i + dir
    end
    return dir > 0 and (lc - 1) or 0
end

--- Range of the paragraph containing point: from the start of the
--- content run (skipping leading blank lines) to the end of the
--- content run before the trailing blank lines. If point is on a
--- blank line, the paragraph is the blank run itself.
--- Returns the conventional (sl,sc,el,ec) plus boundary_len = 0
--- (paragraphs are line-block units; forward motion lands at the
--- blank line after the content, i.e. el+1 col 0 — handled by the
--- caller via the structural registry’s move behavior).
---@param line integer 0-based line
---@return integer sl
---@return integer sc
---@return integer el
---@return integer ec
---@return integer boundary_len
function View:paragraph_range(line)
    local lc = self:line_count()
    if self:is_blank_line(line) then
        local top = line
        while top > 0 and self:is_blank_line(top - 1) do
            top = top - 1
        end
        local bottom = line
        while bottom < lc - 1 and self:is_blank_line(bottom + 1) do
            bottom = bottom + 1
        end
        return top, 0, bottom, 0, 0
    end
    local top = line
    while top > 0 and not self:is_blank_line(top - 1) do
        top = top - 1
    end
    local bottom = line
    while bottom < lc - 1 and not self:is_blank_line(bottom + 1) do
        bottom = bottom + 1
    end
    return top, 0, bottom, 0, 0
end

--- Apply a 0-based half-open range to the primary cursor (mark at
--- start, point at end). Internal helper used by select_range and
--- other commands that already have a concrete range.
---@param sl integer
---@param sc integer
---@param el integer
---@param ec integer
function View:_select_raw(sl, sc, el, ec)
    local p = self:p()
    p.line = sl
    p.col = sc
    self:_set_goal_col(sc)
    self:set_mark()
    p.line = el
    p.col = ec
    self:_set_goal_col(ec)
end

--- Resolve the textobject FUNCTION for `name`: a closure
--- `fn(view, line, col, dir) -> (sl,sc,el,ec,boundary_len)|nil`.
---
--- Registry entries may be:
---   * a boundary PATTERN string (legacy / user-friendly: "[^%w_]") —
---     wrapped once via pattern_textobject_fn (cached);
---   * a plain function from the pattern()/sexp() builders in
---     cursed.textobject, or any user-supplied function.
--- Both unify to a single callable here.
---@param name string
---@return function|nil
function View:_textobject_fn(name)
    local def = self:_get_textobjects()[name]
    if def == nil then
        return nil
    end
    if type(def) == "string" then
        -- Pattern string: wrap once. Cache the wrapped fn so repeated
        -- lookups of the same pattern don't re-wrap.
        local wrapped = View._PATTERN_FN_CACHE[def]
        if not wrapped then
            wrapped = View.pattern_textobject_fn(def)
            View._PATTERN_FN_CACHE[def] = wrapped
        end
        return wrapped
    end
    return def -- plain function (pattern()/sexp() closure or custom)
end

--- The SINGLE public entry point for selecting a text-object range
--- outward in both directions (mark at start, point at end of the
--- full unit containing point). Resolves the textobject function via
--- _textobject_fn and applies its (sl,sc,el,ec). Passes dir=nil so
--- sexp returns the next pair forward when point is between pairs
--- (mark_sexp selects the upcoming unit). Returns false (selection
--- untouched) if there's no function for `name` or no unit at/after
--- point.
---@param name string text-object name
---@param line integer 0-based line of point
---@param col integer 0-based col of point
---@return boolean selected
function View:select_range(name, line, col)
    local fn = self:_textobject_fn(name)
    if not fn then
        return false
    end
    local sl, sc, el, ec = fn(self, line, col, nil)
    if not sl then
        return false
    end
    ---@cast sc integer
    ---@cast el integer
    ---@cast ec integer
    self:_select_raw(sl, sc, el, ec)
    return true
end

----------------------------------------------------------------------------------------------------
-- Balanced pairs (sexp navigation primitives)
--
-- Openers/closers may be MULTI-CHARACTER delimiter strings (e.g.
-- "begin"/"end", "<!--"/"-->", or the classic () [] {}). They're
-- supplied per-textobject by the `sexp(pairs)` builder
-- (cursed.textobject) as open_of/closer maps; the module-level
-- DEFAULT_OPEN_OF / DEFAULT_CLOSE_OF provide the ()[]{} fallback.
--
-- Matching is a flat forward/backward scan: at each position we test
-- whether any delimiter is a PREFIX of the line text starting there
-- (longest match wins; closers break ties over openers). Depth is
-- counted as usual. Delimiters may not span a newline. The pair is
-- returned as a 0-based half-open [opener, end-of-closer) range — i.e.
-- it INCLUDES the delimiters. nil when `pt` is not inside any pair.
--
-- These power mark_sexp / kill_sexp / copy_sexp / transpose_sexp /
-- forward_sexp / backward_sexp / down_list / up_list, and (because the
-- pair set is passed in) each major mode can drive its own sexp
-- definition without touching these primitives.
----------------------------------------------------------------------------------------------------

--- Default ()[]{} pair set (used when no sexp textobject resolves a
--- custom pair set, and as the fallback for legacy no-arg call sites).
local DEFAULT_PAIRS = { { "(", ")" }, { "[", "]" }, { "{", "}" } }
local DEFAULT_OPEN_OF = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local DEFAULT_CLOSE_OF = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

--- Build open_of (opener→closer) and close_of (closer→opener) maps
--- from a `pairs` spec (list of {opener,closer}), caching them on the
--- spec table so a given builder's pair set is converted at most once.
--- `pairs` may be nil → returns the default ()[]{} maps.
---@param pairs table|nil
---@return table open_of
---@return table close_of
function View:_sexp_pair_tables(pairs)
    if pairs == nil then
        return DEFAULT_OPEN_OF, DEFAULT_CLOSE_OF
    end
    if pairs._open_of then
        return pairs._open_of, pairs._close_of
    end
    local open_of, close_of = {}, {}
    for _, p in ipairs(pairs) do
        open_of[p[1]] = p[2]
        close_of[p[2]] = p[1]
    end
    pairs._open_of = open_of
    pairs._close_of = close_of
    return open_of, close_of
end

--- Return the content text of line `li` with a trailing newline stripped,
--- and its byte length. Empty string past EOF.
---@param li integer 0-based line
---@return string text
---@return integer len
function View:_line_content(li)
    local text = self.buffer:line_text(li)
    local n = #text
    if n > 0 and text:byte(n) == 10 then
        n = n - 1
    end
    return text, n
end

--- Whether a byte is a "word" char (identifier-ish), used to enforce
--- word boundaries for multi-char ALPHABETIC delimiters (so `end`
--- does NOT match inside `append` / `send`, and `function` doesn't
--- match inside `dysfunction`). Single-char delimiters like ( [ { are
--- punctuation and never participate in a larger word, so they skip the
--- boundary check. A delimiter string is "wordy" if its first byte is
--- a letter/underscore; punctuation delimiters never require boundaries.
---@param s string delimiter string
---@return boolean
local function is_wordy_delim(s)
    local b = s:byte(1)
    if b == nil then
        return false
    end
    -- A-Z, a-z, _
    return (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or b == 0x5F
end

--- Byte-class check: word char (alnum/underscore) vs not. Used by the
--- word-boundary guards below.
---@param b integer|nil
---@return boolean
local function is_word_byte(b)
    if b == nil then
        return false
    end
    return (b >= 0x41 and b <= 0x5A)
        or (b >= 0x61 and b <= 0x7A)
        or (b >= 0x30 and b <= 0x39)
        or b == 0x5F
end

--- Check that the delimiter match at (li, col..col+#delim-1) has proper
--- word boundaries on BOTH sides: the char immediately before the
--- delimiter and the char immediately after it must NOT be word chars.
--- Punctuation delimiters (`(` etc.) always pass. Returns the delim
--- unchanged if boundaries are satisfied, or nil to reject the match.
--- `text` is the pre-fetched line content (no trailing newline).
---@param text string
---@param n integer content length of `text`
---@param col integer 0-based col where `delim` starts
---@param delim string
---@return string|nil delim nil if the boundary check rejects
local function with_word_boundary(text, n, col, delim)
    if not is_wordy_delim(delim) then
        return delim
    end
    local dl = #delim
    local before = col > 0 and text:byte(col) or nil -- col is 0-based; byte at col-1 is text:byte(col)
    if is_word_byte(before) then
        return nil
    end
    local after_off = col + dl + 1 -- 1-based byte index of the char right after delim
    local after = after_off <= n and text:byte(after_off) or nil
    if is_word_byte(after) then
        return nil
    end
    return delim
end

--- Detect the longest delimiter string that is a PREFIX of this
--- line's content starting at `col`, respecting word boundaries for
--- alphabetic delimiters. `set` is the key set of either open_of or
--- close_of (i.e. the opener strings, or the closer strings).
--- Returns the matching string (longest wins; word-boundary-checked)
--- or nil when nothing matches / col is past end-of-line content.
--- Single-line only: delimiters may not span a newline.
---@param li integer 0-based line
---@param col integer 0-based col
---@param set table<string, any> the delimiter strings to test
---@return string|nil delim
function View:_longest_prefix_at(li, col, set)
    local text, n = self:_line_content(li)
    if col < 0 or col >= n then
        return nil
    end
    local best, best_len = nil, 0
    for s in pairs(set) do
        local sl = #s
        if sl > best_len and sl <= n - col and text:sub(col + 1, col + sl) == s then
            best, best_len = s, sl
            -- (longest wins; boundary check happens after the loop so
            -- a shorter punctuation delim can win when a longer wordy
            -- one is boundary-rejected.)
        end
    end
    -- Now verify word boundaries for the winning match (longest may
    -- be rejected by a boundary, in which case try next-longest).
    if best ~= nil then
        local checked = with_word_boundary(text, n, col, best)
        if checked ~= nil then
            return checked
        end
    end
    -- Fallback: scan non-longest matches for one that passes boundaries.
    -- (Rare path — e.g. `end` matched as a prefix of `endless` needs
    -- rejecting; we try the next candidate.) Collect all matches and
    -- pick the longest boundary-valid one.
    local candidates = {}
    for s in pairs(set) do
        local sl = #s
        if sl <= n - col and text:sub(col + 1, col + sl) == s then
            candidates[#candidates + 1] = s
        end
    end
    table.sort(candidates, function(a, b)
        return #a > #b
    end)
    for _, s in ipairs(candidates) do
        local checked = with_word_boundary(text, n, col, s)
        if checked ~= nil then
            return checked
        end
    end
    return nil
end

--- Combined check at (li, col): returns the longest opener AND/OR
--- closer prefixing the line here, plus is_open/is_close flags. Used
--- by enclosing_pair / scans where a position could be either.
--- Closers win length ties so competing delimiters prefer closing.
---@param li integer 0-based line
---@param col integer 0-based col
---@param open_of table opener→closer map
---@param close_of table closer→opener map
---@return string|nil delim
---@return boolean is_open
---@return boolean is_close
function View:delim_at(li, col, open_of, close_of)
    local op = self:_longest_prefix_at(li, col, open_of)
    local cl = self:_longest_prefix_at(li, col, close_of)
    if not op and not cl then
        return nil, false, false
    end
    -- Longer wins; equal length prefers the closer (so symmetric /
    -- competing delimiters close rather than nest).
    if cl and (not op or #cl >= #op) then
        return cl, op ~= nil and #op == #cl, true
    end
    return op, true, false
end

--- Find the longest opener or closer at (li, col), preferring the
--- longer match (and closers on length ties, so symmetric/competing
--- delimiters close rather than nest). Returns (delim, is_open,
--- is_close, dlen). Helper for the depth-counting scans: at each byte
--- position we ask "is there a delimiter STARTING here?" and count it
--- as +1 if it's an opener, -1 if it's a closer. This is what lets
--- shared-closer pair sets (e.g. Lua's `function`/`then`/`do`/`begin`
--- all closing with `end`) nest correctly: ANY opener increments the
--- running depth and ANY closer decrements it.
---@param li integer
---@param col integer
---@param open_of table opener→closer map
---@param close_of table closer→opener map
---@return string|nil delim
---@return boolean is_open
---@return boolean is_close
---@return integer dlen
function View:_scan_delim_at(li, col, open_of, close_of)
    -- Inline of delim_at, but returning the length too.
    local op = self:_longest_prefix_at(li, col, open_of)
    local cl = self:_longest_prefix_at(li, col, close_of)
    if not op and not cl then
        return nil, false, false, 0
    end
    if cl and (not op or #cl >= #op) then
        return cl, op ~= nil and #op == #cl, true, #cl
    end
    return op, true, false, #op
end

--- Find the matching closer for a DELIMITER (opener) at (ol, oc),
--- depth-counted across lines. `open_of` / `close_of` are the pair
--- maps (compile once from the active pair set; see _sexp_pair_tables).
--- Depth is counted over the WHOLE pair set — ANY opener in `open_of`
--- increments depth, ANY closer in `close_of` decrements it — so
--- shared-closer pair sets (Lua's `function`/`then`/`begin`/`do` all
--- closing with `end`) nest correctly. Word boundaries are enforced
--- by _longest_prefix_at so `end` doesn't match inside `append`.
--- Returns (cl, cc) the POS of the closer, plus closer_len — the
--- closer's byte length — so callers compute its end (cl, cc+clen).
--- nil if no matching closer.
---@param ol integer opener line
---@param oc integer opener col
---@param open_of table opener→closer map (default DEFAULT_OPEN_OF)
---@param close_of table closer→opener map (default DEFAULT_CLOSE_OF)
---@return integer|nil cl
---@return integer|nil cc
---@return integer|nil closer_len
function View:match_forward(ol, oc, open_of, close_of)
    open_of = open_of or DEFAULT_OPEN_OF
    close_of = close_of or DEFAULT_CLOSE_OF
    local opener = self:_longest_prefix_at(ol, oc, open_of)
    if not opener then
        return nil, nil, nil
    end
    local olen = #opener
    -- Start depth at 1 (we're sitting on the opener) and walk forward.
    local depth = 1
    local li, col = ol, oc + olen
    local lc = self:line_count()
    while li < lc do
        local _, n = self:_line_content(li)
        while col < n do
            local _, is_open, is_close, dlen = self:_scan_delim_at(li, col, open_of, close_of)
            if dlen > 0 then
                if is_close then
                    depth = depth - 1
                    if depth == 0 then
                        return li, col, dlen
                    end
                elseif is_open then
                    depth = depth + 1
                end
                col = col + dlen
            else
                col = col + 1
            end
        end
        li = li + 1
        col = 0
    end
    return nil, nil, nil
end

--- Find the matching opener for a closer at (cl, cc), depth-counted
--- backward across lines. Shared-closer aware: ANY opener increments
--- depth, ANY closer decrements it. Word boundaries enforced by
--- _longest_prefix_at. Returns (ol, oc) the POS of the opener, plus
--- opener_len, or nil.
---@param cl integer closer line
---@param cc integer closer col
---@param open_of table opener→closer map (default DEFAULT_OPEN_OF)
---@param close_of table closer→opener map (default DEFAULT_CLOSE_OF)
---@return integer|nil ol
---@return integer|nil oc
---@return integer|nil opener_len
function View:match_backward(cl, cc, open_of, close_of)
    open_of = open_of or DEFAULT_OPEN_OF
    close_of = close_of or DEFAULT_CLOSE_OF
    local closer = self:_longest_prefix_at(cl, cc, close_of)
    if not closer then
        return nil, nil, nil
    end
    local clen = #closer
    local depth = 1
    local li, col = cl, cc - 1
    while li >= 0 do
        local _, n = self:_line_content(li)
        while col >= 0 do
            local _, is_open, is_close, dlen = self:_scan_delim_at(li, col, open_of, close_of)
            if dlen > 0 then
                -- test closer FIRST when scanning back, so a closer at
                -- the scan position increments depth before an opener.
                if is_close then
                    depth = depth + 1
                elseif is_open then
                    depth = depth - 1
                    if depth == 0 then
                        return li, col, dlen
                    end
                end
                col = col - 1
            else
                col = col - 1
            end
        end
        li = li - 1
        if li >= 0 then
            col = self:content_len(li)
        end
    end
    return nil, nil, nil
end

--- Find the innermost balanced pair enclosing `pt`. If `pt` is itself
--- on a delimiter, that pair is treated as enclosing (point at its
--- start / on its closer). Returns (ol, oc, cl, cc, olen, clen) or nil
--- — ol/oc = opener POS, cl/cc = closer POS; olen/clen are the
--- delimiter byte lengths so callers can compute the half-open end.
--- open_of/~close_of default to ()[]{}.
---@param pt table {line, offset}
---@param open_of table|nil
---@param close_of table|nil
---@return integer|nil ol
---@return integer|nil oc
---@return integer|nil cl
---@return integer|nil cc
---@return integer|nil olen
---@return integer|nil clen
function View:enclosing_pair(pt, open_of, close_of)
    open_of = open_of or DEFAULT_OPEN_OF
    close_of = close_of or DEFAULT_CLOSE_OF
    local pli, pcol = pt.line, pt.offset
    local _, is_open_here, is_close_here = self:delim_at(pli, pcol, open_of, close_of)
    -- If sitting on a closer, its opener is the enclosing pair's opener.
    if is_close_here then
        local ol, oc, olen = self:match_backward(pli, pcol, open_of, close_of)
        if ol then
            local clen = #(self:_longest_prefix_at(pli, pcol, close_of) or "")
            return ol, oc, pli, pcol, olen, clen
        end
        return nil
    end
    -- If sitting on an opener, its own pair encloses pt.
    if is_open_here then
        local cl, cc, clen = self:match_forward(pli, pcol, open_of, close_of)
        if cl then
            local olen = #(self:_longest_prefix_at(pli, pcol, open_of) or "")
            return pli, pcol, cl, cc, olen, clen
        end
        return nil
    end
    -- Otherwise walk backward for the nearest unmatched opener, then
    -- forward to its match (and confirm pt is strictly inside).
    local li, col = pli, pcol - 1
    while li >= 0 do
        local text, n = self:_line_content(li)
        while col >= 0 do
            local op = col + 1
            local op_str = self:_longest_prefix_at(li, col, open_of)
            local cl_len, cl_str = 0, self:_longest_prefix_at(li, col, close_of)
            if cl_str then
                cl_len = #cl_str
            end
            if op_str then
                -- candidate opener; verify its match encloses pt.
                -- match_forward already returns closer_len when the opener is valid.
                local mf_cl, mf_cc, mf_clen = self:match_forward(li, col, open_of, close_of)
                if mf_cl then
                    local after_pt = (li > pli) or (li == pli and col > pcol)
                    local before_close = (mf_cl < pli)
                        or (mf_cl == pli and (mf_cc + (mf_clen or 0)) <= pcol)
                    if not after_pt and not before_close then
                        return li, col, mf_cl, mf_cc, #op_str, mf_clen or 0
                    end
                end
            end
            -- a closer on the way back means pt is outside that pair;
            -- skip past it (depth handled by the closer-opener march).
            if cl_str then
                -- skip over the closer plus its matched opener by matching back
                local om_ol, om_oc, om_olen = self:match_backward(li, col, open_of, close_of)
                if om_ol then
                    -- Continue scanning from before THIS opener. The
                    -- opener may be on an EARLIER line than the closer
                    -- (multi-line pair) — update BOTH li and col,
                    -- otherwise we'd re-scan the closer's line and
                    -- re-hit the same closer forever (infinite loop).
                    li = om_ol
                    col = om_oc - 1
                    if col < -0 then
                        if li > 0 then
                            li = li - 1
                            col = self:content_len(li)
                        else
                            break
                        end
                    end
                    -- re-scan within this line before continuing
                    text, n = self:_line_content(li)
                else
                    col = col - 1
                end
            else
                col = col - 1
            end
        end
        li = li - 1
        if li >= 0 then
            col = self:content_len(li)
        end
    end
    return nil
end

--- Range of the innermost balanced pair enclosing point, OR — for
--- directional motion — the next/prev sibling pair at point's depth.
--- `dir` selects the behavior:
---   nil          -> the CONTAINING pair (mark / select_range); falls
---                  back to next-forward only when between pairs.
---   > 0          -> the NEXT pair whose opener is at/after point and
---                  STRICTLY INSIDE the enclosing pair (forward-sexp
---                  steps through children/siblings, depth-aware —
---                  does NOT jump to the enclosing end). When no
---                  child remains before the enclosing closer, returns
---                  the enclosing pair itself (forward lands at its
---                  closer = exit the list, up-list semantics).
---   < 0          -> symmetric: the PREVIOUS pair strictly inside the
---                  enclosing pair, else the enclosing pair (exit).
---   == 0         -> containing-only: nil when between pairs (used by
---                  up-list / backward-up-list, which exit the CURRENT
---                pair and are no-ops when not inside one).
---   == 2         -> the next OPENER strictly after point, as a
---                degenerate zero-width range `(sl, sc+1)` — used by
---                down-list to descend into the next nested opener
---                regardless of containment. nil if none after point.
--- Half-open INCLUDING the delimiters: [ol, oc .. cl, cc+clen).
--- boundary_len = 0 (forward motion lands right after the closer end).
---@param line integer 0-based point line
---@param col integer 0-based point col
---@param open_of table|nil
---@param close_of table|nil
---@param dir integer|nil see above
---@return integer|nil sl
---@return integer|nil sc
---@return integer|nil el
---@return integer|nil ec
---@return integer|nil boundary_len
function View:sexp_range(line, col, open_of, close_of, dir)
    open_of = open_of or DEFAULT_OPEN_OF
    close_of = close_of or DEFAULT_CLOSE_OF
    if dir == 2 then
        -- down-list: next opener strictly after point, as a degenerate
        -- range so the caller lands at (sl, sc+1) = just past the opener.
        local nol, noc, nolen = self:_next_pair_start_after(line, col, open_of, close_of)
        if not nol then
            return nil, nil, nil, nil, nil
        end
        return nol, noc, nol, noc + (nolen or 1), 0
    end
    local ol, oc, cl, cc, olen, clen =
        self:enclosing_pair({ line = line, offset = col }, open_of, close_of)
    -- Helper: is (fl, fc) strictly INSIDE the enclosing pair E (whose
    -- opener is at (ol,oc) len olen, closer at (cl,cc))? "Strictly inside"
    -- = past E's opener end AND before E's closer position.
    local function inside_E(fl, fc)
        if not ol then
            return true -- no enclosing pair: anything goes (top level)
        end
        local after_opener = (fl > ol) or (fl == ol and fc >= oc + (olen or 1))
        local before_closer = (fl < cl) or (fl == cl and fc < cc)
        return after_opener and before_closer
    end
    -- dir == 0 (up-list / containing-only): return the enclosing pair,
    -- or nil when not inside one.
    if dir == 0 then
        if ol then
            return ol, oc, cl, cc + (clen or 1), 0
        end
        return nil, nil, nil, nil, nil
    end
    -- dir == nil (mark / select_range): select the CONTAINING pair when
    -- inside one; only when between pairs do we fall through to the
    -- next-forward pair (so mark_sexp at top level selects the next one).
    if dir == nil and ol then
        return ol, oc, cl, cc + (clen or 1), 0
    end
    if dir == nil or dir > 0 then
        -- Forward motion: step to the NEXT pair whose opener is at/after
        -- point AND strictly inside the enclosing pair E (so we walk
        -- through sibling/child pairs at point's depth rather than
        -- jumping straight to E's end). If no such child remains before
        -- E's closer, return E itself — forward lands at E's closer end,
        -- i.e. exit the list (up-list semantics).
        local nol, noc, nolen = self:_next_pair_start_after(line, col, open_of, close_of)
        if nol and inside_E(nol, noc) then
            ---@cast noc integer
            local ncl, ncc, nclen = self:match_forward(nol, noc, open_of, close_of)
            if ncl then
                return nol, noc, ncl, ncc + (nclen or 1), 0
            end
        end
        if ol then
            return ol, oc, cl, cc + (clen or 1), 0
        end
        return nil, nil, nil, nil, nil
    end
    -- backward (dir < 0): symmetric — step to the PREVIOUS pair whose
    -- closer is strictly before point AND strictly inside E; if none,
    -- return E (backward lands at E's opener = exit backward).
    local pcl, pcc, pclen = self:_prev_pair_end_before(line, col, open_of, close_of)
    if pcl and inside_E(pcl, pcc) then
        ---@cast pcc integer
        local pol, poc, polen = self:match_backward(pcl, pcc, open_of, close_of)
        if pol then
            return pol, poc, pcl, pcc + (pclen or 1), 0
        end
    end
    if ol then
        return ol, oc, cl, cc + (clen or 1), 0
    end
    return nil, nil, nil, nil, nil
end

--- Range of the innermost balanced pair enclosing point (or the
--- adjacent pair by direction when between pairs), driven by a
--- `pairs` spec as produced by the `sexp(pairs)` builder
--- (cursed.textobject). Resolves the pair maps once (cached on the
--- spec) and delegates to View:sexp_range.
---@param line integer 0-based point line
---@param col integer 0-based point col
---@param pairs table list of {opener,closer}
---@param dir integer|nil 0=at/next-forward, >0=forward, <0=backward
---@return integer|nil sl
---@return integer|nil sc
---@return integer|nil el
---@return integer|nil ec
---@return integer|nil boundary_len
function View:_sexp_range(line, col, pairs, dir)
    local open_of, close_of = self:_sexp_pair_tables(pairs)
    return self:sexp_range(line, col, open_of, close_of, dir)
end

--- Find the next opener at depth 0 at/after (li, col), scanning
--- forward. Returns (ol, oc, olen) or nil. Used by forward-sexp
--- (when not already inside a pair) and down-list.
---@param li integer
---@param col integer
---@param open_of table|nil
---@param close_of table|nil
---@return integer|nil ol
---@return integer|nil oc
---@return integer|nil olen
function View:_next_pair_start_after(li, col, open_of, close_of)
    open_of = open_of or DEFAULT_OPEN_OF
    close_of = close_of or DEFAULT_CLOSE_OF
    local lc = self:line_count()
    local l, c = li, col
    while l < lc do
        local text, n = self:_line_content(l)
        while c < n do
            local op_str = self:_longest_prefix_at(l, c, open_of)
            if op_str then
                return l, c, #op_str
            end
            c = c + 1
        end
        l = l + 1
        c = 0
    end
    return nil
end

--- Find the previous closer at depth 0 strictly before (li, col),
--- scanning backward. Returns (cl, cc, clen) or nil. Used by
--- backward-sexp and transpose-sexp to locate the previous pair.
---@param li integer
---@param col integer
---@param open_of table|nil
---@param close_of table|nil
---@return integer|nil cl
---@return integer|nil cc
---@return integer|nil clen
function View:_prev_pair_end_before(li, col, open_of, close_of)
    open_of = open_of or DEFAULT_OPEN_OF
    close_of = close_of or DEFAULT_CLOSE_OF
    local l, c = li, col - 1
    while l >= 0 do
        local text, n = self:_line_content(l)
        while c >= 0 do
            local cl_str = self:_longest_prefix_at(l, c, close_of)
            if cl_str then
                return l, c, #cl_str
            end
            c = c - 1
        end
        l = l - 1
        if l >= 0 then
            c = self:content_len(l)
        end
    end
    return nil
end

--- Move point across N textobject units. Resolved via the textobject
--- FUNCTION (View:_textobject_fn): forward motion lands at
--- (end_line, end_col + boundary_len) — i.e. just past the unit,
--- skipping the boundary gap so the cursor lands at the NEXT unit's
--- start (a word motion skips the separating space; a sentence
--- motion skips the trailing gap; a sexp motion lands right after
--- the closer). Backward motion lands at the unit's (start_line,
--- start_col). Repeats by re-querying from the new position.
---@param n integer signed count
---@param obj_name string textobject name
---@return boolean ok
---@return string|nil err
function View:move_word(n, obj_name)
    if n == 0 then
        return true
    end
    local fn = self:_textobject_fn(obj_name)
    if not fn then
        fn = self:_textobject_fn("word")
    end
    local forward = n > 0
    local remaining = forward and n or -n
    -- Direction hint for direction-aware textobjects (sexp): tells the
    -- range-finder which adjacent pair to return when point sits BETWEEN
    -- units (forward -> next pair, backward -> previous pair). Pattern
    -- textobjects ignore it.
    local dir = forward and 1 or -1
    return self:each_cursor(function(c)
        for _ = 1, remaining do
            local fn1 = fn --[[@as function]]
            local sl, sc, el, ec, blen = fn1(self, c.line, c.col, dir)
            if not sl then
                return nil, forward and "end of document" or "start of document"
            end
            if forward then
                -- If point is already at or past this unit's end,
                -- there's no next unit to step to — report end of
                -- document (prevents re-selecting the last unit and
                -- looping). "At or past" is lexicographic: the end is
                -- strictly above point (el < c.line) or on the same
                -- line at/before the cursor (el == c.line and ec <=
                -- col). A multi-line unit whose end is on a LATER line
                -- (el > c.line) is ahead of us, not past us — we jump
                -- down to it.
                if (el < c.line) or (el == c.line and (ec or 0) <= c.col) then
                    return nil, "end of document"
                end
                local content_len = self:content_len(el)
                local target = (ec or 0) + (blen or 0)
                -- Land at the unit end + boundary skip, clamped to this
                -- line's content. Don't wrap to the next line here: the
                -- unit-above / end-of-document guard catches a point
                -- already at end-of-line on the next iteration.
                c.line = el
                c.col = math.min(target, content_len)
            else
                -- Backward: if already at the unit's start, walk one
                -- more by querying from one char before to force a
                -- strictly-earlier boundary (prevents staying put).
                if sl == c.line and sc == c.col then
                    local pcol = c.col - 1
                    local pline = c.line
                    if pcol < 0 then
                        if c.line > 0 then
                            pline = c.line - 1
                            pcol = self:content_len(pline)
                        else
                            return nil, "start of document"
                        end
                    end
                    local fn1 = fn --[[@as function]]
                    local s2, c2 = fn1(self, pline, pcol, dir)
                    if not s2 then
                        return nil, "start of document"
                    end
                    sl, sc = s2, c2
                end
                c.line = sl
                c.col = sc
            end
        end
        c.goal_col = self:byte_to_col(c.line, c.col)
        c.visual_col = nil
        c.yank_line = nil
        c.yank_col = nil
        return true
    end)
end

function View:cursor_left()
    return self:each_cursor(function(c)
        if c.col > 0 then
            -- Step one grapheme cluster backward so the caret never lands
            -- between a base char and its combining marks / ZWJ sequence.
            c.col = self:advance_grapheme(c.line, c.col, -1)
            c.goal_col = self:byte_to_col(c.line, c.col)
            c.visual_col = nil
            c.yank_line = nil
            c.yank_col = nil
        elseif c.line > 0 then
            c.line = c.line - 1
            c.col = self:content_len(c.line)
            c.goal_col = self:byte_to_col(c.line, c.col)
            c.visual_col = nil
            c.yank_line = nil
            c.yank_col = nil
        end
        return true
    end)
end

function View:cursor_right()
    return self:each_cursor(function(c)
        local dl = self:content_len(c.line)
        if c.col < dl then
            -- Step one grapheme cluster forward (skips zero-width combining
            -- marks / ZWJ continuations so the caret stops on the next base).
            c.col = self:advance_grapheme(c.line, c.col, 1)
            c.goal_col = self:byte_to_col(c.line, c.col)
            c.visual_col = nil
            c.yank_line = nil
            c.yank_col = nil
        elseif c.line < self:line_count() - 1 then
            c.line = c.line + 1
            c.col = 0
            c.goal_col = 0
            c.visual_col = nil
            c.yank_line = nil
            c.yank_col = nil
        end
        return true
    end)
end

function View:cursor_up()
    return self:each_cursor(function(c)
        if c.line > 0 then
            c.line = c.line - 1
            local content_len = self:content_len(c.line)
            local max_col = self:byte_to_col(c.line, content_len)
            local goal = math.min(c.goal_col, max_col)
            c.col = self:col_to_byte(c.line, goal)
        end
        return true
    end)
end

function View:cursor_down()
    return self:each_cursor(function(c)
        if c.line < self:line_count() - 1 then
            c.line = c.line + 1
            local content_len = self:content_len(c.line)
            local max_col = self:byte_to_col(c.line, content_len)
            local goal = math.min(c.goal_col, max_col)
            c.col = self:col_to_byte(c.line, goal)
        end
        return true
    end)
end

----------------------------------------------------------------------------------------------------
-- Scrolling (primary-cursor based)
----------------------------------------------------------------------------------------------------

--- Auto-scroll the viewport to keep the primary cursor on screen.
---
--- This runs every render, but it ONLY adjusts `scroll_y` when the
--- cursor's logical (line, col) has changed since the last auto-scroll.
--- That guard is what lets the user pan the viewport away from the
--- cursor — via the mouse wheel or paging (see `scroll_viewport` /
--- `scroll_page`) — without the next render snapping it right back onto
--- the cursor. As soon as the cursor moves again (any motion or edit:
--- motions go through `each_cursor`, edits through `batch_edit`, and
--- both land here via the render loop), the guard mismatches and we
--- re-scroll to bring the caret back into view.
---
--- `force` (used after a wrap reflow on resize) bypasses the guard so a
--- same-frame re-scroll can correct for the cursor's screen position
--- shifting even though its logical position didn't.
---@param height integer terminal height in rows
---@param force boolean? when true, skip the cursor-unchanged guard
function View:scroll_to_cursor(height, force)
    local scroll_t0 = profile.now_us()
    local c = self:p()
    if not force and c.line == self._scroll_guard_line and c.col == self._scroll_guard_col then
        return
    end
    self._scroll_guard_line = c.line
    self._scroll_guard_col = c.col
    if self.editor then
        self.editor:request_full_damage()
    end

    local text_rows = height - 1
    local margin = text_rows - 1
    local cur_sub_row, _ = self:wrap_sub_position(c.line, c.col)

    -- JUMP fast path: if the cursor is far outside the viewport
    -- (more than two viewports away from the anchor line), computing
    -- its viewport-relative row by walking from the anchor would be
    -- O(distance) — exactly the whole-prefix walk we're trying to
    -- avoid. Instead re-anchor directly: near EOF → anchor so the
    -- cursor sits at the bottom (backward walk of `margin` rows, O(viewport));
    -- elsewhere → anchor so the cursor sits at the top (O(1)).
    local a_li = self.scroll_li or 0
    if math.abs(c.line - a_li) > 2 * text_rows then
        local n = self:line_count()
        if c.line >= n - 1 - text_rows then
            -- Near EOF: bring the tail into view, cursor at bottom.
            self:anchor_so_line_at_row(c.line, cur_sub_row, margin)
        else
            -- Mid-document jump: anchor at the cursor (top).
            self:anchor_to_line(c.line, cur_sub_row)
        end
        self._recenter_state = 0
        self:clamp_anchor_to_eof(text_rows)
        profile.span("view", "scroll_to_cursor", scroll_t0)
        return
    end

    local row = self:viewport_row_for_line(c.line, cur_sub_row)
    if row < 0 then
        -- Cursor above viewport: anchor so cursor sits at the top.
        self:anchor_to_line(c.line, cur_sub_row)
        self._recenter_state = 0
    elseif row > margin then
        -- Cursor below viewport: anchor so cursor sits at the bottom row.
        self:anchor_so_line_at_row(c.line, cur_sub_row, margin)
        self._recenter_state = 0
    end
    -- Clamp so we never scroll past EOF. O(viewport), no full prefix build.
    self:clamp_anchor_to_eof(text_rows)
    profile.span("view", "scroll_to_cursor", scroll_t0)
end

--- Scroll the viewport by `delta` screen rows WITHOUT moving the
--- cursor. Used by mouse-wheel and paging so they no longer get "stuck"
--- on the caret: `scroll_to_cursor`'s guard sees the cursor didn't move
--- and leaves the viewport where the user put it (until the cursor
--- next moves, which re-arms auto-scroll). The cursor may legitimately
--- scroll out of view; that's the point.
---
--- `text_rows` is the number of visible text rows (terminal height minus
--- footer), used only to clamp `scroll_y` to the document bounds.
---@param delta integer signed screen rows (negative = toward start)
---@param text_rows integer visible text-row count (for clamping)
function View:scroll_viewport(delta, text_rows)
    self:scroll_anchor(delta)
    if self.editor then
        self.editor:request_full_damage()
    end
end

--- Page the viewport (no cursor movement). `page_size` is the number of
--- screen rows in a page (≈ visible text rows).keeps the caret's
--- logical position; only the viewport shifts.
---@param n integer signed page count (negative = toward start)
---@param page_size integer screen rows per page
function View:scroll_page(n, page_size)
    self:scroll_viewport(n * page_size, page_size)
    -- Piggyback piece-table compaction onto page navigation. The page
    -- transition already incurs a perceptible viewport shift, so the
    -- O(visible_lines * pieces_per_line) work is hidden there. This
    -- amortizes compaction across normal navigation instead of needing
    -- a separate full-document compaction pass.
    if page_size <= 0 then
        return
    end
    local n_lines = self:line_count()
    if n_lines == 0 then
        return
    end
    -- Visible line range from the anchor, by a viewport-local forward walk.
    local start_li = self.scroll_li or 0
    local li = start_li
    local sub = self.scroll_sub_row or 0
    local filled = (self:wrap_rows(li) or 1) - sub
    while filled < page_size and li < n_lines - 1 do
        li = li + 1
        filled = filled + (self:wrap_rows(li) or 1)
    end
    if start_li > li then
        return
    end
    self.buffer:compact_lines(start_li, li)
end

--- Recenter the view so the cursor line is at the given position.
--- Cycles through: middle → top → bottom.
---@param height integer terminal height in rows
function View:recenter(height)
    local c = self:p()
    local text_rows = height - 1
    local cur_sub_row = select(1, self:wrap_sub_position(c.line, c.col))

    local state = self._recenter_state
    if state == 0 then
        -- Middle
        self:anchor_so_line_at_row(c.line, cur_sub_row, math.floor(text_rows / 2))
    elseif state == 1 then
        -- Top
        self:anchor_to_line(c.line, cur_sub_row)
    else
        -- Bottom
        self:anchor_so_line_at_row(c.line, cur_sub_row, text_rows - 1)
    end

    self._recenter_state = (state + 1) % 3
    if self.editor then
        self.editor:request_full_damage()
    end

    -- Clamp to EOF.
    self:clamp_anchor_to_eof(text_rows)
end

----------------------------------------------------------------------------------------------------
-- Undo/Redo (clamp cursor after applying)
----------------------------------------------------------------------------------------------------

function View:undo()
    if not self.buffer:undo() then
        return false
    end
    if self.editor then
        self.editor:request_full_damage()
    end
    self:clamp_cursor()
    -- Undo swaps buffer content wholesale; the cached spans (and the
    -- lane's retained old_tree) describe pre-undo text. Cold-requery
    -- the viewport so post-undo render shows correct syntax.
    -- Also nuke the wrap cache: its staleness guard keys off
    -- (undo.count + redo.count), which is INVARIANT under undo/redo
    -- (an undo moves one group undo→redo, preserving the sum), so the
    -- proactive check in ensure_wrap_cache would otherwise treat the
    -- stale cache as fresh and index a now-too-short _wrap_rows → nil.
    self:invalidate_wrap_cache()
    local c = self:p()
    local starts = self:_hl_line_starts()
    local byte = (starts[c.line + 1] or 0) + c.col
    self:_hl_cold_requery(byte)
    return true
end

function View:redo()
    if not self.buffer:redo() then
        return false
    end
    if self.editor then
        self.editor:request_full_damage()
    end
    self:clamp_cursor()
    -- See View:undo: the wrap cache staleness guard is invariant under
    -- undo/redo, so we must invalidate it explicitly here too.
    self:invalidate_wrap_cache()
    local c = self:p()
    local starts = self:_hl_line_starts()
    local byte = (starts[c.line + 1] or 0) + c.col
    self:_hl_cold_requery(byte)
    return true
end

--- Clamp every cursor to valid range after undo/redo.
function View:clamp_cursor()
    local lc = self:line_count()
    for _, c in ipairs(self.cursors) do
        if c.line >= lc then
            c.line = math.max(0, lc - 1)
        end
        local cl = self:content_len(c.line)
        if c.col > cl then
            c.col = cl
        end
        c.goal_col = self:byte_to_col(c.line, c.col)
        c.visual_col = nil
        c.yank_line = nil
        c.yank_col = nil
    end
end

----------------------------------------------------------------------------------------------------
-- Undo/Redo in Selection (shadow index approach; per-cursor shadow)
----------------------------------------------------------------------------------------------------

--- Undo within the current selection of the primary cursor.
--- Reads the text that the selection region contained in the previous
--- undo snapshot and replaces the current selection with it.
---@return boolean
function View:undo_in_selection()
    local c = self:p()
    if not c.anchor_line then
        return false
    end

    local shadow = c.shadow_undo
    if shadow == nil then
        return false
    end
    ---@cast shadow integer

    local b = self.buffer._ptr
    local undo_count = tonumber(b.undo.count)
    ---@cast undo_count integer

    -- Clamp shadow if the undo stack has shrunk (e.g. from regular undo)
    shadow = math.min(shadow, undo_count)
    if shadow == 0 then
        c.shadow_undo = 0
        return false
    end

    local sl, sc, el, ec = self:selection_range()
    if not sl or not sc or not el or not ec then
        return false
    end
    local old_text = self.buffer:snapshot_text_range(b.undo, shadow - 1, sl, sc, el, ec)

    -- Replace current selection with the snapshot text
    self.buffer:close_edit()
    self.buffer:begin_edit()

    -- Delete current selection
    local n = self:chars_between(sl, sc, el, ec)
    if n > 0 then
        local rl, rc = self.buffer:delete_char(sl, sc, n)
        c.line = rl
        c.col = rc
        self:_set_goal_col(rc)
    end

    -- Insert old text
    if #old_text > 0 then
        local rl, rc = self.buffer:insert_char(c.line, c.col, old_text)
        c.line = rl
        c.col = rc
        self:_set_goal_col(rc)
    end

    self.buffer:end_edit()

    -- Re-establish mark at cursor (selection persists for further undo-in-selection)
    c.anchor_line = c.line
    c.anchor_col = c.col

    -- Advance shadow indices
    c.shadow_undo = shadow - 1
    c.shadow_redo = (c.shadow_redo or 0) + 1

    return true
end

--- Redo within the current selection of the primary cursor.
---@return boolean
function View:redo_in_selection()
    local c = self:p()
    if not c.anchor_line then
        return false
    end

    local shadow = c.shadow_redo
    if shadow == nil or shadow == 0 then
        return false
    end
    ---@cast shadow integer

    local b = self.buffer._ptr
    local redo_count = tonumber(b.redo.count)
    ---@cast redo_count integer

    -- Clamp shadow if the redo stack has shrunk
    shadow = math.min(shadow, redo_count)
    if shadow == 0 then
        c.shadow_redo = 0
        return false
    end

    local sl, sc, el, ec = self:selection_range()
    if not sl or not sc or not el or not ec then
        return false
    end
    local old_text = self.buffer:snapshot_text_range(b.redo, shadow - 1, sl, sc, el, ec)

    -- Replace current selection with the snapshot text
    self.buffer:close_edit()
    self.buffer:begin_edit()

    local n = self:chars_between(sl, sc, el, ec)
    if n > 0 then
        local rl, rc = self.buffer:delete_char(sl, sc, n)
        c.line = rl
        c.col = rc
        self:_set_goal_col(rc)
    end

    if #old_text > 0 then
        local rl, rc = self.buffer:insert_char(c.line, c.col, old_text)
        c.line = rl
        c.col = rc
        self:_set_goal_col(rc)
    end

    self.buffer:end_edit()

    -- Re-establish mark at cursor
    c.anchor_line = c.line
    c.anchor_col = c.col

    -- Advance shadow indices
    c.shadow_undo = (c.shadow_undo or 0) + 1
    c.shadow_redo = shadow - 1

    return true
end

----------------------------------------------------------------------------------------------------
-- Pattern-string textobject cache
--
-- Pattern-based textobjects (word, bigword, sentence, subsentence,
-- and mode/user ones) get their textobject function AUTO-GENERATED
-- from the pattern via View.pattern_textobject_fn. The wrapped fn is
-- cached here so each distinct pattern string is wrapped at most once.
-- Structural objects (paragraph, sexp, balanced-expression) are now
-- proper functions in default_textobjects.lua, not overrides here.
----------------------------------------------------------------------------------------------------
View._PATTERN_FN_CACHE = {}

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    View = View,
}
