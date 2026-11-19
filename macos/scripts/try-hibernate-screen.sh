#!/bin/zsh
# Does an agent's screen survive its terminal being hibernated while it works?
#
#   scripts/try-hibernate-screen.sh [path/to/Wortel.app] [--keep]
#
# Runs a copy beside yours, never your Wortel, with a four second hibernation
# clock and 6 KB kept for a terminal that is away (512 KB in the app).
#
# The "agent" is a script named claude, which is all the shell integration
# goes by. It draws the way an agent's interface does: a transcript that grows
# and under it a footer rewritten in place, each piece placed from where the
# last one ended, about 150 KB of it in twelve seconds. It says it is working
# in the agents' own protocol (OSC 7501), and it never repaints, so a screen
# that came back wrong stays wrong and is read as it is.
#
# Three sessions, all out of sight:
#
#   1. An agent at work from the start. Its terminal must not hibernate until
#      it is done (2026-11-19: one that did came back as scattered words).
#   2. An agent that rests fourteen seconds, long enough to be hibernated, and
#      then works. Its terminal must be given back before what it writes
#      stops fitting (`HibernationPolicy.outrunning`).
#   3. The control: the same program under another name, so nothing counts it
#      as an agent. It is hibernated, writes past what is kept, and its screen
#      is expected to come back wrong. If it comes back right, this test is
#      not testing anything.
#
# A screen is right when it holds every transcript line once, in order, whole,
# with no piece of a footer left on it. Needs the display awake.
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

# A display that is asleep gives a terminal nothing to draw on. A locked
# screen with the display awake does (measured 2026-11-19), so it is the
# display that is asked about: `caffeinate -u -t 5` wakes it.
displays=$(swift -e 'import CoreGraphics; var n: UInt32 = 0; CGGetActiveDisplayList(0, nil, &n); print(n)' 2>/dev/null)
[[ $displays == 0 ]] && { print -u2 "the display is asleep; wake it and run again"; exit 2; }

work=$(mktemp -d /tmp/wortel-hs.XXXXXX)
data=$HOME/.whs-$$                       # short: the sockets live here
copy=$work/WortelHS.app
wortel=$copy/Contents/Resources/bin/wortel
apppid=""
failures=0

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
w() { env -u WORTEL_SESSION_ID WORTEL_DATA_DIR=$data "$wortel" "$@"; }
pause() { perl -e "select(undef,undef,undef,$1)"; }
wait_for() { # seconds, then a command that succeeds when ready
  local s=$1; shift
  for _ in $(seq 1 $((s * 4))); do "$@" >/dev/null 2>&1 && return 0; pause 0.25; done
  return 1
}
check() { # what, then 0 for right
  if [[ $2 == 0 ]]; then print "ok    $1"; else print "WRONG $1"; failures=$((failures + 1)); fi
}

mkdir -p "$data" "$work/bin" "$work/one" "$work/two" "$work/three"
cp -Rc "$app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gielcobben.Wortel.hibernatescreen" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null

cat > "$work/bin/claude" <<'PY'
#!/usr/bin/python3
# usage: claude <seconds at rest first> <ticks>
import os, signal, sys, time
rest, ticks = float(sys.argv[1]), int(sys.argv[2])
signal.signal(signal.SIGWINCH, signal.SIG_IGN)       # never repaints: what comes back is what is read
out = lambda s: os.write(1, s.encode())
FOOTER = 3
def footer(tick):
    spin = "|/-\\"[tick % 4]
    out("-" * 78 + "\r\n")
    out(f"  {spin} working, tick {tick:5d}: some status text that changes every time it is drawn\r\n")
    out("-" * 78 + "\r\n")
out("FAKE AGENT\r\n")
footer(0)
time.sleep(rest)
out("\x1b]7501;state=working:app=claude\x1b\\")
lines = 0
for tick in range(1, ticks + 1):
    out(f"\x1b[{FOOTER}A\x1b[J")                      # up over the footer, clear to the end
    if tick % 5 == 0:
        lines += 1
        out(f"line {lines:4d}: the quick brown fox jumps over the lazy dog and keeps going\r\n")
    footer(tick)
    time.sleep(0.02)
out(f"\x1b[{FOOTER}A\x1b[J")
out(f"DONE {lines} lines\r\n")
out("\x1b]7501;state=clear\x1b\\")
while True:
    time.sleep(3600)
PY
chmod +x "$work/bin/claude"
cp "$work/bin/claude" "$work/bin/notanagent"

# Whether a screen as read is the one the program drew.
cat > "$work/right.py" <<'PY'
import re, sys
text, want = open(sys.argv[1]).read().split("\n"), int(sys.argv[2])
body = [l.rstrip() for l in text]
try:
    first = max(i for i, l in enumerate(body) if l.startswith("FAKE AGENT"))
except ValueError:
    print("no start of the program on the screen"); sys.exit(1)
body = [l for l in body[first + 1:] if l]
expected = [f"line {n:4d}: the quick brown fox jumps over the lazy dog and keeps going" for n in range(1, want + 1)]
expected.append(f"DONE {want} lines")
if body == expected:
    sys.exit(0)
stray = [l for l in body if l not in expected]
missing = [l for l in expected if l not in body]
print(f"{len(body)} lines for {len(expected)}; {len(missing)} missing, {len(stray)} that were never drawn so"
      + (f', such as "{stray[0][:60]}"' if stray else ""))
sys.exit(1)
PY

open -g -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 --env WORTEL_HIBERNATE_AFTER=4 \
  --env WORTEL_MISSED_OUTPUT_LIMIT=6000 "$copy"
wait_for 20 test -s "$data/instance.lock" || { print -u2 "the copy did not start"; cleanup; exit 2; }
apppid=$(cat "$data/instance.lock")
wait_for 20 w list || { print -u2 "the copy does not answer"; cleanup; exit 2; }

ticks=600 lines=120
one=$(w new --cwd "$work/one" --name working -- "$work/bin/claude" 0 $ticks 2>/dev/null | tail -1)
two=$(w new --cwd "$work/two" --name resting -- "$work/bin/claude" 14 $ticks 2>/dev/null | tail -1)
three=$(w new --cwd "$work/three" --name control -- "$work/bin/notanagent" 14 $ticks 2>/dev/null | tail -1)
w new --cwd "$work" --name front >/dev/null 2>&1      # the one on screen; the three above are out of sight
print "app: $app"
pause 3
w list --json | /usr/bin/python3 -c '
import json, sys
for s in json.load(sys.stdin):
    if s["name"] in ("working", "resting", "control"): print("     ", s["name"], "is", s["state"], "| agent", s.get("agent"))'

# Twelve seconds of work each, the later two after fourteen at rest, and the
# clock once more after the last has finished.
pause 40
log=$(/usr/bin/log show --last 2m --predicate "processID == $apppid && category == \"hibernation\"" --style compact 2>/dev/null \
  | grep -v Timestamp | sed -E 's/^[0-9-]+ ([0-9:.]+) .*hibernation\] /\1 /')
print -- "$log" | sed -E "s/$one/working/; s/$two/resting/; s/$three/control/" | grep -E "working|resting|control|out of sight" | sed 's/^/      /'

# 1. Never hibernated while it worked: the first twelve seconds or so.
started=$(print -- "$log" | head -1 | cut -c1-8)
early=$(print -- "$log" | grep "hibernated $one" | head -1 | cut -c1-8)
/usr/bin/python3 - "$started" "$early" <<'PY'
import sys
def secs(t): h, m, s = t.split(":"); return int(h) * 3600 + int(m) * 60 + int(s)
started, early = sys.argv[1], sys.argv[2]
sys.exit(0 if not early or secs(early) - secs(started) >= 10 else 1)
PY
check "1. an agent at work kept its terminal until it was done" $?
w read $one --lines 400 > "$data/one.txt" 2>/dev/null
/usr/bin/python3 "$work/right.py" "$data/one.txt" $lines > "$data/one.why"; rc=$?
check "1. its screen is what it drew $(cat "$data/one.why")" $rc

# 2. Hibernated at rest, given back when it started to work.
print -- "$log" | grep -q "hibernated $two"; check "2. an agent at rest was hibernated" $?
print -- "$log" | grep -q "out of sight"; check "2. and woken out of sight when it began to write" $?
w read $two --lines 400 > "$data/two.txt" 2>/dev/null
/usr/bin/python3 "$work/right.py" "$data/two.txt" $lines > "$data/two.why"; rc=$?
check "2. its screen is what it drew $(cat "$data/two.why")" $rc

# 3. The control comes back wrong, or the two above prove nothing.
w read $three --lines 400 > "$data/three.txt" 2>/dev/null
/usr/bin/python3 "$work/right.py" "$data/three.txt" $lines > "$data/three.why"; rc=$?
if [[ $rc != 0 ]]; then
  print "ok    3. the control, not counted as an agent, came back wrong as expected: $(cat "$data/three.why")"
else
  print "WRONG 3. the control came back right: nothing was lost, so this run tested nothing"
  failures=$((failures + 1))
fi

if (( keep )); then
  print "left open: pid $apppid, data $data, copy $copy"
else
  cleanup
fi
print "$failures wrong"
exit $(( failures > 0 ))
