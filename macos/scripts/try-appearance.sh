#!/bin/zsh
# Flip a throwaway copy of Wortel between light and dark and check that every
# terminal follows, and that every program that listens is told the truth.
#
#   scripts/try-appearance.sh [path/to/Wortel.app] [--keep]
#
# Runs a copy beside yours, never your Wortel, and never changes the Mac's own
# appearance: a Debug build takes "be dark" and "be light" as a notification
# addressed to its pid (`AppearanceTestHook`), which AppKit then passes on the
# way it passes on a real change. So this needs a Debug build.
#
# What it checks, each of them a thing that was once wrong (docs/appearance.md):
#
#   1. A live change reaches a terminal on screen and one out of sight, and a
#      program that listens (`?2031`) hears only the new theme. Never the old
#      one first.
#   2. The same for terminals that have not been in the window since launch.
#   3. A session started after a change comes up in the new theme.
#   4. A hibernated screen is saved with its palette colours as palette
#      colours, wakes into the theme of the day, and its program is told.
#
# Needs the screen unlocked: with it locked there is no display, libghostty
# cannot make a surface, nothing reads the ptys and nothing runs. --keep leaves
# the copy open afterwards, to look at.
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

work=$(mktemp -d /tmp/wortel-ap.XXXXXX)
data=$HOME/.wap-$$                       # short: the sockets live here
copy=$work/WortelAT.app
probe=$data/probe.py
wortel=$copy/Contents/Resources/bin/wortel
failures=0
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
launch() { # the hibernation clock, in seconds
  rm -f "$data/instance.lock"
  open -g -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 --env WORTEL_HIBERNATE_AFTER=$1 "$copy"
  wait_for 20 test -s "$data/instance.lock" || { print -u2 "the copy did not start"; cleanup; exit 2; }
  apppid=$(cat "$data/instance.lock")
  wait_for 20 w list || { print -u2 "the copy does not answer"; cleanup; exit 2; }
}
quit() {
  kill $apppid 2>/dev/null
  while kill -0 $apppid 2>/dev/null; do pause 0.2; done
  apppid=""
}
# Dark, light, or system: this copy only.
appear() {
  osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('sh.wortel.test.appearance.$apppid', '$1', \$(), true)" >/dev/null
}
mark() { for name in $sessions; do print "MARK $1" >> "$data/$name.log"; done; }
has_colours() { grep -q colours "$data/$1.log"; }
session() { # name, then what its shell runs
  local name=$1; shift
  w new --cwd "$data" --name $name -- "$@" >/dev/null 2>&1
  wait_for 20 has_colours $name || { print -u2 "no terminal answered in $name"; cleanup; exit 2; }
  sessions+=($name)
}
# What a session's log says after a mark: the theme it ended on, every report
# it got, and whether that is what a change to $3 should look like.
expect() { # label, session, theme, "told" or "untold"
  local out
  out=$(python3 - "$data/$2.log" "$mark_now" "$3" "$4" <<'PY'
import sys
path, mark, theme, told = sys.argv[1:5]
lines = open(path).read().split("MARK " + mark + "\n")[-1].splitlines()
reports = [l.split()[-1] for l in lines if " report " in l]
colours = [l.rsplit("(", 1)[-1].rstrip(")") for l in lines if " colours " in l]
problems = []
if not colours or colours[-1] != theme:
    problems.append("its colours ended on %s" % (colours[-1] if colours else "the old theme"))
if any(r != theme for r in reports):
    problems.append("it was told " + ", ".join(reports))
if told == "told" and not reports:
    problems.append("it was told nothing")
if told == "untold" and reports:
    problems.append("it was told, and never asked")
print("; ".join(problems))
PY
)
  if [[ -z $out ]]; then
    print "  ok    $1"
  else
    print "  FAIL  $1: $out"
    failures=$((failures + 1))
  fi
}
change_to() { mark_now=$1-$RANDOM; mark $mark_now; appear $1; pause 2.5; }

cp -Rc "$app" "$copy"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.gielcobben.Wortel.appearancetest' "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
mkdir -p "$data"
cp "${0:A:h}/appearance-probe.py" "$probe"
cat > "$data/colours.sh" <<'EOF'
printf '\033[31mred \033[32mgreen \033[34mblue \033[37mwhite \033[97mbright white \033[30mblack\033[0m plain\n'
printf '\033[41m red \033[47m white \033[40m black \033[0m \033[38;2;63;185;80mits own green\033[0m\n'
EOF

typeset -a sessions
sessions=()
launch 3600
appear light
pause 1

print "A change while running"
session listens python3 "$probe" "$data/listens.log" --poll 0.25
session quiet sh -c "sh '$data/colours.sh'; exec python3 '$probe' '$data/quiet.log' --no-subscribe --poll 0.25"
session front python3 "$probe" "$data/front.log" --poll 0.25
change_to dark
expect "on screen, listening" front dark told
expect "out of sight, listening" listens dark told
expect "out of sight, not listening" quiet dark untold
change_to light
expect "and back: on screen" front light told
expect "and back: out of sight" listens light told

print "Terminals not in the window since launch"
quit
launch 3600
pause 4
appear light
pause 1.5
change_to dark
expect "listening" listens dark told
expect "not listening" quiet dark untold
expect "the one on screen" front dark told

print "A session started after the change"
session late python3 "$probe" "$data/late.log" --poll 0.25
first=$(grep -m1 colours "$data/late.log" | sed 's/.*(\(.*\))/\1/')
if [[ $first == dark ]]; then
  print "  ok    it starts dark"
else
  print "  FAIL  it starts $first"
  failures=$((failures + 1))
fi

print "A terminal that hibernated"
quit
launch 4
appear dark
# Painted now, not before the relaunch: a reattached terminal starts with only
# what its shell wrote while nobody was attached.
session painted sh -c "sh '$data/colours.sh'; exec python3 '$probe' '$data/painted.log' --no-subscribe --poll 0.25"
session cover python3 "$probe" "$data/cover.log" --poll 0.25
painted_id=$(w list --json | python3 -c "import json,sys; print([s['id'] for s in json.load(sys.stdin) if s['name']=='painted'][0])")
listens_id=$(w list --json | python3 -c "import json,sys; print([s['id'] for s in json.load(sys.stdin) if s['name']=='listens'][0])")
if wait_for 90 test -s "$data/hibernated/$painted_id.vt" && wait_for 90 test -s "$data/hibernated/$listens_id.vt"; then
  # Palette colours are saved as markers (165;90;index), never as the theme's
  # own values, and a colour the program chose is saved as itself.
  dump="$data/hibernated/$painted_id.vt"
  if grep -q $'\033\\[38;2;165;90;1mred' "$dump" && grep -q $'\033\\[48;2;165;90;7m white' "$dump" \
     && grep -q $'\033\\[38;2;63;185;80mits own green' "$dump"; then
    print "  ok    its palette colours are saved as palette colours"
  else
    print "  FAIL  its palette colours are saved as today's colours"
    failures=$((failures + 1))
  fi
  change_to light
  w read listens >/dev/null 2>&1
  w read painted >/dev/null 2>&1
  pause 3
  expect "woken, listening" listens light told
  expect "woken, not listening" painted light untold
  restored=$(/usr/bin/log show --last 1m --info --predicate "processID == $apppid AND category == \"hibernation\"" 2>/dev/null \
    | grep "woke $painted_id" | sed -n 's/.* \([0-9][0-9]*\) palette colours.*/\1/p' | tail -1)
  if [[ ${restored:-0} -ge 9 ]]; then
    print "  ok    $restored palette colours went back as palette colours"
  else
    print "  FAIL  ${restored:-no} palette colours went back as palette colours (9 were saved)"
    failures=$((failures + 1))
  fi
else
  print "  FAIL  nothing hibernated in three minutes"
  failures=$((failures + 1))
fi

if (( keep )); then
  print "left open: pid $apppid, data in $data, logs in $data/*.log"
  print "put it away: kill $apppid, end its keeper, rm -rf $work $data"
else
  cleanup
fi
if (( failures )); then
  print "FAILED: $failures"
  exit 1
fi
print "PASSED"
