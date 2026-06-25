# Cursed — Agent Guidelines

## Style

- LuaJIT runtime. Source is plain Lua (`.lua` files). No compilation step.
- Type annotations use LDoc comments (`---@class`, `---@field`, `---@param`, `---@return`, `---@cast`).45;5u
- Annotate public module surfaces (exported classes, key functions). Internal FFI plumbing doesn't need annotations — `any` propagates freely through lua-language-server.
- No unused locals, no implicit globals, no shadowed names, no ignored return values.
- Immutable patterns preferred. Discriminated-union-style tables for state variants.
- Format with stylua before committing: `just fmt`.
- Always use `return nil, errormsg` style errors for recoverable errors.
- `error(msg, 2)` is acceptable for invariant violations (e.g. null FFI pointers, init failures).
- Factory methods on classes (`Tree.new`, `Parser.new`) own the `wrap_gc` + `setmetatable` dance. Callers pass raw FFI pointers.
- Use `require("cursed.gc").wrap_gc(ptr, dtor)` instead of raw `ffi.gc` — single place for the `as ffi.CData` cast.
- Only use `wrap_gc` when cleanup requires a **side effect beyond freeing memory** — e.g. `munmap()`, `tb_shutdown()`, `ts_tree_delete()`. For pure-memory `ffi.new` allocations, LuaJIT's GC handles deallocation automatically; `wrap_gc` is unnecessary and would double-free.
- RAII via `wrap_gc` — no manual `free()` on pure-memory resources. Only resources with observable side effects beyond memory (e.g. `Term:shutdown()` restoring the terminal) get a manual shutdown method, but that should never be called `free`, since it does not free memory.

## FFI Conventions

- `_ffi.lua` modules call `ffi.cdef` and return `ffi.C` (or a table with `ffi.C` + constants). There are no separate `_c.lua` modules.
- FFI cdata can be indexed directly — no casting needed. `self._ptr.piece_table.orig.data` just works.
- `tonumber()` on cdata integers returns `number?` per LLS. Use `---@cast v integer` when you know it's non-nil.
- Lua strings can't be assigned to `void *` fields in FFI structs. Use `ffi.new("char[?]", #s+1)` + `ffi.copy()` + `ffi.string()` to pass strings through C struct fields.
- `ffi.gc` / `ffi.string` expect `ffi.CData`; pass cdata directly (no cast needed in plain Lua).

## LDoc Conventions

- `---@class` for exported classes (SharedState, Term, Parser, etc.) with `---@field` for their properties.
- `---@param` / `---@return` on public methods. Use typed class names (e.g. `Msg`, `Piece`) not bare `table`.
- `---@cast` to narrow types when LLS infers too wide (e.g. `tonumber()` returning `number?`).
- Don't annotate internal locals or FFI plumbing — `any` propagation handles them and annotations would just be noise.

## After Every Change

Run `just check`. It must pass with exit code 0.


