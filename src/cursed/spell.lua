--- Spell subsystem entrypoint.
---
--- `require("cursed.spell").setup(editor)` constructs the driver/client/
--- store trio and registers edit + buffer_open + scroll hooks on the
--- editor's event bus. After setup, the following surfaces are live:
---
---   • squiggles — `on_render_spell_squiggles` (registered in
---     editor_listeners) paints store entries every frame.
---   • completion — `completers.spell` returns the current word's
---     suggestions when the cursor sits on a flagged word.
---   • commands — `flyspell_correct` (iterate-pick), `autocorrect_word`,
---     `flyspell_buffer`, `flyspell_add_to_dict`.
---
--- The driver is idempotent: calling setup twice returns the same
--- instance (stored on `editor._spell`).

local driver_mod = require("cursed.spell.driver")

local M = {}

---@param editor Editor
---@return table driver
function M.setup(editor)
    if editor._spell ~= nil then
        return editor._spell
    end
    local d = driver_mod.new(editor)
    editor._spell = d
    local es = editor.event_system
    -- Edit hook: bump the debounce on every non-trivial edit. Mirrors
    -- how `completers.buffer_words` invalidates its cache on gen change.
    es:on("post_command_hook", function(_ed)
        local view = _ed:current_view()
        if view == nil or view.buffer == nil then
            return
        end
        d:on_edit(view.buffer)
    end)
    -- New buffer / focus-toggled check.
    es:on("buffer_open", function(_ed, buf)
        ---@diagnostic disable-next-line: unused-local
        _ed = _ed
        d:on_buffer_open(buf)
    end)
    -- Buffer closed → clear its store + drop any pending check.
    es:on("buffer_close", function(_ed, buf)
        ---@diagnostic disable-next-line: unused-local
        _ed = _ed
        d:store():clear(buf)
        local k = buf._ptr and tostring(buf._ptr) or nil
        if k ~= nil and d._pending[k] ~= nil then
            if d._pending[k].task ~= nil then
                editor:cancel_task(d._pending[k].task)
            end
            d._pending[k] = nil
        end
    end)
    -- Before-save hook: warn when misspellings remain.
    es:on("before_save", function(_ed, view, buf)
        ---@diagnostic disable-next-line: unused-local
        view = view
        local store = d:store()
        if store == nil then
            return
        end
        local items = store:items(buf)
        if items and #items > 0 then
            _ed.status_message = "spell: "
                .. #items
                .. " misspelling"
                .. (#items == 1 and "" or "s")
                .. " remaining"
        end
    end)
    return d
end

--- Convenience: fetch the active driver's store (or nil when spell
--- isn't wired).
---@param editor Editor
---@return table|nil
function M.store(editor)
    if editor._spell == nil then
        return nil
    end
    return editor._spell:store()
end

--- Convenience: fetch the active driver's client.
---@param editor Editor
---@return table|nil
function M.client(editor)
    if editor._spell == nil then
        return nil
    end
    return editor._spell:client()
end

return M
