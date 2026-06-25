--- View: pure viewport — cursor, scroll, mark/selection.
---
--- A View holds a reference to a Buffer (shared, not owned) and tracks
--- a list of cursors, the scroll offset, and per-cursor mark/selection state.
--- It does NOT mutate the buffer. Editing goes through Buffer methods,

local ffi = require("ffi")
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
---@field scroll_y integer vertical scroll offset in screen rows
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
---@field _wrap_gen integer|nil cache generation counter (undo.count + redo.count)
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
        scroll_y = 0,
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
        _wrap_gen = nil,
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
    }, View)
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
        goal_col = col,
        visual_col = nil,
        anchor_line = nil,
        anchor_col = nil,
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
---@param col integer
function View:_set_goal_col(col)
    local c = self.cursors[1]
    c.goal_col = col
    c.visual_col = nil
    c.yank_line = nil
    c.yank_col = nil
end

--- Set the goal column on every cursor (used when a motion/edit
--- applies uniformly to all cursors, e.g. clamp_cursor after undo).
---@param col integer
function View:_set_goal_col_all(col)
    for _, c in ipairs(self.cursors) do
        c.goal_col = col
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
            if kind == "insert" and rl ~= sl then
                hl_crossed_newline = true
            elseif kind == "replace" or type(kind) == "table" then
                local el, ec = e1, e2
                if el ~= nil and el ~= sl then
                    hl_crossed_newline = true
                end
            end
            -- Move the editing cursor to the buffer-reported result.
            cur.line = rl
            cur.col = rc
            cur.goal_col = rc
            cur.visual_col = nil

            local tr
            if kind == "insert" then
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
---@param li integer 0-based line index
---@return integer
function View:wrap_rows(li)
    if not self.wrap_width or self.wrap_width <= 0 then
        return 1
    end
    local len = self:content_len(li)
    if len == 0 then
        return 1
    end
    return math.ceil(len / self.wrap_width)
end

--- Invalidate the wrap cache (call when buffer content changes or wrap_width changes).
function View:invalidate_wrap_cache()
    self._wrap_rows = nil
    self._wrap_cum = nil
    -- Invalidate the auto-scroll guard: a wrap reflow (resize or edit)
    -- can shift the cursor's screen row even though its logical (line,
    -- col) is unchanged, so the guard's stored position no longer proves
    -- the viewport is correctly positioned. Forcing the next
    -- scroll_to_cursor re-centers on the cursor after the reflow.
    self._scroll_guard_line = nil
    self._scroll_guard_col = nil
end

--- Rebuild the wrap cache from scratch.
--- Also checks the buffer's undo+redo generation counter and
--- invalidates the cache proactively if the buffer was edited
--- since the last build (prevents stale cache between edit and render).
local function ensure_wrap_cache(view)
    -- Proactive staleness check: if buffer was edited, invalidate now
    -- so we never return stale data to scroll_to_cursor etc.
    if view._wrap_rows and view._wrap_gen then
        local gen = tonumber(view.buffer._ptr.undo.count) + tonumber(view.buffer._ptr.redo.count)
        if gen ~= view._wrap_gen then
            view._wrap_rows = nil
            view._wrap_cum = nil
        end
    end
    if view._wrap_rows then
        return
    end
    local n = view:line_count()
    local rows = {} -- rows[i] = screen rows for logical line (i-1), 1-based index
    local cum = {} -- cum[i] = screen row where logical line (i-1) starts, 1-based index
    local screen_row = 0
    for li = 0, n - 1 do
        local r = view:wrap_rows(li)
        rows[li + 1] = r
        cum[li + 1] = screen_row
        screen_row = screen_row + r
    end
    view._wrap_rows = rows
    view._wrap_cum = cum
    -- Record the generation we just built for
    view._wrap_gen = tonumber(view.buffer._ptr.undo.count) + tonumber(view.buffer._ptr.redo.count)
end

--- Return the screen row where logical line `li` starts (0-based).
---@param li integer 0-based line index
---@return integer
function View:line_to_screen_row(li)
    if not self.wrap_width or self.wrap_width <= 0 then
        return li
    end
    ensure_wrap_cache(self)
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
    if #self._wrap_cum == 0 then
        return 0, 0
    end
    -- Binary search in cumulative table
    local lo, hi = 1, #self._wrap_cum
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

--- Total number of screen rows for the entire document.
---@return integer
function View:total_screen_rows()
    if not self.wrap_width or self.wrap_width <= 0 then
        return self:line_count()
    end
    ensure_wrap_cache(self)
    local n = self:line_count()
    if n == 0 then
        return 0
    end
    -- Add up all rows
    local total = 0
    for i = 1, n do
        total = total + self._wrap_rows[i]
    end
    return total
end

--- Return the byte offset within a logical line for a given sub-row and column.
--- In a wrapped display, the cursor's byte position is sub_row * wrap_width + sub_col.
---@param li integer 0-based line index
---@param sub_row integer 0-based sub-row within the wrapped line
---@param sub_col integer 0-based column within the sub-row
---@return integer byte_offset 0-based byte offset within the line
function View:wrap_byte_offset(li, sub_row, sub_col)
    if not self.wrap_width or self.wrap_width <= 0 then
        return sub_col
    end
    return sub_row * self.wrap_width + sub_col
end

--- Return the sub-row and sub-col for a byte offset within a wrapped line.
---@param li integer 0-based line index
---@param byte_offset integer 0-based byte offset
---@return integer sub_row
---@return integer sub_col
function View:wrap_sub_position(li, byte_offset)
    if not self.wrap_width or self.wrap_width <= 0 then
        return 0, byte_offset
    end
    local w = self.wrap_width
    local sub_row = math.floor(byte_offset / w)
    local sub_col = byte_offset % w
    return sub_row, sub_col
end

----------------------------------------------------------------------------------------------------
-- Mark / Selection
----------------------------------------------------------------------------------------------------

function View:set_mark()
    local c = self:p()
    c.anchor_line = c.line
    c.anchor_col = c.col
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
        c.shadow_undo = u
        c.shadow_redo = r
    end
end

--- Clear the mark on every cursor.
function View:unset_mark_all()
    for _, c in ipairs(self.cursors) do
        c.anchor_line = nil
        c.anchor_col = nil
        c.shadow_undo = nil
        c.shadow_redo = nil
    end
end

function View:unset_mark()
    local c = self:p()
    c.anchor_line = nil
    c.anchor_col = nil
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

--- Insert a newline at every cursor, with electric indent.
--- Computes the leading-whitespace indent of each cursor's current
--- line and inserts "\n" + indent. The batch_edit insert translator
--- correctly handles same-line-newline splits: a later cursor on the
--- same line ends up in the new line at the appropriate column.
function View:insert_newline()
    local buf = self.buffer
    local breaks = buf:should_break_edit("\n")
    self:batch_edit(breaks, function(c)
        local line = buf:line_text(c.line)
        local indent = line:match("^([ \t]*)") or ""
        if self.expand_tab then
            indent = indent:gsub("\t", string.rep(" ", self.tab_width))
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
    -- Aggregate will_join across cursors: any structural delete breaks
    -- the group. Preserves single-cursor semantics exactly (N=1 →
    -- "any joins" == "the one joins").
    local any_join = false
    for _, c in ipairs(self.cursors) do
        local content_len = buf:line_len(c.line) - 1
        local will_join
        if n > 0 then
            will_join = c.col + n > content_len
        else
            will_join = c.col + n < 0
        end
        if will_join then
            any_join = true
            break
        end
    end
    self:batch_edit(any_join, function(c)
        -- Compute the pre-edit region end BEFORE the buffer mutates,
        -- since _delete_char_impl walks a changing line_count.
        local el, ec = delete_region_end(buf, c.line, c.col, n)
        local rl, rc = buf:delete_char(c.line, c.col, n)
        -- Normalize so the returned region is [start, end) half-open with
        -- start = min(cursor pre-edit point, region end) and end = the
        -- other. For forward deletes cursor pos is the start; for backward
        -- deletes the region end (below the cursor) is the start.
        local sl, sc
        if n > 0 then
            sl, sc = c.line, c.col
        else
            sl, sc = el, ec
            el, ec = c.line, c.col
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

            if forward then
                local available = content_len - col
                if available > 0 then
                    local step = math.min(remaining, available)
                    col = col + step
                    remaining = remaining - step
                end
            else
                if col > 0 then
                    local step = math.min(remaining, col)
                    col = col - step
                    remaining = remaining - step
                end
            end

            if remaining > 0 then
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
                    c.goal_col = col
                    c.visual_col = nil
                    c.yank_line = nil
                    c.yank_col = nil
                    return nil, forward and "end of document" or "start of document"
                end
            end
        end

        c.line = line
        c.col = col
        c.goal_col = col
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

            local cur_screen = self:line_to_screen_row(c.line) + cur_sub_row
            local target_screen = cur_screen + n
            if target_screen < 0 then
                c.line = 0
                c.col = 0
                c.goal_col = 0
                c.visual_col = nil
                c.yank_line = nil
                c.yank_col = nil
                return nil, "start of document"
            end
            local total = self:total_screen_rows()
            if target_screen >= total then
                c.line = line_count - 1
                c.col = buf:line_len(line_count - 1) - 1
                c.goal_col = c.col
                c.visual_col = nil
                c.yank_line = nil
                c.yank_col = nil
                return nil, "end of document"
            end
            local li, sub_row = self:screen_row_to_line(target_screen)
            c.line = li
            local content_len = self:content_len(li)
            -- Target visual column within the sub-row
            local sub_col
            if sub_row < self:wrap_rows(li) - 1 then
                sub_col = math.min(visual_goal, self.wrap_width - 1)
            else
                -- Last sub-row: width is the remainder
                local last_row_width = content_len - sub_row * self.wrap_width
                sub_col = math.min(visual_goal, math.max(0, last_row_width))
            end
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
            c.col = buf:line_len(line_count - 1) - 1
            c.goal_col = c.col
            c.visual_col = nil
            c.yank_line = nil
            c.yank_col = nil
            return nil, "end of document"
        end

        c.line = target
        c.col = math.min(c.goal_col, buf:line_len(target) - 1)
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
        c.col = self.buffer:line_len(c.line) - 1
        c.goal_col = c.col
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
        c.goal_col = c.col
        c.visual_col = nil
        c.yank_line = nil
        c.yank_col = nil
        return true
    end)
end

function View:cursor_left()
    return self:each_cursor(function(c)
        if c.col > 0 then
            c.col = c.col - 1
            c.goal_col = c.col
            c.visual_col = nil
            c.yank_line = nil
            c.yank_col = nil
        elseif c.line > 0 then
            c.line = c.line - 1
            c.col = self:content_len(c.line)
            c.goal_col = c.col
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
            c.col = c.col + 1
            c.goal_col = c.col
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
            c.col = math.min(c.goal_col, self:content_len(c.line))
        end
        return true
    end)
end

function View:cursor_down()
    return self:each_cursor(function(c)
        if c.line < self:line_count() - 1 then
            c.line = c.line + 1
            c.col = math.min(c.goal_col, self:content_len(c.line))
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
    local c = self:p()
    if not force and c.line == self._scroll_guard_line and c.col == self._scroll_guard_col then
        return
    end
    self._scroll_guard_line = c.line
    self._scroll_guard_col = c.col

    local text_rows = height - 1
    local margin = text_rows - 1
    local cursor_screen = self:line_to_screen_row(c.line)
    -- Add the sub-row offset within the wrapped line
    local cur_sub_row, _ = self:wrap_sub_position(c.line, c.col)
    cursor_screen = cursor_screen + cur_sub_row

    if cursor_screen < self.scroll_y then
        self.scroll_y = cursor_screen
        self._recenter_state = 0
    elseif cursor_screen > self.scroll_y + margin then
        self.scroll_y = cursor_screen - margin
        self._recenter_state = 0
    end

    -- Clamp scroll_y so we never scroll past the document
    local total_rows = self:total_screen_rows()
    local max_scroll = math.max(0, total_rows - text_rows)
    if self.scroll_y > max_scroll then
        self.scroll_y = max_scroll
    end
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
    self.scroll_y = self.scroll_y + delta
    local total_rows = self:total_screen_rows()
    local max_scroll = math.max(0, total_rows - text_rows)
    if self.scroll_y < 0 then
        self.scroll_y = 0
    elseif self.scroll_y > max_scroll then
        self.scroll_y = max_scroll
    end
end

--- Page the viewport (no cursor movement). `page_size` is the number of
--- screen rows in a page (≈ visible text rows).keeps the caret's
--- logical position; only the viewport shifts.
---@param n integer signed page count (negative = toward start)
---@param page_size integer screen rows per page
function View:scroll_page(n, page_size)
    self:scroll_viewport(n * page_size, page_size)
end

--- Recenter the view so the cursor line is at the given position.
--- Cycles through: middle → top → bottom.
---@param height integer terminal height in rows
function View:recenter(height)
    local c = self:p()
    local text_rows = height - 1
    local cursor_screen = self:line_to_screen_row(c.line)
        + select(1, self:wrap_sub_position(c.line, c.col))

    local state = self._recenter_state
    if state == 0 then
        -- Middle
        self.scroll_y = cursor_screen - math.floor(text_rows / 2)
    elseif state == 1 then
        -- Top
        self.scroll_y = cursor_screen
    else
        -- Bottom
        self.scroll_y = cursor_screen - (text_rows - 1)
    end

    self._recenter_state = (state + 1) % 3

    -- Clamp
    local total_rows = self:total_screen_rows()
    local max_scroll = math.max(0, total_rows - text_rows)
    if self.scroll_y < 0 then
        self.scroll_y = 0
    elseif self.scroll_y > max_scroll then
        self.scroll_y = max_scroll
    end
end

----------------------------------------------------------------------------------------------------
-- Undo/Redo (clamp cursor after applying)
----------------------------------------------------------------------------------------------------

function View:undo()
    if not self.buffer:undo() then
        return false
    end
    self:clamp_cursor()
    -- Undo swaps buffer content wholesale; the cached spans (and the
    -- lane's retained old_tree) describe pre-undo text. Cold-requery
    -- the viewport so post-undo render shows correct syntax.
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
    self:clamp_cursor()
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
        c.goal_col = c.col
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
