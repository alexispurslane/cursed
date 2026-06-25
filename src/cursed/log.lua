--- Structured logging module for cursed.
---
--- Provides level-gated, JSON-formatted log output. In production
--- (level >= "warn"), debug/info calls cost a single integer comparison
--- and return immediately — no string formatting or table construction.
---
--- Usage:
---   local log = require("cursed.log")
---   log.configure({ level = "debug", output = "/tmp/cursed.log" })
---   log.debug("editor", "word motion", { direction = "forward", line = 42 })

---@class Log
---@field _levels table<string, integer> level name → numeric value
---@field _level_num integer current minimum numeric level
---@field _output file*|nil output handle (nil = stderr)
---@field _output_path string|nil file path for output
local Log = {}

--- Level name → numeric value
Log._levels = {
    debug = 10,
    info = 20,
    warn = 30,
    error = 40,
}

--- Current minimum level (numeric). Default: warn (30).
Log._level_num = 30

--- Output file handle. nil means stderr.
Log._output = nil

--- If non-nil, we opened this file and must close it on reconfigure.
Log._output_path = nil

----------------------------------------------------------------------------------------------------
-- Minimal JSON encoder (flat tables only, no nesting)
----------------------------------------------------------------------------------------------------

--- Encode a Lua string as a JSON string with proper escaping.
---@param s string
---@return string
local function json_string(s)
    return '"'
        .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
        .. '"'
end

--- Encode a flat Lua table as a JSON object.
--- Values can be strings, numbers, booleans, or nil (nil values are omitted).
---@param t table<string, string|number|boolean|nil>
---@return string
local function json_object(t)
    local parts = {}
    for k, v in pairs(t) do
        if v ~= nil then
            local val
            if type(v) == "string" then
                val = json_string(v)
            elseif type(v) == "boolean" then
                val = v and "true" or "false"
            else
                val = tostring(v)
            end
            parts[#parts + 1] = json_string(k) .. ":" .. val
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

----------------------------------------------------------------------------------------------------
-- Core emit
----------------------------------------------------------------------------------------------------

--- Write a structured log entry.
---@param level_name string one of "debug","info","warn","error"
---@param level_num integer numeric level of this call
---@param module string short module identifier (e.g. "main", "editor")
---@param msg string human-readable message
---@param fields table<string, string|number|boolean|nil>|nil optional structured key-value pairs
local function emit(level_name, level_num, module, msg, fields)
    if level_num < Log._level_num then
        return
    end

    local ts = string.format("%.3f", os.clock())
    local entry
    if fields and next(fields) then
        entry = '{"ts":'
            .. ts
            .. ',"level":'
            .. json_string(level_name)
            .. ',"module":'
            .. json_string(module)
            .. ',"msg":'
            .. json_string(msg)
            .. ',"fields":'
            .. json_object(fields)
            .. "}\n"
    else
        entry = '{"ts":'
            .. ts
            .. ',"level":'
            .. json_string(level_name)
            .. ',"module":'
            .. json_string(module)
            .. ',"msg":'
            .. json_string(msg)
            .. "}\n"
    end

    local out = Log._output or io.stderr
    out:write(entry)
    out:flush()
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

--- Log at debug level.
---@param module string
---@param msg string
---@param fields table<string, string|number|boolean|nil>|nil
function Log.debug(module, msg, fields)
    emit("debug", 10, module, msg, fields)
end

--- Log at info level.
---@param module string
---@param msg string
---@param fields table<string, string|number|boolean|nil>|nil
function Log.info(module, msg, fields)
    emit("info", 20, module, msg, fields)
end

--- Log at warn level.
---@param module string
---@param msg string
---@param fields table<string, string|number|boolean|nil>|nil
function Log.warn(module, msg, fields)
    emit("warn", 30, module, msg, fields)
end

--- Log at error level.
---@param module string
---@param msg string
---@param fields table<string, string|number|boolean|nil>|nil
function Log.error(module, msg, fields)
    emit("error", 40, module, msg, fields)
end

--- Configure the logging system.
---
--- Options:
---   level   — minimum level name: "debug","info","warn","error" (default: "warn")
---   output  — file path to write to; omit for stderr
---
---@param opts { level: string?, output: string? }
function Log.configure(opts)
    if opts.level then
        local num = Log._levels[opts.level]
        if num then
            Log._level_num = num
        end
    end
    if opts.output then
        -- Close previous file if we opened it
        if Log._output then
            Log._output:close()
            Log._output = nil
        end
        Log._output = io.open(opts.output, "a")
        Log._output_path = opts.output
    end
end

return Log
