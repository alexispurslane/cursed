--- UTF-8 foundation: decoding, display widths, and grapheme-cluster
--- boundaries (UAX #29 subset).
---
--- Pure Lua, no FFI dependency. The piece table stays byte-native (UTF-8
--- is self-synchronizing, so byte offsets are unambiguous and slice-safe);
--- this module is the View layer's translation between byte offsets and
--- *character* / *display-column* coordinates used by cursor motion, wrap
--- math, the renderer, and mouse hits.
---
--- Design:
---   - `char_length(b)` decodes the lead byte to a byte count.
---   - `decode(s, i)` returns (codepoint, next_index).
---   - `width(cp)` returns display width: 0 (combining), 1, or 2 (wide).
---   - Grapheme boundaries follow UAX #29 with a pragmatic property set:
---     CR/LF pairing, Control breaks, Extend (combining marks), ZWJ,
---     SpacingMark, Prepend, Hangul L/V/LV/LVT, Regional-Indicator
---     pairs, and Extended_Pictographic for emoji-ZWJ sequences.
---   - `parse_line(s)` materializes a grapheme skeleton (byte starts,
---     widths, prefix-sum of widths) so a line can be queried O(log) in
---     both directions after an O(L) walk. The View caches this per line.

local utf8 = {}

----------------------------------------------------------------------------------------------------
-- Byte-level decoding
----------------------------------------------------------------------------------------------------

-- Lead-byte → sequence length, indexed 1-based by (byte+1).
-- Continuation bytes (0x80-0xBF) and invalid leads (0xF5+) map to 1 so a
-- decode never runs off the end of a malformed sequence.
local LEN = {}
for i = 0, 255 do
    if i < 0x80 then
        LEN[i + 1] = 1
    elseif i < 0xC2 then
        LEN[i + 1] = 1 -- continuation bytes + overlong leads
    elseif i < 0xE0 then
        LEN[i + 1] = 2
    elseif i < 0xF0 then
        LEN[i + 1] = 3
    elseif i < 0xF5 then
        LEN[i + 1] = 4
    else
        LEN[i + 1] = 1 -- 0xF5-0xFF invalid
    end
end

--- Byte length of the UTF-8 sequence starting at lead byte `b` (a 1..255 number).
---@param b integer
---@return integer
function utf8.char_length(b)
    return LEN[b + 1]
end

--- Decode the codepoint at byte index `i` in string `s`.
--- Malformed leads decode to the single byte's value, advancing one byte.
--- Never reads past `#s`.
---@param s string
---@param i integer 1-based byte index
---@return integer codepoint
---@return integer next_i index just past the sequence
function utf8.decode(s, i)
    local b = s:byte(i)
    if b == nil then
        return 0, i
    end
    local n = LEN[b + 1]
    if n == 1 then
        return b, i + 1
    elseif n == 2 then
        local b2 = s:byte(i + 1) or 0x80
        return (b2 % 64) + (b % 32) * 64, i + 2
    elseif n == 3 then
        local b2 = s:byte(i + 1) or 0x80
        local b3 = s:byte(i + 2) or 0x80
        return (b3 % 64) + (b2 % 64) * 64 + (b % 16) * 4096, i + 3
    else -- n == 4
        local b2 = s:byte(i + 1) or 0x80
        local b3 = s:byte(i + 2) or 0x80
        local b4 = s:byte(i + 3) or 0x80
        return (b4 % 64) + (b3 % 64) * 64 + (b2 % 64) * 4096 + (b % 8) * 262144, i + 4
    end
end

----------------------------------------------------------------------------------------------------
-- Display width (Markus Kuhn wcwidth, compacted)
----------------------------------------------------------------------------------------------------
-- Width 0 (combining / zero-width / control) and width 2 (East Asian Wide
-- + Fullwidth + emoji) are stored as flat arrays of {lo, hi} pairs, sorted
-- ascending and non-overlapping, so `in_table` can binary-search them.
-- Anything not listed is width 1, EXCEPT C0/C1 controls (0x00-0x1F,
-- 0x7F-0x9F) which are width 0 (handled in `width` directly).

local WIDTH0 = {
    0x0300,
    0x036F,
    0x0483,
    0x0489,
    0x0591,
    0x05BD,
    0x05BF,
    0x05BF,
    0x05C1,
    0x05C2,
    0x05C4,
    0x05C5,
    0x05C7,
    0x05C7,
    0x0600,
    0x0605,
    0x0610,
    0x061A,
    0x061C,
    0x061C,
    0x064B,
    0x065F,
    0x0670,
    0x0670,
    0x06D6,
    0x06DC,
    0x06DF,
    0x06E4,
    0x06E7,
    0x06E8,
    0x06EA,
    0x06ED,
    0x070F,
    0x070F,
    0x0711,
    0x0711,
    0x0730,
    0x074A,
    0x07A6,
    0x07B0,
    0x07EB,
    0x07F3,
    0x07FD,
    0x07FD,
    0x0816,
    0x0819,
    0x081B,
    0x0823,
    0x0825,
    0x0827,
    0x0829,
    0x082D,
    0x0859,
    0x085B,
    0x0898,
    0x089F,
    0x08CA,
    0x08E1,
    0x08E3,
    0x0902,
    0x093A,
    0x093A,
    0x093C,
    0x093C,
    0x0941,
    0x0948,
    0x094D,
    0x094D,
    0x0951,
    0x0957,
    0x0962,
    0x0963,
    0x0981,
    0x0981,
    0x09BC,
    0x09BC,
    0x09C1,
    0x09C4,
    0x09CD,
    0x09CD,
    0x09E2,
    0x09E3,
    0x09FE,
    0x09FE,
    0x0A01,
    0x0A02,
    0x0A3C,
    0x0A3C,
    0x0A41,
    0x0A42,
    0x0A47,
    0x0A48,
    0x0A4B,
    0x0A4D,
    0x0A51,
    0x0A51,
    0x0A70,
    0x0A71,
    0x0A75,
    0x0A75,
    0x0A81,
    0x0A82,
    0x0ABC,
    0x0ABC,
    0x0AC1,
    0x0AC5,
    0x0AC7,
    0x0AC8,
    0x0ACD,
    0x0ACD,
    0x0AE2,
    0x0AE3,
    0x0AFA,
    0x0AFF,
    0x0B01,
    0x0B01,
    0x0B3C,
    0x0B3C,
    0x0B3F,
    0x0B3F,
    0x0B41,
    0x0B44,
    0x0B4D,
    0x0B4D,
    0x0B55,
    0x0B56,
    0x0B62,
    0x0B63,
    0x0B82,
    0x0B82,
    0x0BC0,
    0x0BC0,
    0x0BCD,
    0x0BCD,
    0x0C00,
    0x0C00,
    0x0C04,
    0x0C04,
    0x0C3C,
    0x0C3C,
    0x0C3E,
    0x0C40,
    0x0C46,
    0x0C48,
    0x0C4A,
    0x0C4D,
    0x0C55,
    0x0C56,
    0x0C62,
    0x0C63,
    0x0C81,
    0x0C81,
    0x0CBC,
    0x0CBC,
    0x0CBF,
    0x0CBF,
    0x0CE6,
    0x0CE8,
    0x0D00,
    0x0D01,
    0x0D3B,
    0x0D3C,
    0x0D41,
    0x0D44,
    0x0D4D,
    0x0D4D,
    0x0D62,
    0x0D63,
    0x0D81,
    0x0D81,
    0x0DCA,
    0x0DCA,
    0x0DD2,
    0x0DD4,
    0x0DD6,
    0x0DD6,
    0x0E31,
    0x0E31,
    0x0E34,
    0x0E3A,
    0x0E47,
    0x0E4E,
    0x0EB1,
    0x0EB1,
    0x0EB4,
    0x0EBC,
    0x0EC8,
    0x0ECE,
    0x0F18,
    0x0F19,
    0x0F35,
    0x0F35,
    0x0F37,
    0x0F37,
    0x0F39,
    0x0F39,
    0x0F71,
    0x0F7E,
    0x0F80,
    0x0F84,
    0x0F86,
    0x0F87,
    0x0F8D,
    0x0F97,
    0x0F99,
    0x0FBC,
    0x0FC6,
    0x0FC6,
    0x102D,
    0x1030,
    0x1032,
    0x1037,
    0x1039,
    0x103A,
    0x103D,
    0x103E,
    0x1058,
    0x1059,
    0x105E,
    0x1060,
    0x1071,
    0x1074,
    0x1082,
    0x1082,
    0x1085,
    0x1086,
    0x108D,
    0x108D,
    0x109D,
    0x109D,
    0x135D,
    0x135F,
    0x1712,
    0x1714,
    0x1732,
    0x1733,
    0x1752,
    0x1753,
    0x1772,
    0x1773,
    0x17B4,
    0x17B5,
    0x17B7,
    0x17BD,
    0x17C6,
    0x17C6,
    0x17C9,
    0x17D3,
    0x17DD,
    0x17DD,
    0x180B,
    0x180F,
    0x1885,
    0x1886,
    0x18A9,
    0x18A9,
    0x1920,
    0x1922,
    0x1927,
    0x1928,
    0x1932,
    0x1932,
    0x1939,
    0x193B,
    0x1A17,
    0x1A18,
    0x1A1B,
    0x1A1B,
    0x1A56,
    0x1A56,
    0x1A58,
    0x1A5E,
    0x1A60,
    0x1A60,
    0x1A62,
    0x1A62,
    0x1A65,
    0x1A6C,
    0x1A73,
    0x1A7C,
    0x1A7F,
    0x1A7F,
    0x1AB0,
    0x1ACE,
    0x1B00,
    0x1B03,
    0x1B34,
    0x1B34,
    0x1B36,
    0x1B3A,
    0x1B3C,
    0x1B3C,
    0x1B42,
    0x1B42,
    0x1B6B,
    0x1B73,
    0x1B80,
    0x1B81,
    0x1BA2,
    0x1BA5,
    0x1BA8,
    0x1BA9,
    0x1BAB,
    0x1BAD,
    0x1BE6,
    0x1BE6,
    0x1BE8,
    0x1BE9,
    0x1BED,
    0x1BED,
    0x1BEF,
    0x1BF1,
    0x1C2C,
    0x1C33,
    0x1C36,
    0x1C37,
    0x1CD0,
    0x1CD2,
    0x1CD4,
    0x1CE0,
    0x1CE2,
    0x1CE8,
    0x1CED,
    0x1CED,
    0x1CF4,
    0x1CF4,
    0x1CF8,
    0x1CF9,
    0x1DC0,
    0x1DFF,
    0x200B,
    0x200F,
    0x202A,
    0x202E,
    0x2060,
    0x2064,
    0x2066,
    0x206F,
    0x20D0,
    0x20F0,
    0x2CEF,
    0x2CF1,
    0x2D7F,
    0x2D7F,
    0x2DE0,
    0x2DFF,
    0x302A,
    0x302D,
    0x3099,
    0x309A,
    0xA66F,
    0xA672,
    0xA674,
    0xA67D,
    0xA69E,
    0xA69F,
    0xA6F0,
    0xA6F1,
    0xA802,
    0xA802,
    0xA806,
    0xA806,
    0xA80B,
    0xA80B,
    0xA825,
    0xA826,
    0xA82C,
    0xA82C,
    0xA8C4,
    0xA8C5,
    0xA8E0,
    0xA8F1,
    0xA8FF,
    0xA8FF,
    0xA926,
    0xA92D,
    0xA947,
    0xA951,
    0xA980,
    0xA982,
    0xA9B3,
    0xA9B3,
    0xA9B6,
    0xA9B9,
    0xA9BC,
    0xA9BD,
    0xA9E5,
    0xA9E5,
    0xAA29,
    0xAA2E,
    0xAA31,
    0xAA32,
    0xAA35,
    0xAA36,
    0xAA43,
    0xAA43,
    0xAA4C,
    0xAA4C,
    0xAA7C,
    0xAA7C,
    0xAAB0,
    0xAAB0,
    0xAAB2,
    0xAAB4,
    0xAAB7,
    0xAAB8,
    0xAABE,
    0xAABF,
    0xAAC1,
    0xAAC1,
    0xAAEC,
    0xAAED,
    0xAAF6,
    0xAAF6,
    0xABE5,
    0xABE5,
    0xABE8,
    0xABE8,
    0xABED,
    0xABED,
    0xFB1E,
    0xFB1E,
    0xFE00,
    0xFE0F,
    0xFE20,
    0xFE2F,
    0xFEFF,
    0xFEFF,
    0xFFF9,
    0xFFFB,
    0x101FD,
    0x101FD,
    0x102E0,
    0x102E0,
    0x10376,
    0x1037A,
    0x10A01,
    0x10A03,
    0x10A05,
    0x10A06,
    0x10A0C,
    0x10A0F,
    0x10A38,
    0x10A3A,
    0x10A3F,
    0x10AE5,
    0x10AE6,
    0x10D24,
    0x10D27,
    0x10EAB,
    0x10EAC,
    0x10F46,
    0x10F50,
    0x10F82,
    0x10F85,
    0x11001,
    0x11001,
    0x11038,
    0x11046,
    0x11070,
    0x11070,
    0x11073,
    0x11074,
    0x1107F,
    0x11081,
    0x110B3,
    0x110B6,
    0x110B9,
    0x110BA,
    0x110C2,
    0x110C2,
    0x11100,
    0x11102,
    0x11127,
    0x1112B,
    0x1112D,
    0x11134,
    0x11173,
    0x11173,
    0x11180,
    0x11181,
    0x111B6,
    0x111BE,
    0x111C9,
    0x111CC,
    0x111CF,
    0x111CF,
    0x1122F,
    0x11331,
    0x1133B,
    0x1133C,
    0x11340,
    0x11340,
    0x11366,
    0x1136C,
    0x11370,
    0x11374,
    0x11438,
    0x1143F,
    0x11442,
    0x11444,
    0x11446,
    0x11446,
    0x1145E,
    0x1145E,
    0x114B3,
    0x114B8,
    0x114BA,
    0x114BA,
    0x114BF,
    0x114C0,
    0x114C2,
    0x114C3,
    0x115B2,
    0x115B5,
    0x115BC,
    0x115BD,
    0x115BF,
    0x115C0,
    0x115DC,
    0x115DD,
    0x11633,
    0x1163A,
    0x1163D,
    0x1163D,
    0x1163F,
    0x11640,
    0x116AB,
    0x116AB,
    0x116AD,
    0x116AD,
    0x116B0,
    0x116B5,
    0x116B7,
    0x116B7,
    0x1171D,
    0x1171F,
    0x11722,
    0x11725,
    0x11727,
    0x1172B,
    0x1182F,
    0x11837,
    0x11839,
    0x1183A,
    0x1193B,
    0x1193C,
    0x1193E,
    0x1193E,
    0x11943,
    0x11943,
    0x119D4,
    0x119D7,
    0x119DA,
    0x119DB,
    0x119E0,
    0x119E0,
    0x11A01,
    0x11A0A,
    0x11A33,
    0x11A38,
    0x11A3B,
    0x11A3E,
    0x11A47,
    0x11A47,
    0x11A51,
    0x11A56,
    0x11A59,
    0x11A5B,
    0x11A8A,
    0x11A96,
    0x11A98,
    0x11A99,
    0x11C30,
    0x11C36,
    0x11C38,
    0x11C3D,
    0x11C3D,
    0x11C3F,
    0x11C3F,
    0x11C92,
    0x11CA7,
    0x11CAA,
    0x11CB0,
    0x11CB2,
    0x11CB3,
    0x11CB5,
    0x11CB6,
    0x11D31,
    0x11D36,
    0x11D3A,
    0x11D3A,
    0x11D3C,
    0x11D3D,
    0x11D3F,
    0x11D45,
    0x11D47,
    0x11D47,
    0x11D90,
    0x11D91,
    0x11D95,
    0x11D95,
    0x11D97,
    0x11D97,
    0x11EF3,
    0x11EF4,
    0x11F00,
    0x11F01,
    0x11F36,
    0x11F3A,
    0x11F40,
    0x11F40,
    0x11F42,
    0x11F42,
    0x13430,
    0x13440,
    0x13447,
    0x13455,
    0x16AF0,
    0x16AF4,
    0x16B30,
    0x16B36,
    0x16F4F,
    0x16F4F,
    0x16F8F,
    0x16F92,
    0x16FE4,
    0x16FE4,
    0x1BC9D,
    0x1BC9E,
    0x1CF00,
    0x1CF2D,
    0x1CF30,
    0x1CF46,
    0x1D167,
    0x1D169,
    0x1D173,
    0x1D182,
    0x1D185,
    0x1D18B,
    0x1D1AA,
    0x1D1AD,
    0x1D242,
    0x1D244,
    0x1DA00,
    0x1DA36,
    0x1DA3B,
    0x1DA6C,
    0x1DA75,
    0x1DA75,
    0x1DA84,
    0x1DA84,
    0x1DA9B,
    0x1DA9F,
    0x1DAA1,
    0x1DAAF,
    0x1E000,
    0x1E006,
    0x1E008,
    0x1E018,
    0x1E01B,
    0x1E021,
    0x1E023,
    0x1E024,
    0x1E026,
    0x1E02A,
    0x1E130,
    0x1E136,
    0x1E2AE,
    0x1E2AE,
    0x1E2EC,
    0x1E2EF,
    0x1E8D0,
    0x1E8D6,
    0x1E944,
    0x1E94A,
    0xE0001,
    0xE0001,
    0xE0020,
    0xE007F,
    0xE0100,
    0xE01EF,
}

local WIDTH2 = {
    -- Hangul Jamo (L) and wide CJK/emoji symbol punctuation.
    0x1100,
    0x115F,
    0x231A,
    0x231B,
    0x2329,
    0x232A,
    0x23E9,
    0x23EC,
    0x23F0,
    0x23F0,
    0x23F3,
    0x23F3,
    0x25FD,
    0x25FD,
    0x2614,
    0x2615,
    0x2648,
    0x2653,
    0x267F,
    0x267F,
    0x2693,
    0x2693,
    0x26A1,
    0x26A1,
    0x26AA,
    0x26AB,
    0x26BD,
    0x26BE,
    0x26C4,
    0x26C5,
    0x26CE,
    0x26CE,
    0x26D4,
    0x26D4,
    0x26EA,
    0x26EA,
    0x26F2,
    0x26F3,
    0x26F5,
    0x26F5,
    0x26FA,
    0x26FA,
    0x26FD,
    0x26FD,
    0x2705,
    0x2705,
    0x270A,
    0x270B,
    0x2728,
    0x2728,
    0x274C,
    0x274C,
    0x274E,
    0x274E,
    0x2753,
    0x2755,
    0x2757,
    0x2757,
    0x2795,
    0x2797,
    0x27B0,
    0x27B0,
    0x27BF,
    0x27BF,
    0x2B1B,
    0x2B1C,
    0x2B50,
    0x2B50,
    0x2B55,
    0x2B55,
    -- CJK ideographs, kana, Hangul syllables, wide symbols.
    0x2E80,
    0x303E,
    0x3041,
    0x33FF,
    0x3400,
    0x4DBF,
    0x4E00,
    0xA4CF,
    0xA960,
    0xA97F,
    0xAC00,
    0xD7A3,
    0xF900,
    0xFAFF,
    0xFE10,
    0xFE19,
    0xFE30,
    0xFE6F,
    0xFF00,
    0xFF60,
    0xFFE0,
    0xFFE6,
    -- CJK Extension blocks (Tangut, Nushu, etc).
    0x16FE0,
    0x16FE4,
    0x16FF0,
    0x16FF1,
    0x17000,
    0x187F7,
    0x18800,
    0x18CD5,
    0x18D00,
    0x18D08,
    0x1AFF0,
    0x1B12F,
    0x1B150,
    0x1B152,
    0x1B164,
    0x1B167,
    0x1B170,
    0x1B2FF,
    -- Sorted emoji / flag ranges. Order matters: `in_table` binary-
    -- searches the sorted (lo,hi) pairs, so each range's lo must be
    -- strictly greater than the previous range's hi.
    0x1F004,
    0x1F004,
    0x1F0CF,
    0x1F0CF,
    0x1F18E,
    0x1F18E,
    0x1F191,
    0x1F19A,
    0x1F1E6,
    0x1F1FF,
    -- Consolidated emoji / Extended_Pictographic block. wcwidth fragments
    -- this into dozens of sub-ranges to exclude a handful of
    -- narrow-by-default pictographs; we collapse to one non-overlapping
    -- 0x1F300-0x1FAFF range matching what most modern terminals render
    -- as width 2 (covers Emoticons, Transport/Map, the rest of the
    -- pictographic plane).
    0x1F300,
    0x1FAFF,
    -- CJK Extension G/H/I (plane 3).
    0x20000,
    0x2FFFD,
    0x30000,
    0x3FFFD,
}

--- Binary-search a flat {lo1,hi1, lo2,hi2, ...} range table for `cp`.
---@param cp integer
---@param t integer[]
---@return boolean
local function in_table(cp, t)
    local n = #t
    if n == 0 then
        return false
    end
    local lo, hi = 1, n / 2
    while lo <= hi do
        local r = math.floor((lo + hi) / 2)
        local rlo = t[2 * r - 1]
        local rhi = t[2 * r]
        if cp < rlo then
            hi = r - 1
        elseif cp > rhi then
            lo = r + 1
        else
            return true
        end
    end
    return false
end
utf8._in_table = in_table

--- Display width of a codepoint: 0, 1, or 2.
---@param cp integer
---@return integer
function utf8.width(cp)
    if cp < 0x20 or (cp >= 0x7F and cp < 0xA0) then
        return 0
    end
    if in_table(cp, WIDTH0) then
        return 0
    end
    if in_table(cp, WIDTH2) then
        return 2
    end
    return 1
end

----------------------------------------------------------------------------------------------------
-- UAX #29 grapheme cluster properties (pragmatic subset)
----------------------------------------------------------------------------------------------------

local CR, LF = 0x000D, 0x000A
local ZWJ = 0x200D
local BOM = 0xFEFF
local L_lo, L_hi = 0x1100, 0x115F
local V_lo, V_hi = 0x1160, 0x11A7
local LV_lo, LV_hi = 0xA960, 0xA97F -- Hangul Jamo Extended-A (L)
local T_lo, T_hi = 0x11A8, 0x11FF
local LVT_lo, LVT_hi = 0xAC00, 0xD7A3
local RI_lo, RI_hi = 0x1F1E6, 0x1F1FF

--- Classify a codepoint for UAX #29 grapheme clustering.
---@param cp integer
---@return string
function utf8.grapheme_type(cp)
    if cp == CR then
        return "CR"
    end
    if cp == LF then
        return "LF"
    end
    if cp == ZWJ then
        return "ZWJ"
    end
    if (cp >= 0x00 and cp <= 0x1F) or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F) then
        return "Control"
    end
    if cp >= L_lo and cp <= L_hi then
        return "L"
    end
    if cp >= V_lo and cp <= V_hi then
        return "V"
    end
    if cp >= LV_lo and cp <= LV_hi then
        return "L"
    end
    if cp >= T_lo and cp <= T_hi then
        return "T"
    end
    if cp >= LVT_lo and cp <= LVT_hi then
        return "LVT"
    end
    if cp >= RI_lo and cp <= RI_hi then
        return "Regional_Indicator"
    end
    -- Extended_Pictographic approximation: the consolidated emoji
    -- ranges mirrored from WIDTH2 (small pre-1F300 pictographs + the
    -- 0x1F300-0x1FAFF block). Grapheme clustering only needs a rough
    -- Pictographic classification for GB11 (ZWJ sequences) — the exact
    -- width comes from `width()`, not from this predicate.
    --
    -- Per Unicode's emoji-data.txt Extended_Pictographic property:
    -- includes the supplemental pictographic blocks below 0x1F300
    -- (symbols, dingbats, arrows) that participate in ZWJ sequences
    -- like the "couple with heart" emoji (woman + ZWJ + heart + VS16 +
    -- ZWJ + man), where the heart U+2764 must be Pictographic for GB11
    -- to keep the cluster intact.
    if
        (cp >= 0x00A9 and cp <= 0x00AE)
        or (cp >= 0x203C and cp <= 0x2049)
        or (cp >= 0x2122 and cp <= 0x2139)
        or (cp >= 0x2194 and cp <= 0x2199)
        or (cp >= 0x21A9 and cp <= 0x21AA)
        or (cp >= 0x231A and cp <= 0x231B)
        or (cp >= 0x2328 and cp <= 0x2328)
        or (cp >= 0x23CF and cp <= 0x23CF)
        or (cp >= 0x23E9 and cp <= 0x23F3)
        or (cp >= 0x23F8 and cp <= 0x23FA)
        or (cp >= 0x24C2 and cp <= 0x24C2)
        or (cp >= 0x25AA and cp <= 0x25AB)
        or (cp >= 0x25B6 and cp <= 0x25B6)
        or (cp >= 0x25C0 and cp <= 0x25C0)
        or (cp >= 0x25FB and cp <= 0x25FE)
        or (cp >= 0x2600 and cp <= 0x27BF)
        or (cp >= 0x2934 and cp <= 0x2935)
        or (cp >= 0x2B05 and cp <= 0x2B07)
        or (cp >= 0x2B1B and cp <= 0x2B1C)
        or (cp >= 0x2B50 and cp <= 0x2B55)
        or (cp >= 0x1F004 and cp <= 0x1F0CF)
        or (cp >= 0x1F18E and cp <= 0x1F19A)
        or (cp >= 0x1F1E6 and cp <= 0x1F1FF)
        or (cp >= 0x1F300 and cp <= 0x1FAFF)
    then
        return "Pictographic"
    end
    -- Prepend: a handful of codepoints with Cf category (this is the
    -- practical set; full Prepend is larger).
    if cp == 0x0605 or cp == 0x070F then
        return "Prepend"
    end
    -- Extend: combining marks (mostly the WIDTH0 set, minus ZWJ/BOM).
    if cp ~= BOM and in_table(cp, WIDTH0) then
        return "Extend"
    end
    return "Other"
end

----------------------------------------------------------------------------------------------------
-- Grapheme walker / line parser
----------------------------------------------------------------------------------------------------

--- Parse a line into a grapheme skeleton.
---
--- `byte_starts[i]` = 1-based byte index where grapheme i starts.
--- `widths[i]`     = display width of grapheme i (sum of codepoint widths;
---                    combinings contribute 0).
--- `prefix[i]`     = display column where grapheme i starts (prefix[1]=0).
--- The number of graphemes is `#byte_starts`. An empty line returns three
--- empty tables. `s` MUST be the line WITHOUT its trailing newline.
---@param s string
---@return integer[] byte_starts
---@return integer[] widths
---@return integer[] prefix
function utf8.parse_line(s)
    local byte_starts, widths, prefix = {}, {}, {}
    local n = #s
    if n == 0 then
        return byte_starts, widths, prefix
    end

    local i = 1
    local col = 0
    local ri_run = 0
    local picto_ext = false
    local zwj_pending = false
    local prev_t = nil
    local cluster_start_byte, cluster_w, cluster_has_zwj, cluster_has_vs16
    local cluster_ri_count

    while i <= n do
        local cp, next_i = utf8.decode(s, i)
        local t = utf8.grapheme_type(cp)
        local w = utf8.width(cp)

        local brk
        if prev_t == nil then
            brk = true -- GB1: break at start of text.
        else
            brk = true -- GB999 default unless a × rule matches.
            if prev_t == "CR" and t == "LF" then
                brk = false -- GB3
            elseif t == "Extend" or t == "ZWJ" or t == "SpacingMark" then
                brk = false -- GB9 / GB9a
            elseif prev_t == "Prepend" then
                brk = false -- GB9b
            elseif prev_t == "L" and (t == "L" or t == "V" or t == "LV" or t == "LVT") then
                brk = false -- GB6
            elseif (prev_t == "LV" or prev_t == "V") and (t == "V" or t == "T") then
                brk = false -- GB7
            elseif (prev_t == "LVT" or prev_t == "T") and t == "T" then
                brk = false -- GB8
            elseif t == "Pictographic" and zwj_pending then
                brk = false -- GB11
            elseif prev_t == "Regional_Indicator" and t == "Regional_Indicator" then
                brk = (ri_run % 2 == 0) -- GB12/13
            end
            -- GB4/GB5 force a break around Control/CR/LF EXCEPT GB3.
            if brk == false then
                if
                    prev_t == "Control"
                    or prev_t == "CR"
                    or prev_t == "LF"
                    or t == "Control"
                    or t == "CR"
                    or t == "LF"
                then
                    if not (prev_t == "CR" and t == "LF") then
                        brk = true
                    end
                end
            end
        end

        if brk then
            if cluster_start_byte ~= nil then
                byte_starts[#byte_starts + 1] = cluster_start_byte
                -- Match termbox2's tb_cluster_width: ZWJ families compose
                -- to a single 2-cell glyph, and a run of >= 2 regional
                -- indicators composes to one 2-cell flag. Rather than
                -- summing each emoji's width, cap the cluster at 2 so
                -- cursor/wrap math stays in lockstep with the renderer.
                if
                    (cluster_has_zwj or cluster_has_vs16 or cluster_ri_count >= 2)
                    and cluster_w >= 1
                then
                    cluster_w = 2
                end
                widths[#widths + 1] = cluster_w
                prefix[#prefix + 1] = col
                col = col + cluster_w
            end
            cluster_start_byte = i
            cluster_w = w
            cluster_has_zwj = (t == "ZWJ")
            cluster_has_vs16 = (cp == 0xFE0F)
            cluster_ri_count = (t == "Regional_Indicator") and 1 or 0
            picto_ext = (t == "Pictographic")
            zwj_pending = false
        else
            cluster_w = cluster_w + w
            cluster_has_zwj = cluster_has_zwj or (t == "ZWJ")
            cluster_has_vs16 = cluster_has_vs16 or (cp == 0xFE0F)
            if t == "Regional_Indicator" then
                cluster_ri_count = cluster_ri_count + 1
            end
            if t == "Pictographic" then
                picto_ext = true
            end
        end

        if t == "Regional_Indicator" then
            ri_run = ri_run + 1
            picto_ext = false
            zwj_pending = false
        elseif t == "ZWJ" then
            zwj_pending = picto_ext
        elseif t == "Extend" or t == "SpacingMark" then
            zwj_pending = false
        else
            if t ~= "Pictographic" then
                picto_ext = false
                zwj_pending = false
            end
            if t ~= "Regional_Indicator" then
                ri_run = 0
            end
        end

        prev_t = t
        i = next_i
    end

    if cluster_start_byte ~= nil then
        if (cluster_has_zwj or cluster_has_vs16 or cluster_ri_count >= 2) and cluster_w >= 1 then
            cluster_w = 2
        end
        byte_starts[#byte_starts + 1] = cluster_start_byte
        widths[#widths + 1] = cluster_w
        prefix[#prefix + 1] = col
    end

    return byte_starts, widths, prefix
end

----------------------------------------------------------------------------------------------------
-- Skeleton queries (used by the View's per-line grapheme cache)
----------------------------------------------------------------------------------------------------
-- All queries take the three tables returned by `parse_line` and 0-based
-- byte offsets / display columns. They binary-search `byte_starts` and use
-- `prefix` for display columns. Runs in O(log G) where G = grapheme count.
-- Convention: byte offset `b` (0-based) belongs to the grapheme whose byte
-- range is [byte_starts[i], byte_starts[i+1]); a byte at a grapheme start
-- belongs to THAT grapheme, and `b == line_len` maps to the past-end slot.

--- Total display width of a parsed line (column just past the last grapheme).
---@param prefix integer[]
---@param widths integer[]
---@return integer
function utf8.line_width(prefix, widths)
    local n = #prefix
    if n == 0 then
        return 0
    end
    return prefix[n] + widths[n]
end

--- Find the grapheme index (1-based, in [1, n+1]) containing byte offset
--- `b` (0-based). A past-end byte maps to the virtual slot n+1.
---@param byte_starts integer[]
---@param b integer 0-based byte offset
---@return integer
local function grapheme_at_byte(byte_starts, b)
    local n = #byte_starts
    if n == 0 then
        return 1
    end
    local target = b + 1
    local lo, hi = 1, n + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if byte_starts[mid] > target then
            hi = mid
        else
            lo = mid + 1
        end
    end
    local gi = lo - 1
    if gi < 1 then
        gi = 1
    end
    return gi
end
utf8.grapheme_at_byte = grapheme_at_byte

--- Display column (0-based) of a byte offset within a parsed line.
--- A byte offset equal to `line_len` maps to the total line width. Mid-cluster
--- offsets report the containing grapheme's start column.
---@param byte_starts integer[]
---@param prefix integer[]
---@param widths integer[]
---@param b integer 0-based byte offset
---@param line_len integer total byte length of the line
---@return integer
function utf8.byte_to_col(byte_starts, prefix, widths, b, line_len)
    local n = #prefix
    if n == 0 then
        return 0
    end
    if b >= line_len then
        return prefix[n] + widths[n]
    end
    local gi = grapheme_at_byte(byte_starts, b)
    if gi > n then
        gi = n
    end
    return prefix[gi]
end

--- Byte offset (0-based) at the START of grapheme `gi` (1-based).
---@param byte_starts integer[]
---@param gi integer 1-based grapheme index
---@return integer
function utf8.grapheme_start_byte(byte_starts, gi)
    local v = byte_starts[gi]
    if v == nil then
        v = byte_starts[#byte_starts]
        if v == nil then
            return 0
        end
    end
    return v - 1
end

--- Byte offset (0-based) just PAST the end of grapheme `gi`.
---@param byte_starts integer[]
---@param gi integer 1-based grapheme index
---@return integer
function utf8.grapheme_end_byte(byte_starts, gi)
    local n = #byte_starts
    if gi >= n then
        local v = byte_starts[n]
        return v and (v - 1) or 0
    end
    return byte_starts[gi + 1] - 1
end

--- Byte offset (0-based) of a DISPLAY COLUMN within a parsed line.
--- Columns inside a wide grapheme snap to that grapheme's start byte.
--- Past-end columns clamp to the line's content length.
---@param byte_starts integer[]
---@param prefix integer[]
---@param widths integer[]
---@param col integer 0-based display column
---@param line_len integer total byte length of the line
---@return integer
function utf8.col_to_byte(byte_starts, prefix, widths, col, line_len)
    local n = #byte_starts
    if n == 0 then
        return 0
    end
    local lo, hi = 1, n + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local p = prefix[mid]
        if p == nil then
            hi = mid
        elseif p > col then
            hi = mid
        else
            lo = mid + 1
        end
    end
    local gi = lo - 1
    if gi < 1 then
        gi = 1
    end
    if gi >= n then
        local last_prefix = prefix[n]
        local last_w = widths[n]
        if col >= last_prefix + last_w then
            return line_len
        end
        return byte_starts[n] - 1
    end
    return byte_starts[gi] - 1
end

--- Advance `n` graphemes from byte offset `b` (0-based); clamped to
--- `[0, line_len]`. `n` may be negative. Landing on a grapheme returns its
--- START byte.
---@param byte_starts integer[]
---@param b integer 0-based starting byte offset
---@param n integer signed grapheme count
---@param line_len integer total byte length of the line
---@return integer
function utf8.advance_grapheme(byte_starts, b, n, line_len)
    local ng = #byte_starts
    if ng == 0 then
        return 0
    end
    local gi
    if b >= line_len then
        gi = ng + 1
    else
        gi = grapheme_at_byte(byte_starts, b)
    end
    local target = gi + n
    if target < 1 then
        target = 1
    elseif target > ng + 1 then
        target = ng + 1
    end
    if target > ng then
        return line_len
    end
    return byte_starts[target] - 1
end

return utf8
