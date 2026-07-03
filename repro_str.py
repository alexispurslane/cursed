#!/usr/bin/env python3
import os, pty, time, struct, fcntl, termios, select, threading

BIN = "./build/cursed"
F = "/tmp/cursed_str.ts"
with open(F, "w") as fh:
    fh.write('let message = "hello world";\nmessage')

WINSIZE = struct.pack("HHHH", 40, 120, 0, 0)

def main():
    try:
        os.unlink("/tmp/cursed.log")
    except FileNotFoundError:
        pass
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, WINSIZE)
        os.execv(BIN, [BIN, F])
        os._exit(127)
    def drain():
        while True:
            r, _, _ = select.select([fd], [], [], 0.5)
            if not r:
                continue
            try:
                d = os.read(fd, 4096)
            except OSError:
                break
            if not d:
                break
    threading.Thread(target=drain, daemon=True).start()
    time.sleep(2.0)
    os.write(fd, b"\x1b[B"); time.sleep(0.3)   # down -> line "message"
    os.write(fd, b"\x05");   time.sleep(0.3)   # C-e -> end of "message"
    os.write(fd, b".");      time.sleep(0.8)   # type '.' (trigger)
    os.write(fd, b"\x1b/");  time.sleep(0.8)   # M-/ (force_open)
    os.write(fd, b"\x03");   time.sleep(0.2)
    try: os.close(fd)
    except OSError: pass
    try: os.waitpid(pid, 0)
    except OSError: pass
    with open("/tmp/cursed.log") as fh:
        log = fh.read()
    print("=== request/response (lsp_complete) ===")
    for line in log.splitlines():
        if "completer_requesting" in line or "completer_response" in line or "request_enqueued" in line or "tick_close" in line or "post_command_trigger_now" in line:
            print(line)

if __name__ == "__main__":
    main()
