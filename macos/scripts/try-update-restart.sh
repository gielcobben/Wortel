#!/bin/zsh
# The update to protocol 2: does a keeper of protocol 1, holding shells, get
# replaced, and does every agent come back in its conversation?
#
#   scripts/try-update-restart.sh <old Wortel.app (protocol 1)> [new Wortel.app] [--keep]
#
# Runs a throwaway copy beside yours, never your Wortel. The old build runs
# first, with one session seeded as having had `pi` running (so launch types
# `pi -c`) and a bottom terminal, and quits the way a person quits before an
# update: its keeper and shells stay. The copy is then replaced in place by
# the new build, as Sparkle replaces the app, and launched.
#
# The new app finds a keeper that speaks another protocol and replaces it,
# which ends its shells: once, at this update, by decision
# (`docs/decisions.md`, 2026-11-20). Passes when that keeper is gone, a new
# one holds new shells for both terminals, and pi is running again under it,
# in its conversation (`pi -c`).
#
# Needs the screen unlocked.
set -u

old="" new="" keep=0
for arg in "$@"; do
  case $arg in
    --keep) keep=1 ;;
    *) if [[ -z $old ]]; then old=$arg; else new=$arg; fi ;;
  esac
done
here=${0:A:h}/..
if [[ -z $new ]]; then
  new="$(xcodebuild -project "$here/Wortel.xcodeproj" -scheme Wortel -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')/Wortel.app"
fi
[[ -d $old && -d $new ]] || { print -u2 "usage: $0 <old Wortel.app> [new Wortel.app]"; exit 2; }
locked=$(swift -e 'import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]; print((d["CGSSessionScreenIsLocked"] as? Int) ?? 0)' 2>/dev/null)
[[ $locked == 1 ]] && { print -u2 "the screen is locked; unlock it and run again"; exit 2; }

work=$(mktemp -d /tmp/wortel-up.XXXXXX)
data=$HOME/.wup-$$                       # short: the sockets live here
copy=$work/WortelUP.app
failures=0
tree() {
  ps -axo pid=,ppid= | awk -v root=$1 '{p[$1]=$2} END {s[root]=1
    for (n = 0; n < 8; n++) for (x in p) if (p[x] in s) s[x]=1
    for (x in s) printf "%s ", x}'
}
cleanup() {
  pkill -f "$copy/Contents/MacOS/Wortel" 2>/dev/null
  sleep 1
  for k in $(pgrep -f "$copy/Contents/Resources/bin/wortel-keeper"); do kill -9 $(tree $k) 2>/dev/null; done
  (( keep )) || rm -rf "$work" "$data"
}
pi_under() {
  local t=" $(tree $1) "
  ps -axo pid=,ppid=,command= | while read -r pid ppid cmd; do
    [[ ( $cmd == pi || $cmd == pi\ * || $cmd == */pi || $cmd == */pi\ * ) && $t == *" $pid "* ]] && { print "$pid"; return; }
  done
}
wait_for() { # seconds, then a command that prints something when ready
  local s=$1; shift
  for _ in $(seq 1 $((s * 2))); do out=$("$@"); [[ -n $out ]] && { print $out; return 0; }; sleep 0.5; done
  return 1
}
install() { # the build at $1 into the copy, as an update replaces the app
  rm -rf "$copy"
  cp -Rc "$1" "$copy"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.gielcobben.Wortel.updatetest' "$copy/Contents/Info.plist"
  codesign --force --deep --sign - "$copy" 2>/dev/null
}
ok() { print "ok    $*"; }
wrong() { print "WRONG $*"; failures=$((failures + 1)); }

mkdir -p "$data/work"
session=$(uuidgen) tab=$(uuidgen)
cat > "$data/sessions.json" <<EOF
[{"id":"$session","name":"update test","title":"pi","cwd":"$data/work","originCwd":"$data/work","selected":true,"nameSource":"user","mainTabs":["session"],"bottomTabs":["terminal:$tab"],"activeBottomTab":"terminal:$tab","bottomVisible":true,"runningAgent":"pi","runningArgv":"pi"}]
EOF

# --- the old build, as it runs before the update ------------------------
install "$old"
open -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 "$copy"
apppid=$(wait_for 20 pgrep -f "$copy/Contents/MacOS/Wortel") || { print "FAIL: the old copy did not start"; cleanup; exit 1; }
keeper=$(wait_for 20 pgrep -f "$copy/Contents/Resources/bin/wortel-keeper") || { print "FAIL: no keeper"; cleanup; exit 1; }
pi=$(wait_for 40 pi_under $keeper) || { print "FAIL: pi -c never started under the old build"; cleanup; exit 1; }
print "old build: keeper $keeper, pi $pi"
osascript -e "tell application \"$copy\" to quit" >/dev/null 2>&1
for _ in $(seq 1 50); do kill -0 $apppid 2>/dev/null || break; sleep 0.2; done
kill $apppid 2>/dev/null
sleep 1
kill -0 $keeper 2>/dev/null && kill -0 $pi 2>/dev/null && ok "after the old build quit, its keeper and pi run on" \
  || wrong "the old keeper or pi did not outlive the quit"

# --- the update ------------------------------------------------------------
install "$new"
open -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 "$copy"
wait_for 20 pgrep -f "$copy/Contents/MacOS/Wortel" >/dev/null || { print "FAIL: the new copy did not start"; cleanup; exit 1; }
newkeeper=$(wait_for 20 sh -c "pgrep -f '$copy/Contents/Resources/bin/wortel-keeper' | grep -vx $keeper") \
  || { print "FAIL: no new keeper"; cleanup; exit 1; }
for _ in $(seq 1 20); do kill -0 $keeper 2>/dev/null || break; sleep 0.5; done
kill -0 $keeper 2>/dev/null && wrong "the protocol 1 keeper $keeper is still running" \
  || ok "the protocol 1 keeper was replaced by $newkeeper"
kill -0 $pi 2>/dev/null && wrong "the old pi $pi still runs" || ok "the old shells ended with it"
pi2=$(wait_for 40 pi_under $newkeeper) && ok "pi was resumed under the new keeper ($pi2)" \
  || wrong "pi was not resumed under the new keeper"
shells=$(ps -axo ppid=,command= | awk -v k=$newkeeper '$1==k && /\/usr\/bin\/login/' | wc -l | tr -d ' ')
(( shells >= 2 )) && ok "the new keeper holds $shells shells" || wrong "the new keeper holds $shells shells, not 2"
/usr/bin/log show --last 2m --style compact \
  --predicate 'subsystem == "com.gielcobben.Wortel" AND category == "keeper"' 2>/dev/null \
  | grep -i "protocol\|replac" | tail -3 | cut -c1-200

cleanup
print "$failures wrong"
(( failures == 0 ))
