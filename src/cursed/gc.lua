--- FFI memory management helpers for RAII via ffi.gc.
---
--- Provides shared GC lifecycle primitives used by all typed FFI wrapper
--- modules (termbox2, treesitter, etc.). Every FFI resource that needs
--- deterministic cleanup goes through wrap_gc so the protocol is
--- consistent across the codebase.
---
--- The GC handles deallocation automatically — no manual free() needed.

local ffi = require("ffi")

--- Attach a Lua finalizer to an FFI cdata pointer.
--- Returns the same pointer (now tracked by the GC).
---@param ptr any FFI cdata pointer
---@param dtor function Finalizer function
---@return any
local function wrap_gc(ptr, dtor)
    return ffi.gc(ptr, dtor)
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    wrap_gc = wrap_gc,
}
