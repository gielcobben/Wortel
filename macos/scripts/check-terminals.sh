#!/bin/zsh
# Every test of how a terminal is sized, shown, put to sleep and brought back,
# in one go, against throwaway copies of a Debug build. About eight minutes.
#
#   scripts/check-terminals.sh [path/to/Wortel.app]
#
# Run it before merging anything that touches `Wortel/Ghostty/`, a terminal's
# host or pane, hibernation, the keeper's replay, or appearance. Each of these
# was written after a bug that a person found first; together they are what
# "it still works" means for terminals. Nothing here touches your own Wortel.
#
# Keeps the display awake while it runs (they need one to draw on). Prints one
# line a test and exits non-zero if any failed. A machine that is busy makes
# the timing ones flaky: try-appearance waits fixed times.
set -u

here=${0:A:h}
app=${1:-}
if [[ -z $app ]]; then
  app="$(xcodebuild -project "$here/../Wortel.xcodeproj" -scheme Wortel -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')/Wortel.app"
fi
[[ -d $app ]] || { print -u2 "no app at $app"; exit 2; }

caffeinate -d -u -t 1200 &
awake=$!
trap 'kill $awake 2>/dev/null' EXIT
sleep 2

failed=0
log=$(mktemp -t wortel-check-terminals)
run() { # name, then the command; passes when it prints none of `bad`
  local name=$1; shift
  local out
  out=$("$@" 2>&1); local code=$?
  print -- "$out" >> "$log"
  local wrong
  wrong=$(print -- "$out" | grep -E "WRONG|FAIL|NOT A MEASUREMENT|no result|did not start|asleep|returns wrong" \
    | grep -v -E " 0 of [0-9]+ returns wrong|came back wrong as expected")
  if [[ $code -ne 0 || -n $wrong ]]; then
    print "FAILED  $name"
    print -- "$wrong" | sed 's/^/          /' | head -6
    failed=$((failed + 1))
  else
    print "ok      $name"
  fi
}

run "switching sessions"                         "$here/try-switch.sh" "$app"
run "switching, with a side terminal and widths" "$here/try-switch.sh" "$app" --side --widths
run "switching into sleeping terminals"          env HIBERNATE_AFTER=0.3 "$here/try-switch.sh" "$app" --side
run "the pages in front of a terminal"           "$here/try-switch.sh" "$app" --pages
run "a sleeping agent's screen"                  "$here/try-hibernate-screen.sh" "$app"
run "a relaunch: sizes and the replay"           "$here/try-relaunch-size.sh" "$app"
run "light and dark"                             "$here/try-appearance.sh" "$app"
run "panes sliding, terminal after"              "$here/bench-resize.sh" "$app" --panes --runs 1

print ""
if (( failed )); then
  print "$failed failed. Everything they printed: $log"
  exit 1
fi
print "all passed"
rm -f "$log"
