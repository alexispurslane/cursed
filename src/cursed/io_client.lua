--- IO lane main-side facade.
---
--- Minimal client: IO ops are stateless per-request. This facade exists
--- so the lane restart machinery has a reinitialize hook and so callers
--- have a single module to require for IO-lane concerns.

local M = {}

function M.setup(editor, shared_state)
    M._ss = shared_state
    M._editor = editor
end

function M.reinitialize(editor, ss)
    M._ss = ss
    M._editor = editor
    -- IO lane is stateless per-request; nothing to rebuild.
end

return M
