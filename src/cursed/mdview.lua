--- Hyper-basic markdown → termbox editor renderer.
---
--- One function: `render(term, x, y, width, md, fg, bg)` draws the
--- markdown string `md` into the termbox back buffer starting at
--- (x, y), wrapping prose to `width` columns. Markup markers are
--- stripped from the visible text; formatting is carried by termbox
--- attributes:
---
---   • headings (`#`..`######`) -> title color + bold
---   • fenced code blocks ``` ` ``` ` ``` -> full tree-sitter syntax
---     highlight via the language named after the opening fence,
---     resolved to the major mode carrying that `language`
---   • inline `` `code` `` -> the scheme's `text.literal` color
---     (a brighter, non-fg palette slot)
---   • `**bold**` / `__bold__` -> bold
---   • `*italic*` / `_italic_` -> italic
---   • `[label](url)` -> the scheme's `text.uri` color + underline for
---     the label, with the bare URL appended in parens in the same hue
---     (dimmer, no underline): `label (url)`. Neither is an OSC 8
---     hyperlink (terminal mouse reporting in the editor intercepts
---     clicks), so the URL is shown explicitly for copy-paste.
---
--- When no active ColorScheme is loaded, the formatting falls back to
--- style bits on top of the caller-supplied `fg` (so it still renders
--- distinctly in truecolor OR `output_normal` mode).
---
--- This module is intentionally line-oriented and tiny: it does not
--- parse the full CommonMark grammar. It is meant for short prose
--- blocks (help text, popups, buffer previews), not as a markdown
--- document engine.

local bit = require("bit")
local tb = require("cursed.tb")
local ColorScheme = require("cursed.colorscheme")
local Highlighter = require("cursed.highlighter")
local log = require("cursed.log")

local M = {}

-- Per-language (info string) highlighter cache. Built lazily from the
-- major-mode registry; nil when no mode carries the language or when
-- the mode has no query.
---@type table<string, Highlighter|false>
local hl_cache = {}

-- Common alias → grammar/mode language. Lets ` ```sh ` and
-- ` ```python ` resolve to the bundled grammar the same way nvim does.
local LANG_ALIAS = {
    sh = "bash",
    shell = "bash",
    py = "python",
    rb = "ruby",
    js = "javascript",
    ts = "typescript",
    cplusplus = "cpp",
    ["c++"] = "cpp",
}

--- Resolve the tree-sitter Highlighter for a fenced-code info string.
--- The info string's first word names the language (common aliases
--- like `sh`→`bash` applied). Looks it up against the major-mode
--- registry (a mode whose `language` matches and that carries a
--- `highlight_query`); builds a Highlighter on first sight and caches
--- it. Returns nil for unknown languages → caller renders plain.
---@param info string|nil raw info string ("lua", "python3", "", ...)
---@return Highlighter|false|nil
local function highlighter_for(info)
    if info == nil or info == "" then
        return nil
    end
    local lang = info:match("%S+") -- first whitespace-delimited token
    if lang == nil then
        return nil
    end
    lang = lang:lower()
    lang = LANG_ALIAS[lang] or lang
    if hl_cache[lang] ~= nil then
        return hl_cache[lang]
    end
    -- Sentinel to short-circuit repeated lookups for languages with no
    -- matching mode; we cache `false` so `~= nil` still distinguishes.
    local resolved = nil
    local ok, modes = pcall(require, "cursed.modes")
    if ok and modes and modes.modes then
        -- Scan by `language` field so an info string names a grammar,
        -- not a mode's display name (they happen to coincide for the
        -- built-ins but the lookup contract is grammar → mode).
        for _, mode in pairs(modes.modes) do
            if mode.language == lang and mode.highlight_query then
                local hl, err = Highlighter.new(mode.language, mode.highlight_query)
                if hl then
                    resolved = hl
                else
                    log.warn(
                        "mdview",
                        "highlighter build failed",
                        { language = lang, error = err or "?" }
                    )
                end
                break
            end
        end
    end
    hl_cache[lang] = resolved or false
    return resolved or nil
end

--------------------------------------------------------------------------------------------------
-- Color resolution (delegated to the active ColorScheme where present).
--------------------------------------------------------------------------------------------------

local function code_color(fg)
    local scheme = ColorScheme.active
    if scheme then
        return scheme:color("text.literal")
    end
    return bit.bor(fg, tb.bright)
end

local function link_color(fg)
    local scheme = ColorScheme.active
    if scheme then
        return bit.bor(scheme:color("text.uri"), tb.underline)
    end
    return bit.bor(fg, tb.underline)
end

--- Dimmer variant of the link color for the parenthesized URL that
--- follows the label. Same hue as the label but without underline,
--- so the human eye parses `label (url)` as one unit with the label
--- emphasized.
local function link_url_color(fg)
    local scheme = ColorScheme.active
    if scheme then
        return scheme:color("text.uri")
    end
    return fg
end

local function heading_attr(fg)
    local scheme = ColorScheme.active
    if scheme then
        return bit.bor(scheme:color("text.title"), tb.bold)
    end
    return bit.bor(fg, tb.bold)
end

--------------------------------------------------------------------------------------------------
-- Inline parser: turns a single prose line into a flat list of
-- {text=string, attr=int} segments with all markup markers stripped.
--
-- Recognizes, in priority order:
--   `code`         — backtick-delimited literal (no nesting inside)
--   **bold**/__bold__  — double-marker emphasis
--   *italic*/_italic_  — single-marker emphasis
--   [label](url)   — link (url dropped, label styled as a link)
-- Anything else is a plain run at base_attr.
--
-- Unmatched markers render literally; this keeps the visible text
-- faithful when markdown is malformed (no silent data loss).
--------------------------------------------------------------------------------------------------

-- Scan the next byte at or after `from` that begins a possible special
-- token. Returns the index of the byte (built-in `string.find` per
-- token type) — we want the MINIMUM across the candidate markers so
-- the plain-run emit can batch normal characters up to it.
local function next_special(line, from)
    local best = #line + 1
    local function consider(byte)
        local p = line:find(byte, from, true)
        if p and p < best then
            best = p
        end
    end
    consider("`")
    consider("*")
    consider("_")
    consider("[")
    return best -- may be #line+1 (none found)
end

--- Parse a prose line into styled segments.
---@param line string
---@param base_attr integer default attr for plain text
---@param code_attr integer  attr for inline code
---@param link_attr integer  attr for link labels
---@param link_url_attr integer attr for the parenthesized URL after a label
---@return table segs  list of {text=string, attr=int}
local function parse_inline(line, base_attr, code_attr, link_attr, link_url_attr)
    local segs = {}
    local function emit(text, attr, url)
        if text ~= "" then
            segs[#segs + 1] = { text = text, attr = attr, url = url }
        end
    end

    local i, n = 1, #line
    while i <= n do
        local ch = line:sub(i, i)
        if ch == "`" then
            local j = line:find("`", i + 1, true)
            if j then
                emit(line:sub(i + 1, j - 1), code_attr)
                i = j + 1
            else
                emit("`", base_attr)
                i = i + 1
            end
        elseif (ch == "*" or ch == "_") and line:sub(i + 1, i + 1) == ch then
            -- Bold (double marker). Find the matching double closer
            -- (ch..ch), NOT the first single occurrence — otherwise
            -- `__under_bold__` mis-detects the inner single `_` as the
            -- closer and bails.
            local start = i + 2
            local pos = line:find(ch .. ch, start, true)
            if pos then
                emit(line:sub(start, pos - 1), bit.bor(base_attr, tb.bold))
                i = pos + 2
            else
                emit(ch .. ch, base_attr)
                i = i + 2
            end
        elseif ch == "*" or ch == "_" then
            -- Italic (single marker)
            local start = i + 1
            local pos = line:find(ch, start, true)
            -- Guard against `*` inside a word faking an opener: only
            -- treat as italic when the closer isn't immediately a
            -- second marker (which would have matched the bold branch).
            if pos and line:sub(pos + 1, pos + 1) ~= ch then
                emit(line:sub(start, pos - 1), bit.bor(base_attr, tb.italic))
                i = pos + 1
            else
                emit(ch, base_attr)
                i = i + 1
            end
        elseif ch == "[" then
            local close = line:find("]", i + 1, true)
            if close and line:sub(close + 1, close + 1) == "(" then
                local urlclose = line:find(")", close + 2, true)
                if urlclose then
                    -- Render the link as `label (url)`: the label in the
                    -- scheme's link color (blue + underline), followed
                    -- by the bare URL in parens in a dimmer link color.
                    -- Both are visible, which makes the destination
                    -- copy-pasteable even without clickable OSC 8.
                    local label = line:sub(i + 1, close - 1)
                    local url = line:sub(close + 2, urlclose - 1)
                    emit(label, link_attr)
                    emit(" (" .. url .. ")", link_url_attr)
                    i = urlclose + 1
                else
                    emit("[", base_attr)
                    i = i + 1
                end
            else
                emit("[", base_attr)
                i = i + 1
            end
        else
            -- Plain run up to the next candidate marker.
            local stop = next_special(line, i) - 1
            if stop < i then
                stop = i
            end
            emit(line:sub(i, stop), base_attr)
            i = stop + 1
        end
    end
    return segs
end

--------------------------------------------------------------------------------------------------
-- Painters.
--------------------------------------------------------------------------------------------------

--- Count the number of screen rows `paint_prose` would write for
--- `segs` at `width` columns. Mirrors paint_prose's wrap logic EXACTLY
--- (word-runs re-joined as single spaces; a word longer than `width`
--- sits alone on its row and overflows). Pure (no painting) so the
--- popup-geometry code can size a box before rendering.
---@param segs table output of parse_inline
---@param width integer wrap width in cells
---@return integer rows
local function prose_rows(segs, width)
    if width < 1 then
        width = 1
    end
    local rows = 1 -- the row we're currently filling
    local col = 0
    local function wrap()
        col = 0
        rows = rows + 1
    end
    for _, s in ipairs(segs) do
        for word in s.text:gmatch("%S+") do
            local wlen = #word
            if col + wlen > width then
                wrap()
            end
            if col > 0 then
                col = col + 1
            end
            col = col + wlen
        end
    end
    return rows
end

--- Paint a list of styled segments into screen rows, word-wrapping at
--- `width` columns. Whitespace runs collapse to single inter-word
--- spaces (markdown-ish). Each row's tail is space-painted to `width`
--- with `bg` so the rendered block reads as a solid background strip.
--- Returns the next row after the painted block.
---@param term table Term
---@param x integer screen origin x
---@param row integer current screen row (mutated upward by wrapping)
---@param width integer wrap width in cells
---@param segs table output of parse_inline
---@param bg integer background attribute
---@return integer next_row
local function paint_prose(term, x, row, width, segs, bg)
    local col = 0
    local function clear_right()
        if col < width then
            term:print(x + col, row, (" "):rep(width - col), 0, bg)
        end
    end
    for _, s in ipairs(segs) do
        -- Iterate words (non-whitespace runs); gmatch("%S+") drops
        -- inter-word whitespace, re-joined below as a single space.
        for word in s.text:gmatch("%S+") do
            local wlen = #word
            if col + wlen > width then
                clear_right()
                col = 0
                row = row + 1
            end
            if col > 0 then
                term:print(x + col, row, " ", s.attr, bg)
                col = col + 1
            end
            term:print(x + col, row, word, s.attr, bg)
            col = col + wlen
        end
    end
    clear_right()
    return row + 1
end

--- Paint one code-block source line using its tree-sitter spans.
--- Unspanned bytes fall back to `plain_attr`. The row is tail-padded
--- to `width` with `bg` so the code block reads as a solid strip.
--- Returns the next row.
---@param term table Term
---@param x integer
---@param row integer
---@param width integer
---@param text string source line (no trailing newline)
---@param spans table|nil  {{cs=int,ce=int,fg=int},...} or nil/empty
---@param plain_attr integer attr for unspanned bytes + spacer
---@param bg integer
---@return integer next_row
local function paint_code_line(term, x, row, width, text, spans, plain_attr, bg)
    local col = 0
    local prev = 0
    if spans then
        for _, sp in ipairs(spans) do
            if sp.cs > prev then
                local pre = text:sub(prev + 1, sp.cs)
                term:print(x + col, row, pre, plain_attr, bg)
                col = col + #pre
            end
            local body = text:sub(sp.cs + 1, sp.ce)
            term:print(x + col, row, body, sp.fg, bg)
            col = col + #body
            prev = sp.ce
        end
    end
    if prev < #text then
        local rest = text:sub(prev + 1)
        term:print(x + col, row, rest, plain_attr, bg)
    end
    return row + 1
end

--- Build the Highlighter-style `line_starts` array for `code_lines`:
--- `line_starts[i]` = byte offset of line i-1's start (0-based), and
--- `line_starts[#]` = total bytes. Lines are joined with `\n`.
---@param code_lines string[] source lines (no trailing newline each)
---@return string text joined document
---@return integer[] line_starts 1-indexed [0, len_1+1, ..., total]
local function build_code_text(code_lines)
    if #code_lines == 0 then
        return "", { 0 }
    end
    local parts = {}
    local line_starts = { 0 }
    local offset = 0
    for i, line in ipairs(code_lines) do
        parts[i] = line
        offset = offset + #line + 1 -- +1 for the joining \n
        line_starts[i + 1] = offset
    end
    return table.concat(parts, "\n"), line_starts
end

--- Paint a complete fenced code block (already in code_lines),
--- highlighting via the resolved Highlighter for `info` when available.
---@param term table Term
---@param x integer
---@param row integer
---@param width integer
---@param code_lines string[]
---@param info string|nil fence info string (language label)
---@param plain_attr integer attr for unspanned bytes
---@param bg integer
---@return integer next_row
local function paint_code_block(term, x, row, width, code_lines, info, plain_attr, bg)
    local text, line_starts = build_code_text(code_lines)
    local spans_by_line = nil
    local hl = highlighter_for(info)
    if hl and #code_lines > 0 then
        spans_by_line = hl:highlight(text, line_starts)
    end
    for i, line in ipairs(code_lines) do
        local spans = spans_by_line and spans_by_line[i] or nil
        row = paint_code_line(term, x, row, width, line, spans, plain_attr, bg)
    end
    return row
end

--------------------------------------------------------------------------------------------------
-- Public entry point.
--------------------------------------------------------------------------------------------------

--- Render a markdown string into the termbox back buffer.
---
--- Layout is line-oriented; prose is word-wrapped to `width` columns
--- and code blocks render one source line per row. The caller is
--- responsible for `:present()` after the call (plus any padding rows
--- before/after). Returns the number of screen rows consumed.
---
--- `max_rows` (optional) caps the number of screen rows written; once
--- reached, rendering stops and the consumed count is returned. nil =
--- unbounded. Useful for fitting output into a fixed popup height.
---@param term table Term
---@param x integer screen origin column
---@param y integer screen origin row
---@param width integer wrap width in cells
---@param md string markdown text
---@param fg integer base foreground attribute (truecolor RGB int + optional style bits)
---@param bg integer background attribute
---@param max_rows integer|nil optional cap on screen rows written
---@return integer rows consumed
local function render(term, x, y, width, md, fg, bg, max_rows)
    local code_attr = code_color(fg)
    local link_attr = link_color(fg)
    local link_url_attr = link_url_color(fg)
    local head_attr = heading_attr(fg)

    local row = y
    local in_fence = false
    local fence_marker = nil -- the actual opener (``` or ~~~) for closing match
    local fence_info = nil
    local code_lines = {}
    local prev_blank = false -- collapse runs of consecutive blank lines

    -- Normalize CRLF/CR → LF and split on \n. The naive
    -- gmatch("[^\r\n]*") yields a spurious EMPTY match between the
    -- \r and \n of every CRLF line ending — which surfaced as a
    -- phantom blank row between every line of a fenced code block
    -- in LSP hover docs (servers emit CRLF). Splitting on \n after
    -- CR-stripping yields exactly one entry per source line.
    local norm = md:gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in (norm .. "\n"):gmatch("([^\n]*)\n") do
        if max_rows ~= nil and (row - y) >= max_rows then
            break -- height cap reached: stop consuming more source lines
        end
        if in_fence then
            -- Closing fence: same run of backticks/tilde, possibly ≥ fence length.
            local closer = line:match("^%s*([`~]+)%s*$")
            if closer and #closer >= #fence_marker then
                row = paint_code_block(term, x, row, width, code_lines, fence_info, code_attr, bg)
                code_lines = {}
                in_fence = false
                fence_marker = nil
                fence_info = nil
                prev_blank = false -- fenced content breaks blank runs
            else
                code_lines[#code_lines + 1] = line
            end
        else
            -- Opening fence: 3+ backticks or tildes, optional info string.
            local opener, info = line:match("^%s*([`~][`~][`~]+)%s*(.*)$")
            if opener then
                in_fence = true
                fence_marker = opener
                fence_info = info
                code_lines = {}
                prev_blank = false -- fenced content breaks blank runs
            elseif line:match("^%s*(#+)%s+") then
                local _, body = line:match("^%s*(#+)%s+(.*)$")
                local segs = parse_inline(body, head_attr, code_attr, link_attr, link_url_attr)
                row = paint_prose(term, x, row, width, segs, bg)
                prev_blank = false
            elseif line:match("^%s*$") then
                -- Collapse consecutive blank lines into ONE blank row
                -- (markdown semantics: a paragraph break is a single
                -- gap regardless of how many blank lines the source has).
                if not prev_blank then
                    term:print(x, row, (" "):rep(width), 0, bg)
                    row = row + 1
                    prev_blank = true
                end
            else
                local segs = parse_inline(line, fg, code_attr, link_attr, link_url_attr)
                row = paint_prose(term, x, row, width, segs, bg)
                prev_blank = false
            end
        end
    end

    -- Unclosed fence: render what we have (don't drop trailing content).
    if in_fence then
        row = paint_code_block(term, x, row, width, code_lines, fence_info, code_attr, bg)
    end

    return row - y
end

--- Measure the number of screen rows `render` would write for `md`
--- at `width` columns, WITHOUT painting. Walks the same line-
--- classification path as render (fences / headings / blank / prose)
--- and reuses `prose_rows` so the count can never drift from what
--- render actually paints. `max_rows` (optional) caps the count the
--- way render's max_rows caps painting; once reached, counting stops
--- and that count is returned. Used by callers that need to size a
--- container box before committing pixels (e.g. the LSP hover popup).
---@param md string markdown text
---@param width integer wrap width in cells
---@param max_rows integer|nil optional cap on counted rows
---@return integer rows
local function measure(md, width, max_rows)
    local code_attr = 0 -- attr is irrelevant for measuring; repaint path
    local link_attr = 0 -- doesn't depend on these. Use plain 0.
    local link_url_attr = 0
    local head_attr = 0
    local fg = 0

    local rows = 0
    local in_fence = false
    local fence_marker = nil
    local code_lines = {}
    local prev_blank = false -- collapse runs of consecutive blank lines

    local function cap_reached()
        return max_rows ~= nil and rows >= max_rows
    end

    -- Mirror render: normalize CRLF/CR → LF and split on \n so CRLF
    -- line endings don't inject phantom blank lines between every
    -- source line (which would inflate the count vs what render
    -- actually paints).
    local norm = md:gsub("\r\n", "\n"):gsub("\r", "\n")
    for line in (norm .. "\n"):gmatch("([^\n]*)\n") do
        if cap_reached() then
            break
        end
        if in_fence then
            local closer = line:match("^%s*([`~]+)%s*$")
            if closer and #closer >= #fence_marker then
                -- Closing fence: the accumulated code block is
                -- one row per source line.
                for _ in ipairs(code_lines) do
                    if cap_reached() then
                        break
                    end
                    rows = rows + 1
                end
                code_lines = {}
                in_fence = false
                fence_marker = nil
                prev_blank = false -- fenced content breaks blank runs
            else
                code_lines[#code_lines + 1] = line
            end
        else
            local opener = line:match("^%s*([`~][`~][`~]+)%s*(.*)$")
            if opener then
                in_fence = true
                fence_marker = opener
                code_lines = {}
                prev_blank = false -- fenced content breaks blank runs
            elseif line:match("^%s*(#+)%s+") then
                local _, body = line:match("^%s*(#+)%s+(.*)$")
                local segs = parse_inline(body, head_attr, code_attr, link_attr, link_url_attr)
                local r = prose_rows(segs, width)
                for _ = 1, r do
                    if cap_reached() then
                        break
                    end
                    rows = rows + 1
                end
                prev_blank = false
            elseif line:match("^%s*$") then
                -- Collapse consecutive blank lines into ONE blank row,
                -- matching render.
                if not prev_blank and not cap_reached() then
                    rows = rows + 1
                    prev_blank = true
                end
            else
                local segs = parse_inline(line, fg, code_attr, link_attr, link_url_attr)
                local r = prose_rows(segs, width)
                for _ = 1, r do
                    if cap_reached() then
                        break
                    end
                    rows = rows + 1
                end
                prev_blank = false
            end
        end
    end

    -- Unclosed fence: count what we have (matches render's fence-flush).
    if in_fence and not cap_reached() then
        for _ in ipairs(code_lines) do
            if cap_reached() then
                break
            end
            rows = rows + 1
        end
    end

    return rows
end

--------------------------------------------------------------------------------------------------
-- Demo popup: an ESC-able centered window that renders a sample
-- markdown document via `render`. Invoke with `M-x mdview-demo`
-- (registered as `commands.mdview_demo`); any subsequent keypress
-- (including Escape) dismisses it. Mirrors the squiggle / diag-hover
-- pattern: a `render_overlay` listener paints while
-- `editor._mdview_demo_active` is set, and a `post_command_hook`
-- listener clears the flag on the next command (covers bound keys,
-- Escape, and printable self-insert, which all post that hook).
--------------------------------------------------------------------------------------------------

-- Sample markdown exercising every feature render() supports.
local DEMO_MD = [[
# mdview demo

A hyper-basic markdown renderer. Markup is stripped; styling is
carried by **termbox attributes**. Try resizing the terminal —
prose *word-wraps* to the popup width.

## Inline formatting

- **bold** via `**double asterisks**` or `__double underscores__`
- *italic* via single `*` or `_`
- inline code renders in the scheme's `text.literal` color, e.g. `ffi.C`
- links drop the URL: [cursed on GitHub](https://github.com)

## Fenced code (tree-sitter highlighted)

```lua
local function greet(name)
    -- comment: resolved through the active ColorScheme
    return ("hello, %s!"):format(name)
end
print(greet("world"))
```

```python
def fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
```

## Unknown language (plain)

```textual-but-not-a-grammar
this block has no matching MajorMode — it renders in the code color
```

Press any key to dismiss this popup.
]]

--- Resolve a UI chrome color from the active scheme, with a fallback
--- to `default` when no scheme is loaded or the concept is absent.
---@param concept string
---@param fallback integer
---@return integer
local function ui_color(concept, fallback)
    local scheme = ColorScheme.active
    if scheme then
        return scheme:color(concept)
    end
    return fallback
end

--- Toggle the demo popup on/off. Bound to `M-x mdview-demo`.
function M.toggle_demo(editor)
    editor._mdview_demo_active = not editor._mdview_demo_active
    -- Sentinel: the post_command_hook that fires for the very command
    -- which opened the popup (e.g. the Enter that submitted `M-x
    -- mdview_demo`, or the `mdview_demo` keybinding itself) must NOT
    -- dismiss it. The dismissal listener consumes this on first sight
    -- and skips; the NEXT command dismisses.
    if editor._mdview_demo_active then
        editor._mdview_demo_just_opened = true
    end
    editor.status_message = editor._mdview_demo_active
            and "mdview demo — press any key to dismiss"
        or "mdview demo off"
end

--- Register the demo's overlay + dismissal listeners on the editor.
--- Called once from main.lua startup alongside the other default
--- listeners. Safe to call multiple times (the event hub dedups? —
--- it does not, so call it ONCE).
---@param editor Editor
function M.setup(editor)
    local es = editor.event_system

    -- Paint: while the demo is active, render the sample markdown into
    -- a centered, borderless solid-backed block sized to ~80% of the
    -- terminal. mdview.render writes directly to the back buffer via
    -- term:print during this render_overlay listener, landing BEFORE
    -- the overlay flush paints its queued floats and BEFORE
    -- term:present() — so the popup reads as an opaque window over
    -- the buffer + modeline.
    es:on("render_overlay", function(ed)
        if not ed._mdview_demo_active then
            return
        end
        local term = ed.term
        if term == nil then
            return
        end
        local w = term:width()
        local h = term:height()
        -- Block geometry: ~80% of the terminal, clamped to a readable range.
        local box_w = math.min(math.max(40, math.floor(w * 0.8)), 96)
        local box_h = math.min(math.max(10, math.floor(h * 0.8)), h - 2)
        if box_w > w then
            box_w = w
        end
        if box_h > h then
            box_h = h
        end
        local x = math.floor((w - box_w) / 2)
        local y = math.floor((h - box_h) / 2)

        local bg = ui_color("popup_bg", 0x000000)
        local fg = ui_color("default_fg", 0xFFFFFF)
        local border_fg = bit.bor(ui_color("border", fg), tb.bold)

        -- Solid background fill across the whole box so the popup
        -- paints opaquely over the buffer underneath. (render() also
        -- pads each row to `width` with `bg`, but a top-to-bottom fill
        -- here guarantees coverage even if the rendered markdown is
        -- shorter than the box.)
        for r = 0, box_h - 1 do
            term:print(x, y + r, (" "):rep(box_w), fg, bg)
        end

        -- Inset the rendered content by 1 cell on every side so the
        -- border (drawn after via put_float) frames it without
        -- overpainting the text.
        local content_w = math.max(1, box_w - 2)
        local content_h = math.max(1, box_h - 2)
        local used = render(term, x + 1, y + 1, content_w, DEMO_MD, fg, bg, content_h)
        local _ = used -- rows consumed; the box size is fixed above

        -- Border rim (queued as floats so it paints during ov:flush(),
        -- AFTER mdview.render's direct term:print, landing on the rim
        -- over any content that bled to the edge).
        local ov = ed.overlays
        if ov ~= nil then
            local top = "╭" .. string.rep("─", box_w - 2) .. "╮"
            local bot = "╰" .. string.rep("─", box_w - 2) .. "╯"
            ov:put_float(x, y, top, border_fg, bg)
            ov:put_float(x, y + box_h - 1, bot, border_fg, bg)
            for r = 1, box_h - 2 do
                ov:put_float(x, y + r, "│", border_fg, bg)
                ov:put_float(x + box_w - 1, y + r, "│", border_fg, bg)
            end
        end
    end)

    -- Dismiss: any command (bound key, Escape, or printable
    -- self-insert — all post `post_command_hook`) clears the flag.
    -- The triggering command still runs normally afterwards, so e.g.
    -- Escape both dismisses the popup AND does its usual no-op.
    -- The `_mdview_demo_just_opened` sentinel lets the opening
    -- command's own post_command_hook pass through without dismissing.
    es:on("post_command_hook", function(ed, _cmd_name, _view)
        if ed._mdview_demo_just_opened then
            ed._mdview_demo_just_opened = false
            return
        end
        if ed._mdview_demo_active then
            ed._mdview_demo_active = false
        end
    end)
end

M.render = render
M.measure = measure
M.highlighter_for = highlighter_for
return M
