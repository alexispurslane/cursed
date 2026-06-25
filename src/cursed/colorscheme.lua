--- Base16 colorscheme loader.
---
--- Reads theme files in the upstream base16 YAML format — flat lines
--- like `base0D: "83a598"`. No YAML library is pulled in: scheme files
--- are aggressively simple (flat key/value pairs with quoted hex
--- string values), so a tiny line scanner that matches
--- `base<XX>: "<RRGGBB>"` handles every real-world base16 scheme. It
--- also incidentally accepts TOML (`base0D = "83a598"`) since the line
--- shape is identical.
---
--- Only the 16 base slots (base00–base0F) are used. Tinted/base24
--- schemes with additional base10–base17 slots are accepted but the
--- extras are ignored — base16 is the whole story, which keeps the
--- concept→slot mapping a flat one-slot-per-concept table.
---
--- Truecolor is assumed: slots are loaded as 0xRRGGBB ints suitable
--- for termbox's TB_OUTPUT_TRUECOLOR mode. If the terminal lacks
--- truecolor, `quantize_to_256()` maps each slot to the nearest cell
--- of the 256-color cube (216 colors + 24 grays) so the scheme still
--- applies in 256-color mode.

local bit = require("bit")
local ffi = require("ffi")
local tb = require("cursed.tb")
local log = require("cursed.log")

local ColorScheme = {}
ColorScheme.__index = ColorScheme

----------------------------------------------------------------------------------------------------
-- Concept → base slot mapping.
--
-- Every highlighter concept maps to exactly one base slot in
-- base00–base0F. Style modifiers (bold/italic) are applied on top of
-- the resolved slot's color AFTER scheme loading, so they live in a
-- separate table.
----------------------------------------------------------------------------------------------------

-- Base slots are 0xNN (e.g. base0D = 0x0D = 13).
local CONCEPT_SLOTS = {
    -- Syntax concepts (resolved from tree-sitter capture names).
    --
    -- Mirrors tinted-vim's (née base16-vim) practical mapping rather than
    -- the literal base16 spec. The upstream spec puts Variables/Identifier
    -- on base08 (red) and Delimiters on base0F, but tinted-vim deliberately
    -- moves Identifier to base05 (default fg) because "too much RED" and
    -- keeps Delimiters/Operators on base05 per styling.md. Those defaults
    -- are what most base16 users expect, so we follow them. Per-theme
    -- tweaks are still possible via init.lua `concept_slots`.
    --   • Operator → base05 (default fg). styling.md lists base05 for
    --     "Delimiters, Operators".
    --   • Delimiter / punctuation.bracket → base05 so structural
    --     punctuation reads as the default fg.
    --   • Variable / parameter → base05 (default fg), matching
    --     tinted-vim's Identifier group.
    --   • Field / member → base04 (dark fg), matching tinted-vim's
    --     @variable.member.
    --   • Repeat/Label → base0A (yellow), distinct from
    --     Conditional/Keyword → base0E (purple/pink).
    comment = 0x03, -- Comment
    string = 0x0B, -- String
    ["string.escape"] = 0x0C, -- Special (escapes / regex)
    number = 0x09, -- Number / Float
    constant = 0x09, -- Constant
    boolean = 0x09, -- Boolean
    keyword = 0x0E, -- Keyword / Define / Structure
    ["keyword.control"] = 0x0E, -- Conditional / Exception / keyword.return
    ["keyword.repeat"] = 0x0A, -- Repeat (for/while) — tinted-vim Repeat→base0A
    ["keyword.operator"] = 0x05, -- Operator (like Operator → base05)
    ["keyword.function"] = 0x0E, -- Keyword (function-decl keyword)
    ["keyword.import"] = 0x0D, -- Include → base0D (blue)
    ["function"] = 0x0D, -- Function / Include
    ["function.call"] = 0x0D, -- jsFuncCall etc.
    type = 0x0A, -- Type / Typedef / StorageClass
    constructor = 0x0E, -- Structure
    variable = 0x05, -- Identifier (tinted-vim uses base05, not spec's base08)
    ["variable.builtin"] = 0x05, -- builtins drawn as fg (italicized)
    method = 0x0D, -- Function (methods collapse to Function)
    field = 0x04, -- Member/field access (tinted-vim @variable.member)
    ["punctuation.bracket"] = 0x05, -- cssBraces / htmlTag → base05
    ["punctuation.delimiter"] = 0x05, -- Delimiter → base05 per styling.md
    operator = 0x05, -- Operator → base05
    label = 0x0A, -- Label
    attribute = 0x0A, -- csAttribute / html attr → base0A
    preproc = 0x0A, -- PreProc → base0A
    tag = 0x0A, -- Tag
    embedded = 0x0F, -- SpecialChar / embedded language tags
    -- Prose / markdown (nvim-treesitter @text.* vocabulary).
    text = 0x05, -- body text reads as default fg
    ["text.title"] = 0x0E, -- headings → base0E (keyword/pink) so they stand out
    ["text.literal"] = 0x0B, -- code spans / code blocks → base0B (string green)
    ["text.emphasis"] = 0x05, -- italic styling distinguishes it; color stays fg
    ["text.strong"] = 0x05, -- bold styling distinguishes it; color stays fg
    ["text.uri"] = 0x0C, -- links → base0C (string.teal)
    ["text.reference"] = 0x09, -- reference labels → base09 (constant orange)
    ["text.todo"] = 0x08, -- TODO markers → base08 (red)
    -- UI chrome concepts. Resolved the same way as syntax concepts
    -- (slot from this table, style from CONCEPT_STYLE — UI entries
    -- have no style entry so they get 0). Keeping them in the SAME
    -- table as syntax concepts means a single override surface (the
    -- user config) covers both syntax AND chrome coloring.
    default_fg = 0x05, -- base05: default foreground (main text color)
    default_bg = 0x00, -- base00: default background
    line_number = 0x03, -- base03: line-number gutter
    line_number_active = 0x04, -- base04: current-line number
    modeline_fg = 0x00, -- base00: dark text on the modeline
    modeline_bg = 0x04, -- base04: ...on a light-ish status strip
    minibuffer_prompt = 0x0D, -- base0D: blue prompt text
    minibuffer_text = 0x05, -- base05: default fg for typed input
    minibuffer_border = 0x02, -- base02: dim border / separator
    minibuffer_metadata = 0x03, -- base03: dim gray for completion metadata (chord hints)
    cursor_fg = 0x00, -- base00: bg-colored text under the cursor
    cursor_bg = 0x05, -- base05: fg-colored cursor block (reverse video)
    selection_bg = 0x02, -- base02: selection / highlight background
    drop_bg = 0x0A, -- base0A: yellow bg for staged drop markers
    status_message = 0x0B, -- base0B: green informational messages
    status_error = 0x08, -- base08: red error messages
}

-- Capture name → concept. Tree-sitter queries use the standard
-- capture vocabulary (copied verbatim from upstream nvim/Helix). This
-- table collapses them into our ~25 concepts. Anything not listed
-- here falls through to `variable` via the strip-dotted-suffix rule.
local CAPTURE_CONCEPT = {
    ["comment"] = "comment",
    ["comment.documentation"] = "comment",
    ["string"] = "string",
    ["string.escape"] = "string.escape",
    ["string.special"] = "string",
    ["string.special.key"] = "string",
    ["number"] = "number",
    ["constant"] = "constant",
    ["constant.builtin"] = "constant",
    ["boolean"] = "boolean",
    ["keyword"] = "keyword",
    ["keyword.control"] = "keyword.control",
    ["keyword.conditional"] = "keyword.control",
    ["conditional"] = "keyword.control",
    ["keyword.repeat"] = "keyword.repeat",
    ["repeat"] = "keyword.repeat",
    ["keyword.return"] = "keyword.control",
    ["keyword.operator"] = "keyword.operator",
    ["keyword.function"] = "keyword.function",
    ["keyword.import"] = "keyword.import",
    ["keyword.debug"] = "keyword",
    ["keyword.exception"] = "keyword.control",
    ["keyword.modifier"] = "keyword",
    ["function"] = "function",
    ["function.call"] = "function.call",
    ["function.builtin"] = "function",
    ["function.macro"] = "function",
    ["function.special"] = "function",
    ["function.method"] = "method",
    ["method"] = "method",
    ["method.call"] = "method",
    ["constructor"] = "constructor",
    ["type"] = "type",
    ["type.builtin"] = "type",
    ["type.definition"] = "type",
    ["variable"] = "variable",
    ["variable.builtin"] = "variable.builtin",
    ["variable.member"] = "field",
    ["variable.parameter"] = "variable",
    ["field"] = "field",
    ["property"] = "field",
    ["parameter"] = "variable",
    ["punctuation.bracket"] = "punctuation.bracket",
    ["punctuation.delimiter"] = "punctuation.delimiter",
    ["punctuation.special"] = "punctuation.delimiter",
    ["operator"] = "operator",
    ["label"] = "label",
    ["attribute"] = "attribute",
    ["preproc"] = "preproc",
    ["tag"] = "tag",
    ["tag.attribute"] = "attribute",
    ["embedded"] = "embedded",
    ["delimiter"] = "punctuation.delimiter",
    -- Markdown / prose captures (nvim-treesitter @text.* vocabulary).
    ["text"] = "text",
    ["text.title"] = "text.title",
    ["text.literal"] = "text.literal",
    ["text.emphasis"] = "text.emphasis",
    ["text.strong"] = "text.strong",
    ["text.uri"] = "text.uri",
    ["text.reference"] = "text.reference",
    ["text.todo"] = "text.todo",
}

-- Style modifiers layered on top of a concept's color.
-- OR'd into the resolved color int (termbox truecolor style bits:
-- bold=0x01000000, italic=0x08000000).
local CONCEPT_STYLE = {
    ["string.escape"] = tb.bold,
    ["comment"] = tb.italic,
    ["text.emphasis"] = tb.italic,
    ["text.strong"] = tb.bold,
    ["keyword"] = tb.bold,
    ["keyword.control"] = tb.bold,
    ["keyword.function"] = tb.bold,
    ["keyword.operator"] = tb.bold,
    ["variable.builtin"] = tb.italic,
}

----------------------------------------------------------------------------------------------------
-- Parsing.
--
-- Line scan: match `base<XX>: "RRGGBB"` (or 'RRGGBB', optional '#',
-- case-insensitive hex). Anything else on the line is ignored — no
-- nesting awareness, no flow style, no comments parsed (they just
-- don't match the pattern). The full YAML/TOML structure of a real
-- base16 scheme file is irrelevant; only the slot assignments matter.
-- Slots ≥ 0x10 (base10–17, tinted/base24 extras) are ignored.
----------------------------------------------------------------------------------------------------

local SLOT_PAT = "^%s*base([0-9A-Fa-f][0-9A-Fa-f])%s*[:=]%s*[\"']?#?(%x%x%x%x%x%x)[\"']?%s*.-$"

--- Parse scheme file text; return { [slot_int] = 0xRRGGBB }.
--- Slots ≥ 0x10 (base24/tinted extras) are filtered out — only
--- base00–base0F are kept.
---@param text string
---@return table slots  mapping 0xNN → 0xRRGGBB
local function parse_text(text)
    local slots = {}
    for line in text:gmatch("[^\r\n]*") do
        local shex, chex = line:match(SLOT_PAT)
        if shex and chex then
            local slot = tonumber(shex, 16)
            if slot <= 0x0F then
                slots[slot] = tonumber(chex, 16)
            end
        end
    end
    return slots
end

----------------------------------------------------------------------------------------------------
-- 256-color quantization fallback (for terminals without truecolor).
-- Maps a truecolor RGB to the nearest cell of the 256-color palette:
-- the 6×6×6 cube (indices 16..231) plus 24 grays (232..255).
----------------------------------------------------------------------------------------------------

local CUBE_VALS = { 0x00, 0x5F, 0x87, 0xAF, 0xD7, 0xFF }

-- Nearest cube component index (0..5) for a 0..255 channel value.
local function nearest_cube_idx(v)
    local best, bestd = 0, math.huge
    for i = 1, #CUBE_VALS do
        local d = math.abs(CUBE_VALS[i] - v)
        if d < bestd then
            bestd = d
            best = i - 1
        end
    end
    return best
end

--- Quantize a 0xRRGGBB truecolor to a 256-color palette index.
---@param rgb integer 0xRRGGBB
---@return integer palette_index (0x00..0xFF)
local function quantize_256(rgb)
    local r = bit.rshift(rgb, 16) % 256
    local g = bit.rshift(rgb, 8) % 256
    local b = rgb % 256
    local ri = nearest_cube_idx(r)
    local gi = nearest_cube_idx(g)
    local bi = nearest_cube_idx(b)
    local cube_idx = 16 + 36 * ri + 6 * gi + bi
    -- Nearest gray (steps of 10 from 8 to 238): index 232 + k.
    local gray_best, gray_bestd = 232, math.huge
    for k = 0, 23 do
        local v = 8 + 10 * k
        local d = math.abs(v - (r + g + b) / 3)
        if d < gray_bestd then
            gray_bestd = d
            gray_best = 232 + k
        end
    end
    -- Compare cube vs gray by squared RGB distance; pick the closer.
    local cr, cg, cb = CUBE_VALS[ri + 1], CUBE_VALS[gi + 1], CUBE_VALS[bi + 1]
    local cube_d = (cr - r) ^ 2 + (cg - g) ^ 2 + (cb - b) ^ 2
    local gv = 8 + 10 * (gray_best - 232)
    local gray_d = (gv - r) ^ 2 + (gv - g) ^ 2 + (gv - b) ^ 2
    if gray_d < cube_d then
        return gray_best
    end
    return cube_idx
end

----------------------------------------------------------------------------------------------------
-- ColorScheme object.
--
-- `slots` is keyed by base-slot (0xNN), values are the resolved color
-- ints as termbox expects them in the active output mode (truecolor =
-- 0xRRGGBB; 256 mode = a 0x00..0xFF index). `color(concept)` returns
-- the termbox fg attr (color OR'd with style bits). UI chrome concepts
-- (line_number, modeline_fg, cursor_bg, …) live in the SAME table;
-- they have no CONCEPT_STYLE entry so `color()` returns them with no
-- style bits, which is what the chrome wants.
----------------------------------------------------------------------------------------------------

---@class ColorScheme
---@field name string
---@field slots table<integer, integer> base-slot (0xNN) → fg color int
---@field concept_slots table<string, integer> concept → 0x0N (defaults merged with config overrides)
---@field truecolor boolean whether slots are 0xRRGGBB (true) or 256-index (false)
---@field active ColorScheme|nil the currently-loaded scheme (set by main.lua / load-theme)
---@field color fun(self: ColorScheme, concept: string): integer
---@field resolve_capture fun(self: ColorScheme, capture: string): integer

--- Resolve a base slot to its termbox color int (no style bits).
--- Falls back to base05 (default fg) then 0 if the slot is absent.
---@param slot integer 0xNN
---@return integer color
function ColorScheme:slot_color(slot)
    return self.slots[slot] or self.slots[0x05] or 0
end

--- Resolve a concept to a termbox fg attr (color OR'd with style).
--- Works for both syntax concepts AND UI chrome concepts (which have
--- no style entry → style 0). The concept→slot lookup uses this
--- scheme instance's `concept_slots` table (CONCEPT_SLOTS defaults
--- merged with the user's config overrides at load time).
---@param concept string
---@return integer fg
function ColorScheme:color(concept)
    local slot = self.concept_slots[concept] or CONCEPT_SLOTS[concept] or 0x08
    local color = self:slot_color(slot)
    local style = CONCEPT_STYLE[concept] or 0
    return bit.bor(color, style)
end

--- Resolve a tree-sitter capture name → concept → fg attr.
--- Falls back through dotted-suffix stripping for captures not in the
--- normalization table, then to `variable` as the last resort.
---@param capture string
---@return integer fg
function ColorScheme:resolve_capture(capture)
    local concept = CAPTURE_CONCEPT[capture]
    if concept == nil then
        -- Strip dotted suffixes: "type.builtin.foo" → "type.builtin" → "type"
        local n = capture
        while true do
            local got = CAPTURE_CONCEPT[n]
            if got then
                concept = got
                break
            end
            local dot = n:match("()%.%S*$")
            if not dot then
                concept = "variable"
                break
            end
            n = n:sub(1, dot - 1)
        end
    end
    return self:color(concept or "variable")
end

--- Build a ColorScheme from parsed slots + metadata.
--- `overrides` (concept → 0x0N) is merged onto the default
--- CONCEPT_SLOTS to form this instance's `concept_slots` table, so
--- user config remappings apply per-scheme. Falls back to the
--- module-level `ColorScheme.config_overrides` (set by main.lua at
--- startup) when `overrides` is nil — this keeps the `load-theme`
--- command honoring config remappings without threading the table
--- through every call.
---@param slots table<integer, integer>
---@param name string
---@param truecolor boolean
---@param overrides table<string, integer>|nil concept → 0x0N
---@return ColorScheme
local function make_scheme(slots, name, truecolor, overrides)
    if not truecolor then
        local q = {}
        for slot, rgb in pairs(slots) do
            q[slot] = quantize_256(rgb)
        end
        slots = q
    end
    -- Resolve concept→slot for this instance: defaults, then config
    -- overrides (if any), then any explicit per-call overrides.
    local concept_slots = CONCEPT_SLOTS
    local cfg = ColorScheme.config_overrides
    if cfg or overrides then
        concept_slots = {}
        for k, v in pairs(CONCEPT_SLOTS) do
            concept_slots[k] = v
        end
        if cfg then
            for k, v in pairs(cfg) do
                concept_slots[k] = v
            end
        end
        if overrides then
            for k, v in pairs(overrides) do
                concept_slots[k] = v
            end
        end
    end
    return setmetatable({
        name = name or "(unnamed)",
        slots = slots,
        concept_slots = concept_slots,
        truecolor = truecolor,
    }, ColorScheme)
end

----------------------------------------------------------------------------------------------------
-- Built-in fallback scheme (base16 Gruvbox dark).
-- Used when no theme file is found OR the loaded file is incomplete
-- (<16 slots). Mirrors the standard tinted-theming base16-gruvbox-dark
-- palette, so the editor lights up correctly even with empty config.
----------------------------------------------------------------------------------------------------

local BUILTIN_GRUVBOX = [[
scheme: "Gruvbox dark (built-in fallback)"
author: "Tinted Theming (https://github.com/tinted-theming), morhetz (https://github.com/morhetz/gruvbox)"
base00: "282828"
base01: "3c3836"
base02: "504945"
base03: "665c54"
base04: "928374"
base05: "ebdbb2"
base06: "fbf1c7"
base07: "f9f5d7"
base08: "cc241d"
base09: "d65d0e"
base0A: "d79921"
base0B: "98971a"
base0C: "689d6a"
base0D: "458588"
base0E: "b16286"
base0F: "9d0006"
]]

--- Load a colorscheme from a file path. Returns the built-in gruvbox
--- fallback if the file is missing, unreadable, or has <16 distinct
--- base slots. `truecolor` selects between 0xRRGGBB (true) and 256-idx.
--- `overrides` (concept → 0x0N) defaults to `ColorScheme.config_overrides`
--- so user-config concept remappings apply automatically; pass an empty
--- table to suppress them for a specific load.
---@param path string|nil  nil → use built-in fallback directly
---@param truecolor boolean
---@param overrides table<string, integer>|nil concept → 0x0N
---@return ColorScheme
local function load(path, truecolor, overrides)
    local text = nil
    local name = "gruvbox-dark (built-in)"
    if path ~= nil then
        local f = io.open(path, "r")
        if f ~= nil then
            text = f:read("*a")
            f:close()
            name = path:match("[^/]+$") or path
            name = name:gsub("%.[^.]+$", "")
        else
            log.warn("colorscheme", "scheme file not found, using built-in", { path = path })
        end
    end
    if text == nil then
        text = BUILTIN_GRUVBOX
    end
    local slots = parse_text(text)
    -- minimum usable: base00 through base0F present (16 slots)
    local count = 0
    for _ in pairs(slots) do
        count = count + 1
    end
    if count < 16 then
        log.warn("colorscheme", "loaded scheme has <16 slots, falling back", {
            path = path or "(built-in)",
            slots = count,
        })
        slots = parse_text(BUILTIN_GRUVBOX)
        name = "gruvbox-dark (built-in, scheme incomplete)"
    end
    return make_scheme(slots, name, truecolor, overrides)
end

ColorScheme.load = load
ColorScheme.parse_text = parse_text
ColorScheme.quantize_256 = quantize_256

----------------------------------------------------------------------------------------------------
-- Scheme discovery + resolution.
--
-- Exposed here so the `load-theme` command can both list available
-- schemes and resolve a bare name to a file path consistently with
-- startup.
----------------------------------------------------------------------------------------------------

local SCHEME_EXTS = { ".yaml", ".yml", ".toml" }

--- Compute the ordered list of directories to search for scheme files.
---@param xdg_cursed string|nil  the user's ~/.config/cursed directory
---@return string[] dirs
function ColorScheme.search_dirs(xdg_cursed)
    local dirs = {}
    if xdg_cursed then
        dirs[#dirs + 1] = xdg_cursed .. "/themes"
    end
    dirs[#dirs + 1] = "themes"
    dirs[#dirs + 1] = "/usr/local/share/cursed/themes"
    dirs[#dirs + 1] = "/usr/share/cursed/themes"
    return dirs
end

--- Resolve the user's cursed config dir (~/.config/cursed or
--- $XDG_CONFIG_HOME/cursed). Returns nil if neither HOME nor
--- XDG_CONFIG_HOME is set.
---@return string|nil
function ColorScheme.config_dir()
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg == nil or xdg == "" then
        local home = os.getenv("HOME")
        if home == nil then
            return nil
        end
        xdg = home .. "/.config"
    end
    return xdg .. "/cursed"
end

--- Resolve a scheme setting (bare name or absolute path) to an
--- existing file path, searching the standard dirs. Returns nil if
--- the setting is nil; returns a best-guess path (that won't load)
--- if no file is found so the caller can surface a clean error.
---@param scheme_setting string|nil name or absolute path
---@param xdg_cursed string|nil  result of config_dir() (precomputed)
---@return string|nil path
function ColorScheme.resolve_path(scheme_setting, xdg_cursed)
    if scheme_setting == nil then
        return nil
    end
    if scheme_setting:sub(1, 1) == "/" then
        return scheme_setting
    end
    local name = scheme_setting:gsub("%.[^.]+$", "")
    for _, dir in ipairs(ColorScheme.search_dirs(xdg_cursed)) do
        for _, ext in ipairs(SCHEME_EXTS) do
            local p = dir .. "/" .. name .. ext
            local f = io.open(p, "r")
            if f then
                f:close()
                return p
            end
        end
    end
    return (xdg_cursed or "themes") .. "/" .. name .. ".yaml"
end

--- List all available scheme names across the search dirs (deduped,
--- sorted). Each entry is the bare scheme name (no extension). Used
--- by the `load-theme` command's completer.
---@param xdg_cursed string|nil
---@return string[] names
function ColorScheme.list_names(xdg_cursed)
    -- posix_ffi is always available in the cursed runtime; required
    -- lazily so the colorscheme module is unit-testable standalone.
    local ok, pffi = pcall(require, "cursed.posix_ffi")
    if not ok then
        return {}
    end
    local C = pffi.C
    local seen = {}
    local names = {}
    for _, dir in ipairs(ColorScheme.search_dirs(xdg_cursed)) do
        local cdir = C.opendir(dir)
        if cdir ~= nil then
            local ent = C.readdir(cdir)
            while ent ~= nil do
                if ent.d_type == pffi.DT_REG then
                    local nm = ffi.string(ent.d_name)
                    -- Accept .yaml/.yml/.toml (case-insensitive). Lua
                    -- patterns don't support `ya?ml` inside an
                    -- alternation reliably, so match each form.
                    local stem = nm:match("^(.+)%.[Yy][Aa]?[Mm][Ll]$")
                        or nm:match("^(.+)%.[Tt][Oo][Mm][Ll]$")
                    if stem and not seen[stem] then
                        seen[stem] = true
                        names[#names + 1] = stem
                    end
                end
                ent = C.readdir(cdir)
            end
            C.closedir(cdir)
        end
    end
    table.sort(names)
    return names
end

--- Apply a scheme by name or absolute path, replacing the active one.
--- `truecolor` should match the terminal's current output mode. Sets
--- `ColorScheme.active` so the next render picks up the new colors.
--- Returns the loaded ColorScheme (the built-in fallback on failure)
--- plus a status string the caller can surface to the user.
---@param setting string name or absolute path
---@param truecolor boolean
---@return ColorScheme scheme
---@return string status
function ColorScheme.apply(setting, truecolor)
    local xdg = ColorScheme.config_dir()
    local path = ColorScheme.resolve_path(setting, xdg)
    local scheme = load(path, truecolor)
    ColorScheme.active = scheme
    -- Bump the generation so the highlight cache (which keys on this)
    -- invalidates and the new scheme's colors get re-resolved on the
    -- next render.
    ColorScheme.generation = ColorScheme.generation + 1
    local status = "theme: " .. scheme.name
    if path == nil or path == "" then
        status = "theme: " .. scheme.name .. " (built-in fallback)"
    end
    return scheme, status
end

--- Generation counter, bumped every time the active scheme changes.
--- Folded into the view's highlight-cache key so a live theme switch
--- invalidates cached spans (which hold the OLD scheme's resolved colors).
ColorScheme.generation = 0

--- User-config concept→slot overrides (set by main.lua at startup from
--- `config.concept_slots`). Consulted by `make_scheme` so both the
--- startup scheme and live `load-theme` switches apply the remappings.
ColorScheme.config_overrides = nil

ColorScheme.SCHEME_EXTS = SCHEME_EXTS

return ColorScheme
