--- Universal function advice (#18).
---
--- Emacs-`advice-add`-equivalent wrapping that works on ANY function
--- reachable as a named field of a module table (not just commands).
--- Because Lua `require` returns a shared singleton (cached in
--- `package.loaded`), reassigning `module[name]` is visible to every
--- caller in the process — this is the substrate that makes transparent,
--- stackable, composable advice possible in Lua.
---
--- ## Why a callable table, not a closure
---
--- We replace `module[name]` with a table that has a `__call` metatable
--- entry, holding a list of fold-steps. The cost: `type(module[name])`
--- becomes `"table"` instead of `"function"`. Code that gates on
--- `type(x) == "function"` must use `Advice.callable(x)` (or
--- `Advice.is_advised(x)`) instead. The editor's command-lookup paths are
--- patched to do this; user code should follow suit.
---
--- (You CANNOT attach `__call` to a function *value* — `setmetatable`
--- rejects functions, and even `debug.setmetatable`, which accepts them,
--- is per-TYPE not per-value and Lua never consults `__call` for function
--- values anyway. Verified empirically; slot-replacement is the only way.)
---
--- ## The fold model (strict Emacs semantics)
---
--- `Advice.__call` is a GENERIC FOLD that knows NOTHING about which
--- combinators exist or how they run. It only knows: "I have an original
--- function and a list of fold-steps; fold them and call the result."
---
---   function Advice.__call(self, ...)
---     local composed = self._original
---     for i = 1, #self._runners do
---       composed = self._runners[i].step(composed)
---     end
---     return composed(...)
---   end
---
--- Each advice is added as ONE fold-step stored in `_runners` in
--- add-order. Folding forward (i=1..N) makes the LAST-added advice the
--- OUTERMOST, matching Emacs `advice-add` exactly (later advice wraps
--- everything added before it). There is no grouping by combinator-type,
--- no fixed phase order, no hardcoded list of lists — just one list of
--- self-describing steps, folded.
---
--- ## Combinators as step-constructors
---
--- A combinator (`Advice.before` / `Advice.around` / etc.) is a FUNCTION
--- that takes the advice `fn` and returns a STEP closure of shape
--- `(next_fn) -> composed_fn`. The step encapsulates ALL of that
--- combinator's semantics: which (closure-captured) fn to run, how to
--- run it, and how to thread `next`.
---
--- `Advice.add(module, name, combinator, fn)` is the FRAMEWORK: it
--- ensures `module[name]` is a wrapper, then calls `combinator(fn)` to
--- build the step and appends `{fn=fn, step=...}` to `_runners`.
--- `Advice.add` never inspects WHICH combinator is being added — adding
--- a NEW combinator is just writing a new `Advice.<how>(fn) -> step`
--- function with zero change to `add`/`__call`.
---
--- ## Combinator semantics (match Emacs `advice-add` HOW)
---
---   before          (args...) — runs before next; return discarded.
---   after           (args...) — runs after next; return discarded;
---                   composition returns next's return.
---   around          (next, args...) — runs INSTEAD OF next; the
---                   original/later-inner runs only if/when/how the advice
---                   chooses to call `next`. Short-circuit by not calling.
---   filter_args     (args_list) -> new_args_list. Transforms the args
---                   the next-inner sees.
---   filter_return   (...rets) -> ...new_rets. Fans out ALL of next's
---                   return values as varargs; the filter's returns
---                   become the tuple for the next-outer / final return.
---                   (Multi-value fan-out — more general than Emacs's
---                   single-value threading.)
---
--- Stack order is strictly add-order (last-added outermost), exactly like
--- Emacs. The `:*-until`/`:*-while`/`:override` Emacs variants are
--- omitted for now (rarely used); `:override` is exactly `around` that
--- ignores `next`. Any can be ADDED later as a new combinator with no
--- edit to `add`/`__call`.

local log = require("cursed.log")

---@class Advice
---@field _original function the unwrapped original function
---@field _runners { fn: function, step: fun(next: function):function }[] fold-steps, add-order (last-added outermost after fold)
local Advice = {}
Advice.__index = Advice

--- Sentinel metatable used to identify advised slots. A slot is advised
--- iff `getmetatable(slot) == Advice` (identity compare, not a subtype
--- check) — this is what `Advice.is_advised` tests.
Advice.__advice_marker = true

--- Is `x` an advice wrapper installed by this module?
---@param x any
---@return boolean
function Advice.is_advised(x)
    return type(x) == "table" and getmetatable(x) == Advice
end

--- Is `x` callable — a function OR an advice wrapper? Use this in place of
--- `type(x) == "function"` whenever the value might have been advised.
---@param x any
---@return boolean
function Advice.callable(x)
    return type(x) == "function" or Advice.is_advised(x)
end

--- Construct a fresh advice wrapper around `original`. The wrapper is a
--- callable table (metatable `__call`); installing it as `module[name]`
--- makes all callers route through the fold.
---@param original function
---@return Advice
function Advice.new(original)
    return setmetatable({
        _original = original,
        _runners = {},
    }, Advice)
end

--- GENERIC FOLD. Knows nothing about combinator types or how any step
--- runs — just folds `_runners` (forward = last-added outermost) around
--- the original and calls the result. This is the entire dispatcher;
--- every combinator's semantics live in its own step closure.
---@param self Advice
function Advice.__call(self, ...)
    local composed = self._original
    for i = 1, #self._runners do
        composed = self._runners[i].step(composed)
    end
    return composed(...)
end

----------------------------------------------------------------------------------------------------
-- Combinators: each is (fn) -> step, where step = (next) -> composed_fn.
--
-- To add a NEW combinator, write a new function with this same shape:
--   function Advice.myhow(fn) return function(next) return function(...) ... end end end
-- `Advice.add`/`__call` never need editing.
----------------------------------------------------------------------------------------------------

--- `:before` — run the advice before next; its return is discarded
--- (pcall'd + logged on error so a faulty before never breaks the call).
--- Composition returns next's return.
---@param fn function(args...) the before-advice
---@return fun(next:function):function step
function Advice.before(fn)
    return function(next)
        return function(...)
            ---@diagnostic disable-next-line: deprecated
            pcall(fn, unpack({ ... }))
            return next(...)
        end
    end
end

--- `:after` — run the advice after next returns; its return is discarded
--- (pcall'd; never breaks the call). Composition returns next's return
--- (multi-value preserved). The after-advice sees the ORIGINAL args, not
--- next's returns (matches Emacs).
---@param fn function(args...) the after-advice
---@return fun(next:function):function step
function Advice.after(fn)
    return function(next)
        return function(...)
            ---@diagnostic disable-next-line: deprecated
            local r = { next(...) }
            ---@diagnostic disable-next-line: deprecated
            pcall(fn, unpack({ ... }))
            ---@diagnostic disable-next-line: deprecated
            return unpack(r)
        end
    end
end

--- `:around` — run the advice INSTEAD OF next; the advice receives `next`
--- as its first arg and decides whether/when/how to call it. This is the
--- short-circuit / wrap-return / mutate-args combinator. NOT pcall'd
--- (it's the core call; let its errors surface like the original's would).
---@param fn function(next:function, args...) the around-advice
---@return fun(next:function):function step
function Advice.around(fn)
    return function(next)
        return function(...)
            return fn(next, ...)
        end
    end
end

--- `:filter-args` — transform the arg list before next sees it. The
--- filter receives the arg LIST (single arg) and returns a new list;
--- a non-list return is logged and the original args pass through.
---@param fn function(args_list) -> new_args_list
---@return fun(next:function):function step
function Advice.filter_args(fn)
    return function(next)
        return function(...)
            local args = { ... }
            local ok, new_args = pcall(fn, args)
            if ok and type(new_args) == "table" then
                ---@diagnostic disable-next-line: deprecated
                return next(unpack(new_args))
            end
            log.error("advice", "filter-args returned non-list; passing args through", {
                error = tostring(new_args),
            })
            return next(...)
        end
    end
end

--- `:filter-return` — transform next's return values. Fans out ALL
--- return values as varargs to the filter; the filter's returns (possibly
--- multiple) become the tuple for the next-outer / final return. A faulty
--- filter is pcall'd + logged and leaves the prior returns unchanged.
---@param fn function(...rets) -> ...new_rets
---@return fun(next:function):function step
function Advice.filter_return(fn)
    return function(next)
        return function(...)
            ---@diagnostic disable-next-line: deprecated
            local r = { next(...) }
            ---@diagnostic disable-next-line: deprecated
            local results = { pcall(fn, unpack(r)) }
            if results[1] then
                table.remove(results, 1)
                ---@diagnostic disable-next-line: deprecated
                return unpack(results)
            end
            log.error("advice", "filter-return errored; keeping prior returns", {
                error = tostring(results[2]),
            })
            ---@diagnostic disable-next-line: deprecated
            return unpack(r)
        end
    end
end

--- Get-or-create the advice wrapper on `module[name]`. If the slot already
--- holds an advised table, return it; otherwise wrap the current value
--- (must be a function) and install the wrapper back into the slot.
--- Wrapping a non-function is an error — you can only advise things that
--- are actually functions (advising a table or nil is almost always a typo
--- for the wrong module/name).
---@param module table
---@param name string
---@return Advice|nil
---@return string|nil err
local function ensure(module, name)
    local cur = module[name]
    if Advice.is_advised(cur) then
        return cur, nil
    end
    if type(cur) ~= "function" then
        return nil, ("cannot advise %s: slot is a %s, not a function"):format(name, type(cur))
    end
    local wrap = Advice.new(cur)
    module[name] = wrap
    return wrap, nil
end

--- Framework: ensure `module[name]` is an advice wrapper (creating one if it
--- isn't already), then build the step via `combinator(fn)` and append it
--- to `_runners`. Each advice is its own fold-step — there is no grouping
--- by combinator-type. `Advice.add` is combinator-agnostic, so a NEW
--- combinator is just a new `Advice.<how>(fn) -> step` function with no
--- change here. Returns `fn` (the handle to pass to `Advice.remove`).
---
--- Per-advice, last-added-outermost: the new step is appended (so folding
--- forward makes it the outermost), matching Emacs `advice-add`.
--- Errors propagate as Lua errors for caller `pcall`.
---
--- STRINGLY-TYPING GUARD: this is the one real flaw of the API — the
--- function name is passed as a string separate from the module, so a
--- typo (`"forwad_char"`) would normally silently wrap a nil slot.
--- `ensure` defends against this: it rejects a nil or non-function slot
--- with an error naming the (typo'd) field, so mismatches are LOUD at
--- add-time, never silent. There is no way in Lua to pass `module.fn` by
--- slot-reference (the eval'd value loses its slot), so the string is
--- unavoidable; the nil check is the best available mitigation.
---@param module table
---@param name string
---@param combinator function(fn):step a step-constructor (Advice.before/around/...)
---@param fn function the advice function (signature depends on the combinator)
---@return function fn
function Advice.add(module, name, combinator, fn)
    if type(combinator) ~= "function" then
        error("advice: combinator must be a function (e.g. Advice.before)", 2)
    end
    if type(fn) ~= "function" then
        error(("advice: advice fn must be a function, got %s"):format(type(fn)), 2)
    end
    local wrap, err = ensure(module, name)
    if not wrap then
        error(("advice: %s"):format(err or "ensure failed"), 2)
    end
    local step = combinator(fn)
    if type(step) ~= "function" then
        error(("advice: combinator did not return a step function, got %s"):format(type(step)), 2)
    end
    wrap._runners[#wrap._runners + 1] = { fn = fn, step = step }
    log.debug("advice", "added", { name = name })
    return fn
end

--- Remove ALL advice pieces that use `fn` from `module[name]` (Emacs
--- `advice-remove` takes just `(symbol, function)`; the combinator used
--- to add is NOT needed — identity is by `fn`). Returns true if at least
--- one piece was removed. If `_runners` becomes empty, the slot is
--- restored to the original function — so advised modules don't carry
--- dead wrappers forever and `type()` returns to `"function"`.
---@param module table
---@param name string
---@param fn function the handle returned by `Advice.add`
---@return boolean removed
function Advice.remove(module, name, fn)
    local wrap = module[name]
    if not Advice.is_advised(wrap) then
        return false
    end
    local removed = false
    local kept = {}
    for _, record in ipairs(wrap._runners) do
        if record.fn == fn then
            removed = true
        else
            kept[#kept + 1] = record
        end
    end
    if removed then
        wrap._runners = kept
        if #kept == 0 then
            module[name] = wrap._original
            log.debug("advice", "restored original (no advices left)", { name = name })
        end
    end
    return removed
end

return Advice
