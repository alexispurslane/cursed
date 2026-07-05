--- fzy: pure LuaJIT fuzzy string matching engine.
---
--- Port of the MIT-licensed fzy algorithm (jhawthorn/fzy) for scoring
--- candidates against a query. The algorithm uses affine-gap DP with
--- position bonuses for word boundaries, camelCase, and path separators,
--- producing human-intuitive rankings for file paths and symbol names.
---
--- Usage:
---   local fzy = require("cursed.fzy")
---   local s = fzy.score("fzy", "src/cursed/fzy.lua")  -- -> score or nil
---   if fzy.has_match("abc", "aXbYc") then ... end

----------------------------------------------------------------------------------------------------
-- Constants (from fzy's config.def.h)
----------------------------------------------------------------------------------------------------

local SCORE_GAP_LEADING = -0.005
local SCORE_GAP_TRAILING = -0.005
local SCORE_GAP_INNER = -0.01
local SCORE_MATCH_CONSECUTIVE = 1.0
local SCORE_MATCH_SLASH = 0.9
local SCORE_MATCH_WORD = 0.8
local SCORE_MATCH_CAPITAL = 0.7
local SCORE_MATCH_DOT = 0.6

local SCORE_MIN = -math.huge
local SCORE_MAX = math.huge

----------------------------------------------------------------------------------------------------
-- Character classification helpers
----------------------------------------------------------------------------------------------------

-- To-lower lookup table: map uppercase ASCII to lowercase, identity otherwise.
local LOWER = {}
for i = 0, 255 do
    if i >= 65 and i <= 90 then -- A-Z -> a-z
        LOWER[i] = i + 32
    else
        LOWER[i] = i
    end
end

--- Compute the fzy match bonus for a position in the candidate string.
--- `last_ch` is the byte value of the character BEFORE this position
--- (or 0x2F = '/' for the first position, matching fzy's convention).
--- `ch` is the byte value at this position.
---@param last_ch integer
---@param ch integer
---@return number
local function compute_bonus(last_ch, ch)
    -- Check special separators in last_ch
    if last_ch == 0x2F then -- /
        return SCORE_MATCH_SLASH
    elseif last_ch == 0x2D or last_ch == 0x5F or last_ch == 0x20 then -- - _ space
        return SCORE_MATCH_WORD
    elseif last_ch == 0x2E then -- .
        return SCORE_MATCH_DOT
    end

    -- camelCase: uppercase after lowercase
    if ch >= 65 and ch <= 90 and last_ch >= 97 and last_ch <= 122 then
        return SCORE_MATCH_CAPITAL
    end

    return SCORE_MATCH_CONSECUTIVE
end

--- Precompute the match bonus for every position in the candidate.
--- Returns a table bonus[1..n] mimicking fzy's precompute_bonus.
---@param haystack string
---@return number[]
local function precompute_bonus(haystack)
    local n = #haystack
    local bonus = {}
    local last_ch = 0x2F -- fzy convention: first char bonus is relative to '/'

    for i = 1, n do
        local ch = haystack:byte(i)
        bonus[i] = compute_bonus(last_ch, ch)
        last_ch = ch
    end

    return bonus
end

----------------------------------------------------------------------------------------------------
-- Fast pre-check: do all needle characters appear in order?
----------------------------------------------------------------------------------------------------

--- Quick check: can every character of `needle` be found in `haystack`
--- in order (case-insensitive)? Returns false early for definite misses.
---@param needle string
---@param haystack string
---@return boolean
local function has_match(needle, haystack)
    local ni = #needle
    local hi = #haystack

    if ni == 0 then
        return true
    end
    if ni > hi then
        return false
    end

    local h = 1
    for n = 1, ni do
        local nc = LOWER[needle:byte(n)]
        local found = false
        while h <= hi do
            if LOWER[haystack:byte(h)] == nc then
                h = h + 1
                found = true
                break
            end
            h = h + 1
        end
        if not found then
            return false
        end
    end
    return true
end

----------------------------------------------------------------------------------------------------
-- Core scoring: fzy's DP algorithm
----------------------------------------------------------------------------------------------------

-- Maximum candidate length we'll score (fzy's MATCH_MAX_LEN).
local MATCH_MAX_LEN = 1024

--- Score a candidate string against a query using fzy's algorithm.
--- Returns the score (higher = better match), or nil if there's no match
--- or the candidate is too long.
---@param needle string the query
---@param haystack string the candidate (e.g. file path)
---@param bonuses? number[] precomputed bonuses (optional; computed if absent)
---@return number? score or nil
local function score(needle, haystack, bonuses)
    local ni = #needle
    local hi = #haystack

    if ni == 0 then
        return SCORE_MIN
    end
    if hi > MATCH_MAX_LEN or ni > hi then
        return nil
    end

    -- Exact-length shortcut: must be case-insensitive exact match.
    if ni == hi then
        for i = 1, ni do
            if LOWER[needle:byte(i)] ~= LOWER[haystack:byte(i)] then
                return nil
            end
        end
        return SCORE_MAX
    end

    -- Fast pre-check: ordered substring match.
    if not has_match(needle, haystack) then
        return nil
    end

    -- Precompute bonuses (or reuse from caller).
    bonuses = bonuses or precompute_bonus(haystack)

    -- Build lowercase needle byte array and lowercase haystack byte array
    -- for fast comparison in the hot loop.
    local lneedle = {}
    for i = 1, ni do
        lneedle[i] = LOWER[needle:byte(i)]
    end
    local lhaystack = {}
    for i = 1, hi do
        lhaystack[i] = LOWER[haystack:byte(i)]
    end

    -- DP arrays: D and M, indexed 1..hi (Lua 1-indexed = C's position 0..hi-1).
    -- We maintain prev_D/prev_M for the previous row, curr_D/curr_M for current.
    local prev_D = {}
    local prev_M = {}
    local curr_D = {}
    local curr_M = {}

    -- Row 1: first query character (i=0 in fzy's 0-indexed C code).
    local gap_score = ni == 1 and SCORE_GAP_TRAILING or SCORE_GAP_INNER
    local running_score = SCORE_MIN
    local nc1 = lneedle[1]

    for j = 1, hi do
        if lhaystack[j] == nc1 then
            local s = ((j - 1) * SCORE_GAP_LEADING) + bonuses[j]
            prev_D[j] = s
            running_score = math.max(s, running_score + gap_score)
            prev_M[j] = running_score
        else
            prev_D[j] = SCORE_MIN
            running_score = running_score + gap_score
            prev_M[j] = running_score
        end
    end

    -- Rows 2..ni: remaining query characters.
    for i = 2, ni do
        gap_score = i == ni and SCORE_GAP_TRAILING or SCORE_GAP_INNER
        local run_prev_D = SCORE_MIN
        local run_prev_M = SCORE_MIN
        running_score = SCORE_MIN
        local nc = lneedle[i]

        for j = 1, hi do
            if lhaystack[j] == nc then
                local s = SCORE_MIN
                if j > 1 then
                    -- Two ways to extend the match:
                    -- 1. prev query char matched at j-1, now matching at j (with bonus)
                    -- 2. prev query char matched anywhere before j, and this is consecutive
                    s = math.max(run_prev_M + bonuses[j], run_prev_D + SCORE_MATCH_CONSECUTIVE)
                end
                -- Save previous row's values at j for the next iteration (as j-1).
                run_prev_D = prev_D[j]
                run_prev_M = prev_M[j]
                curr_D[j] = s
                running_score = math.max(s, running_score + gap_score)
                curr_M[j] = running_score
            else
                run_prev_D = prev_D[j]
                run_prev_M = prev_M[j]
                curr_D[j] = SCORE_MIN
                running_score = running_score + gap_score
                curr_M[j] = running_score
            end
        end

        -- Swap: current becomes previous for the next row.
        prev_D, curr_D = curr_D, prev_D
        prev_M, curr_M = curr_M, prev_M
    end

    return prev_M[hi]
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    score = score,
    has_match = has_match,
    SCORE_MIN = SCORE_MIN,
    SCORE_MAX = SCORE_MAX,
}
