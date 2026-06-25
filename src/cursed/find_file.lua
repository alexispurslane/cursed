--- Find File: completion provider and path utilities.
---
--- Provides a flexible file path completer for the minibuffer,
--- supporting ~, $ENV expansion, path traversal with "/" segment
--- resolution, and space-separated substring matching in any order.

local ffi = require("ffi")
local pffi = require("cursed.posix_ffi")
local c = pffi.C

----------------------------------------------------------------------------------------------------
-- Path expansion
----------------------------------------------------------------------------------------------------

--- Expand ~ and $ENV_VARS in a full file path.
---@param path string
---@return string
local function expand_path(path)
    -- Expand ~ at the start
    if path:sub(1, 1) == "~" then
        local home = os.getenv("HOME")
        if home then
            if #path == 1 then
                path = home
            elseif path:sub(2, 2) == "/" then
                path = home .. path:sub(2)
            end
        end
    end

    -- Expand ${VAR} syntax
    path = path:gsub("%${([^}]+)}", function(var)
        return os.getenv(var) or ("${" .. var .. "}")
    end)
    -- Expand $VAR syntax
    path = path:gsub("%$([%w_]+)", function(var)
        return os.getenv(var) or ("$" .. var)
    end)

    return path
end

--- Expand a single path segment (used during resolution).
--- Handles ~ (full segment only), $ENV_VARS, ".", "..".
---@param segment string
---@return string
local function expand_segment(segment)
    if segment == "~" then
        return os.getenv("HOME") or "~"
    end

    -- Expand ${VAR} syntax
    segment = segment:gsub("%${([^}]+)}", function(var)
        return os.getenv(var) or ("${" .. var .. "}")
    end)
    -- Expand $VAR syntax
    segment = segment:gsub("%$([%w_]+)", function(var)
        return os.getenv(var) or ("$" .. var)
    end)

    return segment
end

----------------------------------------------------------------------------------------------------
-- Directory operations
----------------------------------------------------------------------------------------------------

--- Check if a path exists and is a directory.
---@param path string
---@return boolean
local function is_directory(path)
    local dir = c.opendir(path)
    if dir == nil then
        return false
    end
    c.closedir(dir)
    return true
end

--- List entries in a directory.
--- Uses readdir d_type for fast classification; falls back to opendir
--- for DT_LNK and DT_UNKNOWN entries to follow symlinks correctly.
---@param path string
---@return table[] entries { name: string, is_dir: boolean }
local function list_dir(path)
    local dir = c.opendir(path)
    if dir == nil then
        return {}
    end

    local entries = {}
    local entry = c.readdir(dir)
    while entry ~= nil do
        local name = ffi.string(entry.d_name)
        if name ~= "." and name ~= ".." then
            local dtype = tonumber(entry.d_type)
            ---@cast dtype integer
            local is_dir = false
            if dtype == pffi.DT_DIR then
                is_dir = true
            elseif dtype == pffi.DT_REG then
                is_dir = false
            else
                -- DT_LNK, DT_UNKNOWN, etc. — check with opendir
                is_dir = is_directory(path .. "/" .. name)
            end
            entries[#entries + 1] = {
                name = name,
                is_dir = is_dir,
            }
        end
        entry = c.readdir(dir)
    end

    c.closedir(dir)
    return entries
end

----------------------------------------------------------------------------------------------------
-- Completion provider
----------------------------------------------------------------------------------------------------

--- Split a string by "/" preserving all segments (including empty ones).
--- A trailing "/" produces an empty final segment.
---@param text string
---@return string[]
local function split_by_slash(text)
    local segments = {}
    local i = 1
    while i <= #text do
        local j = text:find("/", i, true)
        if not j then
            segments[#segments + 1] = text:sub(i)
            break
        end
        segments[#segments + 1] = text:sub(i, j - 1)
        i = j + 1
    end
    -- Trailing slash → empty final segment (means "list this directory")
    if #text > 0 and text:sub(#text) == "/" then
        segments[#segments + 1] = ""
    end
    return segments
end

--- File path completion provider for the minibuffer.
---
--- Algorithm:
---   1. Split input by "/"
---   2. Resolve segments left-to-right as directory path components,
---      expanding ~ and $ENV vars, and checking existence with opendir
---   3. Stop at the first segment that doesn't resolve as a directory
---   4. The remaining unresolved segments are space-split into search terms
---   5. List the resolved base directory and filter entries: each entry
---      name must contain ALL search terms as substrings (case-insensitive)
---   6. Return matching paths using the user's original input prefix
---@param text string current minibuffer input
---@return string[] completions
local function find_file_completer(text)
    -- No slashes: treat entire input as space-separated search terms in cwd
    if not text:find("/", 1, true) then
        local search_terms = {}
        for word in text:gmatch("%S+") do
            search_terms[#search_terms + 1] = word:lower()
        end

        local entries = list_dir(".")
        local results = {}
        for _, e in ipairs(entries) do
            local lower_name = e.name:lower()
            local matches = true
            for _, term in ipairs(search_terms) do
                if not lower_name:find(term, 1, true) then
                    matches = false
                    break
                end
            end
            if matches then
                local path = e.name
                if e.is_dir then
                    path = path .. "/"
                end
                results[#results + 1] = path
            end
        end
        table.sort(results)
        return results
    end

    -- Has slashes: resolve path segments left-to-right, then subword-match
    local segments = split_by_slash(text)
    local has_leading_slash = text:sub(1, 1) == "/"

    local base_path = "."
    local user_prefix = ""
    local remaining_start = 1

    for i, seg in ipairs(segments) do
        if i == 1 and seg == "" and has_leading_slash then
            base_path = "/"
            user_prefix = "/"
            remaining_start = 2
        elseif i == 1 then
            local expanded = expand_segment(seg)
            if is_directory(expanded) then
                base_path = expanded
                user_prefix = seg .. "/"
                remaining_start = i + 1
            else
                base_path = "."
                remaining_start = i
                break
            end
        elseif seg == "" then
            remaining_start = i + 1
        else
            local expanded = expand_segment(seg)
            local candidate = base_path .. "/" .. expanded
            if is_directory(candidate) then
                base_path = candidate
                user_prefix = user_prefix .. seg .. "/"
                remaining_start = i + 1
            else
                remaining_start = i
                break
            end
        end
    end

    -- Collect search terms from remaining segments
    local search_terms = {}
    for i = remaining_start, #segments do
        for word in segments[i]:gmatch("%S+") do
            search_terms[#search_terms + 1] = word:lower()
        end
    end

    local entries = list_dir(base_path)
    local results = {}
    for _, e in ipairs(entries) do
        local lower_name = e.name:lower()
        local matches = true
        for _, term in ipairs(search_terms) do
            if not lower_name:find(term, 1, true) then
                matches = false
                break
            end
        end
        if matches and e.name ~= "" then
            local path = user_prefix .. e.name
            if e.is_dir then
                path = path .. "/"
            end
            results[#results + 1] = path
        end
    end

    table.sort(results)
    return results
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    find_file_completer = find_file_completer,
    is_directory = is_directory,
    expand_path = expand_path,
}
