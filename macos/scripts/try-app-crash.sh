#!/bin/zsh
# Does every terminal come back exactly as it was after the app is killed?
#
#   scripts/try-app-crash.sh [path/to/Wortel.app] [--keep]
#
# Runs a copy beside yours, never your Wortel, with the session terminals
# kept by the keeper (WORTEL_KEEPER_TERMINAL=1). Three sessions:
#
# - "drawer", a stand-in agent that draws the way one does: a transcript
#   over a footer rewritten in place, and never repaints. It is drawing when
#   the app is killed with `kill -9`, and goes on drawing while the app is
#   gone. After the relaunch its screen and scrollback must be exactly what
#   it drew: every line once, in order, one footer.
# - "shell", a plain shell that printed 3000 numbered lines: all of them must
#   be there after, scrollback included.
# - "sizes", a program that writes down every size its pty is given: a
#   relaunch must not resize anyone (a resize is a repaint to an agent).
#
# Then the same through an ordinary quit and launch.
#
# Needs the display awake.
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

work=$(mktemp -d /tmp/wortel-ac.XXXXXX)
data=$HOME/.wac-$$                       # short: the sockets live here
copy=$work/WortelAC.app
wortel=$copy/Contents/Resources/bin/wortel
apppid=""
failures=0

tree() {
  ps -axo pid=,ppid= | awk -v root=$1 '{p[$1]=$2} END {s[root]=1
    for (n = 0; n < 8; n++) for (x in p) if (p[x] in s) s[x]=1
    for (x in s) printf "%s ", x}'
}
cleanup() {
  [[ -n $apppid ]] && kill $apppid 2>/dev/null
  sleep 1
  for k in $(pgrep -f "$copy/Contents/Resources/bin/wortel-keeper"); do kill -9 $(tree $k) 2>/dev/null; done
  (( keep )) || rm -rf "$work" "$data"
}
w() { env -u WORTEL_SESSION_ID WORTEL_DATA_DIR=$data "$wortel" "$@"; }
pause() { perl -e "select(undef,undef,undef,$1)"; }
wait_for() {
  local s=$1; shift
  for _ in $(seq 1 $((s * 4))); do "$@" >/dev/null 2>&1 && return 0; pause 0.25; done
  return 1
}
launch() {
  local before=$(cat "$data/instance.lock" 2>/dev/null)
  open -g -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 --env WORTEL_KEEPER_TERMINAL=1 "$copy"
  started() { local now=$(cat "$data/instance.lock" 2>/dev/null); [[ -n $now && $now != $before ]] && kill -0 $now; }
  wait_for 20 started || { print -u2 "the copy did not start"; cleanup; exit 2; }
  apppid=$(cat "$data/instance.lock")
  wait_for 20 w list || { print -u2 "the copy does not answer"; cleanup; exit 2; }
}
crash() {
  kill -9 $apppid
  while kill -0 $apppid 2>/dev/null; do pause 0.1; done
  apppid=""
}
quit() {
  osascript -e "tell application \"$copy\" to quit" >/dev/null 2>&1
  for _ in $(seq 1 50); do kill -0 $apppid 2>/dev/null || break; pause 0.2; done
  kill $apppid 2>/dev/null
  while kill -0 $apppid 2>/dev/null; do pause 0.2; done
  apppid=""
}
id_of() { w list --json | /usr/bin/python3 -c "import json,sys; print([s['id'] for s in json.load(sys.stdin) if s['name']=='$1'][0])"; }
ok() { print "ok    $*"; }
wrong() { print "WRONG $*"; failures=$((failures + 1)); }

mkdir -p "$data"
cp -Rc "$app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gielcobben.Wortel.appcrash" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null

cat > "$data/drawer" <<'PY'
#!/usr/bin/python3
# usage: drawer <ticks> <done-file>: a transcript over a footer drawn in
# place, never repainted, as an agent's inline renderer draws.
import os, signal, sys, termios, time
ticks, done = int(sys.argv[1]), sys.argv[2]
signal.signal(signal.SIGWINCH, signal.SIG_IGN)
attrs = termios.tcgetattr(0); attrs[3] &= ~(termios.ECHO | termios.ICANON); termios.tcsetattr(0, termios.TCSANOW, attrs)
out = lambda s: os.write(1, s.encode())
def footer(tick):
    spin = "|/-\\"[tick % 4]
    out("-" * 60 + "\r\n")
    out(f"  {spin} working, tick {tick:5d}\r\n")
    out("-" * 60 + "\r\n")
out("FAKE AGENT\r\n"); footer(0)
lines = 0
for tick in range(1, ticks + 1):
    out("\x1b[3A\x1b[J")
    if tick % 4 == 0:
        lines += 1
        out(f"line {lines:4d}: the quick brown fox jumps over the lazy dog\r\n")
    footer(tick)
    time.sleep(0.01)
out("\x1b[3A\x1b[J"); out(f"DONE {lines} lines\r\n")
open(done, "w").write(str(lines))
while True:
    time.sleep(3600)
PY
chmod +x "$data/drawer"
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

# What a drawer's text must be: the header, every line once, its last word.
check_drawer() { # <label> <session> <done-file>
  local label=$1 s=$2 file=$3
  wait_for 60 test -s "$file" || { wrong "$label: the drawer never finished"; return; }
  local n=$(cat "$file")
  w read $s --lines 10000 > "$work/screen.txt"
  /usr/bin/python3 - "$work/screen.txt" "$n" "$label" <<'PY'
import sys
text = [l.rstrip() for l in open(sys.argv[1]).read().split("\n")]
n, label = int(sys.argv[2]), sys.argv[3]
want = ["FAKE AGENT"] + [f"line {i:4d}: the quick brown fox jumps over the lazy dog" for i in range(1, n + 1)] + [f"DONE {n} lines"]
got = [l for l in text if l and not l.startswith("➜") and "drawer" not in l and not l.startswith("Last login")]
if got == want:
    print(f"ok    {label}: the drawer's {n} lines, once each, in order")
else:
    extra = [l for l in got if l not in want]
    missing = [l for l in want if l not in got]
    print(f"WRONG {label}: {len(got)} lines for {len(want)}; {len(missing)} missing, {len(extra)} never drawn so, such as {extra[:1] or missing[:1]}")
PY
}

launch
w new --cwd "$data" --name sizes -- /usr/bin/python3 "$data/sizes.py" "$data/sizes.log" >/dev/null
pause 1
w new --cwd "$data" --name shell >/dev/null
pause 1.5
shell=$(id_of shell)
w send $shell 'for i in $(seq 1 3000); do echo "numbered $i"; done' --enter
pause 2
w new --cwd "$data" --name drawer -- "$data/drawer" 1600 "$data/drawer-1.done" >/dev/null
drawer=$(id_of drawer)
pause 4                                   # mid-drawing
sizes_before=$(wc -l < "$data/sizes.log")

# --- 1. kill -9 while it draws -------------------------------------------
crash
pause 4                                   # it draws on with no app
launch
pause 3
check_drawer "after kill -9" $drawer "$data/drawer-1.done"
count=$(w read $shell --lines 10000 | grep -c '^numbered ')
(( count == 3000 )) && ok "after kill -9: the shell's 3000 lines are all there" \
  || wrong "after kill -9: the shell has $count of its 3000 lines"
sizes_after=$(wc -l < "$data/sizes.log")
(( sizes_after == sizes_before )) && ok "after kill -9: no program was resized" \
  || wrong "after kill -9: sizes given: $(tail -n +$((sizes_before + 1)) "$data/sizes.log" | tr '\n' ' ')"

# --- 2. an ordinary quit while it draws ----------------------------------
w new --cwd "$data" --name drawer2 -- "$data/drawer" 1600 "$data/drawer-2.done" >/dev/null
drawer2=$(id_of drawer2)
pause 4
sizes_before=$(wc -l < "$data/sizes.log")
quit
pause 4
launch
pause 3
check_drawer "after a quit" $drawer2 "$data/drawer-2.done"
check_drawer "after a quit, the first drawer" $drawer "$data/drawer-1.done"
count=$(w read $shell --lines 10000 | grep -c '^numbered ')
(( count == 3000 )) && ok "after a quit: the shell's 3000 lines are all there" \
  || wrong "after a quit: the shell has $count of its 3000 lines"
sizes_after=$(wc -l < "$data/sizes.log")
(( sizes_after == sizes_before )) && ok "after a quit: no program was resized" \
  || wrong "after a quit: sizes given: $(tail -n +$((sizes_before + 1)) "$data/sizes.log" | tr '\n' ' ')"

cleanup
print "$failures wrong"
(( failures == 0 ))
