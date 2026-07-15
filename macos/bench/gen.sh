#!/bin/bash
# Generates terminal-throughput benchmark streams (no Rust/vtebench needed).
# Run once; then `cat` the files inside a terminal and time them.
# No pipefail: `yes | head` intentionally SIGPIPEs `yes`.
set -eu
cd "$(dirname "$0")"
mkdir -p data

# 1. Plain scrolling text — the dominant real-world workload.
yes "The quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnop" \
  | head -n 200000 > data/scrolling.txt

# 2. Dense 24-bit truecolor cells — stresses the glyph/color paths.
python3 - <<'PY' > data/colors.txt
import sys
w = 120
for row in range(40000):
    line = []
    for c in range(w):
        r = (c * 2 + row) % 256
        g = (c * 5 + row * 2) % 256
        b = (c * 7 + row * 3) % 256
        line.append(f"\x1b[48;2;{r};{g};{b}m ")
    line.append("\x1b[0m\n")
    sys.stdout.write("".join(line))
PY

# 3. Cursor/attribute churn — SGR + cursor moves.
python3 - <<'PY' > data/cursor.txt
import sys
for i in range(120000):
    sys.stdout.write(f"\x1b[1m\x1b[31mERROR\x1b[0m \x1b[2mfoo bar baz\x1b[0m line {i}\r\n")
PY

echo "Generated:"
ls -lh data/
echo
echo "Run each inside Wortel AND Ghostty.app and compare:"
echo "  time cat bench/data/scrolling.txt"
echo "  time cat bench/data/colors.txt"
echo "  time cat bench/data/cursor.txt"
