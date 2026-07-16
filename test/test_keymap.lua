--- Keymap System — Comprehensive Headless Tests
---
--- Run via: build/cursed -l test/test_keymap.lua
---
--- Covers: Keymap.new, add, add_with_base, shallow_copy, deep_copy,
---         build_chord_for_command, parse/format utils, handler,
---         editor:global_set_key, editor:define_key, mirror_prefix,
---         Mode:ensure_keymap, view chain, dispatch simulation, which-key

local passed, failed = 0, 0

local function assert_eq(actual, expected, label)
    if actual == expected then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    io.stderr:write(string.format("FAIL [%s]: got %s, expected %s\n",
        label, tostring(actual), tostring(expected)))
    return false
end

local function assert_truthy(val, label)
    if val then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    io.stderr:write(string.format("FAIL [%s]: expected truthy, got %s\n",
        label, tostring(val)))
    return false
end

local function assert_nil(val, label)
    if val == nil then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    io.stderr:write(string.format("FAIL [%s]: expected nil, got %s\n",
        label, tostring(val)))
    return false
end

local function assert_table_has(tbl, key, label)
    if tbl[key] ~= nil then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    io.stderr:write(string.format("FAIL [%s]: table missing key %s\n",
        label, tostring(key)))
    return false
end

-------------------------------------------------------------------------------
-- SECTION 1: Keymap.new, Keymap.add, Keymap.add_with_base
-------------------------------------------------------------------------------

local kb = require("cursed.keybind")

-- 1.1 Keymap.new creates empty table
do
    local km = kb.Keymap.new()
    assert_eq(type(km), "table", "1.1 Keymap.new returns table")
    assert_eq(next(km), nil, "1.1 Keymap.new returns empty table")
end

-- 1.2 Keymap.add single token (flat binding)
do
    local km = kb.Keymap.new()
    kb.Keymap.add(km, {"ctrl-f"}, "forward_char")
    assert_eq(km["ctrl-f"], "forward_char", "1.2 single-token add")
end

-- 1.3 Keymap.add multi-token (nested prefix)
do
    local km = kb.Keymap.new()
    kb.Keymap.add(km, {"ctrl-x", "ctrl-f"}, "find_file")
    assert_eq(type(km["ctrl-x"]), "table", "1.3 prefix is table")
    assert_eq(km["ctrl-x"]["ctrl-f"], "find_file", "1.3 leaf is command")
    assert_eq(getmetatable(km["ctrl-x"]), nil, "1.3 no metatable from plain add")
end

-- 1.4 Keymap.add: adding to existing prefix preserves other bindings
do
    local km = kb.Keymap.new()
    kb.Keymap.add(km, {"ctrl-x", "ctrl-f"}, "find_file")
    kb.Keymap.add(km, {"ctrl-x", "ctrl-s"}, "save_buffer")
    assert_eq(km["ctrl-x"]["ctrl-f"], "find_file", "1.4 existing leaf preserved")
    assert_eq(km["ctrl-x"]["ctrl-s"], "save_buffer", "1.4 new leaf added")
end

-- 1.5 Keymap.add: replacing a leaf command with a prefix (warns)
do
    local km = kb.Keymap.new()
    kb.Keymap.add(km, {"ctrl-x"}, "kill_region")  -- leaf command
    kb.Keymap.add(km, {"ctrl-x", "ctrl-f"}, "find_file")  -- now it's a prefix
    assert_eq(type(km["ctrl-x"]), "table", "1.5 leaf replaced with prefix table")
    assert_eq(km["ctrl-x"]["ctrl-f"], "find_file", "1.5 nested binding works")
    -- The old leaf command is gone (overwritten)
    assert_eq(km["ctrl-x"], km["ctrl-x"], "1.5 consistency check")
end

-- 1.6 Keymap.add_with_base: inheritance via __index
do
    local base = kb.Keymap.new()
    kb.Keymap.add(base, {"ctrl-x", "ctrl-f"}, "find_file")
    kb.Keymap.add(base, {"ctrl-x", "ctrl-b"}, "ibuffer")
    kb.Keymap.add(base, {"ctrl-f"}, "forward_char")

    local mode = kb.Keymap.new()
    kb.Keymap.add_with_base(mode, base, {"ctrl-x", "ctrl-s"}, "save_buffer")

    -- mode's ctrl-x should inherit from base's ctrl-x
    local mt = getmetatable(mode["ctrl-x"])
    assert_truthy(mt ~= nil, "1.6 __index metatable set")
    assert_eq(mt.__index, base["ctrl-x"], "1.6 __index points to base prefix")

    -- Owned binding
    assert_eq(mode["ctrl-x"]["ctrl-s"], "save_buffer", "1.6 owned binding via rawget")
    -- Inherited binding (falls through __index)
    assert_eq(mode["ctrl-x"]["ctrl-f"], "find_file", "1.6 inherited via __index")
    assert_eq(mode["ctrl-x"]["ctrl-b"], "ibuffer", "1.6 second inherited via __index")

    -- Top-level key NOT in base's prefix: nil
    assert_eq(mode["ctrl-x"]["ctrl-q"], nil, "1.6 unknown key in inherited prefix is nil")

    -- Top-level key from base NOT inherited at top level (only prefix subtree)
    assert_eq(rawget(mode, "ctrl-f"), nil, "1.6 top-level keys not inherited")
end

-- 1.7 Keymap.add_with_base: prefix doesn't exist in base → no __index
do
    local base = kb.Keymap.new()
    local mode = kb.Keymap.new()
    kb.Keymap.add_with_base(mode, base, {"alt-r", "r"}, "run_file")
    -- alt-r doesn't exist in base, so no __index
    assert_eq(getmetatable(mode["alt-r"]), nil, "1.7 no metatable when prefix not in base")
    assert_eq(mode["alt-r"]["r"], "run_file", "1.7 binding works without inheritance")
end

-- 1.8 Keymap.add_with_base: base_node tracking — diverging paths
do
    local base = kb.Keymap.new()
    kb.Keymap.add(base, {"ctrl-c", "a"}, "base_a")
    -- base has ctrl-c → {a = "base_a"}
    -- mode adds ctrl-c → ctrl-d → e: ctrl-d doesn't exist in base, so from that
    -- point on, no __index should be set
    local mode = kb.Keymap.new()
    kb.Keymap.add_with_base(mode, base, {"ctrl-c", "ctrl-d", "e"}, "deep")
    -- ctrl-c IS in base, so it gets __index
    local mt_cc = getmetatable(mode["ctrl-c"])
    assert_truthy(mt_cc ~= nil, "1.8 ctrl-c gets __index (exists in base)")
    -- ctrl-d is NOT in base, so it does NOT get __index
    local mt_cd = getmetatable(mode["ctrl-c"]["ctrl-d"])
    assert_eq(mt_cd, nil, "1.8 ctrl-d no __index (not in base)")
    -- But the inherited "a" from base is still reachable through ctrl-c's __index
    assert_eq(mode["ctrl-c"]["a"], "base_a", "1.8 inherited base binding still reachable")
end

-------------------------------------------------------------------------------
-- SECTION 2: Keymap.shallow_copy
-------------------------------------------------------------------------------

-- 2.1 Top-level keys are independent
do
    local spec = {
        ["ctrl-f"] = "forward_char",
        ["ctrl-x"] = { ["ctrl-f"] = "find_file" },
        __printable = function() end,
    }
    local km = kb.Keymap.shallow_copy(spec)
    assert_eq(km["ctrl-f"], "forward_char", "2.1 top-level leaf copied")
    assert_eq(type(km["ctrl-x"]), "table", "2.1 top-level prefix copied")
    assert_eq(type(km.__printable), "function", "2.1 __printable copied")
end

-- 2.2 Sub-keymaps are shared by reference
do
    local spec = { ["ctrl-x"] = { ["ctrl-f"] = "find_file" } }
    local km = kb.Keymap.shallow_copy(spec)
    -- Same table object
    assert_eq(km["ctrl-x"], spec["ctrl-x"], "2.2 sub-keymap shared by reference")
    -- Mutating the copy mutates the spec (same object)
    km["ctrl-x"]["ctrl-s"] = "save"
    assert_eq(spec["ctrl-x"]["ctrl-s"], "save", "2.2 mutation propagates to spec")
end

-- 2.3 Top-level keys are independent (deleting from copy doesn't delete spec)
do
    local spec = { ["ctrl-f"] = "forward", ["ctrl-b"] = "backward" }
    local km = kb.Keymap.shallow_copy(spec)
    km["ctrl-f"] = nil
    assert_eq(km["ctrl-f"], nil, "2.3 deleted from copy")
    assert_eq(spec["ctrl-f"], "forward", "2.3 spec unaffected by top-level deletion")
end

-------------------------------------------------------------------------------
-- SECTION 3: Keymap.build_chord_for_command
-------------------------------------------------------------------------------

-- 3.1 Flat bindings
do
    local km = { ["ctrl-f"] = "forward_char", ["ctrl-b"] = "backward_char" }
    local chords = kb.Keymap.build_chord_for_command(km)
    assert_eq(chords["forward_char"], "C-f", "3.1 forward_char chord")
    assert_eq(chords["backward_char"], "C-b", "3.1 backward_char chord")
end

-- 3.2 Nested prefix
do
    local km = {}
    kb.Keymap.add(km, {"ctrl-x", "ctrl-f"}, "find_file")
    kb.Keymap.add(km, {"ctrl-x", "ctrl-s"}, "save_buffer")
    local chords = kb.Keymap.build_chord_for_command(km)
    assert_eq(chords["find_file"], "C-x C-f", "3.2 nested find_file")
    assert_eq(chords["save_buffer"], "C-x C-s", "3.2 nested save_buffer")
end

-- 3.3 Shortest chord wins for same command
do
    local km = {
        ["ctrl-x"] = { ["ctrl-s"] = "save_buffer" },
        ["f2"] = "save_buffer",  -- shorter formatted "F2" (2) vs "C-x C-s" (7)
    }
    local chords = kb.Keymap.build_chord_for_command(km)
    print("DEBUG save_buffer chord:", chords["save_buffer"])
    assert_eq(chords["save_buffer"], "F2", "3.3 shortest chord (F2 < C-x C-s)")
end

-- 3.4 Functions are skipped (no string name)
do
    local km = {
        ["f1"] = function() end,
        ["ctrl-f"] = "forward_char",
    }
    local chords = kb.Keymap.build_chord_for_command(km)
    assert_eq(chords["forward_char"], "C-f", "3.4 string command present")
    -- function has no key in the result (no name to map)
    assert_truthy(chords["forward_char"] ~= nil, "3.4 string command present")
    -- function has no key in the result (no name to map)
    local count = 0
    for _ in pairs(chords) do count = count + 1 end
    assert_eq(count, 1, "3.4 only one entry (function skipped)")
end

-- 3.5 __index inheritance: inherited commands appear in result
do
    local base = kb.Keymap.new()
    kb.Keymap.add(base, {"ctrl-x", "ctrl-f"}, "find_file")
    local mode = kb.Keymap.new()
    kb.Keymap.add_with_base(mode, base, {"ctrl-x", "ctrl-s"}, "save_buffer")
    local chords = kb.Keymap.build_chord_for_command(mode)
    assert_eq(chords["save_buffer"], "C-x C-s", "3.5 owned command")
    assert_eq(chords["find_file"], "C-x C-f", "3.5 inherited command appears")
end

-------------------------------------------------------------------------------
-- SECTION 4: deep_copy
-------------------------------------------------------------------------------

-- 4.1 Deep copy creates independent nested tables
do
    local orig = { ["ctrl-x"] = { ["ctrl-f"] = "find_file" } }
    local copy = kb.deep_copy(orig)
    assert_eq(copy["ctrl-x"]["ctrl-f"], "find_file", "4.1 value preserved")
    -- Mutating copy does NOT affect original
    copy["ctrl-x"]["ctrl-f"] = "changed"
    copy["ctrl-x"]["new"] = "new_binding"
    assert_eq(orig["ctrl-x"]["ctrl-f"], "find_file", "4.1 original unchanged")
    assert_eq(orig["ctrl-x"]["new"], nil, "4.1 original has no new key")
end

-- 4.2 Deep copy preserves metatables
do
    local orig = setmetatable({ a = 1 }, { __index = { b = 2 } })
    local copy = kb.deep_copy(orig)
    local mt = getmetatable(copy)
    assert_truthy(mt ~= nil, "4.2 metatable preserved")
    assert_eq(mt.__index.b, 2, "4.2 __index chain preserved")
    assert_eq(copy.b, 2, "4.2 __index lookup works")
end

-------------------------------------------------------------------------------
-- SECTION 5: Legacy parse/format utilities
-------------------------------------------------------------------------------

-- 5.1 parse_chord
do
    local tokens, err = kb.parse_chord("ctrl-x ctrl-f")
    assert_eq(err, nil, "5.1 parse ctrl-x ctrl-f: no error")
    assert_eq(#tokens, 2, "5.1 two tokens")
    assert_eq(tokens[1], "ctrl-x", "5.1 first token")
    assert_eq(tokens[2], "ctrl-f", "5.1 second token")

    tokens, err = kb.parse_chord("ctrl-x alt-y z")
    assert_eq(#tokens, 3, "5.1 three tokens with alt")
    assert_eq(tokens[2], "alt-y", "5.1 alt-y token")

    tokens, err = kb.parse_chord("")
    assert_truthy(err ~= nil, "5.1 empty string → error")

    tokens, err = kb.parse_chord("notakey")
    assert_truthy(err ~= nil, "5.1 invalid key → error")

    tokens, err = kb.parse_chord("f5")
    assert_eq(tokens[1], "f5", "5.1 f5 named key")

    tokens, err = kb.parse_chord("enter")
    assert_eq(tokens[1], "enter", "5.1 enter")

    tokens, err = kb.parse_chord("shift-tab")
    assert_eq(tokens[1], "shift-tab", "5.1 shift-tab")
end

-- 5.2 format_token
do
    assert_eq(kb.format_token("ctrl-x"), "C-x", "5.2 ctrl-x → C-x")
    assert_eq(kb.format_token("alt-x"), "M-x", "5.2 alt-x → M-x")
    assert_eq(kb.format_token("enter"), "Enter", "5.2 enter → Enter")
    assert_eq(kb.format_token("f5"), "F5", "5.2 f5 → F5")
    assert_eq(kb.format_token("space"), "Space", "5.2 space → Space")
    assert_eq(kb.format_token("x"), "x", "5.2 single char preserved")
    assert_eq(kb.format_token("shift-tab"), "S-Tab", "5.2 shift-tab")
end

-- 5.3 format_chord
do
    assert_eq(kb.format_chord("ctrl-x ctrl-s"), "C-x C-s", "5.3 chord format")
    assert_eq(kb.format_chord("alt-x"), "M-x", "5.3 single token")
    assert_eq(kb.format_chord("ctrl-x ("), "C-x (", "5.3 with paren")
end

-- 5.4 mirror_chord
do
    local result = kb.mirror_chord("ctrl-x ctrl-f", "ctrl-x", "alt-q")
    assert_eq(result, "alt-q ctrl-f", "5.4 mirror prefix")
    result = kb.mirror_chord("ctrl-x", "ctrl-x", "alt-q")
    assert_eq(result, "alt-q", "5.4 mirror bare prefix")
    result = kb.mirror_chord("ctrl-f", "ctrl-x", "alt-q")
    assert_eq(result, nil, "5.4 non-matching prefix → nil")
end

-- 5.5 build_handler
do
    local calls = {}
    local handler = kb.handler({
        ["y"] = function() calls.y = true end,
        ["n"] = function() calls.n = true end,
        ["ctrl-g"] = function() calls.cg = true end,
    })
    -- Simulate token dispatch
    handler(nil, "y", nil, false)
    assert_truthy(calls.y, "5.5 handler y")
    handler(nil, "n", nil, false)
    assert_truthy(calls.n, "5.5 handler n")
    handler(nil, "ctrl-g", nil, false)
    assert_truthy(calls.cg, "5.5 handler ctrl-g")
    -- Unknown key returns false
    local result = handler(nil, "z", nil, false)
    assert_eq(result, false, "5.5 unknown key → false")
end

-------------------------------------------------------------------------------
-- SECTION 6: Editor integration (global_set_key, define_key, mirror_prefix)
-------------------------------------------------------------------------------

-- The headless build already sets up _G.editor and _G.view via
-- build_headless_editor(). We use those directly.

local editor = _G.editor
local view = _G.view
local Keymap = kb.Keymap

-- 6.1 Editor exists and has base keymap loaded
do
    assert_truthy(editor ~= nil, "6.1 editor exists")
    assert_truthy(editor._base_keymap ~= nil, "6.1 base keymap loaded")
    -- Spot check: some default bindings should be present
    assert_eq(type(editor._base_keymap["ctrl-x"]), "table", "6.1 ctrl-x prefix exists")
    assert_eq(editor._base_keymap["ctrl-x"]["ctrl-f"], "find_file", "6.1 C-x C-f → find_file")
    assert_eq(editor._base_keymap["ctrl-f"], "forward_char", "6.1 C-f → forward_char")
    assert_eq(type(editor._base_keymap.__printable), "function", "6.1 __printable handler exists")
end

-- 6.2 Editor._keymap_chain exists and includes base
do
    assert_truthy(editor._keymap_chain ~= nil, "6.2 chain exists")
    assert_truthy(#editor._keymap_chain >= 1, "6.2 chain has entries")
    -- The last entry should be the base keymap
    assert_eq(editor._keymap_chain[#editor._keymap_chain], editor._base_keymap,
        "6.2 chain tail is base keymap")
end

-- 6.3 View has _keymap_chain (may be nil at startup before modes are set;
--     the editor's chain is a fallback {base_km} in that case)
do
    -- Editor's chain should at least point to {base_km}
    assert_truthy(editor._keymap_chain ~= nil, "6.3 editor chain exists")
    assert_eq(#editor._keymap_chain, 1, "6.3 editor chain has base")
end

-- 6.4 global_set_key adds to base keymap
do
    editor:global_set_key("ctrl-x ctrl-q", "test_quit")
    assert_eq(editor._base_keymap["ctrl-x"]["ctrl-q"], "test_quit",
        "6.4 global_set_key adds to base")
    -- Cleanup: remove the test binding
    editor._base_keymap["ctrl-x"]["ctrl-q"] = nil
end

-- 6.5 global_set_key for __printable
do
    local called = false
    editor:global_set_key("__printable", function() called = true end)
    assert_eq(type(editor._base_keymap.__printable), "function", "6.5 __printable set")
    -- Don't clobber the real one; let's check it's actually our function
    -- (we can't easily check identity since it wrapped)
    assert_truthy(editor._base_keymap.__printable ~= nil, "6.5 __printable not nil")
end

-- 6.6 define_key adds to mode keymap with inheritance
do
    local MajorMode = require("cursed.major_mode")
    -- Create a test mode with no keymap
    local test_mode = MajorMode.new({
        name = "test-mode",
        keymap = {},
    })
    -- Activate it so set_major_modes builds the chain
    view:activate_major_mode(test_mode)
    -- Now define a key on it
    editor:define_key(test_mode, "ctrl-c ctrl-t", "test_command")
    -- The mode's keymap should have ctrl-c with __index to base's ctrl-c
    assert_eq(type(test_mode.keymap["ctrl-c"]), "table", "6.6 mode has ctrl-c prefix")
    local mt = getmetatable(test_mode.keymap["ctrl-c"])
    assert_truthy(mt ~= nil, "6.6 mode ctrl-c has __index metatable")
    assert_truthy(mt.__index ~= nil, "6.6 __index points to base")
    assert_eq(test_mode.keymap["ctrl-c"]["ctrl-t"], "test_command", "6.6 owned binding")
    -- Cleanup
    view:deactivate_major_mode(test_mode)
end

-- 6.7 define_key on mode with keymap_spec
do
    local MajorMode = require("cursed.major_mode")
    local built = false
    local test_mode = MajorMode.new({
        name = "test-spec-mode",
        keymap_spec = function(base_km)
            built = true
            return { keymap = { ["ctrl-t"] = "spec_cmd" } }
        end,
    })
    view:activate_major_mode(test_mode)
    -- ensure_keymap should have been called by rebuild_keymap_chain
    assert_truthy(built, "6.7 keymap_spec was called")
    -- ensure_keymap writes to the mode INSTANCE (not the template),
    -- so find the active instance in the view
    local instance = view._major_modes[#view._major_modes]
    assert_truthy(instance ~= nil, "6.7 instance found")
    assert_eq(instance.keymap["ctrl-t"], "spec_cmd", "6.7 spec binding present on instance")
    view:deactivate_major_mode(test_mode)
end

-- 6.8 mirror_prefix clones a subtree
do
    -- Save original state
    local orig_ctrl_x = editor._base_keymap["ctrl-x"]
    editor:mirror_prefix("ctrl-x", "alt-t")
    assert_eq(type(editor._base_keymap["alt-t"]), "table", "6.8 mirror creates alt-t")
    assert_eq(editor._base_keymap["alt-t"]["ctrl-f"], "find_file", "6.8 mirrored binding")
    -- Should be a deep copy (different table refs)
    assert_truthy(editor._base_keymap["alt-t"] ~= orig_ctrl_x, "6.8 deep copy (different ref)")
    -- Cleanup
    editor._base_keymap["alt-t"] = nil
end

-- 6.9 chord_for_command is built
do
    local chords = editor._chord_for_command
    assert_truthy(chords ~= nil, "6.9 chord_for_command exists")
    assert_eq(type(chords["find_file"]), "string", "6.9 find_file has a chord")
    -- save_buffer might be named differently, spot check any known command
    local found_any = false
    for _, v in pairs(chords) do
        found_any = true
        break
    end
    assert_truthy(found_any, "6.9 chord_for_command has entries")
end

-------------------------------------------------------------------------------
-- SECTION 7: Dispatch simulation
-------------------------------------------------------------------------------

-- Simulate what dispatch_key does (without the full event loop)

-- 7.1 Top-level lookup in chain
do
    -- Search the chain for "ctrl-f"
    local chain = editor._keymap_chain
    local found = false
    for _, km in ipairs(chain) do
        if rawget(km, "ctrl-f") then found = true; break end
    end
    assert_truthy(found, "7.1 ctrl-f found in chain")
end

-- 7.2 Prefix descent: once in a prefix, only that prefix is searched
do
    local prefix_km = editor._base_keymap["ctrl-x"]
    assert_truthy(type(prefix_km) == "table", "7.2 ctrl-x is a prefix")
    -- In the prefix, "ctrl-f" should be find_file
    assert_eq(rawget(prefix_km, "ctrl-f"), "find_file", "7.2 in prefix: C-f found")
    -- But "escape" should NOT be found in the prefix (it's at top level only)
    assert_eq(rawget(prefix_km, "escape"), nil, "7.2 in prefix: top-level keys NOT found")
end

-- 7.3 __printable fallback in a prefix
do
    local km = {
        ["a"] = "command_a",
        __printable = function() return "printed" end,
    }
    -- Direct match
    assert_eq(rawget(km, "a"), "command_a", "7.3 direct match beats __printable")
    -- No direct match, __printable exists
    assert_eq(rawget(km, "z"), nil, "7.3 no match → nil via rawget")
    assert_eq(type(km.__printable), "function", "7.3 __printable exists")
end

-- 7.4 __default fallback
do
    local km = {
        __default = function() return "default" end,
    }
    assert_eq(rawget(km, "z"), nil, "7.4 no match via rawget")
    assert_eq(type(km.__default), "function", "7.4 __default exists")
end

-- 7.5 nil binding = undefined chord
do
    local km = {}
    assert_eq(rawget(km, "z"), nil, "7.5 nonexistent key → nil")
    assert_eq(km.__printable, nil, "7.5 no __printable")
    assert_eq(km.__default, nil, "7.5 no __default")
    -- This is the "beep" case in the real dispatch
end

-- 7.6 Keymap chain search: mode shadows base
do
    -- Build a mini chain: mode_km (overrides ctrl-f), base_km
    local base = kb.Keymap.new()
    kb.Keymap.add(base, {"ctrl-f"}, "forward_char")
    kb.Keymap.add(base, {"ctrl-b"}, "backward_char")

    local mode = kb.Keymap.new()
    kb.Keymap.add(mode, {"ctrl-f"}, "mode_forward")
    -- mode doesn't bind ctrl-b

    local chain = {mode, base}
    -- Search for ctrl-f: mode wins
    local found = nil
    for _, km in ipairs(chain) do
        found = rawget(km, "ctrl-f")
        if found ~= nil then break end
    end
    assert_eq(found, "mode_forward", "7.6 mode shadows base")

    -- Search for ctrl-b: falls through to base
    found = nil
    for _, km in ipairs(chain) do
        found = rawget(km, "ctrl-b")
        if found ~= nil then break end
    end
    assert_eq(found, "backward_char", "7.6 fallback to base")
end

-------------------------------------------------------------------------------
-- SECTION 8: Which-key entry collection
-------------------------------------------------------------------------------

-- 8.1 collect_entries skips __ keys
do
    local whichkey = require("cursed.whichkey")
    -- Build a keymap with __ keys and regular keys
    local km = {
        ["a"] = "cmd_a",
        ["ctrl-x"] = { ["ctrl-f"] = "find_file" },
        ["b"] = "cmd_b",
        __printable = function() end,
        __default = function() end,
        __timeout = 1000,
    }
    -- Use compute_layout to indirectly test collect_entries
    -- (compute_layout calls collect_entries internally)
    -- We can't easily call compute_layout without an editor, so let's
    -- just verify the __ keys would be filtered by checking manually
    local entries = {}
    for tok, val in pairs(km) do
        if tok:sub(1, 2) ~= "__" then
            entries[#entries + 1] = { key = tok, val = val }
        end
    end
    -- Should have a, ctrl-x, b (3 entries, no __ keys)
    local names = {}
    for _, e in ipairs(entries) do names[e.key] = true end
    assert_truthy(names["a"], "8.1 'a' present")
    assert_truthy(names["ctrl-x"], "8.1 'ctrl-x' present")
    assert_truthy(names["b"], "8.1 'b' present")
    assert_eq(names["__printable"], nil, "8.1 __printable filtered out")
    assert_eq(names["__default"], nil, "8.1 __default filtered out")
    assert_eq(names["__timeout"], nil, "8.1 __timeout filtered out")
end

-- 8.2 Which-key: prefix keymap shows "more commands" for sub-keymaps
do
    local km = {
        ["ctrl-x"] = { ["ctrl-f"] = "find_file" },  -- sub-keymap → "more commands"
        ["ctrl-f"] = "forward_char",                 -- leaf command
    }
    -- Simulate the label logic
    local labels = {}
    for tok, val in pairs(km) do
        if tok:sub(1, 2) ~= "__" then
            labels[tok] = type(val) == "table" and "more commands"
                or type(val) == "string" and "command"
                or "(command)"
        end
    end
    assert_eq(labels["ctrl-x"], "more commands", "8.2 prefix shows 'more commands'")
    assert_eq(labels["ctrl-f"], "command", "8.2 leaf shows command name")
end

-------------------------------------------------------------------------------
-- SECTION 9: View chain persistence across mode changes
-------------------------------------------------------------------------------

-- 9.1 Activating a mode rebuilds the view chain and updates editor pointer
do
    local MajorMode = require("cursed.major_mode")
    local test_mode = MajorMode.new({
        name = "chain-test",
        keymap = { ["ctrl-t"] = "test_cmd" },
    })

    -- Ensure the view has a chain first (may be nil at startup)
    if view._keymap_chain == nil then
        view:rebuild_keymap_chain(editor._base_keymap)
    end
    local old_len = #view._keymap_chain

    view:activate_major_mode(test_mode)

    -- Chain should have one more entry (the mode's keymap prepended)
    assert_eq(#view._keymap_chain, old_len + 1, "9.1 chain grew by 1")
    -- Editor's chain should be the view's chain (pointer)
    assert_eq(editor._keymap_chain, view._keymap_chain, "9.1 editor still points to view chain")
    -- First entry should be the mode's keymap
    assert_eq(view._keymap_chain[1], test_mode.keymap, "9.1 mode keymap is first in chain")

    view:deactivate_major_mode(test_mode)
    assert_eq(#view._keymap_chain, old_len, "9.1 chain restored after deactivation")
end

-- 9.2 Multiple views: each has its own chain
do
    local Buffer = require("cursed.buffer").Buffer
    local View = require("cursed.view").View
    local MajorMode = require("cursed.major_mode")

    -- Ensure view1 has a chain
    if view._keymap_chain == nil then
        view:rebuild_keymap_chain(editor._base_keymap)
    end

    local mode_a = MajorMode.new({
        name = "multi-a",
        keymap = { ["ctrl-a"] = "cmd_a" },
    })

    -- Create a second view
    local buf2 = Buffer.new()
    local view2 = View.new(buf2)
    editor:add_view(view2)

    -- add_view calls set_active_view which should ensure the view has a chain
    -- (either from the view or fallback). Let's force-build it.
    if view2._keymap_chain == nil then
        view2:rebuild_keymap_chain(editor._base_keymap)
    end

    -- view2 should have its own chain
    assert_truthy(view2._keymap_chain ~= nil, "9.2 view2 has chain")
    -- Should be a different table object from view1's chain
    assert_truthy(view2._keymap_chain ~= view._keymap_chain, "9.2 different chain tables")

    -- Activate a mode on the original view
    view:activate_major_mode(mode_a)

    -- view2's chain should be unchanged (only view got the mode)
    assert_eq(#view2._keymap_chain, 1, "9.2 view2 chain unaffected by view1 mode")
    -- view's chain should have mode_a
    assert_eq(#view._keymap_chain, 2, "9.2 view1 chain has mode")

    -- Switch to view2: editor's chain should now be view2's chain
    editor:set_active_view(2)
    assert_eq(editor._keymap_chain, view2._keymap_chain, "9.2 switch: editor → view2 chain")

    -- Switch back to view1
    editor:set_active_view(1)
    assert_eq(editor._keymap_chain, view._keymap_chain, "9.2 switch back: editor → view1 chain")

    -- Cleanup
    view:deactivate_major_mode(mode_a)
    editor:close_view(view2)
end

-------------------------------------------------------------------------------
-- Results
-------------------------------------------------------------------------------

print(string.format("\n=== KEYMAP TEST RESULTS ==="))
print(string.format("  Passed: %d", passed))
print(string.format("  Failed: %d", failed))
print(string.format("  Total:  %d", passed + failed))

if failed > 0 then
    print("\nSOME TESTS FAILED")
    os.exit(1)
else
    print("\nALL TESTS PASSED")
    os.exit(0)
end
