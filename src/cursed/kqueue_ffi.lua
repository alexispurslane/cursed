--- FFI declarations for kqueue(2) — macOS/BSD event notification primitive.
---
--- Used for both fd-readiness multiplexing (termbox tty + resize fds)
--- and cross-thread wake-up via EVFILT_USER. A single kqueue fd is shared
--- between the main and IO lanes; each lane blocks in kevent() and the
--- other lane wakes it by triggering an EVFILT_USER event.
---
--- Linux support (epoll + eventfd) is a future addition; this file is
--- macOS-only for now. The Lua wrapper in cursed/kqueue.lua hides the
--- difference from callers.

local ffi = require("ffi")

ffi.cdef([[
struct kevent {
    uintptr_t ident;
    short     filter;
    uint16_t  flags;
    uint32_t  fflags;
    intptr_t  data;
    void     *udata;
};

struct timespec {
    long tv_sec;
    long tv_nsec;
};

int kqueue(void);
int kevent(int kq, const struct kevent *changelist, int nchanges,
           struct kevent *eventlist, int nevents,
           const struct timespec *timeout);
int *__error(void);
]])

----------------------------------------------------------------------------------------------------
-- Constants (from <sys/event.h>)
----------------------------------------------------------------------------------------------------

local EVFILT_READ = -1
local EVFILT_USER = -10

local EV_ADD = 0x0001
local EV_DELETE = 0x0002
local EV_ENABLE = 0x0004
local EV_DISABLE = 0x0008
local EV_ONESHOT = 0x0010
local EV_CLEAR = 0x0020

local NOTE_TRIGGER = 0x01000000

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

--- Read the thread-local errno value.
local function errno()
    return tonumber(ffi.C.__error()[0])
end

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    C = ffi.C,
    errno = errno,
    EVFILT_READ = EVFILT_READ,
    EVFILT_USER = EVFILT_USER,
    EV_ADD = EV_ADD,
    EV_DELETE = EV_DELETE,
    EV_ENABLE = EV_ENABLE,
    EV_DISABLE = EV_DISABLE,
    EV_ONESHOT = EV_ONESHOT,
    EV_CLEAR = EV_CLEAR,
    NOTE_TRIGGER = NOTE_TRIGGER,
}
