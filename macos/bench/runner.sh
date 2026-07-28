#!/bin/bash
# Runs INSIDE the terminal under test (compare.sh launches it, or you paste it
# into a terminal it can't drive). Streams each fixture through the terminal
# WORTEL_BENCH_REPS times (default 3), appends timings to results/<name>.csv,
# and drops results/<name>.done so compare.sh knows this terminal is finished.
set -eu
name="${1:?usage: runner.sh <terminal-name>}"
dir="$(cd "$(dirname "$0")" && pwd)"
reps="${WORTEL_BENCH_REPS:-3}"
out="$dir/results/$name.csv"

mkdir -p "$dir/results"
: > "$out"
for fixture in scrolling colors cursor; do
  f="$dir/data/$fixture.txt"
  if [ ! -s "$f" ]; then
    echo "missing fixture $f — run bench/gen.sh first" >&2
    exit 1
  fi
  for i in $(seq 1 "$reps"); do
    ms=$(python3 "$dir/timed_stream.py" "$f")
    echo "$name,$fixture,$i,$ms" >> "$out"
  done
done
touch "$dir/results/$name.done"
printf '\n\n== %s: done (%s) ==\n' "$name" "$out"
