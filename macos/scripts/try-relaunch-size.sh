#!/bin/zsh
# After a relaunch, is a session out of sight given its own width?
#
#   scripts/try-relaunch-size.sh [path/to/Wortel.app] [--keep]
#
# Runs a copy beside yours, never your Wortel. Two sessions: "wide", running a
# program that writes down every size its pty is given, and shown with the
# side column shut; then "narrow", shown last, with the side column open. The
# copy is quit and started again, so "narrow" is in front and "wide" is made
# out of sight. "wide" must be given its own width, the one it will have when
# it is shown, and not the narrow one shown last: an agent answers a
# relaunch's repaint by printing its whole conversation again at the width it
# is given, and what it prints above the screen keeps that width
# (2026-11-19: every hidden terminal at 70 columns in a window of 114).
#
# And a third, "drawer": a stand-in agent that draws the way one does (a
# transcript over a footer rewritten in place) and does it while the copy is
# quit, so all of it reaches the new terminal as the keeper's replay. Its
# screen, read back, must be what it drew: written into a terminal that has
# not taken its size yet, in-place drawing lands in pieces.
#
# Needs the display awake. A Debug build: it opens the column through the
# copy's `SwitchProbe`.
set -u

app="" keep=0
while (( $# )); do
  case $1 in
    --keep) keep=1 ;;
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
displays=$(swift -e 'import CoreGraphics; var n: UInt32 = 0; CGGetActiveDisplayList(0, nil, &n); print(n)' 2>/dev/null)
[[ $displays == 0 ]] && { print -u2 "the display is asleep; wake it and run again"; exit 2; }

work=$(mktemp -d /tmp/wortel-rs.XXXXXX)
data=$HOME/.wrs-$$                       # short: the sockets live here
copy=$work/WortelRS.app
wortel=$copy/Contents/Resources/bin/wortel
apppid=""

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
w() { env -u WORTEL_SESSION_ID WORTEL_DATA_DIR=$data "$wortel" "$@"; }
pause() { perl -e "select(undef,undef,undef,$1)"; }
wait_for() {
  local s=$1; shift
  for _ in $(seq 1 $((s * 4))); do "$@" >/dev/null 2>&1 && return 0; pause 0.25; done
  return 1
}
launch() {
  rm -f "$data/instance.lock"
  open -g -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 "$copy"
  wait_for 20 test -s "$data/instance.lock" || { print -u2 "the copy did not start"; cleanup; exit 2; }
  apppid=$(cat "$data/instance.lock")
  wait_for 20 w list || { print -u2 "the copy does not answer"; cleanup; exit 2; }
}
quit() {
  kill $apppid 2>/dev/null
  while kill -0 $apppid 2>/dev/null; do pause 0.2; done
  apppid=""
}
probe() {
  rm -f "$data/probe.json"
  osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('sh.wortel.test.switch.$apppid', '$data/probe.json|$1', \$(), true)" >/dev/null
  wait_for 20 test -s "$data/probe.json" || { print -u2 "no answer from the probe: is this a Debug build?"; cleanup; exit 2; }
}

mkdir -p "$data"
cp -Rc "$app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gielcobben.Wortel.relaunchsize" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
cat > "$data/sizes.py" <<'PY'
import fcntl, signal, struct, sys, termios, time
log = open(sys.argv[1], "a", buffering=1)
def note(*_):
    rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\0" * 8))
    log.write(f"{cols}x{rows}\n")
signal.signal(signal.SIGWINCH, note)
note()
while True:
    time.sleep(3600)
PY

cat > "$data/claude" <<'PY'
#!/usr/bin/python3
# usage: claude <seconds at rest first> <ticks>; never repaints, so what comes back is what is read
import os, signal, sys, termios, time
rest, ticks = float(sys.argv[1]), int(sys.argv[2])
signal.signal(signal.SIGWINCH, signal.SIG_IGN)
# No echo, as an agent's interface has: what the terminal answers (a focus
# report, the theme) is the program's to read, not to show.
attrs = termios.tcgetattr(0); attrs[3] &= ~(termios.ECHO | termios.ICANON); termios.tcsetattr(0, termios.TCSANOW, attrs)
out = lambda s: os.write(1, s.encode())
def footer(tick):
    spin = "|/-\\"[tick % 4]
    out("-" * 78 + "\r\n")
    out(f"  {spin} working, tick {tick:5d}: some status text that changes every time it is drawn\r\n")
    out("-" * 78 + "\r\n")
out("FAKE AGENT\r\n"); footer(0)
time.sleep(rest)
lines = 0
for tick in range(1, ticks + 1):
    out("\x1b[3A\x1b[J")
    if tick % 5 == 0:
        lines += 1
        out(f"line {lines:4d}: the quick brown fox jumps over the lazy dog and keeps going\r\n")
    footer(tick)
    time.sleep(0.02)
out("\x1b[3A\x1b[J"); out(f"DONE {lines} lines\r\n")
while True:
    time.sleep(3600)
PY
chmod +x "$data/claude"

launch
# Rests for 12 s, through the quit below, then draws for about 6. A
# relaunched terminal starts empty, so what it holds after is only that.
w new --cwd "$data" --name drawer -- "$data/claude" 12 300 >/dev/null
pause 1
w new --cwd "$data" --name wide -- /usr/bin/python3 "$data/sizes.py" "$data/wide.log" >/dev/null
pause 2
wide=$(tail -1 "$data/wide.log")
w new --cwd "$data" --name narrow >/dev/null
pause 1.5
probe column
probe report
narrow=$(/usr/bin/python3 -c "import json; print(json.load(open('$data/probe.json'))['grid'])")
pause 1.5                                 # the sizes are written to defaults a second after they settle
quit
print "before the relaunch: wide shown at $wide, narrow shown last at $narrow (side column open)"
print "MARK" >> "$data/wide.log"
pause 13                                  # the drawer draws while the copy is gone

launch
pause 4
after=$(sed -n '/MARK/,$p' "$data/wide.log" | grep -v MARK | tr '\n' ' ')
print "after the relaunch, out of sight, wide was given: ${after:-nothing}"
last=$(sed -n '/MARK/,$p' "$data/wide.log" | grep -v MARK | tail -1)
failures=0
if [[ -z $after ]]; then
  print "WRONG wide was given no size at all"; failures=1
elif print -- "$after" | tr ' ' '\n' | grep -q -x "$narrow"; then
  print "WRONG wide was given the narrow session's width"; failures=1
elif [[ $last != $wide ]]; then
  print "WRONG wide ended at $last, not its own $wide"; failures=1
else
  print "ok    wide was given its own width"
fi

drawer=$(w list --json | /usr/bin/python3 -c 'import json,sys; print([s["id"] for s in json.load(sys.stdin) if s["name"]=="drawer"][0])')
w read $drawer --lines 400 > "$data/drawer.txt"
/usr/bin/python3 - "$data/drawer.txt" 60 > "$data/drawer.why" <<'PY'
import sys
body = [l.rstrip() for l in open(sys.argv[1]).read().split("\n")]
want = int(sys.argv[2])
body = [l for l in body if l]
expected = [f"line {n:4d}: the quick brown fox jumps over the lazy dog and keeps going" for n in range(1, want + 1)]
expected.append(f"DONE {want} lines")
if body == expected: sys.exit(0)
stray = [l for l in body if l not in expected]
missing = [l for l in expected if l not in body]
print(f"{len(body)} lines for {len(expected)}; {len(missing)} missing, {len(stray)} that were never drawn so"
      + (f', such as "{stray[0][:60]}"' if stray else ""))
sys.exit(1)
PY
if [[ $? == 0 ]]; then
  print "ok    drawer, replayed after the relaunch, is what it drew"
else
  print "WRONG drawer, replayed after the relaunch: $(cat "$data/drawer.why")"; failures=1
fi

if (( keep )); then
  print "left open: pid $apppid, data $data, copy $copy"
else
  cleanup
fi
exit $failures
