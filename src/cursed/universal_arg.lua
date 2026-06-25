--- Universal argument (C-u) support.
---
--- C-u activates a minibuffer-based argument collector. The user types
--- arbitrary text, then hits a key chord. The collected text is parsed
--- into typed arguments and passed to the command.
---
--- Parsing rules (space-separated, shell-like):
---   - Tokens separated by whitespace
---   - Numeric tokens auto-parsed to number
---   - Double-quoted strings preserve spaces, no escapes
---   - Unquoted tokens that look like numbers become numbers
---
--- Universal argument protocol:
---   - No C-u:        command receives { true }
---   - C-u (bare):    command receives { false }  (inverted)
---   - C-u 5:         command receives { true, 5 }
---   - C-u C-u 5:     command receives { false, 5 }
---   - C-u hello:     command receives { true, "hello" }
---
--- The flag (position 1) is computed: start true, flip once per C-u,
--- flip once if args are non-empty. Equivalently:
---   flag = (c_u_count + (args_empty and 0 or 1)) % 2 == 0

----------------------------------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------------------------------

--- Parse a universal argument string into typed values.
---@param input string the raw text from the minibuffer
---@return table args array of typed values (numbers or strings)
local function parse_universal_args(input)
    if #input == 0 then
        return {}
    end

    local args = {}
    local i = 1
    local len = #input

    while i <= len do
        -- Skip whitespace
        while i <= len and input:sub(i, i):match("%s") do
            i = i + 1
        end
        if i > len then
            break
        end

        local ch = input:sub(i, i)

        if ch == '"' then
            -- Double-quoted string: consume until closing quote
            i = i + 1
            local start = i
            while i <= len and input:sub(i, i) ~= '"' do
                i = i + 1
            end
            args[#args + 1] = input:sub(start, i - 1)
            if i <= len then
                i = i + 1 -- skip closing quote
            end
        else
            -- Unquoted token: consume until whitespace
            local start = i
            while i <= len and not input:sub(i, i):match("%s") do
                i = i + 1
            end
            local token = input:sub(start, i - 1)
            -- Auto-parse as number if possible
            local num = tonumber(token)
            if num then
                args[#args + 1] = num
            else
                args[#args + 1] = token
            end
        end
    end

    return args
end

--- Compute the universal argument list from C-u count and collected text.
---@param c_u_count integer number of times C-u was pressed
---@param input string raw text from the minibuffer
---@return table args { flag, ...parsed_args }
local function build_universal_args(c_u_count, input)
    local parsed = parse_universal_args(input)
    local has_args = #parsed > 0
    -- Start true, flip per C-u, flip once if args are non-empty
    local flips = c_u_count + (has_args and 1 or 0)
    local flag = (flips % 2) == 0
    ---@diagnostic disable-next-line: deprecated
    return { flag, unpack(parsed) }
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    parse_universal_args = parse_universal_args,
    build_universal_args = build_universal_args,
}
