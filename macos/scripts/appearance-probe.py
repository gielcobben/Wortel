#!/usr/bin/env python3
"""Write down what a session's terminal says about light and dark, as it happens.

    appearance-probe.py <logfile> [--no-subscribe] [--poll SECONDS]

One line per event:

    t=<s> report dark|light                   a ?997 report arrived
    t=<s> colours fg=.. bg=.. (dark|light)    the OSC 10/11 answers, when they change

It subscribes to theme reports (`?2031`) unless told not to, and asks for the
colours on a timer either way, so the log shows when the terminal's own colours
changed whether or not the program was told. `scripts/try-appearance.sh` runs
one per session and reads the logs; `check-theme-reports.py` is the one to run
by hand. `q` or Ctrl-C stops it.
"""
import os, re, select, sys, termios, time, tty

REPORT = re.compile(rb"\x1b\[\?997;([12])n")
OSC = re.compile(rb"\x1b\](1[01]);rgba?:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})(?:\x07|\x1b\\)")


def lum(r, g, b):
    def ch(h):
        return int(h, 16) / (16 ** len(h) - 1)
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)


def main():
    args = sys.argv[1:]
    log_path = args[0]
    subscribe = "--no-subscribe" not in args
    poll = float(args[args.index("--poll") + 1]) if "--poll" in args else 0.5
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    out = sys.stdout.buffer
    start = time.monotonic()
    log = open(log_path, "a", buffering=1)

    def say(text):
        log.write(f"t={time.monotonic() - start:7.2f} {text}\n")

    say(f"start pid={os.getpid()} subscribe={subscribe}")
    try:
        tty.setraw(fd)
        if subscribe:
            out.write(b"\x1b[?2031h")
        out.flush()
        buf = bytearray()
        last = {}
        colours = {}
        next_poll = 0.0
        while True:
            now = time.monotonic()
            if now >= next_poll:
                out.write(b"\x1b]10;?\x07\x1b]11;?\x07")
                out.flush()
                next_poll = now + poll
            ready, _, _ = select.select([fd], [], [], max(0.0, next_poll - time.monotonic()))
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                buf.extend(chunk)
            if b"\x03" in buf or b"q" in buf:
                break
            for m in list(REPORT.finditer(buf)):
                say("report " + ("dark" if m.group(1) == b"1" else "light"))
            buf = bytearray(REPORT.sub(b"", bytes(buf)))
            for m in list(OSC.finditer(buf)):
                which = "fg" if m.group(1) == b"10" else "bg"
                r, g, b = m.group(2), m.group(3), m.group(4)
                colours[which] = (r[:2] + g[:2] + b[:2]).decode()
                if which == "bg":
                    colours["says"] = "light" if lum(r, g, b) > 0.5 else "dark"
            buf = bytearray(OSC.sub(b"", bytes(buf)))
            if "fg" in colours and "bg" in colours and colours != last:
                say(f"colours fg={colours['fg']} bg={colours['bg']} ({colours['says']})")
                last = dict(colours)
    finally:
        if subscribe:
            out.write(b"\x1b[?2031l")
            out.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        say("stop")
    return 0


if __name__ == "__main__":
    sys.exit(main())
