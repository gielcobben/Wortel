#!/bin/zsh
# What a window resize costs the main thread per step, and how often the
# program in the terminal is told about it.
#
#   scripts/bench-resize.sh [path/to/Wortel.app] [--column] [--file] [--panes] [--compare] [--runs N] [--keep]
#
# Runs a copy beside yours, never your Wortel. **Its window comes to the
# front and floats there while a round runs**, a few seconds at a time: a
# covered window is cheaper (SwiftUI lays nothing out for one nobody can
# see), and a round that was not on screen at every step is marked as no
# measurement. A Debug build resizes its own
# window 480 times at 120 Hz when asked by a notification addressed to its pid
# (`ResizeBench`): 3 points of width a step, then width and height together,
# then (with --column) the divider between the terminal and the column.
# A step's cost is all the time the main thread is awake until the next one.
# A step over 8.3 ms is a frame a 120 Hz display does not get.
#
# The terminal runs a full-screen program that repaints when it gets SIGWINCH
# and writes down each one, as an agent's interface does.
#
# --column opens the side column first, which is how the window mostly is, and
# adds the divider round. --file opens a file in a tab, whose every line is a
# view that follows the width. --compare runs each round twice in the same app, turn about: with
# a frame drawn on the main thread at every step, as libghostty has it
# ("before"), and with Wortel's rule (`SurfaceView.frameForNewSize`, "now").
# Turn about because two runs of the same code minutes apart differ by more
# than most changes do. Needs the display awake. --keep leaves the copy open.
#
# --panes measures something else instead: the side column and the sidebar
# sliding open and shut, six times each. It prints the turns of the run loop
# while a pane slides (how many, the worst, how many over 8.3 ms), how long
# the main thread was busy in a slide, and any slide that left the terminal at
# a size that is not its view's.
#
# The last columns: steps that began on a frame of an older size, steps where
# the terminal's view had not been resized with the window, steps of a window
# round in which the pane beside the terminal changed width (it should only
# move), and SIGWINCHes against the times the grid had really changed.
set -u

app="" keep=0 column=0 file=0 panes=0 runs=3 modes=(now)
while (( $# )); do
  case $1 in
    --keep) keep=1 ;;
    --column) column=1 ;;
    --file) file=1 ;;
    --panes) panes=1 ;;
    --compare) modes=(before now) ;;
    --runs) shift; runs=$1 ;;
    *) app=$1 ;;
  esac
  shift
done
here=${0:A:h}/..
if [[ -z $app ]]; then
  app="$(xcodebuild -project "$here/Wortel.xcodeproj" -scheme Wortel -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')/Wortel.app"
fi
[[ -d $app ]] || { print -u2 "no app at $app"; exit 2; }

# A display that is asleep gives a terminal nothing to draw on. A locked
# screen with the display awake does (measured 2026-11-19), so it is the
# display that is asked about: `caffeinate -u -t 5` wakes it.
displays=$(swift -e 'import CoreGraphics; var n: UInt32 = 0; CGGetActiveDisplayList(0, nil, &n); print(n)' 2>/dev/null)
[[ $displays == 0 ]] && { print -u2 "the display is asleep; wake it and run again"; exit 2; }

work=$(mktemp -d /tmp/wortel-rb.XXXXXX)
data=$HOME/.wrb-$$                       # short: the sockets live here
copy=$work/WortelRB.app
wortel=$copy/Contents/Resources/bin/wortel
apppid=""

# Every pid under $1, and $1.
tree() {
  ps -axo pid=,ppid= | awk -v root=$1 '{p[$1]=$2} END {s[root]=1
    for (n = 0; n < 8; n++) for (x in p) if (p[x] in s) s[x]=1
    for (x in s) printf "%s ", x}'
}
cleanup() {
  [[ -n $apppid ]] && kill $apppid 2>/dev/null
  sleep 1
  for k in $(pgrep -f "$copy/Contents/Resources/bin/wortel-keeper"); do kill -9 $(tree $k) 2>/dev/null; done
  rm -rf "$work" "$data"
}
w() { WORTEL_DATA_DIR=$data "$wortel" "$@"; }
pause() { perl -e "select(undef,undef,undef,$1)"; }
wait_for() { # seconds, then a command that succeeds when ready
  local s=$1; shift
  for _ in $(seq 1 $((s * 4))); do "$@" >/dev/null 2>&1 && return 0; pause 0.25; done
  return 1
}

mkdir -p "$data" "$work/repo"
cp -Rc "$app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gielcobben.Wortel.resizebench" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null

# A screen full of text, repainted on every SIGWINCH, each one written down
# with the size it found: rows, columns, and the two pixel sizes.
cat > "$data/tui.py" <<'EOF'
import fcntl, os, signal, struct, sys, termios, time
log = open(sys.argv[1], "a", buffering=1)
def size():
    return struct.unpack("HHHH", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\0" * 8))
def paint():
    rows, cols, _, _ = size()
    out = ["\x1b[?2026h\x1b[H"]
    for row in range(1, rows):
        text = f"row {row} of {rows} at {cols} columns, the quick brown fox jumps over the lazy dog " * 4
        out.append(f"\x1b[38;5;{row % 200 + 20}m{text[:cols]}\x1b[0m\x1b[K\r\n")
    out.append("\x1b[?2026l")
    os.write(1, "".join(out).encode())
def winch(*_):
    log.write("winch %d %d %d %d\n" % size())
    paint()
signal.signal(signal.SIGWINCH, winch)
os.write(1, b"\x1b[?1049h")
paint()
while True:
    time.sleep(3600)
EOF

( cd "$work/repo" && git init -q && for n in 1 2 3; do seq 1 400 | sed "s/^/line $n /" > f$n.txt; done \
  && git add -A . && git -c user.name=bench -c user.email=bench@example.com commit -qm init && print changed >> f1.txt )

open -g -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 "$copy"
wait_for 20 test -s "$data/instance.lock" || { print -u2 "the copy did not start"; cleanup; exit 2; }
apppid=$(cat "$data/instance.lock")
wait_for 20 w list || { print -u2 "the copy does not answer"; cleanup; exit 2; }

id=$(w new --cwd "$work/repo" --name bench -- /usr/bin/python3 "$data/tui.py" "$data/winch.log" | tail -1)
wait_for 10 test -e "$data/winch.log" || { print -u2 "the program did not start"; cleanup; exit 2; }
pause 1.5
if (( file )); then
  WORTEL_SESSION_ID=$id w open "$work/repo/f1.txt" >/dev/null
  pause 2
fi

print "app: $app"
print "side column: $([[ $column == 1 ]] && print open || print closed), file tab: $([[ $file == 1 ]] && print open || print none)"
for run in $(seq 1 $runs); do
 for mode in $modes; do
  : > "$data/winch.log"
  rm -f "$data/result.json"
  osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('sh.wortel.test.resize.$apppid', '$data/result.json|$mode$([[ $column == 1 ]] && print "|column")$([[ $panes == 1 ]] && print "|panes")', \$(), true)" >/dev/null
  wait_for 30 test -s "$data/result.json" || { print -u2 "no result: is this a Debug build?"; cleanup; exit 2; }
  pause 0.5
  /usr/bin/python3 - "$data/result.json" "$data/winch.log" $run <<'EOF'
import json, sys
result = json.load(open(sys.argv[1]))
if "faults" in result:
    for name in ("column", "sidebar"):
        r = result[name]
        print(f"run {sys.argv[3]} {result['mode']:6s} {name:8s} {r['slides']} slides: {r['turns']} turns, worst {r['worstMs']:6.2f} ms,"
              f" over 8.3 ms: {r['over']}, main thread busy a slide: mean {r['meanSlideMs']:6.2f} ms, most {r['busiestSlideMs']:6.2f} ms")
    print(f"run {sys.argv[3]} {result['mode']:6s} terminal wrong after a slide: {len(result['faults'])}" + "".join("\n     " + f for f in result["faults"][:6])
          + ("" if result.get("seenSlides") == 12 else f"   NOT A MEASUREMENT: on screen for {result.get('seenSlides')} of 12 slides"))
    sys.exit(0)
signals = [line.split()[1:] for line in open(sys.argv[2]) if line.startswith("winch")]
grids = sum(1 for a, b in zip([None] + signals, signals) if a is None or a[:2] != b[:2])
def cell(label, r):
    if not r: return ""
    return f" | {label}: mean {r['meanMs']:5.2f} p95 {r['p95Ms']:5.2f} over {r['overBudget']:3d}/{r['steps']}"
print(f"run {sys.argv[3]} {result.get('mode',''):6s}" + cell("width", result["widthOnly"])
      + cell("width+height", result["widthAndHeight"]) + cell("divider", result.get("divider"))
      + f" | stale {result.get('staleFrames','?')} late {result.get('lateTerminal','?')} beside {result.get('besideResized','?')} winch {len(signals)}/{grids}"
      + ("" if result.get("seenSteps") == result.get("steps") else f"   NOT A MEASUREMENT: on screen for {result.get('seenSteps')} of {result.get('steps')} steps"))
EOF
 done
done

if (( keep )); then
  print "left open: pid $apppid, data $data, copy $copy"
else
  cleanup
fi
