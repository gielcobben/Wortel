#!/usr/bin/env python3
"""Check that a light/dark switch reaches a program the way Claude Code reads it.

Run it in a Wortel session, then flip the Mac's appearance (Control Centre,
or System Settings > Appearance) a few times. Ctrl-C to stop.

Claude Code subscribes to theme reports (`?2031`), but on each `?997` report
it does not trust the light/dark the report carries: it asks the terminal for
its background colour (`OSC 11`) and judges light or dark from that. So the
terminal must have its new colours in place by the time the report is out.
When it didn't (`GhosttyRuntime`, `GHOSTTY_ACTION_RELOAD_CONFIG`), the answer
was the old background and the agent kept the wrong palette until restarted.

This does the same thing Claude does, as fast as it does it, and prints
whether the two answers agree.
"""

import os
import re
import select
import sys
import termios
import tty

REPORT = re.compile(rb"\x1b\[\?997;([12])n")
BACKGROUND = re.compile(
    rb"\x1b\]11;rgba?:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})(?:\x07|\x1b\\)"
)


def luminance_says(r: bytes, g: bytes, b: bytes) -> str:
    # Claude Code's own rule: Rec. 709 luminance over 0.5 is light.
    def channel(hex_: bytes) -> float:
        return int(hex_, 16) / (16 ** len(hex_) - 1)

    y = 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    return "light" if y > 0.5 else "dark"


def read_until(fd: int, pattern: re.Pattern, buffer: bytearray, timeout: float):
    while True:
        match = pattern.search(buffer)
        if match:
            del buffer[: match.end()]
            return match
        ready, _, _ = select.select([fd], [], [], timeout)
        if not ready:
            return None
        chunk = os.read(fd, 4096)
        if not chunk:
            return None
        buffer.extend(chunk)


def main() -> int:
    fd = sys.stdin.fileno()
    if not os.isatty(fd):
        print("Run this in a terminal.", file=sys.stderr)
        return 2
    saved = termios.tcgetattr(fd)
    out = sys.stdout.buffer
    checks = failures = 0
    try:
        tty.setraw(fd)
        out.write(b"\x1b[?2031h")
        out.flush()
        print("Listening. Flip the Mac's appearance; Ctrl-C to stop.\r")
        buffer = bytearray()
        while True:
            # Ctrl-C may already be in the buffer, read in while waiting for
            # a background answer; raw mode means no SIGINT to fall back on.
            if b"\x03" in buffer:
                break
            # The latest report only: after two quick flips the background
            # answers for the second, and judging the first by it would be a
            # false FAIL. Claude ends up on the last one too.
            reports = list(REPORT.finditer(buffer))
            report = reports[-1] if reports else None
            if not report:
                # Only block when nothing already read is left to handle: a
                # second report can arrive in the same chunk as an answer.
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                buffer.extend(chunk)
                continue
            del buffer[: report.end()]
            reported = "dark" if report.group(1) == b"1" else "light"
            # Ask straight away, the way Claude Code does.
            out.write(b"\x1b]11;?\x1b\\")
            out.flush()
            answer = read_until(fd, BACKGROUND, buffer, timeout=2)
            checks += 1
            if not answer:
                failures += 1
                print(f"report {reported:5}  background: no answer          FAIL\r")
                continue
            judged = luminance_says(*answer.groups())
            ok = judged == reported
            failures += 0 if ok else 1
            colour = "/".join(part.decode() for part in answer.groups())
            print(f"report {reported:5}  background {colour} reads {judged:5}  "
                  f"{'ok' if ok else 'FAIL'}\r")
    finally:
        out.write(b"\x1b[?2031l")
        out.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
    print(f"{checks} switches, {failures} wrong.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
