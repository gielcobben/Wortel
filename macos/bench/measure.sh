#!/bin/bash
# Headless-measurable metrics: cold-launch time and memory footprint.
# (Throughput/latency/render need a GUI + Ghostty.app to compare — see
#  BENCHMARKS.md for those.)
set -eu

# A THROWAWAY COPY, NEVER YOUR WORTEL. This used to quit and `pkill -9` every
# running Wortel, several times, because a cold launch is only cold if nothing
# is already up, and the build it measured shared your data folder: with your
# Wortel running it would only have brought that one forward (InstanceLock).
# Wortel is developed in Wortel, so that took the terminal running the script
# down with it. Now the build is copied with a bundle id and a data folder of
# its own, and only the processes that copy started are stopped, by path and
# by pid. Your Wortel can stay open.
#
# The memory figure is a first launch on an empty folder, so it is comparable
# between machines, which a figure taken from your own sessions.json was not.

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

WORK=$(mktemp -d /tmp/wortel-bench.XXXXXX)   # short: the sockets live in it
COPY="$WORK/WortelBench.app"
DATA="$WORK/data"
COPYBIN="$COPY/Contents/MacOS/Wortel"

# The pid of the copy's app, if it runs. Matched on its executable's path,
# which no other Wortel has. pgrep, because the launch loop polls it.
copy_pid() { pgrep -f "^$COPYBIN" | head -1 || true; }
# Every pid under $1, and $1.
tree() {
  ps -axo pid=,ppid= | awk -v root="$1" '{p[$1]=$2} END {s[root]=1
    for (n = 0; n < 8; n++) for (x in p) if (p[x] in s) s[x]=1
    for (x in s) printf "%s ", x}'
}
stop_copy() {
  local pid
  pid=$(copy_pid)
  [ -n "$pid" ] || return 0
  # Quit by the copy's path, never by name: yours is called Wortel too. A
  # quit rather than a signal, so it writes its sessions.json.
  osascript -e "tell application \"$COPY\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
}
cleanup() {
  stop_copy
  # The copy's keeper outlives it by design, as yours does. It and every
  # shell under it go, then the folder.
  for k in $(pgrep -f "$COPY/Contents/Resources/bin/wortel-keeper" || true); do
    # shellcheck disable=SC2046
    kill -9 $(tree "$k") 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$DATA"
cp -Rc "$APP" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gielcobben.Wortel.bench" "$COPY/Contents/Info.plist"
codesign --force --deep --sign - "$COPY" 2>/dev/null

launch() { open -n --env WORTEL_DATA_DIR="$DATA" --env DO_NOT_TRACK=1 "$COPY"; }

echo "Measuring: $APP"
echo "  as a copy on a data folder of its own, $WORK"
echo

echo "== Cold launch (exec -> process alive) =="
for i in 1 2 3; do
  start=$(python3 -c 'import time; print(time.time())')
  launch &
  until [ -n "$(copy_pid)" ]; do :; done
  end=$(python3 -c 'import time; print(time.time())')
  ms=$(python3 -c "print(f'{($end-$start)*1000:.0f}')")
  echo "  run $i: ${ms} ms (to process-alive)"
  wait
  sleep 1
  stop_copy
  sleep 1
done

echo
echo "== Memory footprint =="
launch
sleep 3
pid=$(copy_pid)
FOOTPRINT=$(footprint "$pid" 2>/dev/null | grep -m1 phys_footprint || echo n/a)
stop_copy

# How many sessions that was. Every surface is a live Metal renderer and its
# own glyph atlas, so the number moves a lot with the count, and 205 MB under a
# label claiming one session sends you looking for a leak that is three
# terminals. The copy's sessions.json is written as it quits.
SESSIONS=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    s = d['sessions'] if isinstance(d, dict) and 'sessions' in d else d
    print(len(s))
except Exception:
    print('?')
" "$DATA/sessions.json" 2>/dev/null || echo '?')

echo "  ${SESSIONS} session(s), first launch on an empty folder:  $FOOTPRINT"
