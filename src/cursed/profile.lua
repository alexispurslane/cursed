--- Profile: structured-timing wrapper over `bench`.
---
--- Controlled by the `CURSED_PROFILE` environment variable. When
--- disabled (the default) the public functions are no-ops. When enabled,
--- they emit `bench.span` entries to the configured log as structured
--- JSON with `elapsed_ms` plus any extra fields.

local bench = require("cursed.bench")
local log = require("cursed.log")

local Profile = {
    enabled = os.getenv("CURSED_PROFILE") ~= nil,
}

--- Wall-clock microseconds. Cheap; safe to call whether or not profiling
--- is enabled (the cost of the call is tiny compared with the work being
--- measured).
---@return integer
function Profile.now_us()
    return bench.now_us()
end

--- Emit a profile span if profiling is enabled.
---@param module string
---@param label string
---@param t0 integer start time from `Profile.now_us()`
---@param fields table<string, string|number|boolean|nil>|nil
function Profile.span(module, label, t0, fields)
    if Profile.enabled then
        bench.span(module, label, t0, fields)
    end
end

--- Report an explicitly-accumulated elapsed time (microseconds), for
--- cases where a single span wraps many iterations and you want one
--- summary line rather than one per iteration.
---@param module string
---@param label string
---@param elapsed_us integer accumulated microseconds
---@param fields table<string, string|number|boolean|nil>|nil
function Profile.report(module, label, elapsed_us, fields)
    if not Profile.enabled then
        return
    end
    ---@type table<string, string|number|boolean>
    local f = { elapsed_ms = string.format("%.2f", elapsed_us / 1000) }
    if fields then
        for k, v in pairs(fields) do
            f[k] = v
        end
    end
    log.info(module, label, f)
end

return Profile
