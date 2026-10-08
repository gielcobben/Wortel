#!/bin/zsh
# Kill a running Wortel's keeper the way the Dock did on 2026-10-08, and check
# that the app brings its terminals back with the agent resumed.
#
#   scripts/try-keeper-loss.sh [path/to/Wortel.app] [--keep]
#
# Runs a throwaway copy beside yours, never your Wortel: its own bundle id (so
# its own UserDefaults; WORTEL_DATA_DIR alone shares them, and a first launch
# prunes folder order and pinned sessions there), its own data folder and
# keeper, telemetry off. One session is seeded as having had `pi` running,
# with a bottom terminal open, so launch types `pi -c` into it.
#
# Then every process under the copy's keeper gets SIGKILL at once, keeper
# included, which is what "Force Quit" on a coalition does. Passes when a new
# keeper holds two new shells and pi is running again under it.
#
# Needs the screen unlocked: with it locked there is no display, libghostty
# cannot make a surface, nothing reads the ptys and nothing runs. --keep leaves
# the copy open afterwards, to look at the message it shows.
set -u

app="" keep=0
for arg in "$@"; do
  case $arg in
    --keep) keep=1 ;;
    *) app=$arg ;;
  esac
done
here=${0:A:h}/..
if [[ -z $app ]]; then
  app="$(xcodebuild -project "$here/Wortel.xcodeproj" -scheme Wortel -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')/Wortel.app"
fi
[[ -d $app ]] || { print -u2 "no app at $app"; exit 2; }

locked=$(swift -e 'import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]; print((d["CGSSessionScreenIsLocked"] as? Int) ?? 0)' 2>/dev/null)
[[ $locked == 1 ]] && { print -u2 "the screen is locked; unlock it and run again"; exit 2; }

work=$(mktemp -d /tmp/wortel-kl.XXXXXX)
data=$HOME/.wkt-$$                       # short: the sockets live here
copy=$work/WortelKT.app
cleanup() {
  [[ -n ${apppid:-} ]] && kill $apppid 2>/dev/null
  sleep 1
  for k in $(pgrep -f "$copy/Contents/Resources/bin/wortel-keeper"); do kill -9 $(tree $k) 2>/dev/null; done
  rm -rf "$work" "$data"
}
# Every pid under $1, and $1.
tree() {
  ps -axo pid=,ppid= | awk -v root=$1 '{p[$1]=$2} END {s[root]=1
    for (n = 0; n < 8; n++) for (x in p) if (p[x] in s) s[x]=1
    for (x in s) printf "%s ", x}'
}
# The pid and command of a pi under $1, if one runs: `pi -c` or
# `pi --session <id>` as typed, and plain `pi` once it has renamed itself.
pi_under() {
  local t=" $(tree $1) "
  ps -axo pid=,ppid=,command= | while read -r pid ppid cmd; do
    [[ ( $cmd == pi || $cmd == pi\ * || $cmd == */pi || $cmd == */pi\ * ) && $t == *" $pid "* ]] && { print "$pid ($cmd)"; return; }
  done
}
wait_for() { # seconds, then a command that prints something when ready
  local s=$1; shift
  for _ in $(seq 1 $((s * 2))); do out=$("$@"); [[ -n $out ]] && { print $out; return 0; }; sleep 0.5; done
  return 1
}

cp -Rc "$app" "$copy"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.gielcobben.Wortel.keepertest' "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
mkdir -p "$data/work"
session=$(uuidgen) tab=$(uuidgen)
cat > "$data/sessions.json" <<EOF
[{"id":"$session","name":"keeper test","title":"pi","cwd":"$data/work","originCwd":"$data/work","selected":true,"nameSource":"user","mainTabs":["session"],"bottomTabs":["terminal:$tab"],"activeBottomTab":"terminal:$tab","bottomVisible":true,"runningAgent":"pi","runningArgv":"pi"}]
EOF

open -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 "$copy"
apppid=$(wait_for 20 pgrep -f "$copy/Contents/MacOS/Wortel") || { print "FAIL: the copy did not start"; cleanup; exit 1; }
keeper=$(wait_for 20 pgrep -f "$copy/Contents/Resources/bin/wortel-keeper") || { print "FAIL: no keeper"; cleanup; exit 1; }
pi=$(wait_for 40 pi_under $keeper) || { print "FAIL: pi -c never started at launch (is the screen on?)"; cleanup; exit 1; }
print "before: keeper $keeper, pi $pi"

kill -9 $(tree $keeper)
print "killed keeper $keeper and everything under it"

new=$(wait_for 15 pgrep -f "$copy/Contents/Resources/bin/wortel-keeper") || { print "FAIL: no new keeper"; cleanup; exit 1; }
pi2=$(wait_for 40 pi_under $new) || {
  print "FAIL: new keeper $new, but pi was not resumed. Under it:"
  ps -o pid=,ppid=,stat=,command= -p "${$(tree $new)// /,}" 2>/dev/null | cut -c1-160
  cleanup; exit 1; }
shells=$(ps -axo ppid=,command= | awk -v k=$new '$1==k && /\/usr\/bin\/login/' | wc -l | tr -d ' ')
print "after: keeper $new with $shells shells, pi $pi2"
/usr/bin/log show --last 2m --style compact \
  --predicate 'subsystem == "com.gielcobben.Wortel" AND category == "keeper"' | tail -n +2 | cut -c1-200

if [[ $shells -ge 2 ]]; then print "PASS"; result=0; else print "FAIL: expected 2 shells, got $shells"; result=1; fi
if (( keep )); then
  print "left running: pid $apppid, data $data. Quit it with: kill $apppid"
else
  cleanup
fi
exit $result
