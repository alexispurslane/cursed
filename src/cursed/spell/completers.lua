--- Spell completion source.
---
--- `completers.spell(editor)` returns a completer closure that:
---   • Looks up the word at the cursor in the spell store.
---   • If it's flagged misspelled, returns its suggestions ranked by fzy
---     against `ctx.prefix`, with `pending`/`trigger_chars` plumbing
---     mirroring `completers.lsp`.
---   • If not flagged, returns {} so the normal completer chain runs
---     (which never happens directly — the mode_dispatch wrapper in
---     `editor.lua` checks the store BEFORE calling us and falls through
---     to the mode-declared source when the cursor isn't on a flagged
---     word; but returning {} is the right contract anyway).
---
--- The per-word suggestion cache is shared with the squiggle painter:
--- the store entry's `suggestions` field, populated by the client.

local fzy = require("cursed.fzy")

local M = {}

--- Precompute the lowercase prefix bytes once per completer call.
local function lower_prefix(prefix)
    local t = {}
    for i = 1, #prefix do
        local b = select(1, string.byte(prefix:lower(), i))
        if b ~= nil then
            t[i] = b
        end
    end
    return t
end

--- Build a spell completer bound to `editor`.
---@param editor table
---@return table
function M.spell(editor)
    ---@type table
    local dispatch = setmetatable({}, {
        __call = function(_, ctx)
            local view = ctx and ctx.view or editor:current_view()
            if view == nil or not view.file_loaded then
                return {}
            end
            local buf = view.buffer
            if buf == nil then
                return {}
            end
            local store = require("cursed.spell").store(editor)
            if store == nil then
                return {}
            end
            local p = view:p()
            local line = p.line or 0
            local col = p.col or 0
            local entry = store:word_at(buf, line, col)
            if entry == nil or entry.suggestions == nil then
                return {}
            end
            local prefix = ctx.prefix or ""
            -- No prefix filtering when the cursor is mid-word (the word
            -- itself isn't a useful filter); rank by fzy against the
            -- full word so the closest suggestion floats up.
            local items = {}
            local lneedle = lower_prefix(prefix)
            for _, sug in ipairs(entry.suggestions) do
                local score
                if prefix == "" then
                    score = 0
                else
                    -- fzy.score returns a single number|nil (higher = better match).
                    score = fzy.score(prefix, sug, nil, lneedle) or 0
                end
                items[#items + 1] = { text = sug, score = score }
            end
            table.sort(items, function(a, b)
                return a.score > b.score
            end)
            local out = {}
            for _, it in ipairs(items) do
                out[#out + 1] = it.text
            end
            return out
        end,
    })

    --- Spell has no trigger chars (it never auto-opens on a special char;
    --- the completion_menu naturally pops while typing inside a flagged
    --- word because the prefix never goes to 0 — the word stays in the
    --- store).
    function dispatch.trigger_chars()
        return nil
    end

    --- The spell source is synchronous from the menu's POV — results
    --- are already cached in the store. No async pending state.
    function dispatch.pending()
        return false
    end

    return dispatch
end

return M
