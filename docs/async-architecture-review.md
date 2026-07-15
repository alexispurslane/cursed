# Async & Multithreading Architecture — Issues

Summary of the architectural concerns identified in the lane / event-bus / coroutine / background-task review.

---

## 🔴 1. No timeout on `async.await` — a crashed lane hangs the editor

If a lane thread crashes (segfault, unhandled Lua error), the expected reply event
(`file_op:<id>`, `process_out:<id>`, `task_result:<id>`, etc.) never fires.
The awaiting coroutine hangs forever, and the coroutine that launched it (e.g.
a keybinding handler) is also stuck. The user sees a frozen editor.

`async.sleep` has an implicit timeout via `schedule_after`, but arbitrary
`await` calls do not.

**Fix:** add an optional `timeout_us` to `AsyncToken`. A background deadline
checker resumes the coroutine with `{ err = "timeout" }` if the deadline expires.
Or, more simply: a lane health monitor that notices a dead lane and emits
synthetic error events for all outstanding awaits on that lane's namespace.

---

## 🔴 2. No lane health monitoring

Main has no way to detect that a lane thread has died. Each lane runs
`while ss:running() do ... end`; if it exits early, the ring buffer goes
silent and main simply stops receiving events. Combined with #1, this means
a dead lane = a hung editor with no error message.

`main.c` already calls `pthread_create` for each lane. It could expose
per-lane alive flags through `SharedState` (e.g. `ss._ptr.lane_alive[N]`
as atomics) that main polls. Combined with await timeouts, you'd catch dead
lanes quickly.

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

## 🟢 6. Lane kqueue timeout is always -1 (block forever)

Every lane uses `kq:wait(-1)`. Lanes can't do periodic housekeeping
(garbage collection of old parse trees, reaping dead LSP clients) without
being woken by main. The highlight lane, for instance, accumulates docs
in `per_lang[lang].docs[view_id]` indefinitely — closed views are never
evicted.

**Fix:** use a finite timeout (e.g. 5000ms) and do housekeeping on timeout
wake, or add a lane-internal timerfd. Main could also push a periodic
`MSG_HOUSEKEEP` message.

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

- 🔴 Needs attention before production / heavy concurrent load
- 🟡 Worth fixing, but current usage patterns won't trigger it often
- 🟢 Polish / cleanup — fine to defer
