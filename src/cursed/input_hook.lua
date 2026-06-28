--- Input hooks: declarative "match a Lua pattern as a SUFFIX of the text
-- left of the cursor; when the user finishes typing it (or hits Return,
-- depending on the hook's trigger), run this function".
--
-- A major mode declares `input_hooks` (a list of hook specs). Most
-- modes build them with the higher-order builders in this module:
--
--   * `IH.opener(pattern, closer, opts)`  — auto-insert a closer the
--     moment the opener is typed (printable trigger). For
--     `opts.block=true` it ALSO fires on Return (auto-split into two
--     hook entries: one per trigger) so `function f() <RET>` pre-places
--     the `end`; a non-block opener fires on printable only.
--   * `IH.closer(pattern, opts)`          — on Return, snap the line's
--     indent one unit LESS (to the structural opener level) using the
--     tree-sitter `@indent` query, and start the new line at that
--     dedented indent. Declines (no-op) when no parse tree is available.
--   * `IH.hook(pattern, trigger, fn, opts)` — the generic escape hatch
--     for major modes that want arbitrary input-hook behaviour.
--
-- Hook contract (the value of `fn`):
--   fn(view, cursors) -> handled_cursors
--   `cursors` is the list of cursors (in document order) whose left-of-
--   cursor text matched THIS hook (first-match-wins per cursor, last
--   mode wins cross-mode, last-declared wins within a mode). `fn` runs
--   its OWN `batch_edit` (multi-cursor coordination is preserved within
--   one hook's batch) and returns the subset of `cursors` it actually
--   edited; the rest fall through to the trigger site's default
--   behaviour (carry-indent newline for the `return` trigger; nothing
--   for the `printable` trigger). Fns are free to call back into View
--   methods (`view:batch_edit(...)`, `view:hl_tree()`, `view:_indent_query()`)
--   — this module never requires cursed.view, so there's no cycle.
--
-- Triggers differ ONLY in how the trigger site prepares `left` for
-- matching (the suffix the pattern is matched against):
--   "printable": left = line_text(c.line):sub(1, c.col)              (raw)
--   "return":    left = line_text(c.line):sub(1, c.col):gsub("%s+$","") (ws-stripped)
-- The strip lets `function f() <RET>` (trailing space) still complete a
-- block opener whose pattern is `function%s*[^%s]*%([^%)]*%)$`.
--
-- The block-opener autocompletion machinery in here (block_text /
-- body_target_indent / fixup_body_indent / enclosing_indent_depth) and
-- the closer-dedent machinery (closer_target_indent) were lifted out of
-- View; they take `view` and consult its tree-sitter state via the
-- View methods that remained on View (`_indent_query`, `hl_tree`).

local M = {}

----------------------------------------------------------------------------------------------------
-- Shared low-level helpers (small; duplicated from view.lua to keep
-- input_hook free of a require cycle on cursed.view)
----------------------------------------------------------------------------------------------------

--- One unit of indentation: tab, or `indent_width` spaces when expand_tab.
local function indent_unit(view)
    if view.expand_tab then
        return string.rep(" ", view.indent_width)
    end
    return "\t"
end

--- Absolute byte offset of (line, col) in the buffer (line_len sums
--- include the trailing newline, matching the tree's byte space).
local function cursor_byte_offset(buf, c)
    local off = c.col
    for i = 0, c.line - 1 do
        off = off + buf:line_len(i)
    end
    return off
end

--- Match `pat` as a SUFFIX (ending exactly at the cursor) of `left`.
-- With `spec.word=true`, additionally require a leading word boundary
-- (BOL or a non-`[%w_]` char) so `append`/`send`/`bend` don't fire
-- `end`. Returns the matched string + its 1-based start byte, or nil.
---@param left string text left of the cursor (bytes [1, c.col])
---@param spec table {pattern=string, word?=boolean}
---@return string|nil, integer|nil
function M.match_suffix(left, spec)
    local pat = spec.pattern
    if pat == nil or #left == 0 then
        return nil
    end
    local s, e = string.find(left, pat, 1)
    while s do
        if e == #left then
            if spec.word then
                if s == 1 then
                    return left:sub(s, e), s
                end
                local prev = left:sub(s - 1, s - 1)
                if not prev:match("[%w_]") then
                    return left:sub(s, e), s
                end
            else
                return left:sub(s, e), s
            end
        end
        s, e = string.find(left, pat, e + 1)
    end
    return nil
end

----------------------------------------------------------------------------------------------------
-- Tree-sitter structural indent (used by opener body fixup + closer dedent)
----------------------------------------------------------------------------------------------------

--- Count `@indent`-captured nodes (per the active mode's `indent_queries`)
--- whose line range contains the cursor's line. Returns nil when no
--- parse tree / `@indent` query is available; callers treat nil as "no
--- structural answer — fall back". Drives the closer-dedent target
--- (depth - 1 = opener level) and the electric-opener body target
--- (depth = body indent, queried AFTER the block text lands so the
--- opener is a real `@indent` node).
---@param view View
---@param c Cursor
---@return integer|nil depth
local function enclosing_indent_depth(view, c)
    local query = view:_indent_query()
    if query == nil then
        return nil
    end
    local tree = view:hl_tree()
    if tree == nil then
        return nil
    end
    local ts = require("cursed.ts")
    local root = tree:root()
    if ts.node_is_null(root) then
        return nil
    end
    local cursor, _cerr = ts.QueryCursor.new()
    if not cursor then
        return nil
    end
    local byte = cursor_byte_offset(view.buffer, c)
    cursor:set_byte_range(0, byte + 1)
    cursor:exec(query, root)
    local depth = 0
    for match in cursor:matches() do
        for _, cap in ipairs(match.captures) do
            if cap.name == "indent" then
                local srow, _scol, erow = ts.node_point_range(cap.node)
                if srow ~= nil and srow <= c.line and c.line <= erow then
                    depth = depth + 1
                end
            end
        end
    end
    return depth
end

--- Structural target indent for a closer at the cursor = (depth - 1)
--- indent units, floored at 0. Returns nil when no tree/query is
--- available (callers treat nil as "don't dedent").
---@param view View
---@param c Cursor
---@return string|nil
local function closer_target_indent(view, c)
    local depth = enclosing_indent_depth(view, c)
    if depth == nil then
        return nil
    end
    local units = depth - 1
    if units < 0 then
        units = 0
    end
    return string.rep(indent_unit(view), units)
end

--- Structural target indent for the BODY line of a just-opened electric
--- block = depth of `@indent` blocks whose line range contains the body
--- line, where the depth already counts the just-opened block. MUST be
--- queried AFTER the block text (opener + empty body + closer) is
--- inserted (before, the opener is just an ERROR node and the depth is
--- wrong). Returns nil when no tree/query is available.
---@param view View
---@param c Cursor cursor on the body line (post-insertion)
---@return string|nil
local function body_target_indent(view, c)
    local depth = enclosing_indent_depth(view, c)
    if depth == nil then
        return nil
    end
    return string.rep(indent_unit(view), depth)
end

----------------------------------------------------------------------------------------------------
-- Opener (block + non-block) machinery
----------------------------------------------------------------------------------------------------

--- Compute the opener-line indent, body indent, and block-completion
--- text for a cursor where a block opener just matched. `text` is the
--- string to insert at the cursor: `\n<body_ind>\n<opener_ind><closer>`.
---@param view View
---@param c Cursor
---@param closer string
---@return string body_ind, string opener_ind, string text
local function block_text(view, c, closer)
    local unit = indent_unit(view)
    local line = view.buffer:line_text(c.line)
    local ind = line:match("^([ \t]*)") or ""
    if view.expand_tab then
        ind = ind:gsub("\t", string.rep(" ", view.tab_width))
    end
    local body_ind = ind .. unit
    local text = "\n" .. body_ind .. "\n" .. ind .. closer
    return body_ind, ind, text
end

--- Snap just-inserted electric block-opener body lines from their
--- provisional `opener_indent + one unit` indent to the tree-sitter
--- structural target. The freshly-typed opener only becomes a real
--- `@indent` node once its closer is present, so this MUST run AFTER
--- the block text's `batch_edit` (which inserts opener+empty-body+
--- closer and sync-parses). `block_body` maps each block-opener cursor
--- to its provisional body indent string. All targets are computed from
--- the current (post-insertion) tree BEFORE any fixup edit lands, so a
--- multi-cursor pass isn't invalidated by an earlier cursor's fixup in
--- the same batch. Noop when empty.
---@param view View
---@param block_body table<Cursor,string>
local function fixup_body_indent(view, block_body)
    if next(block_body) == nil then
        return
    end
    local buf = view.buffer
    local targets = {}
    for c, provisional in pairs(block_body) do
        local target = body_target_indent(view, c)
        if target ~= nil and target ~= provisional then
            targets[c] = target
        end
    end
    if next(targets) == nil then
        return
    end
    view:batch_edit(false, function(c)
        local provisional = block_body[c]
        local target = targets[c]
        if target == nil then
            return c.line, c.col, c.line, c.col, "insert"
        end
        local sl, sc = c.line, 0
        local el, ec = c.line, #provisional
        buf:delete_char(sl, sc, ec)
        local rl, rc = buf:insert_char(sl, sc, target)
        return sl, sc, rl, rc, "replace", el, ec
    end)
end

--- Insert the block-completion text (`\n<body_ind>\n<opener_ind><closer>`)
--- at each cursor, relocate to the body line, then tree-sitter-fix the
--- provisional body indent. The shared `fn` of a block opener hook
--- (used by BOTH the printable and return triggers; they differ only
--- in when match scoring happens + how `left` is prepared, not in what
--- the fn does). Returns the cursors it actually edited (all of them —
--- block completion always handles its matched cursors).
---@param closer string
---@return function fn
local function make_block_opener_fn(closer)
    return function(view, cursors)
        if #cursors == 0 then
            return {}
        end
        local buf = view.buffer
        local block_body = {}
        view:batch_edit(false, function(c)
            local body_ind, _ind, text = block_text(view, c, closer)
            block_body[c] = body_ind
            local sl, sc = c.line, c.col
            local rl, rc = buf:insert_char(c.line, c.col, text)
            return sl, sc, rl, rc, "insert_relocate", c.line + 1, #body_ind
        end)
        fixup_body_indent(view, block_body)
        local handled = {}
        for _, c in ipairs(cursors) do
            handled[#handled + 1] = c
        end
        return handled
    end
end

--- Insert `closer` right after the cursor; cursor stays between (`(|)`).
--- The shared `fn` of a non-block (bracket) opener hook. Only ever
--- attached to the `printable` trigger.
---@param closer string
---@return function fn
local function make_opener_fn(closer)
    return function(view, cursors)
        if #cursors == 0 then
            return {}
        end
        local buf = view.buffer
        view:batch_edit(false, function(c)
            local sl, sc = c.line, c.col
            local rl, rc = buf:insert_char(c.line, c.col, closer)
            return sl, sc, rl, rc, "insert_relocate", c.line, c.col
        end)
        local handled = {}
        for _, c in ipairs(cursors) do
            handled[#handled + 1] = c
        end
        return handled
    end
end

----------------------------------------------------------------------------------------------------
-- Closer (Return-trigger dedent) machinery
----------------------------------------------------------------------------------------------------

--- On Return, for each matched cursor: if the structural target
--- indent (opener level) is available AND the current line indent
--- exceeds it, snap THIS line's leading indent to the target and
--- create the new line at that same dedented indent, all as one
--- "replace" over region [0, cursor). Cursors where no tree is
--- available, or whose indent is already <= the target, are DECLINED
--- (fall through to the default carry-indent newline).
---@return function fn
local function make_closer_fn()
    return function(view, cursors)
        if #cursors == 0 then
            return {}
        end
        local buf = view.buffer
        local to_handle = {}
        local targets = {}
        for _, c in ipairs(cursors) do
            local target = closer_target_indent(view, c)
            if target ~= nil then
                local line = buf:line_text(c.line)
                local raw_indent = line:match("^([ \t]*)") or ""
                local cur_indent = raw_indent
                if view.expand_tab then
                    cur_indent = cur_indent:gsub("\t", string.rep(" ", view.tab_width))
                end
                if #cur_indent > #target then
                    to_handle[#to_handle + 1] = c
                    targets[c] = target
                end
            end
        end
        if #to_handle == 0 then
            return {}
        end
        view:batch_edit(false, function(c)
            local target = targets[c]
            local line = buf:line_text(c.line)
            local raw_indent = line:match("^([ \t]*)") or ""
            local content = line:sub(#raw_indent + 1, c.col)
            local replacement = target .. content .. "\n" .. target
            local sl, sc = c.line, 0
            local el, ec = c.line, c.col
            buf:delete_char(sl, sc, ec)
            local rl, rc = buf:insert_char(sl, sc, replacement)
            return sl, sc, rl, rc, "replace", el, ec
        end)
        return to_handle
    end
end

----------------------------------------------------------------------------------------------------
-- Builders
---------------------------------------------------------------------------------------------------

--- Generic hook: match `pattern` as a suffix of the left-of-cursor
--- text on `trigger` ("printable" or "return"); on match run `fn(view,
--- cursors) -> handled_cursors` for the matched cursors. `opts.word =
--- true` enforces a leading word boundary on the match. The bare escape
--- hatch underlying `opener` / `closer`.
---@param pattern string
---@param trigger "printable" | "return"
---@param fn function fn(view, cursors) -> handled_cursors
---@param opts table? { word?: boolean }
---@return table hook
function M.hook(pattern, trigger, fn, opts)
    opts = opts or {}
    return {
        pattern = pattern,
        word = opts.word,
        trigger = trigger,
        fn = fn,
    }
end

--- Opener hook. After the user types text ending in `pattern`, the
--- `closer` is auto-inserted. Non-block: closer goes right after the
--- cursor (`(|)`) on the printable trigger. Block (`opts.block=true`):
--- inserts `\n<opener-indent><indent_unit>\n<opener-indent><closer>`,
--- relocates to the body line, and tree-sitter-fixes the body indent;
--- fires on the printable trigger AND the return trigger (so
--- `function f() <RET>` pre-places `end`). `word=true` enforces a
--- leading word boundary so `append`/`send`/`bend` don't trigger `end`.
---
--- For block openers this builder returns a MULTI-entry spec the loader
--- splices into two hook entries (one per trigger); they share the same
--- fn since what they DO is identical — only WHEN they fire differs.
---@param pattern string
---@param closer string
---@param opts table? { block?: boolean, word?: boolean }
---@return table hook (or { _multi=true, hooks={...} } for block openers)
function M.opener(pattern, closer, opts)
    opts = opts or {}
    if opts.block then
        local fn = make_block_opener_fn(closer)
        local printable_hook = {
            pattern = pattern,
            closer = closer,
            word = opts.word,
            trigger = "printable",
            fn = fn,
        }
        local return_hook = {
            pattern = pattern,
            closer = closer,
            word = opts.word,
            trigger = "return",
            fn = fn,
        }
        return { _multi = true, hooks = { printable_hook, return_hook } }
    end
    local fn = make_opener_fn(closer)
    return {
        pattern = pattern,
        closer = closer,
        word = opts.word,
        trigger = "printable",
        fn = fn,
    }
end

--- Closer dedent hook. On Return, if the line's trailing text matches
--- `pattern`, snap that line's indent one unit LESS (to the structural
--- opener level via the tree-sitter `@indent` query) and create the new
--- line at that dedented indent. Declines (no-op, defers to the default
--- carry-indent newline) when no parse tree is available or the line is
--- not over-indented. `word=true` enforces a leading word boundary.
---@param pattern string
---@param opts table? { word?: boolean }
---@return table hook
function M.closer(pattern, opts)
    opts = opts or {}
    return {
        pattern = pattern,
        word = opts.word,
        trigger = "return",
        fn = make_closer_fn(),
    }
end

return M
