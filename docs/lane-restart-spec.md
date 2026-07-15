# Lane Restart on Death — Implementation Spec

## Goal
When a `lane_dead` event fires (3 consecutive heartbeat misses), restart the dead lane,
clean up any pending async ops, emit error events to resume awaiting coroutines,
and re-initialize lane-specific client state.

## 1. C-side: lane thread restart (main.c + shared_ffi.lua)

Add a FFI-callable function in `main.c`:

```c
void restart_lane_thread(uint8_t lane_idx);
```

It must:
- Map lane_idx to the correct module name:
  - 0 → "cursed.io_lane"
  - 1 → "cursed.highlight_lane"
  - 2 → "cursed.lsp_lane"
  - 3 → "cursed.proc_lane"
  - 4 → "cursed.task_lane"
- Create a new lua_State via create_lane_state()
- Call setup_lane_globals(L, 0, NULL)
- Allocate LaneThreadArgs with the module name
- pthread_create + pthread_detach (don't track the thread handle)
- On failure: close L, free args, return silently

Declare in shared_ffi.lua's ffi.cdef:
```c
void restart_lane_thread(uint8_t lane_idx);
```

## 2. Pending ops tracking (editor.lua)

Add to Editor:

```lua
-- _pending_ops: table<integer, table<integer, boolean>>
-- indexed by lane_idx, each maps op_id → true for in-flight ops
Editor._pending_ops = nil  -- initialized in new()

Editor:track_pending_op(lane_idx, op_id)   -- mark op as in-flight
Editor:clear_pending_op(lane_idx, op_id)   -- clear on normal completion
Editor:flush_lane_pending(lane_idx)        -- emit error for all, clear set
```

### Event patterns per lane (for flush_lane_pending):

| lane_idx | Event name pattern | Payload |
|---|---|---|
| LANE_IDX_IO (0) | `file_op:<id>` | `{ err = "IO lane restarted" }` |
| LANE_IDX_HL (1) | `hl_spans:<id>` | `{ err = "HL lane restarted" }` |
| LANE_IDX_LSP (2) | `lsp_response:<id>` | `nil, true, cid` (is_err=true) |
| LANE_IDX_PROC (3) | `process_out:<procid>` | `"failed", 0` |
| LANE_IDX_TASK (4) | `task_result:<id>` | `{ success = false, error = "task lane restarted" }` |

### Integration points
- All callers that push an op to a lane MUST call `track_pending_op` with the op id
- All callers that receive a reply MUST call `clear_pending_op` with the op id
- flush_lane_pending emits the synthetic error for every tracked op, then clears the set

## 3. Lane clients

### 3a. New: `src/cursed/io_client.lua`

Minimal client facade (mirrors pattern of proc_client.lua, task_client.lua).

```lua
local M = {}

function M.setup(editor, shared_state)
    M._ss = shared_state
    M._editor = editor
end

function M.reinitialize(editor, ss)
    M._ss = ss
    M._editor = editor
    -- IO lane is stateless per-request; nothing to rebuild
end

return M
```

### 3b. New: `src/cursed/hl_client.lua`

```lua
local M = {}

function M.setup(editor, shared_state)
    M._ss = shared_state
    M._editor = editor
end

function M.reinitialize(editor, ss)
    M._ss = ss
    M._editor = editor
    -- Re-request highlighting for all open views
    -- Walk editor.views, for each: re-init language + re-query
    local shared = require("cursed.shared")
    for _, view in ipairs(editor.views) do
        if view.file_loaded and view._hl_language then
            -- Re-initialize language (sends MSG_HL_INITIALIZE_LANGUAGE)
            view:hl_reinitialize()
        end
    end
end

return M
```

NOTE: view:hl_reinitialize() needs to be added to View. It re-sends the init language + query
requests that were originally sent on mode enter. The View may already have a method for this;
check view.lua for `_hl_request_spans` or similar.

### 3c. Existing: `src/cursed/proc_client.lua`

Add:
```lua
function M.reinitialize(editor, ss)
    M._ss = ss
    M._editor = editor
    -- All child processes died with the lane. Clean up main-side state:
    -- unregister all process_in:<id> listeners
    M.shutdown()
    -- Reset procid counter? No — keep monotonic to avoid ID reuse
end
```

### 3d. Existing: `src/cursed/lsp_client.lua`

Add:
```lua
function M.reinitialize(editor, ss)
    -- Re-spawn all known language servers for open views
    -- Walk editor.views, for each mode that has lsp_servers, spawn them
    -- The existing spawn logic in editor_listeners.lua mode_enter handler
    -- can be reused — call spawn_lsp_for_view or similar
end
```

NOTE: lsp_client already has `spawn_server` and tracking. Need to check what
state needs clearing before re-spawning (the old servers are dead with the lane).

### 3e. Existing: `src/cursed/task_client.lua`

Add:
```lua
function M.reinitialize(editor, ss)
    M._ss = ss
    M._editor = editor
    -- Task lane is stateless; just reset the next_task_id?
    -- Actually keep monotonic — IDs don't need to reset
end
```

## 4. Main-side wiring (main.lua)

Add a `lane_dead` event handler in the editor initialization section:

```lua
editor.event_system:on("lane_dead", function(_, lane_idx, lane_name)
    log.error("main", "lane died, restarting", { lane_idx = lane_idx, name = lane_name })
    editor.status_message = lane_name .. " lane died; restarting..."
    
    -- 1. Flush all pending ops for this lane (resumes awaiting coroutines)
    editor:flush_lane_pending(lane_idx)
    
    -- 2. Restart the lane thread (creates new lua_State + pthread)
    local ffi = require("ffi")
    ffi.C.restart_lane_thread(lane_idx)
    
    -- 3. Re-initialize lane client state
    local reinitializers = {
        [shared.LANE_IDX_IO]   = function() require("cursed.io_client").reinitialize(editor, ss) end,
        [shared.LANE_IDX_HL]   = function() require("cursed.hl_client").reinitialize(editor, ss) end,
        [shared.LANE_IDX_LSP]  = function() require("cursed.lsp_client").reinitialize(editor, ss) end,
        [shared.LANE_IDX_PROC] = function() require("cursed.proc_client").reinitialize(editor, ss) end,
        [shared.LANE_IDX_TASK] = function() require("cursed.task_client").reinitialize(editor, ss) end,
    }
    local reinit = reinitializers[lane_idx]
    if reinit then
        local ok, err = pcall(reinit)
        if not ok then
            log.error("main", "lane reinit failed", { lane_idx = lane_idx, error = tostring(err) })
        end
    end
end)
```

## 5. Caller integration (track_pending_op / clear_pending_op)

Audit and add tracking calls at every push site. The key ones:

### IO lane callers (editor.lua, main.lua):
- All `editor:open_file`, `editor:save_file`, `editor:dirlist_async`, etc. that push MSG_FILE_*
  and await `file_op:<req_id>` should call `track_pending_op(LANE_IDX_IO, req_id)` before push
- The one-shot `file_op:<req_id>` handler should call `clear_pending_op(LANE_IDX_IO, req_id)` on both success and error paths

### LSP lane callers:
- `lsp_client` methods that push MSG_LSP_SEND with an id and await `lsp_response:<id>`
  should call `track_pending_op(LANE_IDX_LSP, id)` / `clear_pending_op(LANE_IDX_LSP, id)`

### Task lane callers:
- `task_client.send_task` should call `track_pending_op(LANE_IDX_TASK, task_id)` before push
- The `task_result:<task_id>` handler should call `clear_pending_op(LANE_IDX_TASK, task_id)`

### Proc lane callers:
- Any caller that spawns a process and awaits `process_out:<procid>` events
  should track/clear the procid

## 6. Existing wire-up sites that need updates

In main.lua, the current client setup sites:
```lua
local proc_client = require("cursed.proc_client")
proc_client.setup(editor, ss)
editor.proc = proc_client

local task_client = require("cursed.task_client")
task_client.setup(editor, ss)
editor.task = task_client
```

Add:
```lua
local io_client = require("cursed.io_client")
io_client.setup(editor, ss)
editor.io = io_client

local hl_client = require("cursed.hl_client")
hl_client.setup(editor, ss)
editor.hl = hl_client
```

And expose lsp_client similarly if not already exposed.

## Files to change (by group)

### Group 1: C-side + FFI (main.c, shared_ffi.lua)
- main.c: add `restart_lane_thread(uint8_t)` function
- shared_ffi.lua: add FFI declaration

### Group 2: Editor (editor.lua)
- Add `_pending_ops` init in new()
- Add `track_pending_op`, `clear_pending_op`, `flush_lane_pending` methods
- The flush method needs to know event patterns per lane

### Group 3: New clients (io_client.lua, hl_client.lua)
- Create both files

### Group 4: Existing clients (proc_client.lua, lsp_client.lua, task_client.lua)
- Add `reinitialize` method to each

### Group 5: View (view.lua)
- Add `hl_reinitialize` method OR check if one already exists

### Group 6: All push sites (editor.lua, main.lua, task_client.lua, lsp_client.lua, proc_client.lua)
- Add `track_pending_op` / `clear_pending_op` calls

### Group 7: Main-side wiring (main.lua)
- Add lane_dead handler
- Add io_client/hl_client setup
- Add reinitializer table
