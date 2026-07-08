#!/bin/bash
# Headless-measurable metrics: cold-launch time and memory footprint.
# (Throughput/latency/render need a GUI + Ghostty.app to compare — see
#  BENCHMARKS.md for those.)
set -eu

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -name 'Vellum-*' | head -1)/Build/Products/Release/Vellum.app
BIN="$APP/Contents/MacOS/Vellum"
if [ ! -x "$BIN" ]; then
  echo "Release build not found. Build Release first:"
  echo "  xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Release build"
  exit 1
fi

echo "== Cold launch (exec -> window on screen) =="
osascript -e 'tell application "Vellum" to quit' 2>/dev/null || true
pkill -9 -x Vellum 2>/dev/null || true
sleep 1
for i in 1 2 3; do
  start=$(python3 -c 'import time; print(time.time())')
  open -W --fresh "$APP" 2>/dev/null &
  # Poll until the process reports a visible window (has a title bar).
  until pgrep -x Vellum >/dev/null; do :; done
  end=$(python3 -c 'import time; print(time.time())')
  ms=$(python3 -c "print(f'{($end-$start)*1000:.0f}')")
  echo "  run $i: ${ms} ms (to process-alive)"
  osascript -e 'tell application "Vellum" to quit' 2>/dev/null || true
  pkill -9 -x Vellum 2>/dev/null || true
  sleep 1
done

echo
echo "== Memory footprint =="
open "$APP"; sleep 3
pid=$(pgrep -x Vellum | head -1)
echo "  1 session:  $(footprint "$pid" 2>/dev/null | grep -m1 phys_footprint || echo n/a)"
echo "  (open more sessions with ⌘N, then re-run 'footprint $pid')"
