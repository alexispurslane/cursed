--- High-level termbox2 bindings with RAII memory management via ffi.gc.
---
--- Usage:
---   local tb = require("cursed.tb")
---
---   local term = tb.Term.new()
---   term:print(0, 0, "Hello, world!", tb.color_white, tb.color_black)
---   term:present()
---
---   local event = term:poll_event()
---   if event.type == tb.event_key and event.key == tb.key_esc then
---       -- exit
---   end
---
---   -- GC calls tb_shutdown automatically when the term is collected.
---   -- Call :shutdown() if you need to shut down before GC runs (e.g. to
---   -- restore the terminal before exiting a scope).

local ffi = require("ffi")
local bit = require("bit")
local c_api = require("cursed.termbox2_ffi")
local gc = require("cursed.gc")

----------------------------------------------------------------------------------------------------
-- Constants — event types
----------------------------------------------------------------------------------------------------

local event_key = 1
local event_resize = 2
local event_mouse = 3

----------------------------------------------------------------------------------------------------
-- Constants — modifiers
----------------------------------------------------------------------------------------------------

local mod_alt = 1
local mod_ctrl = 2
local mod_shift = 4
local mod_motion = 8

----------------------------------------------------------------------------------------------------
-- Constants — special keys
----------------------------------------------------------------------------------------------------

local key_f1 = 0xFFFF - 0
local key_f2 = 0xFFFF - 1
local key_f3 = 0xFFFF - 2
local key_f4 = 0xFFFF - 3
local key_f5 = 0xFFFF - 4
local key_f6 = 0xFFFF - 5
local key_f7 = 0xFFFF - 6
local key_f8 = 0xFFFF - 7
local key_f9 = 0xFFFF - 8
local key_f10 = 0xFFFF - 9
local key_f11 = 0xFFFF - 10
local key_f12 = 0xFFFF - 11
local key_insert = 0xFFFF - 12
local key_delete = 0xFFFF - 13
local key_home = 0xFFFF - 14
local key_end = 0xFFFF - 15
local key_pgup = 0xFFFF - 16
local key_pgdn = 0xFFFF - 17
local key_backspace = 0x7F
local key_enter = 0x0D
local key_arrow_up = 0xFFFF - 18
local key_arrow_down = 0xFFFF - 19
local key_arrow_left = 0xFFFF - 20
local key_arrow_right = 0xFFFF - 21
local key_mouse_left = 0xFFFF - 23
local key_mouse_right = 0xFFFF - 24
local key_mouse_middle = 0xFFFF - 25
local key_mouse_release = 0xFFFF - 26
local key_mouse_wheel_up = 0xFFFF - 27
local key_mouse_wheel_down = 0xFFFF - 28

local key_names = {
    [key_f1] = "f1",
    [key_f2] = "f2",
    [key_f3] = "f3",
    [key_f4] = "f4",
    [key_f5] = "f5",
    [key_f6] = "f6",
    [key_f7] = "f7",
    [key_f8] = "f8",
    [key_f9] = "f9",
    [key_f10] = "f10",
    [key_f11] = "f11",
    [key_f12] = "f12",
    [key_insert] = "insert",
    [key_delete] = "delete",
    [key_home] = "home",
    [key_end] = "end",
    [key_pgup] = "pgup",
    [key_pgdn] = "pgdn",
    [key_arrow_up] = "up",
    [key_arrow_down] = "down",
    [key_arrow_left] = "left",
    [key_arrow_right] = "right",
    [key_mouse_left] = "mouse_left",
    [key_mouse_right] = "mouse_right",
    [key_mouse_middle] = "mouse_middle",
    [key_mouse_release] = "mouse_release",
    [key_mouse_wheel_up] = "mouse_wheel_up",
    [key_mouse_wheel_down] = "mouse_wheel_down",
}

----------------------------------------------------------------------------------------------------
-- Constants — colors (TB_OUTPUT_NORMAL mode: 0-8 fg/bg slots)
----------------------------------------------------------------------------------------------------

local color_default = 0x0000
local color_black = 0x0001
local color_red = 0x0002
local color_green = 0x0003
local color_yellow = 0x0004
local color_blue = 0x0005
local color_magenta = 0x0006
local color_cyan = 0x0007
local color_white = 0x0008

----------------------------------------------------------------------------------------------------
-- Constants — style attributes (64-bit attr mode: TB_OPT_ATTR_W=64)
----------------------------------------------------------------------------------------------------

local bold = 0x01000000
local underline = 0x02000000
local reverse = 0x04000000
local italic = 0x08000000
local blink = 0x10000000
local bright = 0x40000000
local dim = 0x80000000
local hi_black = 0x20000000

-- 64-bit-only style attributes
local strikeout = 0x0000000100000000
local underline_2 = 0x0000000200000000
local overline = 0x0000000400000000
local invisible = 0x0000000800000000

----------------------------------------------------------------------------------------------------
-- Constants — input modes
----------------------------------------------------------------------------------------------------

local input_esc = 1
local input_alt = 2
local input_mouse = 4

----------------------------------------------------------------------------------------------------
-- Constants — output modes
----------------------------------------------------------------------------------------------------

local output_normal = 1
local output_256 = 2
local output_216 = 3
local output_grayscale = 4
local output_truecolor = 5

----------------------------------------------------------------------------------------------------
-- Error codes
----------------------------------------------------------------------------------------------------

local err_ok = 0
local err_need_more = -2
local err_init_already = -3
local err_init_open = -4
local err_mem = -5
local err_no_event = -6
local err_not_init = -8
local err_out_of_bounds = -9
local err_read = -10

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

--- Pack a 0xRRGGBB color into a termbox2 truecolor attribute.
--- Only valid when output mode is TB_OUTPUT_TRUECOLOR (5).
--- For black, use `hi_black` (0x20000000) since 0x000000 means default.
--- Style attributes (bold, underline, etc.) may be bitwise OR'd on top.
local function rgb(r, g, b)
    return bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b)
end

--- Parse a hex color string ("RRGGBB", optional '#'/0x prefix,
--- case-insensitive) to a truecolor int (0xRRGGBB). nil on malformed
--- input. Convenience for theme code that reads hex literals.
---@param s string|nil
---@return integer|nil
local function hex(s)
    if s == nil then
        return nil
    end
    local h = s:match("^#?(%x%x%x%x%x%x)$")
    if h == nil then
        h = s:match("^[xX]?(%x%x%x%x%x%x)$")
    end
    if h == nil then
        return nil
    end
    return tonumber(h, 16)
end

----------------------------------------------------------------------------------------------------
-- Term
----------------------------------------------------------------------------------------------------

---@class Term
---@field initialized boolean
local Term = {}
Term.__index = Term

--- GC finalizer — called automatically when a term object is collected.
local function term_finalizer(term_obj)
    if term_obj.initialized then
        c_api.tb_shutdown()
        term_obj.initialized = false
    end
end

--- Initialize termbox2 and return a Term wrapper.
---@return Term|nil
---@return string|nil errmsg
function Term.new()
    local rc = c_api.tb_init()
    if rc ~= 0 then
        return nil, ("cursed.tb: tb_init failed (code %d)"):format(rc)
    end
    local t = setmetatable({ initialized = true }, Term)
    -- Attach a finalizer via a dummy cdata + ffi.gc so tb_shutdown runs on GC.
    local guard = gc.wrap_gc(ffi.new("uint8_t[1]"), function()
        term_finalizer(t)
    end)
    rawset(t, "_guard", guard)
    return t, nil
end

--- Get the terminal width in cells.
---@return integer
function Term:width()
    local v = tonumber(c_api.tb_width())
    ---@cast v integer
    return v
end

--- Get the terminal height in cells.
---@return integer
function Term:height()
    local v = tonumber(c_api.tb_height())
    ---@cast v integer
    return v
end

--- Clear the terminal with the given attributes.
---@param fg integer Foreground attribute
---@param bg integer Background attribute
---@return boolean|nil ok
---@return string|nil errmsg
function Term:clear(fg, bg)
    c_api.tb_set_clear_attrs(fg or color_default, bg or color_default)
    local rc = c_api.tb_clear()
    if rc ~= 0 then
        return nil, ("cursed.tb: tb_clear failed (code %d)"):format(rc)
    end
    return true, nil
end

--- Flip the back buffer to the terminal.
---@return boolean|nil ok
---@return string|nil errmsg
function Term:present()
    local rc = c_api.tb_present()
    if rc ~= 0 then
        return nil, ("cursed.tb: tb_present failed (code %d)"):format(rc)
    end
    return true, nil
end

--- Set a single cell.
---@param x integer
---@param y integer
---@param ch integer Unicode codepoint
---@param fg integer
---@param bg integer
function Term:set_cell(x, y, ch, fg, bg)
    c_api.tb_set_cell(x, y, ch, fg, bg)
end

--- Print a string at the given position.
---@param x integer
---@param y integer
---@param str string
---@param fg integer
---@param bg integer
function Term:print(x, y, str, fg, bg)
    c_api.tb_print(x, y, fg, bg, str)
end

--- Set the cursor position, or hide it if both args are nil.
---@param cx integer?
---@param cy integer?
function Term:set_cursor(cx, cy)
    if cx == nil and cy == nil then
        c_api.tb_hide_cursor()
    else
        c_api.tb_set_cursor(cx or -1, cy or -1)
    end
end

--- Hide the cursor.
function Term:hide_cursor()
    c_api.tb_hide_cursor()
end

--- Set the input mode.
---@param mode integer
---@return integer
function Term:set_input_mode(mode)
    local v = tonumber(c_api.tb_set_input_mode(mode))
    ---@cast v integer
    return v
end

--- Set the output mode.
---@param mode integer
---@return integer
function Term:set_output_mode(mode)
    local v = tonumber(c_api.tb_set_output_mode(mode))
    ---@cast v integer
    return v
end

--- Block until an event is received.
---@return any? struct tb_event cdata
---@return string|nil errmsg
function Term:poll_event()
    local ev = ffi.new("struct tb_event")
    local rc = c_api.tb_poll_event(ev)
    if rc ~= 0 then
        return nil, ("cursed.tb: tb_poll_event failed (code %d)"):format(rc)
    end
    return ev, nil
end

--- Peek for an event with a timeout.
---@param timeout_ms integer
---@return any? struct tb_event cdata, or nil if no event
---@return string|nil errmsg when a real error occurred (not just no event)
function Term:peek_event(timeout_ms)
    local ev = ffi.new("struct tb_event")
    local rc = c_api.tb_peek_event(ev, timeout_ms)
    if rc == err_no_event or rc == err_need_more then
        return nil
    end
    if rc ~= 0 then
        return nil, ("cursed.tb: tb_peek_event failed (code %d)"):format(rc)
    end
    return ev
end

--- Check if the terminal supports truecolor.
---@return boolean
function Term:has_truecolor()
    return c_api.tb_has_truecolor() ~= 0
end

--- Get termbox2 internal file descriptors.
---@return integer ttyfd
---@return integer resizefd
function Term:get_fds()
    local ttyfd = ffi.new("int[1]")
    local resizefd = ffi.new("int[1]")
    c_api.tb_get_fds(ttyfd, resizefd)
    local t = tonumber(ttyfd[0])
    local r = tonumber(resizefd[0])
    ---@cast t integer
    ---@cast r integer
    return t, r
end

--- Shut down the terminal immediately, bypassing the GC.
--- Unlike treesitter resources, this IS important — it calls tb_shutdown()
--- to restore the terminal to its original state.
function Term:shutdown()
    if self.initialized then
        c_api.tb_shutdown()
        self.initialized = false
    end
end

----------------------------------------------------------------------------------------------------
-- Event helpers
----------------------------------------------------------------------------------------------------

--- Check if an event is a key event.
---@param ev any struct tb_event cdata
---@return boolean
local function event_is_key(ev)
    return ev.type == event_key
end

--- Check if an event is a resize event.
---@param ev any struct tb_event cdata
---@return boolean
local function event_is_resize(ev)
    return ev.type == event_resize
end

--- Check if an event is a mouse event.
---@param ev any struct tb_event cdata
---@return boolean
local function event_is_mouse(ev)
    return ev.type == event_mouse
end

--- Get a human-readable name for a key code.
---@param key integer
---@return string
local function key_name_fn(key)
    return key_names[key] or string.char(key)
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    -- Class
    Term = Term,
    -- Event types
    event_key = event_key,
    event_resize = event_resize,
    event_mouse = event_mouse,
    -- Modifiers
    mod_alt = mod_alt,
    mod_ctrl = mod_ctrl,
    mod_shift = mod_shift,
    mod_motion = mod_motion,
    -- Special keys
    key_f1 = key_f1,
    key_f2 = key_f2,
    key_f3 = key_f3,
    key_f4 = key_f4,
    key_f5 = key_f5,
    key_f6 = key_f6,
    key_f7 = key_f7,
    key_f8 = key_f8,
    key_f9 = key_f9,
    key_f10 = key_f10,
    key_f11 = key_f11,
    key_f12 = key_f12,
    key_insert = key_insert,
    key_delete = key_delete,
    key_home = key_home,
    key_end = key_end,
    key_pgup = key_pgup,
    key_pgdn = key_pgdn,
    key_backspace = key_backspace,
    key_enter = key_enter,
    key_arrow_up = key_arrow_up,
    key_arrow_down = key_arrow_down,
    key_arrow_left = key_arrow_left,
    key_arrow_right = key_arrow_right,
    -- Mouse keys
    key_mouse_left = key_mouse_left,
    key_mouse_right = key_mouse_right,
    key_mouse_middle = key_mouse_middle,
    key_mouse_release = key_mouse_release,
    key_mouse_wheel_up = key_mouse_wheel_up,
    key_mouse_wheel_down = key_mouse_wheel_down,
    -- Colors
    color_default = color_default,
    color_black = color_black,
    color_red = color_red,
    color_green = color_green,
    color_yellow = color_yellow,
    color_blue = color_blue,
    color_magenta = color_magenta,
    color_cyan = color_cyan,
    color_white = color_white,
    -- Style attributes
    bold = bold,
    underline = underline,
    reverse = reverse,
    italic = italic,
    blink = blink,
    bright = bright,
    dim = dim,
    hi_black = hi_black,
    strikeout = strikeout,
    underline_2 = underline_2,
    overline = overline,
    invisible = invisible,
    -- Input modes
    input_esc = input_esc,
    input_alt = input_alt,
    input_mouse = input_mouse,
    -- Output modes
    output_normal = output_normal,
    output_256 = output_256,
    output_216 = output_216,
    output_grayscale = output_grayscale,
    output_truecolor = output_truecolor,
    -- Error codes
    err_ok = err_ok,
    err_need_more = err_need_more,
    err_init_already = err_init_already,
    err_init_open = err_init_open,
    err_mem = err_mem,
    err_no_event = err_no_event,
    err_not_init = err_not_init,
    err_out_of_bounds = err_out_of_bounds,
    err_read = err_read,
    -- Helpers
    rgb = rgb,
    hex = hex,
    event_is_key = event_is_key,
    event_is_resize = event_is_resize,
    event_is_mouse = event_is_mouse,
    key_name = key_name_fn,
}
