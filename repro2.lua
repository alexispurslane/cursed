-- Reproduction v2: enable highlighting path, stub lane dispatch.
package.path = "./src/?.lua"

local Buffer = require("cursed.buffer").Buffer
local View = require("cursed.view").View

local b = Buffer.new()
b:begin_edit()
b:insert_char(0, 0, "hello world\nfoo bar\n")
b:end_edit()

local v = View.new(b)
-- Pretend highlighting is set up.
v._hl_enabled = true
v._hl_lang = "lua"
-- Stub away lane I/O so we exercise cold_requery's body + dispatch math.
v._hl_dispatch = function(self, lo, hi, has_edit, edit, force_cold)
    self._hl_in_flight = { gen = self._hl_gen, bucket_start = lo, bucket_end = hi }
end
v._hl_wait_response = function(self) self._hl_in_flight = nil; return true end
-- _hl_snapshot_text is only called by the real dispatch (stubbed), so not needed.

local c = v:p()
-- select cols 2..7 on line 0 ("llo w")
c.line = 0; c.col = 2
v:set_mark()
c.col = 7
print("sel:", v:selection_range())

-- Type a char (replaces selection): delete_selection then insert
print("delete:", pcall(function() v:delete_selection() end))
print("after del cursor:", c.line, c.col, "line0:", b:line_text(0))
print("insert:", pcall(function() v:insert_char("Z") end))
print("after ins cursor:", c.line, c.col, "line0:", b:line_text(0))

-- Now undo — should revert the insert+delete
local ok, err = pcall(function() v:undo() end)
print("undo ok:", ok, err)
print("after undo cursor:", c.line, c.col, "line0:", b:line_text(0))

-- Undo again — revert the selection-replace delete entirely
ok, err = pcall(function() v:undo() end)
print("undo2 ok:", ok, err)
print("after undo2 cursor:", c.line, c.col, "line0:", b:line_text(0))
