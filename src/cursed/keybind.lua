--- Keybind engine: chord parsing, event-to-token mapping, and trie-based key binding.
---
--- Usage:
---   local keybind = require("cursed.keybind")
---
---   local tokens = keybind.parse_chord("ctrl-x alt-y z")
---   local trie = keybind.Trie.build({
---     ["ctrl-x ctrl-s"] = function() save() end,
---     ["ctrl-q"]        = function() quit() end,
---   })
---   local result = trie:lookup(tokens)

local bit = require("bit")
local tonumber = tonumber

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
-- Trie class
----------------------------------------------------------------------------------------------------

---@class keybind.Trie
---@field action string|function|nil command name (string) or function to call if this node is a complete chord
---@field children table<string, keybind.Trie> child nodes keyed by token
local Trie = {}
Trie.__index = Trie

--- Create an empty trie node.
---@return keybind.Trie
function Trie:new()
    return setmetatable({ action = nil, children = {} }, self)
end

--- Add a chord (sequence of tokens) with its action to the trie.
---@param tokens string[] array of key token strings (from parse_chord)
---@param act string|function command name or function to call when the full chord is matched
function Trie:add(tokens, act)
    local node = self
    for i = 1, #tokens do
        local tok = tokens[i]
        if not node.children[tok] then
            node.children[tok] = Trie:new()
        end
        node = node.children[tok]
    end
    node.action = act
end

--- Walk the trie with a sequence of tokens.
--- Walk the trie with a sequence of tokens or a single token string.
---@param tokens string|string[] key token string or array of key token strings
---@return function|nil action
---@return boolean continued true if a longer chord might match
function Trie:lookup(tokens)
    local node = self
    for i = 1, #tokens do
        local tok = tokens[i]
        local child = node.children[tok]
        if not child then
            return nil, false
        end
        node = child
    end
    if node.action then
        return node.action, next(node.children) ~= nil
    end
    return nil, next(node.children) ~= nil
end

--- Reset the trie (no-op: the trie is stateless).
function Trie:reset() end

--- Walk the trie and return the action and whether more keys could extend.
---@param tokens string|string[]
---@return function|nil action
---@return boolean continued
function Trie:lookup_with_continuation(tokens)
    local node = self
    for i = 1, #tokens do
        local tok = tokens[i]
        local child = node.children[tok]
        if not child then
            return nil, false
        end
        node = child
    end
    if node.action then
        return node.action, next(node.children) ~= nil
    end
    return nil, next(node.children) ~= nil
end

--- Build a trie from a bindings table.
---@param bindings table<string, string|function> chord_string → command name or function
---@return keybind.Trie
function Trie.build(bindings)
    local root = Trie:new()
    for chord_str, func in pairs(bindings) do
        local tokens, err = parse_chord(chord_str)
        if not tokens then
            io.stderr:write(("keybind: skipping bad chord %q: %s\n"):format(chord_str, err))
            goto continue
        end
        root:add(tokens, func)
        ::continue::
    end
    return root
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
local function format_chord(chord_str)
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
-- Module export
----------------------------------------------------------------------------------------------------

return {
    parse_chord = parse_chord,
    event_to_token = event_to_token,
    is_modified = is_modified,
    format_chord = format_chord,
    build_chord_for_command = build_chord_for_command,
    Trie = Trie,
}
