#!/bin/zsh
# Split the main area in a copy of the app, step by step, and say what came
# of it: where each split is, where each terminal's view is against its
# split, what the terminal was told, and who has the keyboard.
#
#   scripts/try-splits.sh [path/to/Wortel.app] [--keep] [--picture] [steps...]
#
# Runs a copy beside yours, never your Wortel. A Debug build does the
# splitting itself when asked by a notification addressed to its pid
# (`SplitProbe`, which lists the steps). With no steps it runs a tour: two
# splits right, one down, a zoom and back, a drag, an equalize, the keyboard
# around the splits, a session switch away and back, and every split closed.
#
# --picture leaves the window as its views draw it after the steps in
# $TMPDIR/wortel-splits.png (terminals are the GPU's and come out as their
# page colour; the rows, the tabs and the dividers are what it is for).
# Needs the display awake.
set -u

app="" keep=0 picture=0 steps=()
while (( $# )); do
  case $1 in
    --keep) keep=1 ;;
    --picture) picture=1 ;;
    *.app|*/Wortel.app) app=$1 ;;
    *) steps+=($1) ;;
  esac
  shift
done
here=${0:A:h}/..
if [[ -z $app ]]; then
  app="$(xcodebuild -project "$here/Wortel.xcodeproj" -scheme Wortel -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')/Wortel.app"
fi
[[ -d $app ]] || { print -u2 "no app at $app"; exit 2; }
(( ${#steps} )) || steps=(right right down zoom zoom wide equalize focus-left focus-left focus-right \
                          focus-down next next next tab move-left close close close close)

displays=$(swift -e 'import CoreGraphics; var n: UInt32 = 0; CGGetActiveDisplayList(0, nil, &n); print(n)' 2>/dev/null)
[[ $displays == 0 ]] && { print -u2 "the display is asleep; wake it and run again"; exit 2; }

work=$(mktemp -d /tmp/wortel-sp.XXXXXX)
data=$HOME/.wsp-$$                       # short: the sockets live here
copy=$work/WortelSP.app
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
w() { env -u WORTEL_SESSION_ID WORTEL_DATA_DIR=$data "$wortel" "$@"; }
pause() { perl -e "select(undef,undef,undef,$1)"; }
wait_for() { # seconds, then a command that succeeds when ready
  local s=$1; shift
  for _ in $(seq 1 $((s * 4))); do "$@" >/dev/null 2>&1 && return 0; pause 0.25; done
  return 1
}

mkdir -p "$data" "$work/repo"
cp -Rc "$app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.gielcobben.Wortel.splitprobe" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
( cd "$work/repo" && git init -q && seq 1 40 > f1.txt && git add -A . \
  && git -c user.name=probe -c user.email=probe@example.com commit -qm init && print changed >> f1.txt )

open -g -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 "$copy"
wait_for 20 test -s "$data/instance.lock" || { print -u2 "the copy did not start"; cleanup; exit 2; }
apppid=$(cat "$data/instance.lock")
wait_for 20 w list || { print -u2 "the copy does not answer"; cleanup; exit 2; }

w new --cwd "$work" --name other >/dev/null; pause 0.7
# Made last, so it is the one in front, and the one split.
w new --cwd "$work/repo" --name home >/dev/null
pause 2

request="$data/result.json|${(j:|:)steps}"
(( picture )) && request="$request|picture:${TMPDIR:-/tmp}/wortel-splits.png"
print "app: $app"
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('sh.wortel.test.split.$apppid', '$request', \$(), true)" >/dev/null
wait_for $(( ${#steps} * 2 + 30 )) test -s "$data/result.json" || { print -u2 "no result: is this a Debug build?"; cleanup; exit 2; }
kill -0 $apppid 2>/dev/null || { print -u2 "the copy quit during the steps"; cleanup; exit 1; }

/usr/bin/python3 - "$data/result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
faults = 0
def line(state):
    global faults
    splits = "  ".join("%s[%s]%s" % (s["region"][:10], s["frame"], "" if len(s["tabs"]) == 1 else " x%d" % len(s["tabs"]))
                       for s in state.get("splits", []))
    print("%-12s area=%-10s zoom=%-10s keyboard=%-10s %s" % (
        state.get("step", "end"), state.get("area", "")[:10], state.get("zoomed", "")[:10] or "-",
        str(state.get("keyboardIn", "-"))[:10], splits))
    for t in state.get("terminals", []):
        if t["hidden"]:
            if t["keyboard"]:
                faults += 1
                print("    FAULT %s has the keyboard and is out of sight" % t["tab"][:18])
            continue
        wrong = []
        if t.get("inside") is False: wrong.append("runs outside its split")
        if t["told"] != t["view"]: wrong.append("told %s, view %s" % (t["told"], t["view"]))
        if not t["gridFits"]: wrong.append("grid %s wider than its view" % t["grid"])
        if t["holds"]: wrong.append("%d resize holds left" % t["holds"])
        if wrong:
            faults += 1
            print("    FAULT %s at %s: %s" % (t["tab"][:18], t["frame"], "; ".join(wrong)))
for state in result.get("trail", []):
    if state.get("unknown"):
        print("%-12s unknown step" % state["step"])
        continue
    line(state)
line(result)
print("faults:", faults)
sys.exit(1 if faults else 0)
PY
code=$?
(( picture )) && [[ -s ${TMPDIR:-/tmp}/wortel-splits.png ]] && print "picture: ${TMPDIR:-/tmp}/wortel-splits.png"
(( keep )) && print "left open: pid $apppid, data $data, copy $copy" || cleanup
exit $code
