#!/usr/bin/env python3
import os, pty, time, select, struct, fcntl, termios, re, sys

BIN = "./build/cursed"
WINSIZE = struct.pack("HHHH", 40, 120, 0, 0)

# action sequences to try. Each is a list of (bytes, label).
SEQS = {
  "select+delkey+undo": [
     (b"\x00", "setmark"),
     (b"\x1b[C"*4, "right4"),
     (b"\x1b[3~", "Del"),       # delete key (termbox: key_dc)
     (b"\x1f", "undo"),
  ],
  "select+ctrld+undo": [
     (b"\x00", "setmark"),
     (b"\x1b[C"*4, "right4"),
     (b"\x04", "C-d"),
     (b"\x1f", "undo"),
  ],
  "select+backspace+undo": [
     (b"\x00", "setmark"),
     (b"\x1b[C"*4, "right4"),
     (b"\x7f", "BS"),
     (b"\x1f", "undo"),
  ],
  "select+type+undo": [
     (b"\x00", "setmark"),
     (b"\x1b[C"*4, "right4"),
     (b"X", "typeX"),
     (b"\x1f", "undo"),
  ],
  "select跨newline+type+undo": [
     (b"\x1b[C"*8, "right8"),       # move to end of line1
     (b"\x00", "setmark"),
     (b"\x1b[C"*4, "right4"),      # into line2
     (b"X", "typeX"),
     (b"\x1f", "undo"),
     (b"\x1f", "undo"),
  ],
  "justtype+undo": [
     (b"Z", "typeZ"),
     (b"\x1f", "undo"),
  ],
}

def run(seq):
    with open("/tmp/cursed_repro.lua","w") as f:
        f.write("local x = 1\nlocal y = 'hello world'\nprint(y, x)\n")
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, WINSIZE)
        os.execv(BIN, [BIN, "/tmp/cursed_repro.lua"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, WINSIZE)
    log = bytearray()
    def drain(t):
        end=time.time()+t
        while time.time()<end:
            r,_,_=select.select([fd],[],[],0.03)
            if r:
                try: d=os.read(fd,65536)
                except OSError: break
                if not d: break
                log.extend(d)
    time.sleep(0.6); drain(0.4)
    time.sleep(1.8); drain(0.6)   # let highlighter lane install
    for b,label in seq:
        os.write(fd,b); time.sleep(0.06); drain(0.35)
    time.sleep(0.2); drain(0.6)
    try: os.write(fd, b"\x18\x18")
    except: pass
    time.sleep(0.15)
    try: os.close(fd)
    except: pass
    try: os.waitpid(pid,0)
    except: pass
    text = log.decode("utf-8","replace")
    plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]","",text)
    plain = re.sub(r"\x1b[()][AB0]","",plain)
    return plain

for name,seq in SEQS.items():
    plain = run(seq)
    err = ""
    for needle in ["command error","arithmetic","attempt to"]:
        if needle in plain:
            err = needle; break
    # extract a window around 'error' if present
    idx = plain.find("command error")
    snippet = plain[idx-5:idx+120] if idx>=0 else ""
    print(f"=== {name}: {'ERROR!! '+err if err else 'ok'}")
    if err:
        print("   snippet:", repr(snippet))
