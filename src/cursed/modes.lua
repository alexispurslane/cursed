--- Built-in major modes registry.
---
--- Requiring `cursed.modes` returns a table with:
---   .modes  — name → constructed MajorMode (built from each spec)
---   .order  — ordered list of mode names (registration order)
---
--- The per-language specs live alongside this file in `modes/<lang>.lua`
--- and are compiled into the binary as `cursed.modes.<lang>`. Each spec
--- returns a MajorModeSpec (indent settings, language + highlight_query
--- where applicable, textobjects); this registry runs MajorMode.new on
--- each and exposes the constructed objects.
---
--- This module is required LAZILY from `Config.load()` (not at config
--- module-top) so the spec files' top level runs after the global
--- `editor` exists — letting a spec register per-mode event handlers
--- (`editor.event_system:on("mode_enter:<name>", ...)`) before returning
--- its table. See `cursed.config` for the full unsandboxing contract.
---
--- User config references built-ins by name in `file_patterns`:
---
---   file_patterns = {
---     { ".*",       "base" },
---     { "%.lua$",   "lua" },
---   }
---
--- Modes with no `language` (or a `language` whose grammar has no
--- bundled query) simply don't highlight.

local MajorMode = require("cursed.major_mode")

local SPECS = {
    "cursed.modes.base",
    "cursed.modes.lua",
    "cursed.modes.c",
    "cursed.modes.python",
    "cursed.modes.rust",
    "cursed.modes.go",
    "cursed.modes.bash",
    "cursed.modes.json",
    "cursed.modes.toml",
    "cursed.modes.yaml",
    "cursed.modes.makefile",
    "cursed.modes.markdown",
    "cursed.modes.zig",
}

local modes = {}
local order = {}
for _, spec_path in ipairs(SPECS) do
    local spec = require(spec_path)
    local mode = MajorMode.new(spec)
    modes[mode.name] = mode
    order[#order + 1] = mode.name
end

return {
    modes = modes,
    order = order,
}
