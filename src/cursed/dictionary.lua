--- Dictionary: provides prefix completion from the system word list.
---
--- Lazily loads the system dictionary (`/usr/share/dict/words` or
--- similar) into memory on first use, re-sorting it to ASCII collation
--- order (the dictionary on macOS is locale-sorted, which isn't safe for
--- binary search). Uses binary search + linear forward scan for
--- case-insensitive prefix lookup.
---
--- ASCII sort puts uppercase-first entries (e.g. "Aardvark") before
--- other-letter blocks ("B...", "C...", ...) which are before lowercase-
--- first entries ("aardvark").  We probe separately from the uppercase
--- and lowercase prefix to cover both regions.
---
--- Usage:
---   local dict = require("cursed.dictionary")
---   local words = dict.lookup("hel", 20)   -- up to 20 words

local log = require("cursed.log")

local M = {}

---@type string[]|nil
local words = nil

---@type string|nil
local dict_path = nil

--- Candidate system dictionary paths, in preference order.
local CANDIDATES = {
    "/usr/share/dict/words",
    "/usr/dict/words",
    "/usr/share/dict/web2",
}

--- Resolve the first existing dictionary path, or nil.
---@return string|nil
local function find_dict()
    for _, p in ipairs(CANDIDATES) do
        local f = io.open(p, "r")
        if f ~= nil then
            f:close()
            return p
        end
    end
    return nil
end

--- Load all words from the dictionary file into `words[]`, then
--- re-sort to ASCII collation order (the system dictionary on macOS
--- is locale-sorted, which breaks binary search).
local function load_dict()
    if words ~= nil then
        return
    end
    local path = dict_path or find_dict()
    if path == nil then
        log.warn("dictionary", "no_dictionary_found")
        words = {}
        return
    end
    local f = io.open(path, "r")
    if f == nil then
        log.warn("dictionary", "open_failed", { path = path })
        words = {}
        return
    end
    local t = {} ---@type string[]
    for line in f:lines() do
        -- Skip empty lines and possessive entries (e.g. "abbot's").
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= nil and #trimmed > 0 and trimmed:byte(#trimmed) ~= 39 then
            ---@cast trimmed string
            t[#t + 1] = trimmed
        end
    end
    f:close()
    -- Re-sort to ASCII collation.  macOS ships a locale-sorted
    -- dictionary; binary search requires strict lexicographic order.
    table.sort(t)
    words = t
    log.info("dictionary", "loaded", { path = path, count = #words })
end

--- Binary search for the first word >= prefix in `ws[]`.
--- Assumes `ws` is ASCII-sorted.
---@param prefix string
---@param ws string[] sorted word list
---@return integer index (1-based)
local function lower_bound(prefix, ws)
    local lo, hi = 1, #ws
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        ---@cast ws string[]
        if ws[mid] < prefix then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return lo
end

--- Return up to `limit` dictionary words whose lowercase form starts
--- with `prefix` (case-insensitive).  Under ASCII sort, entries with
--- the same case-insensitive first letter live in two SEPARATE blocks
--- separated by entries for other first letters: the uppercase block
--- (e.g. "Aardvark") sorts first, then other letters, then the
--- lowercase block (e.g. "aardvark").  We probe from both the
--- title-case and lowercase prefix variants and merge the results.
---
--- Every matching entry appears at most once (deduped by text).
--- Returns a new table, empty when no matches or no dictionary loaded.
---@param prefix string
---@param limit integer? max results (default 50)
---@return string[]
function M.lookup(prefix, limit)
    load_dict()
    if words == nil or #words == 0 or prefix == nil or #prefix == 0 then
        return {}
    end
    limit = limit or 50
    local lower = prefix:lower()
    local first_lower = lower:sub(1, 1)
    local results = {} ---@type string[]
    local seen = {} ---@type table<string,boolean>

    -- Build probes.  Under ASCII sort, uppercase-first entries for a
    -- given first letter sort BEFORE lowercase-first entries, and
    -- other letters' entries sit between them.  Each probe scans
    -- forward from its own lower-bound until the case-insensitive
    -- first letter changes — that covers exactly one block.
    --
    -- Priority order: lowercase probe first (common words like "help",
    -- "head") then the uppercase probe as supplement (proper nouns,
    -- scientific terms).  Keeps the completion popup useful.
    local probes = {} ---@type string[]
    -- Lowercase probe for the common-word block ("aardvark").
    probes[#probes + 1] = lower
    local first_byte = lower:byte(1)
    if first_byte >= 97 and first_byte <= 122 then
        -- Title-case probe for the uppercase-first block ("Aardvark").
        probes[#probes + 1] = string.char(first_byte - 32) .. lower:sub(2)
    end

    for _, probe in ipairs(probes) do
        local idx = lower_bound(probe, words)
        ---@cast words string[]
        for i = idx, #words do
            if #results >= limit then
                break
            end
            local w = words[i]
            ---@cast w string
            -- Stop when the word's first letter (case-insensitively) no
            -- longer matches the prefix's first letter — we've left the
            -- block for this letter.
            if w:sub(1, 1):lower() ~= first_lower then
                break
            end
            if w:sub(1, #prefix):lower() == lower and not seen[w] then
                seen[w] = true
                results[#results + 1] = w
            end
        end
    end

    return results
end

--- Override the dictionary path (for testing).
---@param path string
function M.set_path(path)
    dict_path = path
    words = nil
end

--- Unload the cached dictionary.
function M.reset()
    words = nil
    dict_path = nil
end

return M
