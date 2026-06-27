--- Configuration loader for the cursed editor.
---
--- Reads ~/.config/cursed/init.lua on startup (plus any user mode
--- files in ~/.config/cursed/modes/*.lua) and returns a Config object
--- containing major-mode definitions and the file→mode mapping.
---
--- Built-in major modes live in `src/cursed/modes/<lang>.lua` and are
--- always registered; their names are the registry keys ("base",
--- "lua", "c", "python", "go", "makefile", "markdown", "zig").
--- The env exposed to init.lua provides:
---   MajorMode  — constructor for custom modes
---   modes      — the merged mode table (built-ins + user mode files),
---                addressed by name (e.g. `modes.lua`, `modes.c`)
---
--- Modes themselves bundle indent settings, language, and the
--- tree-sitter `highlight_query`; they do NOT carry file_patterns.
--- The pattern→mode mapping lives entirely in `file_patterns` here.
---
--- MODE FILES ARE UNSANDBOXED: a mode spec file (built-in OR user)
--- runs against the main thread's global context, and it loads AFTER
--- the global `editor` exists (see the lazy `require("cursed.modes")`
--- below). So a mode file may run arbitrary top-level code — including
--- registering per-mode event handlers on `editor.event_system` —
--- before returning its MajorModeSpec. The View emits a specific
--- `mode_enter:<name>` / `mode_exit:<name>` event for each mode (plus
--- the generic `mode_enter` / `mode_exit`), so a mode registers for its
--- own event directly instead of if/else dispatching on the name:
---
---   -- src/cursed/modes/lua.lua
---   editor.event_system:on("mode_enter:lua", function(ed, instance, view)
---       instance._entered_at = os.time()
---   end)
---   return { name = "lua", language = "lua", ... }
---
--- USER MODE FILES: drop a spec file in ~/.config/cursed/modes/<name>.lua
--- to ADD a mode or OVERRIDE a built-in (same shape as the built-in mode
--- files — return a MajorModeSpec). These load BEFORE init.lua and even
--- run with no init.lua present; they're then available as `modes.<name>`
--- inside init.lua. To *extend* a built-in instead of replacing it,
--- require the built-in spec and return a tweaked copy:
---
---   -- ~/.config/cursed/modes/lua.lua  (rebind tab_width, keep the rest)
---   local spec = require("cursed.modes.lua")
---   return vim.tbl_extend("force", spec, { tab_width = 2 })  -- or manual copy
---
---   return {
---     -- Global keybinding overrides
---     keybindings = {},
---
---     -- Custom (user-defined) modes, by name
---     modes = {
---       mything = MajorMode.new{ name = "mything", tab_width = 2, ... },
---     },
---
---     -- Ordered { pattern, mode } pairs. `mode` MUST be a `modes.<name>`
---     -- MajorMode object (built-in or user) — bare name strings are
---     -- NOT accepted. All matches apply in order; later modes override
---     -- earlier ones. Built-in defaults (.* → base, etc.) are seeded
---     -- AFTER all override merges, so they pick up any overridden mode
---     -- automatically; user entries are appended on top so they win.
---     file_patterns = {
---       { "%.th$", modes.lua },   -- treat .th files as lua
---     },
---   }
---
--- If no init.lua exists, the built-in modes (plus any user mode files)
--- and default file_patterns are used as-is.

local ffi = require("ffi")
local MajorMode = require("cursed.major_mode")
local pffi = require("cursed.posix_ffi")
local log = require("cursed.log")

--- Default file_patterns: built-in modes mapped to common extensions.
--- Prepend these so user-supplied patterns (appended later) override them.
local DEFAULT_FILE_PATTERNS = {
    { ".*", "base" },
    { "%.c$", "c" },
    { "%.h$", "c" },
    { "%.cpp$", "c" },
    { "%.hpp$", "c" },
    { "%.cc$", "c" },
    { "%.go$", "go" },
    { "%.lua$", "lua" },
    { "Makefile$", "makefile" },
    { "%.md$", "markdown" },
    { "%.py$", "python" },
    { "%.rs$", "rust" },
    { "%.zig$", "zig" },
    { "%.sh$", "bash" },
    { "%.bash$", "bash" },
    { "%.json$", "json" },
    { "%.toml$", "toml" },
    { "%.ya?ml$", "yaml" },
}

---@class Config
---@field modes table<string, MajorMode> name → MajorMode (built-ins + user)
---@field file_patterns { [1]: string, [2]: MajorMode }[] normalized {pattern, MajorMode}
---@field keybindings table<string, string|function> global keybinding overrides
---@field colorscheme string|nil name or absolute path to a base16 theme file
---@field concept_slots table<string, integer>|nil concept → base-slot (0x0N) overrides
---@field margin integer|nil max text render width; when the window is wider, the (gutter+text) column is centered within it
---@field mirror_prefix string|nil when set (e.g. "alt-q"), clone the ctrl-x prefix subtree under this prefix — for terminals that swallow C-x
local Config = {}
Config.__index = Config

----------------------------------------------------------------------------------------------------
-- User mode files: ~/.config/cursed/modes/<name>.lua
--
-- Each file returns a MajorModeSpec (the same shape built-in mode files
-- in src/cursed/modes/<lang>.lua return). At load time we run MajorMode.new
-- on each and merge by spec.name — a user file overrides a built-in of the
-- same name (full replace), or adds a new mode. This runs BEFORE init.lua
-- so the constructed modes are available as `modes.<name>` inside init.lua,
-- and it runs even with no init.lua present at all.
--
-- A user file that wants to *extend* a built-in instead of replacing it
-- can require the built-in spec and return a tweaked copy:
--
--   local spec = require("cursed.modes.lua")
--   spec = vim.tbl_extend("force", spec, { tab_width = 2 })  -- or manual copy
--   return spec
--
-- Errors in individual files are logged and skipped (never brick the
-- editor over a bad mode file).
----------------------------------------------------------------------------------------------------

--- Load `<dir>/*.lua` user mode specs, construct each, and merge into
--- `modes` by name (overriding built-ins). No-op if `dir` is missing.
---@param dir string absolute path to the modes directory
---@param modes table<string, MajorMode> table to merge into
local function load_user_modes(dir, modes)
    local C = pffi.C
    local cdir = C.opendir(dir)
    if cdir == nil then
        -- Directory doesn't exist or is unreadable: nothing to do.
        return
    end

    -- Collect *.lua filenames first (DT_REG only), then sort for a
    -- deterministic load order in case of name collisions.
    local names = {}
    local ent = C.readdir(cdir)
    while ent ~= nil do
        if ent.d_type == pffi.DT_REG then
            local nm = ffi.string(ent.d_name)
            if nm:sub(-4) == ".lua" and nm ~= "init.lua" then
                names[#names + 1] = nm
            end
        end
        ent = C.readdir(cdir)
    end
    C.closedir(cdir)
    table.sort(names)

    local function load_one(nm)
        local path = dir .. "/" .. nm
        local chunk, lerr = loadfile(path)
        if not chunk then
            log.error("config", "failed to load user mode file", {
                file = nm,
                error = tostring(lerr),
            })
            return
        end
        local ok, spec = pcall(chunk)
        if not ok then
            log.error("config", "user mode file errored", { file = nm, error = tostring(spec) })
            return
        end
        if type(spec) ~= "table" then
            log.error("config", "user mode file did not return a table", { file = nm })
            return
        end
        -- If the file already returned a constructed MajorMode (metatable
        -- is MajorMode), use it as-is to avoid double-wrapping. Otherwise
        -- it's a spec table — construct it.
        local mode
        if getmetatable(spec) == MajorMode then
            mode = spec
        else
            if type(spec.name) ~= "string" then
                log.error("config", "user mode spec missing name", { file = nm })
                return
            end
            mode = MajorMode.new(spec)
        end
        modes[mode.name] = mode
        log.info("config", "loaded user mode", { file = nm, name = mode.name })
    end

    for _, nm in ipairs(names) do
        load_one(nm)
    end
end

--- Resolve a file_patterns mode reference to a MajorMode object.
--- The ONLY accepted form is a MajorMode object (a constructed mode —
--- built-in or user). Bare name strings are intentionally NOT
--- supported: this keeps file_patterns an explicit, object-typed list
--- with no name-lookup indirection at runtime.
---@param val any
---@return MajorMode|nil
local function resolve_mode_ref(val)
    if type(val) == "table" and val.name ~= nil then
        return val
    end
    return nil
end

--- Parse a user-supplied concept → base-slot override table into the
--- normalized internal form { concept_name → 0x0N }.
---
--- Accepted value forms (any of these for each concept key):
---   "base0E", "BASE0E", "0e", "0E"  → 0x0E  (hex slot, optional "base" prefix)
---   0x0E, 14                          → that slot index (0..15)
--- Keys not already known concepts are still accepted (the user may
--- be pre-declaring one we add later); invalid slot values are dropped
--- with a warning so a typo doesn't silently black out the UI.
---@param raw table<string, string|integer> concept → slot spec
---@return table<string, integer> normalized concept → 0x0N
local function parse_concept_slots(raw)
    local out = {}
    for concept, slot in pairs(raw) do
        local n
        if type(slot) == "string" then
            local s = slot:lower():gsub("^base", "")
            n = tonumber(s, 16)
        elseif type(slot) == "number" then
            n = slot
        end
        if n == nil or n < 0 or n > 0x0F then
            log.warn("config", "invalid concept slot, ignoring", {
                concept = concept,
                slot = tostring(slot),
            })
        else
            out[concept] = n
        end
    end
    return out
end

--- Load the user configuration from ~/.config/cursed/init.lua.
--- Returns a config backed by built-in modes + default file_patterns
--- if init.lua is missing or errors.
---@return Config
function Config.load()
    -- Built-in modes are always present. `require("cursed.modes")` is
    -- deferred to here (NOT at module top) so the per-language spec
    -- files in src/cursed/modes/*.lua run their top level AFTER the
    -- global `editor` exists — that top level is where a mode file
    -- registers its per-mode event handlers
    -- (`editor.event_system:on("mode_enter:<name>", ...)`). Requiring
    -- at module-load time (before `_G.editor` is set in main.lua)
    -- would sandbox them.
    local builtin = require("cursed.modes")
    local modes = {} ---@type table<string, MajorMode>
    for name, mode in pairs(builtin.modes) do
        modes[name] = mode
    end

    local file_patterns = {} ---@type { [1]: string, [2]: MajorMode }[]
    local keybindings = {} ---@type table<string, string|function>

    -- Definition order is critical for override flow:
    --   1. build-ins → modes
    --   2. user mode files (~/.config/cursed/modes/*.lua) merge on top
    --      (available as `modes.<name>` inside init.lua)
    --   3. init.lua's `modes={}` merges on top of all of the above
    --   4. ONLY THEN are DEFAULT_FILE_PATTERNS seeded (as resolved
    --      MajorMode objects), so any override above wins for the
    --      default `%.lua$`→lua etc. mappings.
    --   5. user `file_patterns` append after defaults (later-match-wins)
    -- Users reference modes ONLY via `modes.<name>` objects — no name
    -- strings — so resolution is eager and there's no lazy layer.

    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg == nil or xdg == "" then
        local home = os.getenv("HOME")
        if home == nil then
            -- No HOME: built-ins + defaults only.
            for _, entry in ipairs(DEFAULT_FILE_PATTERNS) do
                local mode = modes[entry[2]]
                if mode ~= nil then
                    file_patterns[#file_patterns + 1] = { entry[1], mode }
                end
            end
            return setmetatable({
                modes = modes,
                file_patterns = file_patterns,
                keybindings = keybindings,
                colorscheme = nil,
            }, Config)
        end
        xdg = home .. "/.config"
    end

    -- (2) Load user mode files BEFORE init.lua so they're available as
    -- `modes.<name>` inside init.lua. Runs even if init.lua is absent.
    load_user_modes(xdg .. "/cursed/modes", modes)

    -- (3) Run init.lua (if present). Unsandboxed (#20): the chunk runs
    -- against the main thread's global context — reads fall through to
    -- `_G` (so init.lua can see the global `editor`, `require`, `io`,
    -- …) and writes propagate to `_G` (defined globals persist; this is
    -- how init.lua can `editor.event_system:on(...)` and have the
    -- listener live on the real editor). `MajorMode` and the merged
    -- `modes` table are injected as convenience bare names.
    local result = nil
    local path = xdg .. "/cursed/init.lua"
    local f = io.open(path, "r")
    if f ~= nil then
        f:close()
        local ok, res = pcall(function()
            local chunk, err = loadfile(path)
            if not chunk then
                error(err or "failed to load init.lua", 0)
            end
            -- Passthrough env: reads → _G, writes → _G. Only `MajorMode`
            -- and `modes` are shadowed as convenience locals. This is
            -- NOT a sandbox — init.lua can do anything main-thread
            -- code can (access the global editor, require any module,
            -- spawn background tasks, register event listeners, …).
            local env = {
                MajorMode = MajorMode,
                modes = modes,
            }
            setmetatable(env, {
                __index = _G,
                __newindex = function(_t, k, v)
                    _G[k] = v
                end,
            })
            ---@diagnostic disable-next-line: deprecated
            setfenv(chunk, env)
            return chunk()
        end)
        if not ok then
            log.error("config", "failed to load init.lua", { error = tostring(res) })
        elseif type(res) ~= "table" then
            log.error("config", "init.lua did not return a table", {})
        else
            result = res
        end
    end

    -- Merge user-defined modes (by name) on top of built-ins + user files.
    if result and result.modes ~= nil and type(result.modes) == "table" then
        for name, mode in pairs(result.modes) do
            if type(name) == "string" and type(mode) == "table" and mode.name then
                modes[name] = mode
            else
                log.error("config", "invalid mode entry", { name = tostring(name) })
            end
        end
    end

    -- (4) Seed default file_patterns NOW — after all mode merges — so
    -- overrides (user mode files OR init.lua `modes`) flow into the
    -- defaults via the resolved object.
    for _, entry in ipairs(DEFAULT_FILE_PATTERNS) do
        local mode = modes[entry[2]]
        if mode ~= nil then
            file_patterns[#file_patterns + 1] = { entry[1], mode }
        else
            log.error("config", "default file_pattern references unknown mode", {
                pattern = entry[1],
                mode_name = tostring(entry[2]),
            })
        end
    end

    -- (5) Parse user file_patterns (append AFTER defaults to win).
    -- Mode refs MUST be `modes.<name>` objects; bare strings are rejected.
    if result and result.file_patterns ~= nil and type(result.file_patterns) == "table" then
        for i, entry in ipairs(result.file_patterns) do
            if type(entry) == "table" and type(entry[1]) == "string" then
                local mode = resolve_mode_ref(entry[2])
                if mode ~= nil then
                    file_patterns[#file_patterns + 1] = { entry[1], mode }
                else
                    log.error("config", "file_patterns entry must reference a mode object", {
                        index = i,
                        pattern = entry[1],
                        mode_ref = tostring(entry[2]),
                    })
                end
            else
                log.error("config", "invalid file_patterns entry", { index = i })
            end
        end
    end

    -- Parse global keybinding overrides
    if result and result.keybindings ~= nil and type(result.keybindings) == "table" then
        for chord, action in pairs(result.keybindings) do
            if
                type(chord) == "string" and (type(action) == "string" or type(action) == "function")
            then
                keybindings[chord] = action
            end
        end
    end

    -- Colorscheme: name or absolute path to a base16 YAML theme file.
    -- nil → built-in gruvbox-dark-medium fallback. Resolved in main.lua.
    local colorscheme = nil
    if result and type(result.colorscheme) == "string" then
        colorscheme = result.colorscheme
    end

    -- Concept → base-slot overrides (e.g. { keyword = "base0D",
    -- modeline_bg = "base02" }). Lets the user remap how concepts
    -- (syntax AND UI chrome) draw from the active scheme's 16 slots
    -- without editing the scheme file. Parsed to { concept → 0x0N }.
    local concept_slots = nil
    if result and type(result.concept_slots) == "table" then
        concept_slots = parse_concept_slots(result.concept_slots)
    end

    -- Margin: maximum text render width. When the window is wider than
    -- this, the gutter + text column is centered within the window with
    -- the text left-aligned inside it. nil or <=0 → no margin (fill the
    -- available width, current behavior). Set in init.lua as `margin = 80`.
    local margin = nil
    if result and type(result.margin) == "number" then
        local m = math.floor(result.margin)
        if m > 0 then
            margin = m
        end
    end

    -- Mirror prefix: clone the ctrl-x prefix subtree under this token
    -- (e.g. "alt-q") so terminals that swallow bare C-x (Ghostty) still
    -- reach the family. nil → no mirroring. Set in init.lua as
    -- `mirror_prefix = "alt-q"`.
    local mirror_prefix = nil
    if result and type(result.mirror_prefix) == "string" then
        local mp = result.mirror_prefix:gsub("^%s+", ""):gsub("%s+$", "")
        if mp ~= "" then
            mirror_prefix = mp
        end
    end

    return setmetatable({
        modes = modes,
        file_patterns = file_patterns,
        keybindings = keybindings,
        colorscheme = colorscheme,
        concept_slots = concept_slots,
        margin = margin,
        mirror_prefix = mirror_prefix,
    }, Config)
end

--- Find all major modes that match the given filepath, in the order
--- defined by file_patterns. Later modes override earlier ones.
--- Returns an empty table if no patterns match. Mode refs are already
--- resolved MajorMode objects (no name lookup at runtime).
---@param filepath string
---@return MajorMode[]
function Config:find_modes(filepath)
    local basename = filepath:match("[^/]+$") or filepath
    local matched = {} ---@type MajorMode[]
    for _, entry in ipairs(self.file_patterns) do
        if basename:match(entry[1]) then
            matched[#matched + 1] = entry[2]
        end
    end
    return matched
end

return Config
