--- Bench — tiny wall-clock timing helpers for instrumentation.
---
--- Uses gettimeofday(2) for microsecond wall-clock resolution.
--- This is *wall* time (not CPU time), suitable for measuring latency
--- across lanes/threads and async round-trips. It is not monotonic-
--- guaranteed, but gettimeofday is monotonic enough on the platforms
--- cursed targets for short-interval benchmarking.
---
--- All public functions are cheap and safe to leave in place in
--- production; log emission is level-gated by the `log` module.

local ffi = require("ffi")
local pffi = require("cursed.posix_ffi")
local log = require("cursed.log")

local Bench = {}

--- Reusable timeval scratch (thread-local-ish: cursed is single-threaded
--- per lua_State, and the io/highlight lanes each require their own copy
--- of this module, so a single upvalue is fine).
local _tv = ffi.new("struct timeval[1]")

--- Wall-clock time in microseconds.
---@return integer
function Bench.now_us()
    pffi.C.gettimeofday(_tv, nil)
    local sec = tonumber(_tv[0].tv_sec)
    local usec = tonumber(_tv[0].tv_usec)
    ---@cast sec integer
    ---@cast usec integer
    return sec * 1000000 + usec
end

--- Wall-clock time in milliseconds (fractional).
---@return number
function Bench.now_ms()
    return Bench.now_us() / 1000
end

--- Log an elapsed interval at info level.
---
--- `t0` is a start timestamp from `now_us()`; the end is sampled now.
--- Emits a single structured log entry tagged with `module`/`label`
--- carrying `elapsed_ms` (rounded to 0.01ms) plus any extra `fields`.
---
--- Returns the elapsed time in microseconds.
---@param module string
---@param label string
---@param t0 integer start timestamp (us) from now_us()
---@param fields table<string, string|number|boolean|nil>|nil
---@return integer elapsed_us
function Bench.span(module, label, t0, fields)
    local t1 = Bench.now_us()
    local elapsed_us = t1 - t0
    ---@type table<string, string|number|boolean>
    local f = { elapsed_ms = string.format("%.2f", elapsed_us / 1000) }
    if fields then
        for k, v in pairs(fields) do
            f[k] = v
        end
    end
    log.info(module, label, f)
    return elapsed_us
end

return Bench
