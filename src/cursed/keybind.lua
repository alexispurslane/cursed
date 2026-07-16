--- Keybind engine: chord parsing, event-to-token mapping, and nested-keymap key binding.
---
--- Usage:
---   local keybind = require("cursed.keybind")
---
---   local tokens = keybind.parse_chord("ctrl-x alt-y z")
---   local km = keybind.Keymap.shallow_copy({
---     ["ctrl-x"] = { ["ctrl-s"] = "save_file", ["ctrl-c"] = "quit" },
---     ["ctrl-q"] = "quit",
---   })
---   local action = km["ctrl-x"]["ctrl-s"]

local bit = require("bit")
local tonumber = tonumber
local log = require("cursed.log")

----------------------------------------------------------------------------------------------------
-- Constants (matching termbox2.h)
----------------------------------------------------------------------------------------------------

local TB_EVENT_KEY = 1
local TB_MOD_ALT = 1
local TB_MOD_CTRL = 2
local TB_MOD_SHIFT = 4

-- Special key constants
local KEY_F1 = 0xFFFF - 0
local KEY_F2 = 0xFFFF - 1
local KEY_F3 = 0xFFFF - 2
local KEY_F4 = 0xFFFF - 3
local KEY_F5 = 0xFFFF - 4
local KEY_F6 = 0xFFFF - 5
local KEY_F7 = 0xFFFF - 6
local KEY_F8 = 0xFFFF - 7
local KEY_F9 = 0xFFFF - 8
local KEY_F10 = 0xFFFF - 9
local KEY_F11 = 0xFFFF - 10
local KEY_F12 = 0xFFFF - 11
local KEY_INSERT = 0xFFFF - 12
local KEY_DELETE = 0xFFFF - 13
local KEY_HOME = 0xFFFF - 14
local KEY_END = 0xFFFF - 15
local KEY_PGUP = 0xFFFF - 16
local KEY_PGDN = 0xFFFF - 17
local KEY_ARROW_UP = 0xFFFF - 18
local KEY_ARROW_DOWN = 0xFFFF - 19
local KEY_ARROW_LEFT = 0xFFFF - 20
local KEY_ARROW_RIGHT = 0xFFFF - 21
local KEY_BACK_TAB = 0xFFFF - 22

----------------------------------------------------------------------------------------------------
-- Key-to-token mapping for event_to_token
----------------------------------------------------------------------------------------------------

--- Map from ev.key value to token string for special keys.
--- Ctrl+letter range [0x01..0x1A] is handled in event_to_token logic.
local key_to_token = {
    [0x1B] = "escape", -- TB_KEY_ESC / CTRL-[
    [0x20] = "space", -- TB_KEY_SPACE
    [0x7F] = "backspace", -- TB_KEY_BACKSPACE2 (macOS)
    -- Function keys
    [KEY_F1] = "f1",
    [KEY_F2] = "f2",
    [KEY_F3] = "f3",
    [KEY_F4] = "f4",
    [KEY_F5] = "f5",
    [KEY_F6] = "f6",
    [KEY_F7] = "f7",
    [KEY_F8] = "f8",
    [KEY_F9] = "f9",
    [KEY_F10] = "f10",
    [KEY_F11] = "f11",
    [KEY_F12] = "f12",
    -- Navigation/editing keys
    [KEY_INSERT] = "insert",
    [KEY_DELETE] = "delete",
    [KEY_HOME] = "home",
    [KEY_END] = "end",
    [KEY_PGUP] = "pageup",
    [KEY_PGDN] = "pagedown",
    -- Arrow keys
    [KEY_ARROW_UP] = "up",
    [KEY_ARROW_DOWN] = "down",
    [KEY_ARROW_LEFT] = "left",
    [KEY_ARROW_RIGHT] = "right",
    -- Shift+Tab (termbox2 emits a separate key code)
    [KEY_BACK_TAB] = "shift-tab",
}

----------------------------------------------------------------------------------------------------
-- Named keys set (used by parse_chord)
----------------------------------------------------------------------------------------------------

local named_keys = {
    backspace = true,
    enter = true,
    tab = true,
    escape = true,
    space = true,
    delete = true,
    insert = true,
    home = true,
    ["end"] = true,
    pageup = true,
    pagedown = true,
    up = true,
    down = true,
    left = true,
    right = true,
    f1 = true,
    f2 = true,
    f3 = true,
    f4 = true,
    f5 = true,
    f6 = true,
    f7 = true,
    f8 = true,
    f9 = true,
    f10 = true,
    f11 = true,
    f12 = true,
}

----------------------------------------------------------------------------------------------------
-- Ctrl+letter normalizations (used by parse_chord)
----------------------------------------------------------------------------------------------------

local ctrl_normalizations = {
    ["ctrl-h"] = "backspace",
    ["ctrl-m"] = "enter",
    ["ctrl-i"] = "tab",
    ["ctrl-["] = "escape",
}

----------------------------------------------------------------------------------------------------
-- parse_chord
----------------------------------------------------------------------------------------------------

--- Parse a chord string into an array of key tokens.
---@param chord_str string whitespace-separated chord components
---@return string[]|nil tokens array of key token strings
---@return string|nil err error message on failure
local function parse_chord(chord_str)
    local tokens = {}
    for component in chord_str:gmatch("%S+") do
        local lower = component:lower()

        -- ctrl- prefix
        if lower:find("^ctrl%-") then
            local normalized = ctrl_normalizations[lower]
            if normalized then
                tokens[#tokens + 1] = normalized
            else
                local letter = lower:sub(6)
                local is_ctrl_key = (
                    #letter == 1 and (letter:match("^[a-z]$") or letter:match("^[_\\^]$"))
                ) or letter == "space"
                if is_ctrl_key then
                    tokens[#tokens + 1] = "ctrl-" .. letter
                else
                    return nil, ("unknown key: %s"):format(component)
                end
            end
            -- alt- prefix
        elseif lower:find("^alt%-") then
            local rest = component:sub(5) -- preserve case/shift: e.g. "alt-<" not "alt-lt"
            if #rest == 1 then
                tokens[#tokens + 1] = "alt-" .. rest
            elseif #rest > 1 and named_keys[lower:sub(5)] then
                tokens[#tokens + 1] = "alt-" .. lower:sub(5)
            else
                return nil, ("unknown key: %s"):format(component)
            end
            -- shift- prefix (only valid with named keys)
        elseif lower:find("^shift%-") then
            local rest = lower:sub(7)
            if named_keys[rest] then
                tokens[#tokens + 1] = "shift-" .. rest
            else
                return nil, ("unknown key: %s"):format(component)
            end
            -- Named key
        elseif named_keys[lower] then
            tokens[#tokens + 1] = lower
            -- Single printable character
        elseif #component == 1 then
            tokens[#tokens + 1] = component
        else
            return nil, ("unknown key: %s"):format(component)
        end
    end

    if #tokens == 0 then
        return nil, "empty chord string"
    end

    return tokens
end

----------------------------------------------------------------------------------------------------
-- event_to_token
----------------------------------------------------------------------------------------------------

--- Convert a termbox2 struct tb_event cdata into a key token string.
---@param ev any struct tb_event cdata
---@return string|nil token nil if the event is not a mappable key event
local function event_to_token(ev)
    if tonumber(ev.type) ~= TB_EVENT_KEY then
        return nil
    end

    local key = tonumber(ev.key)
    ---@cast key integer
    local ch = tonumber(ev.ch)
    ---@cast ch integer
    local mod = tonumber(ev.mod)
    ---@cast mod integer

    -- Ctrl+letter range [0x01..0x1A]. Termbox flags these with TB_MOD_CTRL
    -- (a raw control char always carries an implicit Ctrl); we therefore
    -- only honor the Shift/Alt bits here to build "shift-"/"alt-" prefixes.
    -- A plain Enter (\r) arrives as key=0x0d with mod=CTRL and must resolve
    -- to the bare "enter" token, NOT "ctrl-enter".
    if key >= 0x01 and key <= 0x1A then
        local base
        if key == 0x08 then
            base = "backspace"
        elseif key == 0x09 then
            base = "tab"
        elseif key == 0x0D then
            base = "enter"
        else
            base = "ctrl-" .. string.char(key + 0x60)
        end
        if bit.band(mod, TB_MOD_SHIFT) ~= 0 and not base:find("^shift%-") then
            base = "shift-" .. base
        end
        if bit.band(mod, TB_MOD_ALT) ~= 0 and not base:find("^alt%-") then
            base = "alt-" .. base
        end
        return base
    end

    if key == 0x1C then
        return "ctrl-\\"
    end
    if key == 0x1D then
        return "ctrl-]"
    end
    if key == 0x1E then
        return "ctrl-^"
    end
    if key == 0x1F then
        return "ctrl-_"
    end

    local token = key_to_token[key]
    if token then
        if bit.band(mod, TB_MOD_CTRL) ~= 0 and token == "space" then
            return "ctrl-space"
        end
        -- Alt+named-key (e.g. Alt+Up/Down/Enter): build an alt- prefixed
        -- token so chords like "alt-up" / "alt-down" / "alt-enter" can
        -- be bound. (Terminals vary in how they encode Alt+named keys;
        -- termbox2 surfaces it via the mod bit, which we honor here.)
        if bit.band(mod, TB_MOD_ALT) ~= 0 then
            return "alt-" .. token
        end
        if bit.band(mod, TB_MOD_SHIFT) ~= 0 and not token:find("^shift%-") then
            return "shift-" .. token
        end
        return token
    end

    if key == 0 and ch == 0 and bit.band(mod, TB_MOD_CTRL) ~= 0 then
        return "ctrl-space"
    end

    if key == 0 and ch ~= 0 then
        if bit.band(mod, TB_MOD_ALT) ~= 0 then
            local c = string.char(ch)
            return "alt-" .. c
        end
        if ch == 0x20 then
            return "space"
        end
        return string.char(ch)
    end

    return nil
end

----------------------------------------------------------------------------------------------------
-- is_modified
----------------------------------------------------------------------------------------------------

--- Return true if the event is a modified/control key (should be looked up in the chord trie)
--- vs a printable key (falls through to editing when key_state is empty).
---@param ev any struct tb_event cdata
---@return boolean
local function is_modified(ev)
    if tonumber(ev.type) ~= TB_EVENT_KEY then
        return false
    end
    return tonumber(ev.key) ~= 0 or tonumber(ev.mod) ~= 0
end

----------------------------------------------------------------------------------------------------
-- Keymap API (Emacs-style nested keymap tables)
----------------------------------------------------------------------------------------------------

---@section keybind.Keymap

-- Forward declaration for format_chord (defined after the Keymap section
-- but used by Keymap_build_chord_for_command via closure upvalues).
local format_chord

--- Create an empty keymap table.
---@return table
local function Keymap_new()
    return {}
end

--- Add a key binding (sequence of tokens) with its action to a keymap.
--- Walks or creates nested sub-keymaps for each token in the sequence,
--- then sets the final token to the given action. If an intermediate
--- node is currently a command (string/function), it is replaced with
--- an empty table (logged via log.warn).
---@param km table keymap table
---@param tokens string[] array of key token strings (from parse_chord)
---@param action string|function command name or function
local function Keymap_add(km, tokens, action)
    local node = km
    for i = 1, #tokens do
        local tok = tokens[i]
        if i == #tokens then
            node[tok] = action
        else
            if node[tok] == nil then
                node[tok] = {}
            elseif type(node[tok]) ~= "table" then
                log.warn("keybind", "overwriting command with prefix", { token = tok })
                node[tok] = {}
            end
            node = node[tok]
        end
    end
end

--- Add a key binding with base-keymap inheritance.
--- Like Keymap.add, but when a prefix exists in both `mode_km` and
--- `base_km`, the intermediate sub-keymap is wrapped with
--- `setmetatable({}, {__index = base_sub})` so lookups fall through
--- to the base when the mode prefix has no explicit binding.
---@param mode_km table mode-specific keymap
---@param base_km table base keymap
---@param tokens string[] array of key token strings
---@param action string|function command name or function
local function Keymap_add_with_base(mode_km, base_km, tokens, action)
    local node = mode_km
    ---@type table|nil
    local base_node = base_km
    for i = 1, #tokens do
        local tok = tokens[i]
        if i == #tokens then
            node[tok] = action
        else
            if node[tok] == nil then
                node[tok] = {}
            elseif type(node[tok]) ~= "table" then
                log.warn("keybind", "overwriting command with prefix", { token = tok })
                node[tok] = {}
            end
            -- Wrap newly created sub-keymap with __index inheritance
            if base_node and type(base_node[tok]) == "table" then
                local sub = node[tok]
                if type(sub) == "table" and getmetatable(sub) == nil then
                    setmetatable(sub, { __index = base_node[tok] })
                end
            end
            node = node[tok]
            local next_base = base_node and base_node[tok]
            base_node = (type(next_base) == "table") and next_base or nil
        end
    end
end

--- Shallow-copy a keymap spec table. Top-level keys are copied; sub-keymaps
--- are shared by reference (intentional — modes need __index to point at live
--- base subtrees, not stale snapshots).
---@param spec table nested keymap spec
---@return table runtime keymap
local function Keymap_shallow_copy(spec)
    local km = {}
    for k, v in pairs(spec) do
        km[k] = v
    end
    return km
end

--- Recursively walk a nested keymap and build a command_name → formatted
--- chord map (shortest chord per command, ties broken lexicographically).
--- The optional `prefix` is a token array prepended to every chord found
--- (used internally for recursion; external callers may pass nil).
---@param km table nested keymap
---@param prefix string[]|nil optional token prefix for recursive calls
---@return table<string, string> command_name → formatted_chord
local function Keymap_build_chord_for_command(km, prefix)
    local best = {}
    local parts = {}
    if prefix then
        for _, p in ipairs(prefix) do
            parts[#parts + 1] = p
        end
    end

    local function walk(node)
        for tok, val in pairs(node) do
            if type(tok) == "string" then
                if type(val) == "string" then
                    parts[#parts + 1] = tok
                    local chord_str = table.concat(parts, " ")
                    local formatted = format_chord(chord_str)
                    local existing = best[val]
                    if existing == nil
                        or #formatted < #existing
                        or (#formatted == #existing and formatted < existing)
                    then
                        best[val] = formatted
                    end
                    parts[#parts] = nil
                elseif type(val) == "table" then
                    parts[#parts + 1] = tok
                    walk(val)
                    parts[#parts] = nil
                end
                -- Skip functions (no command name)
            end
        end
        -- Walk inherited keys (from __index metatable chain)
        local mt = getmetatable(node)
        local inherited = mt and type(mt.__index) == "table" and mt.__index or nil
        if inherited then
            for tok, val in pairs(inherited) do
                if type(tok) == "string" and rawget(node, tok) == nil then
                    if type(val) == "string" then
                        parts[#parts + 1] = tok
                        local chord_str = table.concat(parts, " ")
                        local formatted = format_chord(chord_str)
                        local existing = best[val]
                        if existing == nil
                            or #formatted < #existing
                            or (#formatted == #existing and formatted < existing)
                        then
                            best[val] = formatted
                        end
                        parts[#parts] = nil
                    elseif type(val) == "table" then
                        parts[#parts + 1] = tok
                        walk(val)
                        parts[#parts] = nil
                    end
                end
            end
        end
    end

    walk(km)
    return best
end

----------------------------------------------------------------------------------------------------
-- deep_copy (deep-copy a keymap table)
----------------------------------------------------------------------------------------------------

--- Deep-copy a keymap table, recursively copying nested sub-keymaps
--- (preserving metatables for __index inheritance).
---@param t table
---@return table
local function deep_copy(t)
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = deep_copy(v)
        else
            copy[k] = v
        end
    end
    return setmetatable(copy, getmetatable(t))
end

----------------------------------------------------------------------------------------------------
-- build_handler (transient key handler from a flat bindings table)
----------------------------------------------------------------------------------------------------

--- Build a transient key handler from a keybinding map.
--- Returns a function `(editor, token, ch, is_printable) → boolean`
--- suitable for `Editor:push_transient_handler`. The handler uses
--- Keymap internally, so chords (e.g. "ctrl-g", "C-x C-s") are
--- parsed the same way as editor keybindings.
---
--- Usage:
---   editor:push_transient_handler(keybind.handler({
---       ["y"] = function(ed) ed:_promote(); return true end,
---       ["n"] = function(ed) ed:_skip(); return true end,
---       ["ctrl-g"] = function(ed) ed:_cancel(); return true end,
---   }))
---
---@param bindings table<string, function> chord_string → handler(editor): boolean
---@return function handler(editor, token, ch, is_printable): boolean
local function build_handler(bindings)
    local km = Keymap_new()
    for chord_str, func in pairs(bindings) do
        local tokens, err = parse_chord(chord_str)
        if tokens then
            if #tokens == 1 then
                km[tokens[1]] = func
            else
                Keymap_add(km, tokens, func)
            end
        else
            io.stderr:write(("keybind: skipping bad chord %q: %s\n"):format(chord_str, err or "?"))
        end
    end
    return function(editor, token, _, _)
        local action = km[token]
        if action then
            return action(editor)
        end
        return false
    end
end

----------------------------------------------------------------------------------------------------
-- Chord formatting (token form → human-readable, e.g. "C-x C-s")
----------------------------------------------------------------------------------------------------

--- Format a single chord token for display.
--- "ctrl-a" → "C-a", "alt-x" → "M-x", "enter" → "Enter",
--- single chars are kept as-is (preserving case), named keys are title-cased.
--- Emacs-style: the letter after a modifier dash stays lowercase (C-x C-s).
---@param token string
---@return string
local function format_token(token)
    local lower = token:lower()
    if lower:find("^ctrl%-") then
        return "C-" .. token:sub(6)
    elseif lower:find("^alt%-") then
        return "M-" .. token:sub(5)
    elseif lower:find("^shift%-") then
        local rest = token:sub(7)
        return "S-" .. rest:sub(1, 1):upper() .. rest:sub(2)
    elseif #token == 1 then
        return token
    else
        return token:sub(1, 1):upper() .. token:sub(2)
    end
end

--- Format a full chord string (space-separated token form) for display.
--- e.g. "ctrl-x ctrl-s" → "C-x C-s", "ctrl-x (" → "C-x (".
---@param chord_str string
---@return string
function format_chord(chord_str)
    local parts = {}
    for component in chord_str:gmatch("%S+") do
        parts[#parts + 1] = format_token(component)
    end
    return table.concat(parts, " ")
end

--- Build a reverse map command_name → formatted chord from a flat
--- bindings table (chord → action string|function). When a command is
--- bound to multiple chords, the SHORTEST chord (by formatted display
--- length, ties broken lexicographically) is chosen for determinism.
--- Actions that are functions (not command-name strings) are skipped.
---@param bindings table<string, string|function>
---@return table<string, string> command_name → formatted chord
local function build_chord_for_command(bindings)
    local best = {}
    for chord_str, action in pairs(bindings) do
        if type(action) == "string" then
            local formatted = format_chord(chord_str)
            local existing = best[action]
            if
                existing == nil
                or #formatted < #existing
                or (#formatted == #existing and formatted < existing)
            then
                best[action] = formatted
            end
        end
    end
    return best
end

----------------------------------------------------------------------------------------------------
-- Chord mirroring (clone a prefix subtree under a new prefix)
----------------------------------------------------------------------------------------------------

--- Rewrite a chord string whose FIRST component (case-insensitive)
--- matches `from_token` so it instead begins with `to_token`. Returns
--- nil when the chord doesn't start with `from_token`. The remaining
--- components keep their ORIGINAL casing (so "ctrl-x S" → "alt-q S",
--- preserving the shift-capital that parse_chord relies on for
--- alt-letter select motions).
---@param chord_str string
---@param from_token string  first component to replace (e.g. "ctrl-x")
---@param to_token string    replacement first component (e.g. "alt-q")
---@return string|nil mirrored chord, or nil if it doesn't match
local function mirror_chord(chord_str, from_token, to_token)
    local first, rest = chord_str:match("^(%S+)(.*)$")
    if first and first:lower() == from_token:lower() then
        if rest == "" or rest:match("^%s*$") then
            return to_token
        end
        return to_token .. rest
    end
    return nil
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    parse_chord = parse_chord,
    event_to_token = event_to_token,
    is_modified = is_modified,
    format_token = format_token,
    format_chord = format_chord,
    build_chord_for_command = build_chord_for_command,
    mirror_chord = mirror_chord,
    Keymap = {
        new = Keymap_new,
        add = Keymap_add,
        add_with_base = Keymap_add_with_base,
        shallow_copy = Keymap_shallow_copy,
        build_chord_for_command = Keymap_build_chord_for_command,
    },
    deep_copy = deep_copy,
    handler = build_handler,
}
