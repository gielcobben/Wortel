#!/bin/zsh
# When the window is resized, does a session out of sight follow it, once?
#
#   scripts/try-hidden-resize.sh [path/to/Wortel.app] [--keep]
#
# Runs a copy beside yours, never your Wortel. Two sessions, neither with the
# side column, each running a program that writes down every size its pty is
# given: "hidden", shown first and then left, and "front", shown last. The
# copy's window is then resized in 20 steps over a second, as a drag would,
# twice (narrower, then shorter and wider). After each, "hidden" must have
# been given exactly one new size, after the drag and not during it, and the
# same one "front" ended at, since the two have the same layout
# (`SurfaceView.followWindow`). Needs the display awake.
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

work=$(mktemp -d /tmp/wortel-hr.XXXXXX)
data=$HOME/.whr-$$
copy=$work/WortelHR.app
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

mkdir -p "$data"
cp -Rc "$app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gielcobben.Wortel.hiddenresize" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
cat > "$data/sizes.py" <<'PY'
import fcntl, signal, struct, sys, termios, time
log = open(sys.argv[1], "a", buffering=1)
def note(*_):
    rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\0" * 8))
    log.write(f"{time.time():.2f} {cols}x{rows}\n")
signal.signal(signal.SIGWINCH, note)
note()
while True:
    time.sleep(3600)
PY

open -g -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 --env WORTEL_HIBERNATE_AFTER=${HIBERNATE_AFTER:-600} "$copy"
wait_for 20 test -s "$data/instance.lock" || { print -u2 "the copy did not start"; cleanup; exit 2; }
apppid=$(cat "$data/instance.lock")
wait_for 20 w list || { print -u2 "the copy does not answer"; cleanup; exit 2; }
w new --cwd "$data" --name hidden -- /usr/bin/python3 "$data/sizes.py" "$data/hidden.log" >/dev/null
pause 2
w new --cwd "$data" --name front -- /usr/bin/python3 "$data/sizes.py" "$data/front.log" >/dev/null
pause 2
# With HIBERNATE_AFTER, "hidden" has no terminal in the app by the drag: a
# terminal the keeper keeps follows the window through the keeper.
[[ -n ${HIBERNATE_AFTER:-} ]] && pause $((HIBERNATE_AFTER + 2))

failures=0
drag() { # width, height to end at
  local from=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $apppid) to get size of window 1" | tr -d ' ')
  local w0=${from%,*} h0=${from#*,}
  : > "$data/hidden.log.mark"; date +%s.%N | cut -c1-13 > "$data/started"
  for i in $(seq 1 20); do
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $apppid) to set size of window 1 to {$(( w0 + ($1 - w0) * i / 20 )), $(( h0 + ($2 - h0) * i / 20 ))}" >/dev/null
    pause 0.05
  done
  local ended=$(date +%s.%N | cut -c1-13)
  pause 1.5
  local started=$(cat "$data/started")
  local hidden=$(awk -v t=$started '$1 >= t {print $1, $2}' "$data/hidden.log")
  local count=$(print -- "$hidden" | grep -c .)
  local last=$(print -- "$hidden" | tail -1 | cut -d' ' -f2)
  local first_at=$(print -- "$hidden" | head -1 | cut -d' ' -f1)
  local front=$(tail -1 "$data/front.log" | cut -d' ' -f2)
  print "drag to ${1}x$2 points: front ended at $front; hidden was given ${count} size(s): $(print -- "$hidden" | cut -d' ' -f2 | tr '\n' ' ')"
  if [[ $count -ne 1 ]]; then
    print "WRONG hidden was given $count sizes, not one"; failures=$((failures + 1))
  elif [[ $last != $front ]]; then
    print "WRONG hidden ended at $last, not $front"; failures=$((failures + 1))
  elif (( $(print "$first_at < $ended" | bc) )); then
    print "WRONG hidden was resized during the drag, not after it"; failures=$((failures + 1))
  else
    print "ok    hidden followed the window, once, after the drag"
  fi
}
drag 900 700
drag 1200 560

if (( keep )); then
  print "left open: pid $apppid, data $data, copy $copy"
else
  cleanup
fi
exit $(( failures > 0 ))
