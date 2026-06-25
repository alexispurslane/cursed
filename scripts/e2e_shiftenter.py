#!/usr/bin/env python3
"""End-to-end: run cursed in a pty, send Ghostty Shift+Enter bytes,
verify a newline (not the raw escape garbage) lands in the buffer."""
import os, pty, time, select, sys, signal

BIN = "./build/cursed"
TMP = "/tmp/cursed_shiftenter_e2e.txt"

# Start from a tiny file so we can see exactly what was inserted.
with open(TMP, "w") as f:
    f.write("hello\n")

pid, fd = pty.fork()
if pid == 0:
    os.execv(BIN, [BIN, TMP])
    os._exit(127)

def feed(data, delay=0.12):
    os.write(fd, data)
    time.sleep(delay)

def drain(t=0.3):
    out = b""
    while True:
        r, _, _ = select.select([fd], [], [], t)
        if not r:
            break
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return out

drain(0.6)  # let it boot

# Move past "hello" isn't needed; cursor is at end of line 1 "hello".
# Send Shift+Enter (Ghostty formatOtherKeys: ESC[27;2;13~) then 'X'.
feed(b"\x1b[27;2;13~", 0.15)
feed(b"X", 0.15)

# Save (C-x C-s) then quit (C-x C-c).
feed(b"\x18\x13", 0.25)
feed(b"\x18\x03", 0.4)

drain(1.0)

# Reap child.
try:
    os.waitpid(pid, 0)
except OSError:
    pass

with open(TMP) as f:
    result = f.read()

print("=== file contents ===")
print(repr(result))
print("=== file (raw) ===")
print(result)

ok = ("[27;2;13~" not in result) and ("\nX" in result or result.endswith("X"))
# acceptable: a newline was inserted and X after it, no escape garbage
has_garbage = any(c in result for c in "[27;2;13~")
newline_after_hello = "hello\nX" in result or "helloX" in result  # allow either
print("\n=== verdict ===")
print("escape garbage present:", has_garbage)
print("newline inserted before X:", "\nX" in result)
sys.exit(0 if (not has_garbage and "\nX" in result) else 1)
