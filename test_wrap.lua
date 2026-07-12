-- Test word-wrap behavior
package.path = "./src/?.lua"

local Buffer = require("cursed.buffer").Buffer
local View = require("cursed.view").View

local text = table.concat({
    "Hello world this is a test of word wrapping in the cursed editor.",
    "We want to make sure that words are not split in half when soft wrapping occurs.",
    "",
    "Short text.",
    "A singleverylongwordthatexceedswrapwidth.",
}, "\n")

local buf = Buffer.from_string(text)
local view = View.new(buf)
view.wrap_width = 20

-- Test wrap_rows for each line
print("=== wrap_rows for each line ===")
for li = 0, 4 do
    local rows = view:wrap_rows(li)
    local _, _, total = view:_wrap_graph(li)
    print(string.format("Line %d: wrap_rows=%d, _wrap_graph total=%d", li, rows, total))

    -- Print each sub-row's content
    print("  Sub-rows:")
    for sr = 0, rows - 1 do
        local runs, row_w = view:sub_row_runs(li, sr)
        local s = view:_line_text_stripped(li)
        local parts = {}
        for _, run in ipairs(runs) do
            table.insert(parts, s:sub(run.byte_start, run.byte_end))
        end
        print(string.format("    [%d] col=%d: '%s'", sr, row_w, table.concat(parts)))
    end
end

-- Test cursor navigation
print("\n=== cursor position after wraps ===")
local function test_pos(li, col)
    local sr, sc = view:wrap_sub_position(li, col)
    local bo = view:wrap_byte_offset(li, sr, sc)
    print(string.format("(li=%d, col=%d) -> sub_row=%d, sub_col=%d -> byte_offset=%d", li, col, sr, sc, bo))
end

test_pos(0, 0)
test_pos(0, 6)
test_pos(0, 12)

-- Get wrap graph details
local t0 = view:_line_text_stripped(0)
print("\nLine 0 text:", t0)

local bs, widths, _, _ = view:_graph(0)
local sub_rows, sub_cols, total, sub_first, sub_last = view:_wrap_graph(0)
print("Grapheme details for line 0:")
for i = 1, #widths do
    local next_b = bs[i+1]
    local ch = t0:sub(bs[i], next_b and (next_b - 1) or #t0)
    local is_space = t0:byte(bs[i]) == 0x20 and "SPACE" or ""
    print(string.format("  gi=%d byte=%d width=%d sub_row=%d sub_col=%d char='%s' %s",
        i, bs[i], widths[i], sub_rows[i], sub_cols[i], ch, is_space))
end

print("\nsub_first:")
if sub_first then
    for k, v in pairs(sub_first) do print(string.format("  row %d -> gi %d", k, v)) end
end
print("sub_last:")
if sub_last then
    for k, v in pairs(sub_last) do print(string.format("  row %d -> gi %d", k, v)) end
end
print("total_rows:", total)

-- Print all sub-rows for line 0 in order
print("\n=== Full wrap layout for line 0 ===")
for sr = 0, total - 1 do
    local runs, row_w = view:sub_row_runs(0, sr)
    local s = view:_line_text_stripped(0)
    local parts = {}
    for _, run in ipairs(runs) do
        table.insert(parts, s:sub(run.byte_start, run.byte_end))
    end
    print(string.format("  sub_row %d: '%s'", sr, table.concat(parts)))
end

print("\nDONE")
