--- FFI declarations for POSIX and C stdlib functions.
---
--- Single place for open, close, mmap, munmap, free, calloc, realloc, etc.
--- All other _ffi modules depend on this being loaded first.

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef([[

typedef void (*sighandler_t)(int);
sighandler_t signal(int signum, sighandler_t handler);

int open(const char *path, int flags, ...);
int close(int fd);
void *mmap(void *addr, unsigned long length, int prot, int flags, int fd, long offset);
int munmap(void *addr, unsigned long length);
int usleep(unsigned int microseconds);
long sysconf(int name);
int gettimeofday(struct timeval *tv, void *tz);

void free(void *ptr);
void *calloc(unsigned long nmemb, unsigned long size);
void *realloc(void *ptr, unsigned long size);
void *memcpy(void *dst, const void *src, unsigned long n);

ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int pipe(int fildes[2]);

struct pollfd {
    int   fd;
    short events;
    short revents;
};

int poll(struct pollfd *fds, unsigned int nfds, int timeout);

/* select(2) — macOS-friendly tty watching */
struct timeval {
    long tv_sec;
    long tv_usec;
};

int select(int nfds, void *readfds, void *writefds, void *exceptfds, struct timeval *timeout);

void _exit(int status);

/* Ensure all output on a tty fd has been transmitted */
int tcdrain(int fd);
]])

-- macOS 64-bit dirent + directory operations
ffi.cdef([[
typedef struct DIR DIR;

struct dirent {
    uint64_t d_ino;
    int64_t  d_seekoff;
    uint16_t d_reclen;
    uint16_t d_namlen;
    uint8_t  d_type;
    char     d_name[1024];
};

DIR *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int closedir(DIR *dirp);
]])

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

local O_RDONLY = 0
local O_WRONLY = 1
local O_CREAT = 0x0200
local O_TRUNC = 0x0400
local PROT_READ = 0x01
local PROT_WRITE = 0x02
local MAP_PRIVATE = 0x0002
local MAP_ANONYMOUS = 0x1000 -- macOS; Linux uses 0x20
local _SC_PAGESIZE = 29
local MAP_FAILED = ffi.cast("void *", -1)
local POLLIN = 0x0001
local POLLHUP = 0x0010
local POLLNVAL = 0x0020
local DT_DIR = 4
local DT_REG = 8

----------------------------------------------------------------------------------------------------
-- select(2) helpers
----------------------------------------------------------------------------------------------------

--- Size of an fd_set that can hold fds 0–1023 (macOS FD_SETSIZE = 1024).
--- On 64-bit macOS, fd_set is long[16] = 128 bytes.
local FD_SET_SIZE = 128

--- Allocate a zeroed fd_set buffer.
---@return any cdata  uint8_t[128] cdata, zeroed
local function fd_set_new()
    return ffi.new("uint8_t[?]", FD_SET_SIZE)
end

--- Set a bit in an fd_set (equivalent of FD_SET).
local function fd_set_set(set, fd)
    set[math.floor(fd / 8)] = bit.bor(set[math.floor(fd / 8)], bit.lshift(1, fd % 8))
end

--- Test a bit in an fd_set (equivalent of FD_ISSET).
local function fd_set_isset(set, fd)
    return bit.band(set[math.floor(fd / 8)], bit.lshift(1, fd % 8)) ~= 0
end

----------------------------------------------------------------------------------------------------
-- SaveRequest: heap-allocated struct for async save (main → IO → main)
----------------------------------------------------------------------------------------------------
ffi.cdef([[
struct SaveRequest {
    void    *data;
    uint32_t data_len;
    uint32_t data_cap;
    char    *filepath;
};
]])

----------------------------------------------------------------------------------------------------
-- Module export
----------------------------------------------------------------------------------------------------

return {
    C = ffi.C,
    O_RDONLY = O_RDONLY,
    PROT_READ = PROT_READ,
    PROT_WRITE = PROT_WRITE,
    MAP_PRIVATE = MAP_PRIVATE,
    MAP_ANONYMOUS = MAP_ANONYMOUS,
    _SC_PAGESIZE = _SC_PAGESIZE,
    MAP_FAILED = MAP_FAILED,
    POLLIN = POLLIN,
    POLLHUP = POLLHUP,
    POLLNVAL = POLLNVAL,
    DT_DIR = DT_DIR,
    DT_REG = DT_REG,
    O_WRONLY = O_WRONLY,
    O_CREAT = O_CREAT,
    O_TRUNC = O_TRUNC,
    -- select(2) helpers
    fd_set_new = fd_set_new,
    fd_set_set = fd_set_set,
    fd_set_isset = fd_set_isset,
}
