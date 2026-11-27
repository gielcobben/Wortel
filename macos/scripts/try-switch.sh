#!/bin/zsh
# Switch between sessions quickly, many times, and say how often the terminal
# came back at the wrong size or running under the side column.
#
#   scripts/try-switch.sh [path/to/Wortel.app] [--side] [--widths] [--pages] [--compare] [--keep]
#
# Runs a copy beside yours, never your Wortel. A Debug build does the
# switching itself when asked by a notification addressed to its pid
# (`SwitchProbe`): from a session with the side column open to one, two or
# three others without it and back, at six paces from 0.4 s a stop down to
# none, four times each. After every return it writes down, 0.15 s on and
# again 0.75 s on, where the terminal's view is against the column, what the
# terminal was told, its grid, and the size of the frame on its layer.
#
# --side opens a terminal in the side column and holds that one to the same
# things. --widths gives one of the other sessions a column 120 points wider,
# so a switch moves the divider instead of opening and shutting the column.
#
# --pages asks something else instead: what a click in the middle of the
# terminal's pane lands on, with a session and after every session is closed,
# when the page for no sessions is up in front of where the terminal was. It
# leaves a picture of the window with that page in $TMPDIR/wortel-pages.png.
#
# HIBERNATE_AFTER=0.3 in the environment gives the copy a hibernation clock
# that short, so the session switched back to has usually been hibernated and
# every return is a wake as well.
#
# --compare runs it twice: with libghostty's frame at every change of size
# ("before") and with Wortel's rule ("now"). Needs the display awake.
set -u

app="" keep=0 pages=0 modes=(now) extra=""
while (( $# )); do
  case $1 in
    --keep) keep=1 ;;
    --compare) modes=(before now) ;;
    --side) extra="$extra|side" ;;
    --widths) extra="$extra|widths" ;;
    --pages) pages=1 ;;
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

work=$(mktemp -d /tmp/wortel-sw.XXXXXX)
data=$HOME/.wsw-$$                       # short: the sockets live here
copy=$work/WortelSW.app
wortel=$copy/Contents/Resources/bin/wortel
apppid=""

# Every pid under $1, and $1.
tree() {
  ps -axo pid=,ppid= | awk -v root=$1 '{p[$1]=$2} END {s[root]=1
    for (n = 0; n < 8; n++) for (x in p) if (p[x] in s) s[x]=1
    for (x in s) printf "%s ", x}'
}
cleaned=0
cleanup() {
  (( cleaned )) && return
  cleaned=1
  # Only this copy: its pid is the one its own data folder holds, its keeper
  # is found by the copy's path, and with no copy path there is nothing of
  # it to look for (an empty one would match any Wortel's keeper).
  [[ -n $work ]] || return
  [[ -n $apppid ]] && kill $apppid 2>/dev/null
  sleep 1
  for k in $(pgrep -f "$copy/Contents/Resources/bin/wortel-keeper"); do kill -9 $(tree $k) 2>/dev/null; done
  rm -rf "$work" "$data"
}
# Ctrl-C, a kill or a closed terminal cleans up as a failed step does; any
# other way out too, unless --keep asked for the copy to stay. A second
# cleanup (the interrupt's, then the exit's) does nothing.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap '(( keep )) || cleanup' EXIT
w() { env -u WORTEL_SESSION_ID WORTEL_DATA_DIR=$data "$wortel" "$@"; }
pause() { perl -e "select(undef,undef,undef,$1)"; }
wait_for() { # seconds, then a command that succeeds when ready
  local s=$1; shift
  for _ in $(seq 1 $((s * 4))); do "$@" >/dev/null 2>&1 && return 0; pause 0.25; done
  return 1
}

mkdir -p "$data" "$work/repo"
cp -Rc "$app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gielcobben.Wortel.switchprobe" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null

# A screen full of text that repaints at the width it is given, as an agent does.
cat > "$data/tui.py" <<'PY'
import fcntl, os, signal, struct, termios, time
def size():
    return struct.unpack("HHHH", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\0" * 8))
def paint(*_):
    rows, cols, _, _ = size()
    out = ["\x1b[?2026h\x1b[H"]
    for row in range(1, rows):
        text = f"row {row} of {rows} at {cols} columns, the quick brown fox jumps over the lazy dog " * 4
        out.append(f"{text[:cols]}\x1b[K\r\n")
    out.append("\x1b[?2026l")
    os.write(1, "".join(out).encode())
signal.signal(signal.SIGWINCH, paint)
os.write(1, b"\x1b[?1049h")
paint()
while True:
    time.sleep(3600)
PY
( cd "$work/repo" && git init -q && seq 1 400 > f1.txt && git add -A . \
  && git -c user.name=probe -c user.email=probe@example.com commit -qm init && print changed >> f1.txt )

open -g -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 ${HIBERNATE_AFTER:+--env} ${HIBERNATE_AFTER:+WORTEL_HIBERNATE_AFTER=$HIBERNATE_AFTER} "$copy"
wait_for 20 test -s "$data/instance.lock" || { print -u2 "the copy did not start"; cleanup; exit 2; }
apppid=$(cat "$data/instance.lock")
wait_for 20 w list || { print -u2 "the copy does not answer"; cleanup; exit 2; }

for name in two three four; do w new --cwd "$work" --name $name -- /usr/bin/python3 "$data/tui.py" >/dev/null; pause 0.7; done
# Made last, so it is the one in front, and the one measured.
w new --cwd "$work/repo" --name home -- /usr/bin/python3 "$data/tui.py" >/dev/null
pause 2

print "app: $app"
if (( pages )); then
  osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('sh.wortel.test.switch.$apppid', '$data/pages.json|pages', \$(), true)" >/dev/null
  wait_for 20 test -s "$data/pages.json" || { print -u2 "no result: is this a Debug build?"; cleanup; exit 2; }
  /usr/bin/python3 -c "
import json; r = json.load(open('$data/pages.json'))
print('with a session, a click lands on:', r['withSession'])
print('with', r['sessionsLeft'], 'sessions, a click lands on:', r['withNone'])"
  window=$(swift -e "import CoreGraphics; let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]; for w in l where (w[\"kCGWindowOwnerPID\"] as? Int) == $apppid && (w[\"kCGWindowLayer\"] as? Int) == 0 { let b = w[\"kCGWindowBounds\"] as! [String: Any]; if (b[\"Width\"] as! Double) > 500 && (b[\"Height\"] as! Double) > 300 { print(w[\"kCGWindowNumber\"] as! Int) } }" 2>/dev/null | head -1)
  [[ -n $window ]] && screencapture -x -o -l "$window" "${TMPDIR:-/tmp}/wortel-pages.png" && print "picture: ${TMPDIR:-/tmp}/wortel-pages.png"
  (( keep )) && print "left open: pid $apppid, data $data, copy $copy" || cleanup
  exit 0
fi
for mode in $modes; do
  rm -f "$data/result.json"
  osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('sh.wortel.test.switch.$apppid', '$data/result.json|$mode$extra', \$(), true)" >/dev/null
  wait_for 240 test -s "$data/result.json" || { print -u2 "no result: is this a Debug build?"; cleanup; exit 2; }
  /usr/bin/python3 - "$data/result.json" <<'PY'
import json, sys, collections
result = json.load(open(sys.argv[1]))
rows = result["rows"]
def wrong(s):
    faults = []
    if s.get("under", 0) > 1: faults.append("under the column by %d pt" % s["under"])
    if s.get("told") != s.get("view"): faults.append("told %s, view %s" % (s.get("told"), s.get("view")))
    if s.get("gridFits") is False: faults.append("grid %s wider than its view" % s.get("grid"))
    if s.get("shown") != s.get("layer"): faults.append("frame %s on a layer of %s" % (s.get("shown"), s.get("layer")))
    if s.get("columnShut"): faults.append("column shut")
    if s.get("frame") != result["start"]["frame"]: faults.append("at %s, started at %s" % (s.get("frame"), result["start"]["frame"]))
    side, first = s.get("side"), result["start"].get("side")
    if first and not side: faults.append("side terminal gone")
    if side:
        if first and side["frame"] != first["frame"]: faults.append("side terminal at %s, started at %s" % (side["frame"], first["frame"]))
        if side.get("inPane") is False: faults.append("side terminal %s not filling its pane %s" % (side["frame"], side.get("pane")))
        if side["told"] != side["view"]: faults.append("side terminal told %s, view %s" % (side["told"], side["view"]))
        if side["shown"] != side["layer"]: faults.append("side terminal frame %s on a layer of %s" % (side["shown"], side["layer"]))
    return faults
print(f"{result['mode']:6s} with the column: terminal at {result['start']['frame']}, grid {result['start'].get('grid')};"
      f" on the other session: {result['startOther']['frame']}, grid {result['startOther'].get('grid')}"
      + (f"; side terminal at {result['start']['side']['frame']}, grid {result['start']['side']['grid']}" if result['start'].get('side') else ""))
for when in ("soon", "settled"):
    bad = [(r["gap"], r["stops"], wrong(r[when])) for r in rows if wrong(r[when])]
    print(f"{result['mode']:6s} {when:8s}: {len(bad)} of {len(rows)} returns wrong")
    seen = collections.Counter((gap, stops, "; ".join(f)) for gap, stops, f in bad)
    for (gap, stops, f), n in sorted(seen.items(), key=lambda x: -x[1])[:8]:
        print(f"         {n}x  away {gap}s a stop, {stops} stop(s): {f}")
PY
done

if (( keep )); then
  print "left open: pid $apppid, data $data, copy $copy"
else
  cleanup
fi
