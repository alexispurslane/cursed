--- file_index: fast recursive file listing with TTL-based caching.
---
--- Walks the project root with fts(3) — the native BSD/macOS hierarchical
--- directory walker — and stores every non-ignored file path in a sorted
--- flat array. The cache is invalidated on a configurable TTL (default 5s)
--- so external file changes are picked up quickly without filesystem
--- watching. A manual `invalidate()` hook is provided for editor-driven
--- invalidation (e.g. on buffer save/create).
---
--- Usage:
---   local FileIndex = require("cursed.file_index")
---   local idx = FileIndex.new("/path/to/project", { ttl_sec = 10 })
---   local paths = idx:get_files()  -- returns string[]
---   idx:invalidate()               -- force rebuild on next get_files()
---
--- The index is a module-level singleton keyed by workspace directory.

local ffi = require("ffi")
local pffi = require("cursed.posix_ffi")
local c = pffi.C

----------------------------------------------------------------------------------------------------
-- Directory exclusion set: directories whose entries are skipped entirely.
-- Case-sensitive, exact name match.
----------------------------------------------------------------------------------------------------

local IGNORED_DIRS = {
    [".git"] = true,
    [".hg"] = true,
    [".svn"] = true,
    ["node_modules"] = true,
    ["__pycache__"] = true,
    [".pytest_cache"] = true,
    [".mypy_cache"] = true,
    [".ruff_cache"] = true,
    ["target"] = true, -- Rust
    ["build"] = true, -- C/C++/CMake
    ["dist"] = true,
    [".next"] = true, -- Next.js
    [".cache"] = true,
    ["vendor"] = true,
    ["deps"] = true,
    ["zig-cache"] = true,
    [".zig-cache"] = true,
    [".svelte-kit"] = true,
}

--- Check if a directory entry name should be skipped.
---@param name string
---@return boolean
local function is_ignored_dir(name)
    -- Skip directories that start with "." except "."
    if name:byte(1) == 0x2E and #name > 1 then
        return true
    end
    return IGNORED_DIRS[name] == true
end

----------------------------------------------------------------------------------------------------
-- Monotonic time helper (microseconds)
----------------------------------------------------------------------------------------------------

--- Get a monotonic-ish microsecond timestamp for cache-timing.
--- Uses gettimeofday which is fast and monotonic enough for TTL purposes.
---@return integer us
local function now_us()
    local tv = ffi.new("struct timeval")
    c.gettimeofday(tv, nil)
    return tonumber(tv.tv_sec) * 1000000 + tonumber(tv.tv_usec)
end

----------------------------------------------------------------------------------------------------
-- FileIndex class
----------------------------------------------------------------------------------------------------

---@class FileIndex
---@field _dir string workspace root directory
---@field _files string[]|nil cached file paths (sorted)
---@field _mtime_us integer monotonic timestamp (us) of last rebuild
---@field _ttl_us integer cache time-to-live in microseconds
local FileIndex = {}
FileIndex.__index = FileIndex

local DEFAULT_TTL_SEC = 5

--- Create a new FileIndex for a workspace directory.
---@param workspace_dir string absolute path to the project root
---@param opts? { ttl_sec?: number }
---@return FileIndex
function FileIndex.new(workspace_dir, opts)
    opts = opts or {}
    local ttl_sec = tonumber(opts.ttl_sec) or DEFAULT_TTL_SEC
    return setmetatable({
        _dir = workspace_dir,
        _files = nil,
        _mtime_us = 0,
        _ttl_us = ttl_sec * 1000000,
    }, FileIndex)
end

--- Walk the project root with fts(3) and collect all file paths.
--- Handles the FTS lifecycle: FTSENTs are only valid until the next
--- fts_read or fts_close, so we extract ffi.string from them eagerly.
---@return string[]
local function walk_with_fts(root)
    -- Build NULL-terminated path array for fts_open.
    -- Must assign explicitly: { str, nil } in Lua is a 1-element table
    -- (nil terminates the list), leaving argv[1] as uninitialized garbage.
    local path_str = ffi.new("char[?]", #root + 1, root)
    local path_argv = ffi.new("const char *[2]")
    path_argv[0] = path_str
    path_argv[1] = nil
    local ftsp = c.fts_open(path_argv, pffi.FTS_PHYSICAL + pffi.FTS_NOCHDIR, nil)
    if ftsp == nil then
        return {}
    end

    local paths = {}
    local root_len = #root
    -- Ensure root has a trailing slash for relative path stripping.
    local root_prefix = root
    if root_len > 0 and root:byte(root_len) ~= 0x2F then
        root_prefix = root .. "/"
    end

    local ent = c.fts_read(ftsp)
    while ent ~= nil do
        local info = tonumber(ent.fts_info)
        ---@cast info integer

        if info == pffi.FTS_F then
            -- Regular file: extract relative path.
            local full = ffi.string(ent.fts_path)
            local rel = full
            if #full > #root_prefix and full:sub(1, #root_prefix) == root_prefix then
                rel = full:sub(#root_prefix + 1)
            end
            paths[#paths + 1] = rel
        elseif info == pffi.FTS_D then
            -- Pre-order directory: check if we should skip its contents.
            local name = ffi.string(ent.fts_name)
            if is_ignored_dir(name) then
                c.fts_set(ftsp, ent, 4) -- FTS_SKIP = 4
            end
        elseif info == pffi.FTS_DP then
            -- Post-order directory: nothing to do.
        elseif info == pffi.FTS_DNR or info == pffi.FTS_ERR then
            -- Unreadable directory or error: skip.
        end
        -- else: FTS_NS (stat failed), FTS_SL (symlink), etc. — skip.

        ent = c.fts_read(ftsp)
    end

    c.fts_close(ftsp)

    -- Sort for consistent ordering and bsearch-friendly prefix lookups.
    table.sort(paths)
    return paths
end

--- Get the file list, rebuilding the cache if stale.
---@return string[]
function FileIndex:get_files()
    if self._files == nil or (now_us() - self._mtime_us) > self._ttl_us then
        self:_rebuild()
    end
    return self._files
end

--- Force rebuild of the file index now. Called internally by get_files()
--- when the cache is stale, and exposed for editor hooks.
function FileIndex:invalidate()
    self._mtime_us = 0
end

--- Rebuild the cached file list by walking the workspace root with fts.
function FileIndex:_rebuild()
    self._files = walk_with_fts(self._dir)
    self._mtime_us = now_us()
end

----------------------------------------------------------------------------------------------------
-- Singleton factory
----------------------------------------------------------------------------------------------------

-- Cache FileIndex instances by workspace dir so multiple callers share
-- the same index (avoids redundant fts walks).
local instances = {}

--- Get or create a FileIndex singleton for a workspace directory.
---@param workspace_dir string
---@param opts? { ttl_sec?: number }
---@return FileIndex
function FileIndex.for_dir(workspace_dir, opts)
    if instances[workspace_dir] == nil then
        instances[workspace_dir] = FileIndex.new(workspace_dir, opts)
    end
    return instances[workspace_dir]
end

return {
    FileIndex = FileIndex,
    for_dir = FileIndex.for_dir,
    walk_with_fts = walk_with_fts,
}
