--- High-level tree-sitter bindings with RAII memory management via ffi.gc.
---
--- Usage:
---   local ts = require("cursed.ts")
---
---   local lua_lang = ts.lang.lua()
---   local parser = ts.Parser.new(lua_lang)
---   local tree = parser:parse_string("local x = 1 + 2")
---   local root = tree:root()
---   print(ts.node_type(root))  -- "chunk"
---
---   -- GC handles all cleanup automatically.
---
--- Incremental re-parse:
---   tree:edit({
---       start_byte = 0, old_end_byte = 0, new_end_byte = 4,
---       start_point = { row = 0, column = 0 },
---       old_end_point = { row = 0, column = 0 },
---       new_end_point = { row = 0, column = 4 },
---   })
---   local new_tree = parser:parse_string("locax = 1", tree)
---
--- Query:
---   local query = ts.Query.new(lua_lang, "(variable_declaration) @decl")
---   local cursor = ts.QueryCursor.new()
---   cursor:exec(query, new_tree:root())
---   for match in cursor:matches() do
---       for _, capture in ipairs(match.captures) do
---           print(capture.name, ts.node_type(capture.node))
---       end
---   end

local ffi = require("ffi")
local c_api = require("cursed.treesitter_ffi")
local gc = require("cursed.gc")

----------------------------------------------------------------------------------------------------
-- Record definitions (all defined first to allow forward references)
----------------------------------------------------------------------------------------------------

---@class Point
---@field row integer
---@field column integer

---@class Edit
---@field start_byte integer
---@field old_end_byte integer
---@field new_end_byte integer
---@field start_point Point
---@field old_end_point Point
---@field new_end_point Point

---@class Capture
---@field name string
---@field node any

---@class Match
---@field id integer
---@field pattern_index integer
---@field captures Capture[]

---@class Tree
---@field ptr any
local Tree = {}
Tree.__index = Tree

---@class Parser
---@field ptr any
local Parser = {}
Parser.__index = Parser

---@class Query
---@field ptr any
local Query = {}
Query.__index = Query

---@class QueryCursor
---@field ptr any
---@field bound_query Query
local QueryCursor = {}
QueryCursor.__index = QueryCursor

----------------------------------------------------------------------------------------------------
-- Language accessors
----------------------------------------------------------------------------------------------------

local lang = {
    bash = c_api.tree_sitter_bash,
    c = c_api.tree_sitter_c,
    go = c_api.tree_sitter_go,
    json = c_api.tree_sitter_json,
    lua = c_api.tree_sitter_lua,
    markdown = c_api.tree_sitter_markdown,
    markdown_inline = c_api.tree_sitter_markdown_inline,
    python = c_api.tree_sitter_python,
    rust = c_api.tree_sitter_rust,
    toml = c_api.tree_sitter_toml,
    yaml = c_api.tree_sitter_yaml,
}

local function lang_get(name)
    local fn = lang[name]
    if fn == nil then
        return nil, ("cursed.ts: unknown language %q"):format(name)
    end
    local ptr = fn()
    if ptr == nil then
        return nil, ("cursed.ts: language %q returned nil"):format(name)
    end
    return ptr
end

----------------------------------------------------------------------------------------------------
-- Parser
----------------------------------------------------------------------------------------------------

--- Create a new parser with the given language.
---@param language any TSLanguage pointer
---@return Parser|nil
---@return string|nil errmsg
function Parser.new(language)
    local ptr = c_api.ts_parser_new()
    if ptr == nil then
        return nil, "cursed.ts: failed to allocate TSParser"
    end
    if not c_api.ts_parser_set_language(ptr, language) then
        c_api.ts_parser_delete(ptr)
        return nil, "cursed.ts: incompatible language ABI version"
    end
    return setmetatable({ ptr = gc.wrap_gc(ptr, c_api.ts_parser_delete) }, Parser), nil
end

--- Parse a string, optionally using an old tree for incremental parsing.
---@param text string
---@param old_tree Tree? Previous tree for incremental parsing
---@return Tree|nil
---@return string|nil errmsg
function Parser:parse_string(text, old_tree)
    local old_ptr = old_tree and old_tree.ptr or nil
    local tree_ptr = c_api.ts_parser_parse_string(self.ptr, old_ptr, text, #text)
    if tree_ptr == nil then
        return nil, "cursed.ts: parse failed (no language set?)"
    end
    return Tree.new(tree_ptr), nil
end

--- Parse a C buffer (cdata pointer + byte length), optionally using an
--- old tree for incremental parsing. Used by the highlight lane, which
--- receives a malloc'd text snapshot via the ring (a Lua string would
--- be copied; the cdata path lets tree-sitter read the buffer in place).
---@param ptr any cdata pointer to the bytes (char*, uint8_t*, void*)
---@param len integer byte length
---@param old_tree Tree? Previous tree for incremental parsing
---@return Tree|nil
---@return string|nil errmsg
function Parser:parse_string_ptr(ptr, len, old_tree)
    local old_ptr = old_tree and old_tree.ptr or nil
    local tree_ptr = c_api.ts_parser_parse_string(self.ptr, old_ptr, ptr, len)
    if tree_ptr == nil then
        return nil, "cursed.ts: parse failed (no language set?)"
    end
    return Tree.new(tree_ptr), nil
end

--- Parse using a custom input callback.
---@param read_fn function
---@param payload any
---@param old_tree Tree? Previous tree for incremental parsing
---@return Tree|nil
---@return string|nil errmsg
function Parser:parse_input(read_fn, payload, old_tree)
    local old_ptr = old_tree and old_tree.ptr or nil
    local input = ffi.new("TSInput")
    input.payload = payload
    input.read = read_fn
    input.encoding = 0 -- TSInputEncodingUTF8
    input.decode = nil
    local tree_ptr = c_api.ts_parser_parse(self.ptr, old_ptr, input)
    if tree_ptr == nil then
        return nil, "cursed.ts: parse_input failed"
    end
    return Tree.new(tree_ptr), nil
end

--- Reset the parser state.
function Parser:reset()
    c_api.ts_parser_reset(self.ptr)
end

--- Restrict subsequent parses to the given byte ranges. Used by the
--- markdown split-parser: after the block parse marks `inline` node
--- ranges, we set them here on the inline parser so its parse only
--- touches inline content (and matches per-range, not the whole doc).
--- Passing nil/empty restores full-document parsing.
--- Each range is { start_byte, end_byte }; we build a TSRange[] cdata
--- array (point field is required by tree-sitter but the inline parser
--- ignores it for matching — start/end byte drive the ranges).
---@param ranges table<integer, {start_byte:integer, end_byte:integer}>|nil
function Parser:set_included_ranges(ranges)
    if ranges == nil or #ranges == 0 then
        -- An empty array isn't valid; tree-sitter treats "no ranges" as
        -- "parse the whole document", which is what nil means here. Use
        -- the documented reset path: set with count=0.
        c_api.ts_parser_set_included_ranges(self.ptr, nil, 0)
        return
    end
    local arr = ffi.new("TSRange[?]", #ranges)
    for i, r in ipairs(ranges) do
        arr[i - 1].start_point.row = 0
        arr[i - 1].start_point.column = 0
        arr[i - 1].end_point.row = 0
        arr[i - 1].end_point.column = 0
        arr[i - 1].start_byte = r.start_byte
        arr[i - 1].end_byte = r.end_byte
    end
    c_api.ts_parser_set_included_ranges(self.ptr, arr, #ranges)
end

----------------------------------------------------------------------------------------------------
-- Tree
----------------------------------------------------------------------------------------------------

--- Create a Tree wrapper around an FFI tree pointer.
---@param ptr any TSTree pointer (ownership transferred)
---@return Tree
function Tree.new(ptr)
    return setmetatable({ ptr = gc.wrap_gc(ptr, c_api.ts_tree_delete) }, Tree)
end

--- Get the root node of the tree.
---@return any TSNode
function Tree:root()
    return c_api.ts_tree_root_node(self.ptr)
end

--- Apply an edit to the tree for incremental parsing.
---@param edit Edit
function Tree:edit(edit)
    local c_edit = ffi.new("TSInputEdit")
    c_edit.start_byte = edit.start_byte
    c_edit.old_end_byte = edit.old_end_byte
    c_edit.new_end_byte = edit.new_end_byte
    c_edit.start_point.row = edit.start_point.row
    c_edit.start_point.column = edit.start_point.column
    c_edit.old_end_point.row = edit.old_end_point.row
    c_edit.old_end_point.column = edit.old_end_point.column
    c_edit.new_end_point.row = edit.new_end_point.row
    c_edit.new_end_point.column = edit.new_end_point.column
    c_api.ts_tree_edit(self.ptr, c_edit)
end

--- Get the ranges that changed between this tree and an old tree.
---@param old_tree Tree
---@return any, integer
function Tree:get_changed_ranges(old_tree)
    local count_arr = ffi.new("uint32_t[1]")
    local ranges = c_api.ts_tree_get_changed_ranges(old_tree.ptr, self.ptr, count_arr)
    return ranges, count_arr[0]
end

----------------------------------------------------------------------------------------------------
-- Node helpers
----------------------------------------------------------------------------------------------------

local function node_is_null(node)
    return c_api.ts_node_is_null(node)
end

local function node_type(node)
    return ffi.string(c_api.ts_node_type(node))
end

local function node_byte_range(node)
    return tonumber(c_api.ts_node_start_byte(node)), tonumber(c_api.ts_node_end_byte(node))
end

local function node_eq(a, b)
    return c_api.ts_node_eq(a, b)
end

local function node_point_range(node)
    local sp = c_api.ts_node_start_point(node)
    local ep = c_api.ts_node_end_point(node)
    return sp.row, sp.column, ep.row, ep.column
end

local function node_named_child(node, idx)
    return c_api.ts_node_named_child(node, idx)
end

local function node_named_child_count(node)
    return tonumber(c_api.ts_node_named_child_count(node))
end

local function node_parent(node)
    return c_api.ts_node_parent(node)
end

local function node_descendant_for_byte_range(node, start_byte, end_byte)
    return c_api.ts_node_descendant_for_byte_range(node, start_byte, end_byte)
end

local function node_string(node)
    local s = c_api.ts_node_string(node)
    local str = ffi.string(s)
    c_api.free(s)
    return str
end

----------------------------------------------------------------------------------------------------
-- Query
----------------------------------------------------------------------------------------------------

--- Create a new query from a source string.
---@param language any TSLanguage pointer
---@param source string Query source
---@return Query|nil
---@return string|nil errmsg
function Query.new(language, source)
    local err_offset = ffi.new("uint32_t[1]")
    local err_type = ffi.new("TSQueryError[1]")
    local ptr = c_api.ts_query_new(language, source, #source, err_offset, err_type)
    if ptr == nil then
        -- err_offset[0]/err_type[0] are cdata (uint32_t/enum); tonumber()
        -- them — LuaJIT's string.format %d does not auto-convert cdata
        -- ("number expected, got cdata"), which would mask the real error.
        return nil,
            ("cursed.ts: query error at byte %d (type %d)"):format(
                tonumber(err_offset[0]),
                tonumber(err_type[0])
            )
    end
    return setmetatable({ ptr = gc.wrap_gc(ptr, c_api.ts_query_delete) }, Query), nil
end

--- Get the name of a capture by index.
---@param index integer
---@return string
function Query:capture_name(index)
    local len = ffi.new("uint32_t[1]")
    local name = c_api.ts_query_capture_name_for_id(self.ptr, index, len)
    return ffi.string(name, len[0])
end

--- Get the number of patterns in the query.
---@return integer
function Query:pattern_count()
    local v = tonumber(c_api.ts_query_pattern_count(self.ptr))
    ---@cast v integer
    return v
end

--- Get a query string constant by id (predicate operator names +
--- string-literal arguments).
---@param id integer
---@return string
function Query:string_value(id)
    local len = ffi.new("uint32_t[1]")
    local s = c_api.ts_query_string_value_for_id(self.ptr, id, len)
    return ffi.string(s, len[0])
end

--- Cache of parsed predicate steps per pattern index. Each entry is a
--- list of predicates, where each predicate is { op = string, args = step[] }
--- and each step is { type = "capture"|"string", value = string }.
--- `nil` means "no predicates for this pattern" (the common case).
---@type table<integer, table[]|nil>

--- Get the parsed predicate steps for a pattern, with caching. Returns
--- a list of {op = string, args = {step}} (one per predicate in the
--- pattern), or nil if the pattern has no predicates. Each step is
--- {type="capture", capture_index=i, name=s} (value_id is a CAPTURE INDEX
--- for capture steps — a different id space from string ids) or
--- {type="string", value=s}.
---@param pattern_index integer
---@return table[]|nil
function Query:predicates_for_pattern(pattern_index)
    if self._pred_cache == nil then
        self._pred_cache = {}
    end
    local cached = self._pred_cache[pattern_index]
    if cached ~= nil then
        return cached
    end
    local step_count = ffi.new("uint32_t[1]")
    local steps = c_api.ts_query_predicates_for_pattern(self.ptr, pattern_index, step_count)
    local n = tonumber(step_count[0])
    if n == 0 then
        self._pred_cache[pattern_index] = false
        return nil
    end
    ---@cast n integer
    local predicates = {}
    local i = 0
    while i < n do
        local op_step = steps[i]
        if op_step.type == c_api.TSQueryPredicateStepTypeDone then
            i = i + 1
        else
            local op = self:string_value(op_step.value_id)
            i = i + 1
            local args = {}
            while i < n and steps[i].type ~= c_api.TSQueryPredicateStepTypeDone do
                local st = steps[i]
                if st.type == c_api.TSQueryPredicateStepTypeCapture then
                    args[#args + 1] = {
                        type = "capture",
                        capture_index = st.value_id,
                        name = self:capture_name(st.value_id),
                    }
                else
                    args[#args + 1] = { type = "string", value = self:string_value(st.value_id) }
                end
                i = i + 1
            end
            i = i + 1 -- skip Done
            predicates[#predicates + 1] = { op = op, args = args }
        end
    end
    if #predicates == 0 then
        self._pred_cache[pattern_index] = false
        return nil
    end
    self._pred_cache[pattern_index] = predicates
    return predicates
end

----------------------------------------------------------------------------------------------------
-- QueryCursor
----------------------------------------------------------------------------------------------------

--- Create a new query cursor.
---@return QueryCursor|nil
---@return string|nil errmsg
function QueryCursor.new()
    local ptr = c_api.ts_query_cursor_new()
    if ptr == nil then
        return nil, "cursed.ts: failed to allocate TSQueryCursor"
    end
    return setmetatable(
        { ptr = gc.wrap_gc(ptr, c_api.ts_query_cursor_delete), bound_query = nil },
        QueryCursor
    ),
        nil
end

--- Execute a query on a node.
---@param q Query
---@param node any TSNode
function QueryCursor:exec(q, node)
    self.bound_query = q
    c_api.ts_query_cursor_exec(self.ptr, q.ptr, node)
end

--- Set the byte range for the cursor.
---@param start_byte integer
---@param end_byte integer
function QueryCursor:set_byte_range(start_byte, end_byte)
    c_api.ts_query_cursor_set_byte_range(self.ptr, start_byte, end_byte)
end

--- Return an iterator over matches.
--- Each match's captures carry {name, node, index} where `index` is the
--- capture index (needed by predicate resolution to find which captures
--- a predicate arg refers to).
---@return function
function QueryCursor:matches()
    local cursor_ptr = self.ptr
    local match = ffi.new("TSQueryMatch")
    return function()
        if c_api.ts_query_cursor_next_match(cursor_ptr, match) then
            local captures = {}
            for i = 0, match.capture_count - 1 do
                local cap = match.captures[i]
                local cap_idx = cap.index
                local cap_name = self.bound_query:capture_name(cap_idx)
                local cap_node = cap.node
                captures[i + 1] = { name = cap_name, node = cap_node, index = cap_idx }
            end
            return {
                id = match.id,
                pattern_index = match.pattern_index,
                captures = captures,
            }
        end
        return nil
    end
end

--- Return an iterator over individual captures, ordered by start byte
--- (ties broken by pattern index). Each iteration yields:
---   { name = string, node = TSNode, start_byte = integer, end_byte = integer }
--- This is the iteration order the tree-sitter highlighter stack algorithm
--- relies on to resolve overlapping captures (later-emitted wins).
---@return function
function QueryCursor:captures()
    local cursor_ptr = self.ptr
    local match = ffi.new("TSQueryMatch")
    local cap_index = ffi.new("uint32_t[1]")
    return function()
        if not c_api.ts_query_cursor_next_capture(cursor_ptr, match, cap_index) then
            return nil
        end
        local i = cap_index[0]
        local cap = match.captures[i]
        local cap_name = self.bound_query:capture_name(cap.index)
        local cap_node = cap.node
        return {
            name = cap_name,
            node = cap_node,
            start_byte = tonumber(c_api.ts_node_start_byte(cap_node)),
            end_byte = tonumber(c_api.ts_node_end_byte(cap_node)),
        }
    end
end

----------------------------------------------------------------------------------------------------
-- Predicate evaluation
--
-- The tree-sitter C library parses predicate syntax but does NOT execute
-- predicates (#eq?, #match?, #set!, ...). Editors implement their own
-- interpreter over the exposed TSQueryPredicateStep arrays. This is it.
--
-- We support the predicates nvim/helix ship for highlighting + injections:
--   #eq? cap cap|str ...   all args' text equal
--   #not-eq? ...           negation of eq?
--   #match? cap pattern    Lua-pattern match (unanchored)
--   #not-match? ...        negation of match?
--   #any-of? cap str...    capture text equals any of the strings
--   #not-any-of? ...        negation
--   #set! key value...      directive: set property `key` to value (injection.language, etc.)
--   #set-local! ...         treated like #set! (same scope for our use)
--   #is? / #not-is?         module-level named predicates; none configured
--                          → #is? returns true, #not-is? returns false
--
-- A match whose predicates fail is dropped (its captures are not emitted).
-- #set! directives are collected alongside #eq?/#match? evaluation: a
-- match can both be filtered in AND carry property directives.
----------------------------------------------------------------------------------------------------

--- Resolve a predicate argument (capture or string) to its text. For a
--- capture arg, finds ALL captures in `captures` whose `.index` equals
--- the arg's `capture_index` (a repeated @capture yields several) and
--- joins their text with a newline (matching nvim's convention).
---@param captures table[] the match's captures ({name, node, index})
---@param arg table {type="capture"|"string", ...}
---@param get_text_fn function(int,int)->string grabs source bytes for a capture node
---@return string
local function resolve_arg(captures, arg, get_text_fn)
    if arg.type == "string" then
        return arg.value
    end
    -- Collect text of all captures matching the index; join with "\n".
    local texts = {}
    for _, c in ipairs(captures) do
        if c.index == arg.capture_index then
            local sb = tonumber(c_api.ts_node_start_byte(c.node))
            local eb = tonumber(c_api.ts_node_end_byte(c.node))
            if eb > sb then
                texts[#texts + 1] = get_text_fn(sb, eb)
            end
        end
    end
    return table.concat(texts, "\n")
end

--- Evaluate a single predicate against a match's captures.
--- Returns (ok, directive). `directive` is {key=value} for #set!, nil for
--- filter predicates.
---@param pred table {op=string, args=step[]}
---@param captures table[] match captures
---@param get_text_fn function(int,int)->string
---@return boolean ok
---@return table|nil directive {key=value} for #set!, nil otherwise
local function eval_predicate(pred, captures, get_text_fn)
    local op = pred.op
    local args = pred.args
    if op == "set!" or op == "set-local!" then
        -- #set! key value...  → directive { [key] = value }
        local key = args[1]
        if key == nil or key.type ~= "string" then
            return true, nil
        end
        local value_parts = {}
        for i = 2, #args do
            value_parts[#value_parts + 1] = resolve_arg(captures, args[i], get_text_fn)
        end
        local value = table.concat(value_parts, "\n")
        return true, { [key.value] = value }
    elseif op == "is?" then
        return true, nil
    elseif op == "not-is?" then
        return false, nil
    end
    -- Filter predicates below.
    if #args < 2 then
        return true, nil
    end
    local first = resolve_arg(captures, args[1], get_text_fn)
    if op == "eq?" then
        for i = 2, #args do
            if first ~= resolve_arg(captures, args[i], get_text_fn) then
                return false, nil
            end
        end
        return true, nil
    elseif op == "not-eq?" then
        for i = 2, #args do
            if first == resolve_arg(captures, args[i], get_text_fn) then
                return false, nil
            end
        end
        return true, nil
    elseif op == "match?" then
        local pat = args[2].value
        local ok = pcall(function()
            return string.find(first, pat, 1, false) ~= nil
        end)
        return ok, nil
    elseif op == "not-match?" then
        local pat = args[2].value
        local ok = pcall(function()
            return string.find(first, pat, 1, false) == nil
        end)
        return ok, nil
    elseif op == "any-of?" then
        for i = 2, #args do
            if first == resolve_arg(captures, args[i], get_text_fn) then
                return true, nil
            end
        end
        return false, nil
    elseif op == "not-any-of?" then
        for i = 2, #args do
            if first == resolve_arg(captures, args[i], get_text_fn) then
                return false, nil
            end
        end
        return true, nil
    end
    -- Unknown predicate: be permissive (don't drop matches we don't
    -- understand). Log nothing here; the lane can warn if needed.
    return true, nil
end

--- Evaluate all predicates for a match's pattern index. Returns
--- (ok, directives) where ok=false drops the match, and `directives`
--- is the merged {key=value} table from all #set!/#set-local! predicates
--- (or nil if there were none).
---@param query Query
---@param pattern_index integer
---@param captures table[] match captures
---@param get_text_fn function(int,int)->string
---@return boolean ok
---@return table|nil directives
local function eval_match_predicates(query, pattern_index, captures, get_text_fn)
    local preds = query:predicates_for_pattern(pattern_index)
    if not preds then
        return true, nil
    end
    local directives = nil
    for _, pred in ipairs(preds) do
        local ok, directive = eval_predicate(pred, captures, get_text_fn)
        if not ok then
            return false, nil
        end
        if directive ~= nil then
            if directives == nil then
                directives = {}
            end
            for k, v in pairs(directive) do
                directives[k] = v
            end
        end
    end
    return true, directives
end

--- Return an iterator over matches that PASS their predicates. Each
--- yielded value is {captures=..., directives=...} where `directives`
--- is the #set! key→value table (or nil). `get_text_fn(start_byte,
--- end_byte)` returns the source bytes for a capture node (text predicates
--- need node text).
---@param get_text_fn function(int,int)->string
---@return function
function QueryCursor:filtered_matches(get_text_fn)
    local q = self.bound_query
    local inner = self:matches()
    return function()
        for match in inner do
            local ok, directives =
                eval_match_predicates(q, match.pattern_index, match.captures, get_text_fn)
            if ok then
                return {
                    captures = match.captures,
                    directives = directives,
                    pattern_index = match.pattern_index,
                }
            end
        end
        return nil
    end
end

--- Return an iterator over captures from matches that PASS their
--- predicates. Unlike the raw captures() iterator (which yields from
--- next_capture, pre-sorted by byte), this drains ALL surviving matches
--- and sorts their captures by start byte (ties → pattern_index) before
--- yielding — so the byte-order contract that the stack algorithm relies
--- on is preserved. Each yielded value is
---   {name=string, node=TSNode, start_byte=int, end_byte=int}.
---@param get_text_fn function(int,int)->string
---@return function
function QueryCursor:filtered_captures(get_text_fn)
    local all = {}
    for match in self:filtered_matches(get_text_fn) do
        for _, cap in ipairs(match.captures) do
            local sb = tonumber(c_api.ts_node_start_byte(cap.node))
            local eb = tonumber(c_api.ts_node_end_byte(cap.node))
            all[#all + 1] = {
                name = cap.name,
                node = cap.node,
                start_byte = sb,
                end_byte = eb,
                _pi = match.pattern_index,
            }
        end
    end
    table.sort(all, function(a, b)
        if a.start_byte ~= b.start_byte then
            return a.start_byte < b.start_byte
        end
        return a._pi < b._pi
    end)
    local i = 0
    return function()
        i = i + 1
        if i > #all then
            return nil
        end
        return all[i]
    end
end

local function tree_cursor_new(node)
    return c_api.ts_tree_cursor_new(node)
end

local function tree_cursor_delete(cursor)
    c_api.ts_tree_cursor_delete(cursor)
end

local function tree_cursor_current_node(cursor)
    return c_api.ts_tree_cursor_current_node(cursor)
end

local function tree_cursor_goto_first_child(cursor)
    return c_api.ts_tree_cursor_goto_first_child(cursor)
end

local function tree_cursor_goto_next_sibling(cursor)
    return c_api.ts_tree_cursor_goto_next_sibling(cursor)
end

local function tree_cursor_goto_parent(cursor)
    return c_api.ts_tree_cursor_goto_parent(cursor)
end

--- Single-getter byte accessors (avoid unpacking both when we only
--- need one end — used by the markdown inline-range walk).
local function node_start_byte(node)
    return tonumber(c_api.ts_node_start_byte(node))
end

local function node_end_byte(node)
    return tonumber(c_api.ts_node_end_byte(node))
end

--- Collect byte ranges of every node named `name` under `root` (depth-first
--- walk). Used by the markdown split-parser: the block tree marks inline
--- content as `inline` nodes; we feed those byte ranges to the inline
--- parser via ts_parser_set_included_ranges, then parse the inline grammar
--- over exactly those spans. Returns a Lua array of {start_byte, end_byte},
--- in document order. Excludes zero-length nodes (set_included_ranges
--- rejects them — a zero-length range produces nothing and can fail the call).
---
--- The markdown block grammar's `inline` node is a leaf wrapper around
--- inline content; we do NOT descend into a matching node (its children
--- would step past the inline span into adjacent block nodes).
---@param root any TSNode
---@param name string node type to collect
---@return table<integer, {start_byte:integer, end_byte:integer}> ranges
local function collect_named_ranges(root, name)
    local ranges = {}
    local cursor = c_api.ts_tree_cursor_new(root)
    local depth = 0
    if not c_api.ts_tree_cursor_goto_first_child(cursor) then
        c_api.ts_tree_cursor_delete(cursor)
        return ranges
    end
    depth = 1
    while depth > 0 do
        local node = c_api.ts_tree_cursor_current_node(cursor)
        local matched = false
        if ffi.string(c_api.ts_node_type(node)) == name then
            local sb = tonumber(c_api.ts_node_start_byte(node))
            local eb = tonumber(c_api.ts_node_end_byte(node))
            if eb > sb then
                ranges[#ranges + 1] = { start_byte = sb, end_byte = eb }
            end
            matched = true
            -- Do not descend into a matched leaf; advance sibling.
        end
        if not matched and c_api.ts_tree_cursor_goto_first_child(cursor) then
            depth = depth + 1
        else
            -- Advance to next sibling; when none, climb to parent.
            while depth > 0 and not c_api.ts_tree_cursor_goto_next_sibling(cursor) do
                if not c_api.ts_tree_cursor_goto_parent(cursor) then
                    break
                end
                depth = depth - 1
            end
        end
    end
    c_api.ts_tree_cursor_delete(cursor)
    return ranges
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    lang = lang,
    lang_get = lang_get,
    Parser = Parser,
    Tree = Tree,
    Query = Query,
    QueryCursor = QueryCursor,
    node_is_null = node_is_null,
    node_type = node_type,
    node_byte_range = node_byte_range,
    node_eq = node_eq,
    node_point_range = node_point_range,
    node_named_child = node_named_child,
    node_named_child_count = node_named_child_count,
    node_parent = node_parent,
    node_descendant_for_byte_range = node_descendant_for_byte_range,
    node_string = node_string,
    tree_cursor_new = tree_cursor_new,
    tree_cursor_delete = tree_cursor_delete,
    tree_cursor_current_node = tree_cursor_current_node,
    tree_cursor_goto_first_child = tree_cursor_goto_first_child,
    tree_cursor_goto_next_sibling = tree_cursor_goto_next_sibling,
    tree_cursor_goto_parent = tree_cursor_goto_parent,
    node_start_byte = node_start_byte,
    node_end_byte = node_end_byte,
    collect_named_ranges = collect_named_ranges,
    eval_match_predicates = eval_match_predicates,
    ffi = ffi,
}
