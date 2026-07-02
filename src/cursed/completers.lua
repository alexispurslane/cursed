--- completers: named completion provider factories for the minibuffer.
---
--- Each exported function returns a `completer(text) -> string[]` closure,
--- binding any required context (editor, command names iterator, etc.)
--- at creation time. Users can override any completer by replacing the
--- field on this module before commands reference it.

local find_file = require("cursed.find_file")

local completers = {}

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

--- Split text into space-separated lowercase search terms.
---@param text string
---@return string[]
local function space_terms(text)
    local words = {}
    for w in text:gmatch("%S+") do
        words[#words + 1] = w:lower()
    end
    return words
end

--- Test whether `display` matches all terms as case-insensitive substrings.
---@param display string
---@param terms string[]
---@return boolean
local function matches_all(display, terms)
    if #terms == 0 then
        return true
    end
    local lower = display:lower()
    for _, t in ipairs(terms) do
        if not lower:find(t, 1, true) then
            return false
        end
    end
    return true
end

----------------------------------------------------------------------------------------------------
-- Command completion (M-x)
----------------------------------------------------------------------------------------------------

--- Create a completer for command names.
--- Takes a `names_fn` iterator (from Commands.names) to avoid circular deps,
--- and an optional `chord_fn(name) -> string?` that resolves a command name
--- to a human-readable chord for display as completion metadata.
---@param names_fn fun(): function iterator over command name strings
---@param chord_fn fun(name: string): string?|nil
---@return fun(text: string): table
function completers.commands(names_fn, chord_fn)
    return function(text)
        -- Split on first ":" for inline argument syntax; only match
        -- command names against the part before the colon.
        local colon_pos = text:find(":", 1, true)
        local cmd_text, arg_suffix
        if colon_pos then
            cmd_text = text:sub(1, colon_pos - 1)
            arg_suffix = text:sub(colon_pos)
        else
            cmd_text = text
            arg_suffix = ""
        end
        local terms = space_terms(cmd_text)
        local results = {}
        for name in names_fn() do
            local cmd_words = {}
            for w in name:gmatch("[^_]+") do
                cmd_words[#cmd_words + 1] = w:lower()
            end
            local all_match = true
            for _, uw in ipairs(terms) do
                local found = false
                for _, cw in ipairs(cmd_words) do
                    if cw:sub(1, #uw) == uw then
                        found = true
                        break
                    end
                end
                if not found then
                    all_match = false
                    break
                end
            end
            if all_match then
                -- `name` is the canonical underscore form (e.g. save_as);
                -- display with spaces. chord_fn receives the canonical
                -- form so it matches the reverse command_name→chord map
                -- built from the keybindings (which use underscores).
                local display = name:gsub("_", " ") .. arg_suffix
                local chord = chord_fn and chord_fn(name) or nil
                results[#results + 1] = {
                    text = display,
                    metadata = chord and #chord > 0 and chord or nil,
                }
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Find-file completion
----------------------------------------------------------------------------------------------------

--- File path completer — subword-matches against directory entries.
--- Re-exports find_file.find_file_completer for a single import point.
completers.find_file = find_file.find_file_completer

----------------------------------------------------------------------------------------------------
-- Theme completion (M-x load-theme)
----------------------------------------------------------------------------------------------------

--- Create a completer for available color schemes.
--- Lists scheme names discovered by ColorScheme.list_names across the
--- standard search dirs (user config themes/, repo themes/, installed).
---@param names_fn fun(): string[]  closure returning the current name list
---@return fun(text: string): string[]
function completers.themes(names_fn)
    return function(text)
        local terms = space_terms(text)
        local results = {}
        for _, name in ipairs(names_fn()) do
            if matches_all(name, terms) then
                results[#results + 1] = name
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Ibuffer completion (C-x b)
----------------------------------------------------------------------------------------------------

--- Create a completer for the buffer list.
--- Lists all views with index, dirty marker, and filepath.
---@param editor Editor
---@return fun(text: string): string[]
function completers.ibuffer(editor)
    return function(text)
        local terms = space_terms(text)
        local results = {}
        for i, v in ipairs(editor.views) do
            local path = v.buffer:filepath() or "[no file]"
            local dirty = v.buffer:is_dirty() and "*" or " "
            local display = string.format("%d %s %s", i, dirty, path)
            if matches_all(display, terms) then
                results[#results + 1] = display
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Kill-buffer completion (C-x k)
----------------------------------------------------------------------------------------------------

--- Create a completer for killing buffers.
--- Lists the current buffer first, then all others, with dirty marker
--- and filepath. The `current` view is determined at creation time.
---@param editor Editor
---@return fun(text: string): string[]
function completers.kill_buffer(editor)
    local current = editor:current_view()

    return function(text)
        local terms = space_terms(text)
        -- Build list: current first, then the rest
        local ordered = {}
        if current then
            ordered[#ordered + 1] = current
        end
        for _, v in ipairs(editor.views) do
            if v ~= current then
                ordered[#ordered + 1] = v
            end
        end

        local results = {}
        for _, v in ipairs(ordered) do
            local path = v.buffer:filepath() or "[no file]"
            local dirty = v.buffer:is_dirty() and "*" or " "
            local display = dirty .. " " .. path
            if matches_all(display, terms) then
                results[#results + 1] = display
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Buffer-word completion (in-buffer completion dogfood source)
----------------------------------------------------------------------------------------------------

--- Build a buffer-word (dabbrev-style) completer: scans ALL loaded
--- views' buffers for `[%w_]+` tokens, keeps those that start with the
--- cursor's current prefix (case-sensitive), excludes the exact prefix
--- itself, dedups, preserves first-seen order, and caps the result so a
--- huge file doesn't blow up the popup. Used by CompletionMenu as the
--- default source — a cheap, dependency-free way to exercise the whole
--- in-buffer completion loop end-to-end. An LSP completion provider can
--- later plug in via `CompletionMenu:set_completer` without changes here.
---
--- The closure is editor-bound at creation; the per-query cost is an
--- O(buffer) scan, which is fine for a debounced (120ms) completion.
---@param editor Editor
---@param opts table? { cap?: integer, min_token?: integer }
---@return fun(ctx: table): table  items (strings)
function completers.buffer_words(editor, opts)
    opts = opts or {}
    local cap = opts.cap or 200
    local min_token = opts.min_token or 3
    return function(ctx)
        local prefix = ctx.prefix
        if prefix == nil or #prefix < 1 then
            return {}
        end
        local seen = {}
        local results = {}
        local function consider(token)
            if #token < min_token then
                return
            end
            if token:sub(1, #prefix) ~= prefix then
                return
            end
            if token == prefix then
                return
            end
            if seen[token] then
                return
            end
            seen[token] = true
            results[#results + 1] = token
            if #results >= cap then
                return true -- stop iteration
            end
            return false
        end
        -- Scan the active buffer first (most relevant), then the others.
        local active = ctx.buf
        local function scan_buf(buf)
            local n = buf:line_count()
            for li = 0, n - 1 do
                local text = buf:line_text(li)
                for tok in text:gmatch("[%w_]+") do
                    if consider(tok) then
                        return
                    end
                end
            end
        end
        if active then
            scan_buf(active)
        end
        for _, v in ipairs(editor.views) do
            if v.buffer ~= active and v.buffer ~= nil then
                scan_buf(v.buffer)
                if #results >= cap then
                    break
                end
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Yes/No/All completion (for query-replace)
----------------------------------------------------------------------------------------------------

--- Create a completer offering "yes", "no", "all" options.
---@return fun(text: string): string[]
function completers.yes_no_all()
    local options = { "y", "n", "a" }
    return function(text)
        if #text == 0 then
            return { "y", "n", "a" }
        end
        local lower = text:lower()
        local results = {}
        for _, opt in ipairs(options) do
            if opt:sub(1, #lower) == lower then
                results[#results + 1] = opt
            end
        end
        return results
    end
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

-- Re-export the completion-item helpers (canonical home is minibuffer.lua)
-- for callers that reach them via the completers module. Resolved lazily
-- on first use to avoid a require cycle at module-load time.
completers.comp_text = function(item)
    return require("cursed.minibuffer").comp_text(item)
end
completers.comp_meta = function(item)
    return require("cursed.minibuffer").comp_meta(item)
end

return completers
