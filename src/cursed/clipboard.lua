--- System clipboard integration for the cursed editor.
---
--- Reads from and writes to the OS system clipboard using available tools:
---   macOS:   pbpaste / pbcopy
---   Linux:   wl-copy (Wayland) / xclip or xsel (X11)
---
--- This module is purely IO: all state lives in the OS clipboard.
--- No Lua-side buffers.

local clipboard = {}

----------------------------------------------------------------------------------------------------
-- Platform detection
----------------------------------------------------------------------------------------------------

--- Detect which clipboard tools are available.
--- Returns { paste = "cmd", copy = "cmd" } or nil.
---@return { paste: string, copy: string }|nil
local function detect_backend()
    local uname = io.popen("uname -s 2>/dev/null"):read("*l") or ""

    if uname == "Darwin" then
        return { paste = "pbpaste", copy = "pbcopy" }
    end

    if uname ~= "Linux" then
        return nil
    end

    -- Wayland takes priority over X11
    if os.execute("command -v wl-copy >/dev/null 2>&1") then
        return { paste = "wl-copy -o", copy = "wl-copy" }
    end

    if os.execute("command -v xclip >/dev/null 2>&1") then
        return { paste = "xclip -o -selection clipboard", copy = "xclip -selection clipboard -i" }
    end

    if os.execute("command -v xsel >/dev/null 2>&1") then
        return {
            paste = "xsel --clipboard --output",
            copy = "xsel --clipboard --input",
        }
    end

    return nil
end

local _backend = detect_backend()

--- Execute a shell command and return its stdout as a string, or nil + error message.
--- Usage: local data, err = clipboard._exec("pbpaste")
---@param cmd string shell command to execute
---@return string|nil data stdout on success
---@return string|nil err error message on failure
local function exec(cmd)
    local fh = io.popen(cmd .. " 2>/dev/null", "r")
    if not fh then
        return nil, "command failed"
    end
    local data = fh:read("*a")
    local ok = fh:close()
    if not ok then
        return nil, "command failed or returned error"
    end
    return data
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

--- Read text from the system clipboard.
---@return string|nil
function clipboard.paste()
    if not _backend then
        return nil
    end
    return exec(_backend.paste)
end

--- Write text to the system clipboard.
---@param text string
---@return boolean ok
---@return string|nil err
function clipboard.copy(text)
    if not _backend then
        return false, "no clipboard backend"
    end
    -- On Linux, xclip needs the data from stdin
    local fh = io.popen(_backend.copy .. " 2>/dev/null", "w")
    if not fh then
        return false, "command failed"
    end
    -- Write the text (without a trailing newline to match pbcopy behavior)
    fh:write(text)
    local ok, err = fh:close()
    if not ok then
        return false, err or "command failed"
    end
    return true
end

--- Set the system clipboard to text, if the current text differs.
--- This is an optimization to avoid unnecessary clipboard updates.
---@param text string
---@return boolean ok
---@return string|nil err
function clipboard.set_if_different(text)
    local current = clipboard.paste()
    if current == text then
        return true
    end
    return clipboard.copy(text)
end

return clipboard
