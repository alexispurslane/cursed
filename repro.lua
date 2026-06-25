-- Reproduction: select text, delete selection, then undo.
package.path = "./src/?.lua"

local Buffer = require("cursed.buffer").Buffer
local View = require("cursed.view").View

local b = Buffer.new()
-- insert "hello world\n"
b:begin_edit()
b:insert_char(0, 0, "hello world\n")
b:end_edit()

local v = View.new(b)
v._hl_enabled = false

-- move cursor to select "llo w" region (cols 2..7) on line 0
-- cursor at line 0, col 2, anchor at line 0, col 7
local c = v:p()
c.line = 0
c.col = 2
v:set_mark()           -- anchor at 0,2; shadow_undo snapshotted
c.col = 7              -- selection [2,7)
print("selection:", v:selection_range())

-- Now delete the selection
local ok, err = pcall(function() v:delete_selection() end)
print("delete_selection ok:", ok, err)
print("after delete cursor:", c.line, c.col)
print("buffer line 0:", ("%q"):format(b:line_text(0)))

-- Now type something
ok, err = pcall(function() v:insert_char("XX") end)
print("insert ok:", ok, err)
print("after insert cursor:", c.line, c.col)
print("buffer line 0:", ("%q"):format(b:line_text(0)))

-- Now undo
ok, err = pcall(function() v:undo() end)
print("undo ok:", ok, err)
print("after undo cursor:", c.line, c.col)
print("buffer line 0:", ("%q"):format(b:line_text(0)))

-- Undo again (should undo the delete)
ok, err = pcall(function() v:undo() end)
print("undo2 ok:", ok, err)
print("after undo2 cursor:", c.line, c.col)
print("buffer line 0:", ("%q"):format(b:line_text(0)))
