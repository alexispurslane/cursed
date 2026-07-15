# Async & Multithreading Architecture — Issues

Summary of the architectural concerns identified in the lane / event-bus / coroutine / background-task review.

---

## ✅ 1. No timeout on `async.await` (resolved)

`async.await` can only be called from inside a coroutine — keybinding handlers,
event listeners, and background tasks. It yields back to the event loop, never
blocks the main thread. The awaiting coroutine pauses, but the editor continues
running.

Additionally, the crash case (a lane dies while replies are outstanding) is
handled by `flush_lane_pending`, which fires when `lane_dead` is emitted: it
emits synthetic error events (`{ err = "..." }`) for every pending op on that
lane, unblocking all awaiting coroutines. No hanging.

A fine-grained per-token timeout could still be added if desired (e.g., for
lost replies due to bugs), but there's no mechanism by which an `await` can
freeze the editor.

---

## ✅ 2. Lane health monitoring (implemented)

- Each lane calls `ss:heartbeat_set(lane_idx)` at the top of its main loop
  **and** on every message popped inside the dispatch loop, so the lane
  stays alive as long as no single handler runs for >3s.
- A background task (`Editor:start_heartbeat_checker`) reads and resets all
  heartbeats every 1s. Three consecutive misses → `lane_dead` event.
- The `lane_dead` handler in `main.lua` calls `restart_lane_thread` followed
  by the lane's client reinitialize function.
- `flush_lane_pending` emits synthetic error events for all in-flight ops
  on the dead lane before restarting, so no awaiters hang.
- Implements:
  - `SharedState.lane_heartbeats[]` atomic array in C
  - `shared_heartbeat_set()` / `shared_heartbeat_read_reset()`
  - Heartbeat checker with configurable miss threshold (currently 3)
  - Per-lane reinit functions in `main.lua`

---

## ✅ 3. Ring buffer backpressure (resolved)

`SharedState:push` heap-allocates the Msg struct (fixing a pre-existing
GC race on string payloads). If `ring_push` returns false (ring full), the
heap-allocated Msg is queued in a Lua-side `_overflow[ring]` table instead
of blocking or failing — the caller always sees success.

Each producer calls `SharedState:flush_overflow(ring)` after the consumer
has had a chance to drain: main does this for all outbox rings after each
inbox drain cycle, and each lane does it for its inbox ring after each
outbox drain. Lanes shorten their kqueue wait from 1000ms to ~10ms while
overflow is pending for faster recovery.

Consumers always see their ring slots freed after a drain; the deferred
flush repopulates them. No silent drops, no blocking, fully transparent
to callers.

---

## ✅ 4. Background task scheduling (resolved)

Replaced the one-task-per-tick round-robin with a two-phase scheduler:
Phase 1 runs all deadline-passed tasks, Phase 2 runs one continuous task.
Extracted `_tick_run_entry` helper with the `_async_awaiting` flag guard
(preventing the scheduler from resuming event-waiting coroutines).

---

## ✅ 5. Proc lane: blocking stdin writes (resolved)

Stdin writes are non-blocking with `pending_write` buffering. If the
pipe is full (EAGAIN), unwritten bytes are buffered in `proc.pending_write`
and flushed on subsequent kqueue cycles. The proc lane never blocks on
`write()`, so a child with a full stdin pipe can't stall other subprocesses.

---

## ✅ 6. Lane kqueue timeout is always -1 (resolved)

All lanes now use `kq:wait(1000)` (1 second timeout) instead of blocking
forever. This means every lane wakes at least once per second for
housekeeping (periodic gc, heartbeat, etc.) even without an external event.

---

## ✅ 7. File-load path has two codepaths (resolved)

All callers use `editor:_next_file_op_id()` to mint a req_id and route
through `file_op:<id>` events. The legacy `MSG_FILE_LOADED` type (1) is
never pushed or handled — `drain_inbox` only handles `MSG_FILE_LOADED_V2`.
Stale comments updated across `main.lua`, `io_lane.lua`, `editor.lua`,
`shared.lua`, and `shared_state.h`.

---

## 🟢 8. `shared:push` with Lua strings copies on every send (acknowledged)

The convenience path in `shared:push` (for pushes from main) copies Lua
strings into `ffi.new("char[?]")` buffers. Avoiding the copy via
`ffi.cast("const char *", p)` is fragile — the GC may collect the string
before the consumer pops the message. Since all ring-buffer payloads are
small (file paths, short control messages), the copy overhead is negligible.
Accepted as a known minor cost.

---

## Legend

- ✅ Resolved / implemented
- 🟡 Worth fixing, but current usage patterns won't trigger it often
- 🟢 Polish / cleanup — fine to defer
