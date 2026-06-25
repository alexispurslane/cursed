--- FFI declarations for vendored TRE regex library.
---
--- Provides the TRE POSIX extended regex API via ffi.cdef plus
--- Lua-side helpers for compiling regex patterns.

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef([[
    typedef struct {
        int re_nsub;
        char opaque[64]; /* big enough for TRE regex_t */
    } regex_t_eds;

    typedef struct {
        int rm_so;
        int rm_eo;
    } regmatch_t_eds;

    int tre_regcomp(regex_t_eds *preg, const char *regex, int cflags);
    int tre_regnexec(const regex_t_eds *preg, const char *string, size_t len, size_t nmatch, regmatch_t_eds *pmatch, int eflags);
    void tre_regfree(regex_t_eds *preg);
    size_t tre_regerror(int errcode, const regex_t_eds *preg, char *errbuf, size_t errbuf_size);
]])

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

-- TRE flag values
local REG_EXTENDED = 1
local REG_ICASE = 2
local REG_NOSUB = 8
local REG_NOTBOL = 1
local REG_NOTEOL = 2

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

--- Compile a POSIX extended regex pattern using vendored TRE.
---@param pattern string POSIX extended regex
---@param icase boolean|nil case-insensitive if true
---@return any|nil compiled regex_t_eds cdata
---@return string|nil errmsg
local function compile_regex(pattern, icase)
    local regex = ffi.new("regex_t_eds")
    local flags = REG_EXTENDED
    if icase then
        flags = bit.bor(flags, REG_ICASE)
    end
    local rc = ffi.C.tre_regcomp(regex, pattern, flags)
    if rc ~= 0 then
        local buf = ffi.new("char[?]", 256)
        ffi.C.tre_regerror(rc, regex, buf, 256)
        ffi.C.tre_regfree(regex)
        return nil, ffi.string(buf)
    end
    return regex
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    C = ffi.C,
    compile_regex = compile_regex,
    regmatch_type = "regmatch_t_eds[1]",
    REG_EXTENDED = REG_EXTENDED,
    REG_ICASE = REG_ICASE,
    REG_NOSUB = REG_NOSUB,
    REG_NOTBOL = REG_NOTBOL,
    REG_NOTEOL = REG_NOTEOL,
}
