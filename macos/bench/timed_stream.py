#!/usr/bin/env python3
"""Stream a fixture to the terminal and time until the terminal has parsed it.

`time cat file` stops when the last write() into the pty is accepted, which
rewards a terminal for having a deep pty buffer, not for being fast. Instead:
write the file to /dev/tty, then send a Device Status Report query (ESC[6n)
and stop the clock when the reply arrives — the terminal answers a DSR only
after every prior byte has gone through its parser, so the number orders
terminals by actual processing speed (rendering may still lag; parse-complete
is the event every terminal reports the same way).

Prints elapsed milliseconds on stdout; run it under command substitution so
the tty only sees the fixture. Used by runner.sh.
"""
import os
import select
import sys
import termios
import time
import tty

CHUNK = 1 << 20
REPLY_TIMEOUT_S = 30


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: timed_stream.py <fixture>", file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as f:
        data = f.read()

    fd = os.open("/dev/tty", os.O_RDWR)
    saved = termios.tcgetattr(fd)
    try:
        # Raw mode so the DSR reply isn't echoed into the display or eaten by
        # the line discipline.
        tty.setraw(fd)
        start = time.monotonic()
        off = 0
        while off < len(data):
            off += os.write(fd, data[off : off + CHUNK])
        os.write(fd, b"\x1b[6n")
        buf = b""
        deadline = time.monotonic() + REPLY_TIMEOUT_S
        while not buf.endswith(b"R"):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                print("no DSR reply from terminal", file=sys.stderr)
                return 1
            buf += os.read(fd, 64)
        elapsed_ms = (time.monotonic() - start) * 1000
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        os.close(fd)

    print(f"{elapsed_ms:.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
