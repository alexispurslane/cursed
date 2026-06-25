--- Kill ring for the cursed editor.
---
--- Stores killed text in a fixed-size ring buffer.
--- ctrl-y yanks the most recent entry; alt-y cycles through older entries.

local MAX_SIZE = 60

---@class kill_ring
---@field ring string[] entries, newest at ring[1]
---@field yank_idx integer|nil 1-based index into ring for yank-pop cycling (nil when not cycling)
local kill_ring = {
    ring = {},
    yank_idx = nil,
}

--- Push killed text onto the kill ring.
---@param text string
function kill_ring:push(text)
    if #text == 0 then
        return
    end
    table.insert(self.ring, 1, text)
    if #self.ring > MAX_SIZE then
        self.ring[MAX_SIZE + 1] = nil
    end
    -- New push invalidates any in-progress yank-pop cycle
    self.yank_idx = nil
end

--- Get the most recent kill ring entry for yanking.
--- Starts a yank-pop cycle (yank_idx = 1).
---@return string|nil
function kill_ring:top()
    if #self.ring == 0 then
        return nil
    end
    self.yank_idx = 1
    return self.ring[1]
end

--- Get the next older entry for yank-pop (M-y).
--- Increments yank_idx and returns ring[yank_idx].
--- Returns nil if the cycle hasn't been started (no prior C-y) or
--- if we've run out of entries.
---@return string|nil
function kill_ring:next()
    if self.yank_idx == nil then
        return nil
    end
    local next_idx = self.yank_idx + 1
    if next_idx > #self.ring then
        return nil
    end
    self.yank_idx = next_idx
    return self.ring[next_idx]
end

--- Cancel the yank-pop cycle (e.g. after any non-yank command).
function kill_ring:cancel_yank()
    self.yank_idx = nil
end

return kill_ring
