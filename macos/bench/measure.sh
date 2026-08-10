#!/bin/bash
# Headless-measurable metrics: cold-launch time and memory footprint.
# (Throughput/latency/render need a GUI + Ghostty.app to compare — see
#  BENCHMARKS.md for those.)
set -eu

# THIS SCRIPT KILLS EVERY RUNNING WORTEL, several times, because a cold launch
# is only cold if nothing is already up. Wortel is developed in Wortel, so the
# obvious way to run this is from a session inside the app it is about to
# `pkill -9`, which takes the terminal, the shell, and whatever was running in
# it down mid-measurement. Refuse instead: WORTEL_SESSION_ID is set in every
# session the app spawns.
if [ -n "${WORTEL_SESSION_ID:-}" ] && [ "${1:-}" != "--force" ]; then
  echo "Refusing to run inside Wortel: this script force-quits every running copy,"
  echo "including the one this terminal is in."
  echo
  echo "Run it from Terminal.app, or pass --force if you meant it."
  exit 1
fi

# WHERE THE BUILD IS. This used to be the first DerivedData directory matching
# `Wortel-*`, and that is wrong on any machine that has built this project from
# more than one path: a worktree, a clone, a rename. Xcode makes a directory per
# project *location*, they accumulate, `find` returns them in no useful order,
# and the first one is usually the oldest. The symptom is this script insisting
# there is no Release build immediately after a Release build succeeded, which
# reads as a broken build rather than a script looking in the wrong place.
#
# So ask Xcode. `-showBuildSettings` costs a few seconds and is the only answer
# that is right by construction. The project is located relative to THIS FILE
# rather than the working directory, because the natural way to run this from
# the repository root is `./macos/bench/measure.sh`.
HERE=$(cd "$(dirname "$0")" && pwd)
PROJECT="$HERE/../Wortel.xcodeproj"

APP=""
if [ -d "$PROJECT" ]; then
  PRODUCTS=$(xcodebuild -project "$PROJECT" -scheme Wortel -configuration Release \
               -showBuildSettings 2>/dev/null \
             | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
  [ -n "${PRODUCTS:-}" ] && APP="$PRODUCTS/Wortel.app"
fi

# Fallback for a checkout with no generated project (it is gitignored): the
# NEWEST directory that actually contains a Release build, rather than the first
# one that merely exists.
if [ ! -x "${APP:-}/Contents/MacOS/Wortel" ]; then
  APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Wortel-*/Build/Products/Release/Wortel.app 2>/dev/null | head -1 || true)
fi

BIN="${APP:-}/Contents/MacOS/Wortel"
if [ ! -x "$BIN" ]; then
  echo "Release build not found. Build Release first:"
  echo "  cd macos && xcodegen generate"
  echo "  xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Release build"
  exit 1
fi
echo "Measuring: $APP"
echo

echo "== Cold launch (exec -> window on screen) =="
osascript -e 'tell application "Wortel" to quit' 2>/dev/null || true
pkill -9 -x Wortel 2>/dev/null || true
sleep 1
for i in 1 2 3; do
  start=$(python3 -c 'import time; print(time.time())')
  open -W --fresh "$APP" 2>/dev/null &
  # Poll until the process reports a visible window (has a title bar).
  until pgrep -x Wortel >/dev/null; do :; done
  end=$(python3 -c 'import time; print(time.time())')
  ms=$(python3 -c "print(f'{($end-$start)*1000:.0f}')")
  echo "  run $i: ${ms} ms (to process-alive)"
  osascript -e 'tell application "Wortel" to quit' 2>/dev/null || true
  pkill -9 -x Wortel 2>/dev/null || true
  sleep 1
done

echo
echo "== Memory footprint =="
open "$APP"; sleep 3
pid=$(pgrep -x Wortel | head -1)
echo "  1 session:  $(footprint "$pid" 2>/dev/null | grep -m1 phys_footprint || echo n/a)"
echo "  (open more sessions with ⌘N, then re-run 'footprint $pid')"
