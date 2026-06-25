--- Thin Lua wrapper around kqueue(2) for fd multiplexing and cross-thread wake.
---
--- Two flavours of event source:
---   - add_fd(fd)        — fire when fd becomes readable (EVFILT_READ)
---   - add_wake(ident)   — fire when another thread triggers `ident` (EVFILT_USER)
---
--- wait(timeout_ms) blocks the calling thread until any registered event fires
--- (or until the timeout). It returns a pointer to a buffer of kevents and a
--- count; callers iterate and dispatch.
---
--- Both lanes share the same underlying kq fd (stored in SharedState.kq_fd).
--- macOS guarantees kevent() is safe to call concurrently from multiple
--- threads on the same kq. A wake from thread A will wake any thread B that
--- is currently blocked in kevent() on the same kq.

local ffi = require("ffi")
local bit = require("bit")
local kq_ffi = require("cursed.kqueue_ffi")

---@class Kqueue
---@field fd integer
---@field _event_buf any struct kevent[16] reusable buffer
local Kqueue = {}
Kqueue.__index = Kqueue

--- Wrap an existing kqueue fd (created elsewhere — typically in main.c).
--- Both lanes wrap the same fd.
---@param fd integer
---@return Kqueue
function Kqueue.wrap(fd)
    return setmetatable({
        fd = tonumber(fd),
        _event_buf = ffi.new("struct kevent[16]"),
    }, Kqueue)
end

local _ev_buf = ffi.new("struct kevent[1]")
local function make_event(ident, filter, flags, fflags)
    _ev_buf[0].ident = ident
    _ev_buf[0].filter = filter
    _ev_buf[0].flags = flags
    _ev_buf[0].fflags = fflags or 0
    _ev_buf[0].data = 0
    _ev_buf[0].udata = nil
    return _ev_buf
end

--- Register an fd for read-readiness.
---@param fd integer
function Kqueue:add_fd(fd)
    local nfd = tonumber(fd)
    local ev = make_event(nfd, kq_ffi.EVFILT_READ, bit.bor(kq_ffi.EV_ADD, kq_ffi.EV_CLEAR))
    local rc = ffi.C.kevent(self.fd, ev, 1, nil, 0, nil)
    if tonumber(rc) < 0 then
        error(
            ("kqueue: add_fd(%d) on kq=%d failed (rc=%d errno=%d)"):format(
                nfd,
                self.fd,
                tonumber(rc),
                kq_ffi.errno()
            )
        )
    end
end

--- Register a user-event ident. Fires when another thread calls wake(ident).
---@param ident integer arbitrary uintptr_t (must match between add_wake + wake)
function Kqueue:add_wake(ident)
    local nid = tonumber(ident)
    local ev = make_event(nid, kq_ffi.EVFILT_USER, bit.bor(kq_ffi.EV_ADD, kq_ffi.EV_CLEAR))
    ffi.C.kevent(self.fd, ev, 1, nil, 0, nil)
end

--- Trigger a previously-registered wake ident. Safe to call from any thread.
---@param ident integer
function Kqueue:wake(ident)
    local nid = tonumber(ident)
    local ev = make_event(nid, kq_ffi.EVFILT_USER, 0, kq_ffi.NOTE_TRIGGER)
    ffi.C.kevent(self.fd, ev, 1, nil, 0, nil)
end

--- Block until any registered event fires, or timeout.
---
--- timeout_ms < 0  : block forever
--- timeout_ms == 0 : non-blocking poll
--- timeout_ms > 0  : block for at most that many ms
---
---@param timeout_ms integer
---@return any struct kevent* events buffer (valid until next :wait() call)
---@return integer count number of events (0 if timeout, -1 on error)
function Kqueue:wait(timeout_ms)
    local ts
    if timeout_ms < 0 then
        ts = nil
    else
        local s = math.floor(timeout_ms / 1000)
        local ns = (timeout_ms - s * 1000) * 1000000
        ts = ffi.new("struct timespec[1]", { { tv_sec = s, tv_nsec = ns } })[0]
    end

    local n = tonumber(ffi.C.kevent(self.fd, nil, 0, self._event_buf, 16, ts))
    return self._event_buf, n or 0
end

return {
    Kqueue = Kqueue,
}
