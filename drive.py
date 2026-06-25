#!/usr/bin/env python3
import os, pty, time, sys, select

BIN = "./build/cursed"
F = "/tmp/cursed_repro.txt"
with open(F, "w") as fh:
    fh.write("hello world\nfoo bar baz\n")

# keystrokes as termbox key strings. We send raw terminal escape sequences.
# cursed uses termbox2 which reads from the tty. We must send bytes that
# termbox decodes into the right keys.
KEYS = {
    "C-space": b"\x00",
    "right":   b"\x1b[C",
    "left":    b"\x1b[D",
    "C-_":     b"\x1f",       # ctrl-_ produces 0x1f
    "C-x":     b"\x18",
    "u":       b"u",
    "d":       b"d",
    "X":       b"X",
    "C-c":     b"\x03",
    "C-a":     b"\x01",
    "C-e":     b"\x05",
}

def seq(*names, delay=0.15):
    out = b""
    for n in names:
        out += KEYS[n]
    return out, delay

import struct, fcntl, termios
WINSIZE = struct.pack("HHHH", 40, 120, 0, 0)

def main():
    pid, fd = pty.fork()
    if pid == 0:
        # set winsize in child
        fcntl.ioctl(0, termios.TIOCSWINSZ, WINSIZE)
        os.execv(BIN, [BIN, F])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, WINSIZE)
    buf = bytearray()
    log = open("/tmp/cursed_pty.log", "wb")
    def drain(t):
        end = time.time() + t
        while time.time() < end:
            r,_,_ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    d = os.read(fd, 65536)
                except OSError:
                    break
                if not d: break
                buf.extend(d); log.write(d); log.flush()
    # scenario: set mark, move right 5, type X (replaces selection), then undo
    actions = [
        ([b"\x00"], 0.3),                 # set mark
        ([b"\x1b[C"]*5, 0.3),             # right x5
        ([b"X"], 0.5),                    # type X (replaces selection)
        ([b"\x1f"], 1.0),                 # ctrl-_ undo
    ]
    time.sleep(0.8); drain(0.6)
    for frames, delay in actions:
        for fr in frames:
            os.write(fd, fr)
            time.sleep(0.06)
        drain(delay)
    time.sleep(0.3); drain(1.0)
    # search the raw buffer for "command error"
    text = buf.decode("utf-8","replace")
    # crude: strip escapes
    import re
    plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    plain = re.sub(r"\x1b[()][AB0]", "", plain)
    if "command error" in plain or "arithmetic" in plain:
        print("ERROR DETECTED")
    # print last 2000 chars
    print(plain[-1500:])
    # quit
    try: os.write(fd, b"\x18\x18\x18")
    except: pass
    time.sleep(0.2)
    try: os.close(fd)
    except: pass
    os.waitpid(pid, os.WNOHANG)

main()
