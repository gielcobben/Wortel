#!/bin/bash
# One-command throughput comparison: Wortel vs every terminal installed here.
#
#   ./bench/compare.sh            # run everything, write results/report.md
#   WORTEL_BENCH_REPS=5 ./bench/compare.sh
#
# Detects which terminals exist (Ghostty, kitty, Alacritty, iTerm, Apple
# Terminal) and skips the rest, so installing a competitor is all it takes to
# add it to the report. Each terminal runs runner.sh sequentially — never in
# parallel, they'd contend for cores — and is quit afterwards.
#
# Wortel has no CLI (zero-config by design), so it's driven by typing into it
# via System Events, which needs Accessibility permission for *this* terminal.
# Without it, the script prints the command to paste into Wortel by hand and
# waits. It always benches into a FRESH session (⌘N): existing sessions may be
# running agents that must not receive keystrokes. Wortel is left open.
#
# Typometer (latency) and DOOM-fire (render) stay manual — see BENCHMARKS.md;
# the epilogue prints the steps.
set -eu
cd "$(dirname "$0")"
BENCH="$PWD"
REPS="${WORTEL_BENCH_REPS:-3}"
TIMEOUT="${WORTEL_BENCH_TIMEOUT:-300}"

[ -s data/scrolling.txt ] || ./gen.sh
rm -rf results
mkdir -p results

# Wait for runner.sh's done marker; fail the terminal, not the run, on timeout.
wait_done() { # name
  local waited=0
  until [ -f "results/$1.done" ]; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$TIMEOUT" ]; then
      echo "  $1: timed out after ${TIMEOUT}s — skipping" >&2
      return 1
    fi
  done
  echo "  $1: done"
}

quit_app() { # app-name process-name
  osascript -e "tell application \"$1\" to quit" >/dev/null 2>&1 || true
  sleep 1
  pkill -x "$2" 2>/dev/null || true
}

echo "== Throughput: $REPS reps × 3 fixtures per terminal =="

# --- Apple Terminal (always present) ------------------------------------------
echo "-- Terminal.app"
osascript -e "tell application \"Terminal\" to do script \"WORTEL_BENCH_REPS=$REPS bash '$BENCH/runner.sh' terminal\"" >/dev/null
wait_done terminal && quit_app Terminal Terminal

# --- iTerm2 -------------------------------------------------------------------
if [ -d "/Applications/iTerm.app" ]; then
  echo "-- iTerm2"
  osascript >/dev/null <<EOF
tell application "iTerm"
  create window with default profile command "/bin/bash -c 'WORTEL_BENCH_REPS=$REPS bash $BENCH/runner.sh iterm'"
end tell
EOF
  wait_done iterm && quit_app iTerm iTerm2
fi

# --- Ghostty ------------------------------------------------------------------
if [ -d "/Applications/Ghostty.app" ]; then
  echo "-- Ghostty"
  # Config keys are accepted as CLI args; `command` replaces the shell.
  open -na Ghostty --args --command="/bin/bash -c 'WORTEL_BENCH_REPS=$REPS bash $BENCH/runner.sh ghostty'"
  wait_done ghostty && quit_app Ghostty ghostty
fi

# --- kitty --------------------------------------------------------------------
if [ -x "/Applications/kitty.app/Contents/MacOS/kitty" ]; then
  echo "-- kitty"
  /Applications/kitty.app/Contents/MacOS/kitty \
    /bin/bash -c "WORTEL_BENCH_REPS=$REPS bash '$BENCH/runner.sh' kitty" &
  wait_done kitty && quit_app kitty kitty
fi

# --- Alacritty ----------------------------------------------------------------
if [ -x "/Applications/Alacritty.app/Contents/MacOS/alacritty" ]; then
  echo "-- Alacritty"
  /Applications/Alacritty.app/Contents/MacOS/alacritty \
    -e /bin/bash -c "WORTEL_BENCH_REPS=$REPS bash '$BENCH/runner.sh' alacritty" &
  wait_done alacritty && quit_app Alacritty alacritty
fi

# --- Wortel -------------------------------------------------------------------
WORTEL_APP="/Applications/Wortel.app"
if [ ! -d "$WORTEL_APP" ]; then
  # Fall back to the newest Release build in DerivedData.
  WORTEL_APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 \
    -path '*/Release/Wortel.app' 2>/dev/null | head -1 || true)
fi
if [ -n "$WORTEL_APP" ] && [ -d "$WORTEL_APP" ]; then
  echo "-- Wortel ($WORTEL_APP)"
  RUN_CMD="WORTEL_BENCH_REPS=$REPS bash '$BENCH/runner.sh' wortel"
  open -a "$WORTEL_APP"
  sleep 2
  # Accessibility probe: an empty keystroke types nothing but still needs the
  # permission, so it fails exactly when real typing would.
  if osascript -e 'tell application "System Events" to keystroke ""' >/dev/null 2>&1; then
    osascript >/dev/null <<EOF
tell application "Wortel" to activate
delay 1
tell application "System Events"
  keystroke "n" using command down
  delay 1
  keystroke "$RUN_CMD"
  key code 36
end tell
EOF
  else
    echo
    echo "  No Accessibility permission to type into Wortel."
    echo "  Paste this into a NEW Wortel session (⌘N):"
    echo
    echo "    $RUN_CMD"
    echo
    echo "  Waiting for it to finish…"
  fi
  wait_done wortel || true
  # Deliberately not quitting Wortel: it may hold the user's live sessions.
else
  echo "-- Wortel: no /Applications/Wortel.app or Release build found — skipped" >&2
fi

# --- Report -------------------------------------------------------------------
python3 - "$BENCH/results" <<'PY'
import csv, glob, statistics, sys, os, datetime

results_dir = sys.argv[1]
rows = []
for path in glob.glob(os.path.join(results_dir, "*.csv")):
    with open(path) as f:
        rows += [r for r in csv.reader(f) if len(r) == 4]
if not rows:
    sys.exit("no results collected")

fixtures = ["scrolling", "colors", "cursor"]
terminals = sorted({r[0] for r in rows}, key=lambda t: (t != "wortel", t))
med = {
    (t, fx): statistics.median(
        float(r[3]) for r in rows if r[0] == t and r[1] == fx
    )
    for t in terminals
    for fx in fixtures
    if any(r[0] == t and r[1] == fx for r in rows)
}

lines = [
    f"# Terminal throughput — {datetime.date.today().isoformat()}",
    "",
    "Median ms to stream each fixture through the terminal's parser",
    "(DSR-synced, not pty-buffered `time cat`). Lower is better;",
    "(xN.NN) is relative to Wortel.",
    "",
    "| terminal | " + " | ".join(fixtures) + " |",
    "|---|" + "---|" * len(fixtures),
]
for t in terminals:
    cells = []
    for fx in fixtures:
        v = med.get((t, fx))
        if v is None:
            cells.append("—")
        elif t == "wortel" or ("wortel", fx) not in med:
            cells.append(f"{v:.0f} ms")
        else:
            cells.append(f"{v:.0f} ms (x{v / med[('wortel', fx)]:.2f})")
    lines.append(f"| {t} | " + " | ".join(cells) + " |")

report = "\n".join(lines) + "\n"
with open(os.path.join(results_dir, "report.md"), "w") as f:
    f.write(report)
print()
print(report)
PY

echo "Report: bench/results/report.md"
echo
echo "Still manual (see BENCHMARKS.md):"
echo "  - Typometer latency: ≥5 passes in Wortel + each competitor, same display/font."
echo "  - DOOM-fire render:  clone github.com/const-void/DOOM-fire-zig, run side by side."
