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

## 🟡 3. No backpressure on ring buffers

`shared:push()` calls `c.ring_push` with no capacity check. If a lane
falls behind (e.g. highlight lane stuck parsing a large file), the main
thread could overflow the ring buffer. Either messages are silently
dropped or `ring_push` blocks — neither is desirable.

**Fix:** expose ring buffer capacity and have `push` return a `full` error
that callers can retry. A watermark callback (e.g. "ring at 75% — slow
down") is more idiomatic but adds complexity. For v1, making `push` return
`false` on full and having callers handle it is sufficient.

---

## 🟡 4. Single-step background task scheduling can starve

`tick_background_tasks` processes exactly **one** task per main-loop
iteration — strict round-robin. A coroutine-based task that does
`async.await()` gets re-queued after each yield. With N tasks, each gets
1/N of the ticks. The blink timer is one such task; as more deferred work
lands (LSP didChange debounce, spellcheck, file watchers), the blink could
visibly stutter.

**Fix:** either run all ready deadline tasks per tick (not just one), or
separate timered tasks (deadline-based) from continuous tasks (plain
functions) and run all deadline tasks whose deadline has passed plus one
continuous task.

---

## 🟡 5. Proc lane: blocking stdin writes can stall all subprocesses

```lua
-- proc_lane.lua: blocking write loop
while written < len do
    local n = ffi.C.write(proc.stdin_fd, write_ptr + written, len - written)
```

The proc lane processes all subprocess I/O in a single thread. If one
child has a full stdin pipe (not reading), this write blocks the entire
proc lane — no stdout/stderr from *any* child is drained, no new spawns
are processed.

**Fix:** make stdin writes non-blocking (like reads), buffer unwritten bytes,
and retry on the next kqueue cycle when the fd is writable.

---

## ✅ 6. Lane kqueue timeout is always -1 (resolved)

All lanes now use `kq:wait(1000)` (1 second timeout) instead of blocking
forever. This means every lane wakes at least once per second for
housekeeping (periodic gc, heartbeat, etc.) even without an external event.

---

## 🟢 7. File-load path has two codepaths

The legacy path (no `req_id`, FIFO view matching) and the v2 path
(req_id-correlated via `file_op:<id>` events) coexist in `drain_inbox`.
The legacy path only exists for backward compatibility and could be removed
once all callers use req_id-based loads.

**Fix:** audit remaining callers that push `MSG_FILE_LOAD` with `arg = 0`
and migrate them to use `editor:_next_file_op_id()`. Then remove the legacy
drain path.

---

## 🟢 8. `shared:push` with Lua strings copies on every send

The convenience path in `shared:push` (for pushes from main) copies Lua
strings into `ffi.new("char[?]")` buffers. This is copy-on-every-send.
For small control messages it's fine, but worth noting.

**Fix:** not urgent. Could use the string's internal pointer via
`ffi.cast("const char *", p)` plus `#p` to avoid the copy, but this is
fragile (the string must stay alive until the consumer pops it).

---

## Legend

- ✅ Resolved / implemented
- 🟡 Worth fixing, but current usage patterns won't trigger it often
- 🟢 Polish / cleanup — fine to defer
