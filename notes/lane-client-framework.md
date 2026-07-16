# Lane Client Framework

## Goal

Every lane-facing client module follows the same structure: own its state,
own its pending ops, depend only on SharedState + EventSystem (not Editor),
and expose a uniform lifecycle for lane-death recovery.

## Pattern

```lua
local M = {
    _ss       = nil,  -- SharedState (for outbox push)
    _es       = nil,  -- EventSystem (for response events + tokens)
    _pending  = {},   -- { [op_id] = true }
    _next_id  = 1,    -- monotonic request/proc/task id counter
}
local PREFIX = "<lane>"  -- e.g. "file", "process", "lsp", "task"

--- @param ss  SharedState
--- @param es  EventSystem
function M.setup(ss, es)
    M._ss = ss
    M._es = es
    M._pending = {}
    M._next_id = 1
end

-- Each public operation:
--   1. id = M._next_id; M._next_id = id + 1
--   2. M._pending[id] = true
--   3. Build wire struct, push to outbox (via M._ss)
--   4. If the operation produces a response:
--        return async.token(M._es, PREFIX .. "_<op>:" .. id, function()
--            M._pending[id] = nil
--        end)
--      If fire-and-forget (no response):
--        return nil

--- Emit synthetic error events for every in-flight operation.
--- Called by main.lua's lane_dead handler BEFORE reinitialize.
function M.flush_pending()
    for id in pairs(M._pending) do
        M._es:emit(PREFIX .. "_<op>:" .. tostring(id), { err = "<lane> lane restarted" })
    end
    M._pending = {}
end

--- Restore shared state + event system after lane restart.
--- _next_id stays monotonic (no reuse).
function M.reinitialize(ss, es)
    -- flush_pending should have been called before us by lane_dead handler.
    M._ss = ss
    M._es = es
end
```

## Event Naming Convention

The response event for an operation is:

    <PREFIX>_<OP>:<ID>

Where:
- `<PREFIX>` is the lane namespace: `file`, `process`, `lsp`, `task`, `hl`
- `<OP>` is a short operation name: `load`, `delete`, `create`, `mkdir`,
  `chmod`, `rename`, `dirlist`, `write`, `insert`, `spawn`, `result`, etc.
- `<ID>` is the monotonic request/proc/task id (integer).

The `<OP>` segment exists because some lanes (notably `process`) emit
multiple event types per request id — e.g. `process_spawn:<id>`,
`process_out:<id>`, `process_exit:<id>`.  For simpler lanes where one
request maps to exactly one response event (e.g. `file_delete:<id>` →
`file_op:<id>` becomes `file_delete:<id>`), the OP is redundant but
kept for consistency.

Fire-and-forget operations that produce no response event don't need
a token or event name; they just push to the outbox and return nil.

## main.lua Lane-Death Handler

Current (centralized on Editor):

```lua
editor:flush_lane_pending(lane_idx)
ffi.C.restart_lane_thread(lane_idx)
local reinit = reinitializers[lane_idx]
reinit()
```

New (delegated to each client):

```lua
local clients = { [LANE_IDX_IO]   = io_client,
                  [LANE_IDX_HL]   = hl_client,
                  [LANE_IDX_LSP]  = lsp_client,
                  [LANE_IDX_PROC] = proc_client,
                  [LANE_IDX_TASK] = task_client }
local c = clients[lane_idx]
if c.flush_pending then c.flush_pending() end
ffi.C.restart_lane_thread(lane_idx)
if c.reinitialize then c.reinitialize(ss, es) end
```

`flush_pending` and `reinitialize` are optional — a client may choose
not to implement one (e.g. `hl_client` stays stateless).

## Shared Helpers

A shared utility module (`cursed.lane_client`?) provides:

```lua
-- Build a monotonic-id + pending-tracking + async.token in one call.
-- Not every client will use this (some have custom struct shapes),
-- but it's available for the simplest case.
function lane_client.make_send(opts)
    -- opts: { ss, es, lane_idx, msg_type, prefix, op, build_ptr(filepath) }
    -- returns: function(filepath) -> AsyncToken
end

-- Standard flush_pending implementation.
function lane_client.flush_pending(pending, es, prefix, op, err_msg)
    for id in pairs(pending) do
        es:emit(prefix .. "_" .. op .. ":" .. tostring(id), { err = err_msg })
    end
end
```

Whether we pull this trigger depends on how much repetition survives after
refactoring the first two clients.

## Headless Drain Coordination

The Editor's `_pending_ops_count` is used by the headless eval loop to
wait until outstanding IO operations complete. Under the new model, each
client owns its pending table, so the headless loop needs a different
mechanism.

Option A: Each client exposes `pending_count()` and the Editor polls
all of them (or the headless loop does).

Option B: A lightweight `_pending_ops_count` stays on Editor, but each
client method that creates an async token also calls an editor callback
to increment/decrement. (Trade-off: couples clients to Editor again.)

Option C: The headless loop simply calls `async.await` on the single
outstanding operation it cares about — no global count needed.

We'll cross this bridge when IO client has its own pending ops and the
headless path needs updating.

## Current State Assessment

| Client | Owns pending ops? | Owns id counter? | Depends on Editor? | Uses async.token? | Has flush_pending? | Uses <PREFIX>_<OP>:<ID>? |
|--------|:-:|:-:|:-:|:-:|:-:|:-:|
| **io_client**    | ✗ (all on Editor methods) | ✗ (on Editor via `_next_file_op_id()`) | ✓ (via `self`) | ✓ | ✗ | ✗ (`file_op:<id>`) |
| **lsp_client**   | ✗ (on `M._editor`) | ✓ (`_next_request_id`) | ✓ (for track/clear_pending_op) | ✓ (`request_async`) | ✗ | 𝘦𝘧𝘧𝘦𝘤𝘵𝘪𝘷𝘦𝘭𝘺 (`lsp_response:<id>`) |
| **proc_client**  | ✗ (on `M._editor`) | ✓ (`_next_procid`) | ✓ (for track + event system) | ✗ (returns bare procid) | ✗ | 𝘱𝘢𝘳𝘵𝘪𝘢𝘭𝘭𝘺 (`process_out:<id>`) |
| **task_client**  | ✗ (on `M._editor`) | ✓ (`_next_task_id`) | ✓ (for track + event system) | ✓ | ✗ | 𝘦𝘧𝘧𝘦𝘤𝘵𝘪𝘷𝘦𝘭𝘺 (`task_result:<id>`) |
| **hl_client**    | n/a (stateless) | n/a | ✓ (needs `editor.views` for reinit) | ✗ (synchronous) | n/a | n/a |

All five clients currently receive `editor` in their `setup()` call and
use it to reach `editor.event_system` and `editor:track_pending_op()`.
The target is: **zero editors in setup; just SharedState + EventSystem**.

## Migration Order

1. **io_client** — first mover; extract from Editor methods, establish
   the pattern.
2. **task_client** — closest to target already; minimal refactor.
3. **proc_client** — add MSG_PROC_SPAWNED message type so `spawn()` can
   return an AsyncToken; restructure pending tracking.
4. **lsp_client** — move pending ops from `M._editor` to own `_pending`.
5. **hl_client** — stays synchronous; just strip `editor` from setup
   (replace with `ss` if needed, or make setup a no-op since hl only
   cares about `editor.views` at reinit time, which can be passed in).

Each step updates main.lua's setup call and lane-dead handler.
