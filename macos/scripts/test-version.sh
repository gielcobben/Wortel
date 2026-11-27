#!/bin/bash
# The release version numbers (scripts/version.sh): what comes next, how two
# compare, and whether Sparkle's own comparator agrees with that order.
#
#   scripts/test-version.sh                      Sparkle from any Wortel build
#   scripts/test-version.sh <Sparkle.framework>  that one, and it must be there
#
# Run by ../scripts/check.sh, and by scripts/release.sh twice: before it
# derives a version (with whatever Sparkle a build of this project left, of
# the pinned version; without one it warns on stderr and checks the rest),
# and after its build against the framework that build links, where a
# missing Sparkle is a failure.
set -uo pipefail
REQUIRED_FW=${1:-}
cd "$(dirname "$0")/.."
. scripts/version.sh

failures=0
ok() { :; }
wrong() { echo "WRONG $*"; failures=$((failures + 1)); }
expect() { # what, got, want
  [ "$2" = "$3" ] && ok || wrong "$1: got '$2', want '$3'"
}

# --- What comes next ---------------------------------------------------------
#            last           beta year week   next
cases=(
  "            ''            0   2026 48     2026.48.1"
  "            ''            1   2026 48     2026.48.1b1"
  "            2026.48.1     0   2026 48     2026.48.2"
  "            2026.48.1     1   2026 48     2026.48.2b1"
  "            2026.48.3     1   2026 48     2026.48.4b1"
  "            2026.48.4b1   1   2026 48     2026.48.4b2"
  "            2026.48.4b9   1   2026 48     2026.48.4b10"
  "            2026.48.4b2   0   2026 48     2026.48.4"
  "            2026.48.4     0   2026 48     2026.48.5"
  "            2026.48.4     1   2026 48     2026.48.5b1"
  "            2026.47.9     0   2026 48     2026.48.1"
  "            2026.47.9     1   2026 48     2026.48.1b1"
  "            2026.48.4b2   0   2026 49     2026.49.1"
  "            2026.48.4b2   1   2026 49     2026.49.1b1"
  "            2026.52.3     0   2027 1      2027.1.1"
  "            2026.53.1b1   0   2027 1      2027.1.1"
  "            2026.48.09    0   2026 48     2026.48.10"
  "            2026.9.2      1   2026 09     2026.9.3b1"
  "            2026.9.2      0   2026 09     2026.9.3"
)
for c in "${cases[@]}"; do
  read -r last beta year week want <<<"$c"
  [ "$last" = "''" ] && last=""
  expect "next after '$last' (beta $beta, $year week $week)" "$(version_next "$last" "$beta" "$year" "$week")" "$want"
done

# --- Spelling ----------------------------------------------------------------
expect "display of a beta" "$(version_display 2026.48.4b1)" "2026.48.4 beta 1"
expect "display of a beta 12" "$(version_display 2026.48.4b12)" "2026.48.4 beta 12"
expect "display of a release" "$(version_display 2026.48.4)" "2026.48.4"
version_is_beta 2026.48.4b1 || wrong "2026.48.4b1 is a beta"
version_is_beta 2026.48.4 && wrong "2026.48.4 is not a beta"
[ -z "$(version_key 2026.48.4-beta.1)" ] || wrong "a dashed version is refused"
[ -z "$(version_key '2026.48.4 beta 1')" ] || wrong "the person's spelling is refused as a machine version"
[ -z "$(version_key latest)" ] || wrong "'latest' is refused"

# --- Order -------------------------------------------------------------------
# Oldest first. The feed has carried 0.x versions and four-part ones never.
ORDER=(0.3.9 0.3.12 2026.9.1 2026.10.1 2026.47.4 2026.48.1 2026.48.2 2026.48.3
       2026.48.4b1 2026.48.4b2 2026.48.4b10 2026.48.4 2026.48.5b1 2026.48.5
       2026.49.1b1 2026.49.1 2027.1.1b1 2027.1.1)
for ((i = 1; i < ${#ORDER[@]}; i++)); do
  version_is_newer "${ORDER[$i]}" "${ORDER[$((i - 1))]}" || wrong "${ORDER[$i]} should be newer than ${ORDER[$((i - 1))]}"
  version_is_newer "${ORDER[$((i - 1))]}" "${ORDER[$i]}" && wrong "${ORDER[$((i - 1))]} should not be newer than ${ORDER[$i]}"
done
version_is_newer 2026.48.4 2026.48.4 && wrong "a version is not newer than itself"
version_is_newer 2026.48.4 "" || wrong "anything is newer than nothing"
shuffled=$(printf '%s\n' "${ORDER[@]}" garbage 2026.48.4-beta.1 | sort -R)
expect "newest of the lot" "$(version_newest <<<"$shuffled")" "2027.1.1"
expect "newest with a beta on top" "$(printf '%s\n' 2026.48.3 2026.48.4b1 2026.48.2 | version_newest)" "2026.48.4b1"
expect "newest with the release on top" "$(printf '%s\n' 2026.48.4b2 2026.48.4 2026.48.4b1 | version_newest)" "2026.48.4"

# --- Sparkle agrees ----------------------------------------------------------
# The order above is ours. What decides an update is Sparkle's comparator over
# CFBundleVersion, so ask it about every pair.
# The Sparkle the release links: the one Package.resolved pins.
PINNED=$(awk '/"identity" : "sparkle"/ { s = 1 } s && /"version"/ { gsub(/[",]/, "", $3); print $3; exit }' Package.resolved)
FW=""
if [ -n "$REQUIRED_FW" ]; then
  [ -d "$REQUIRED_FW/Headers" ] && FW=$REQUIRED_FW
else
  for f in "$HOME"/Library/Developer/Xcode/DerivedData/Wortel-*/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework; do
    [ -d "$f" ] || continue
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$f/Resources/Info.plist" 2>/dev/null)" = "$PINNED" ] && { FW=$f; break; }
  done
fi
if [ -z "$FW" ] && [ -n "$REQUIRED_FW" ]; then
  echo "WRONG no Sparkle.framework with headers at $REQUIRED_FW: Sparkle's own order could not be checked." >&2
  failures=$((failures + 1))
elif [ -z "$FW" ]; then
  echo "!  No Sparkle $PINNED from a Wortel build; Sparkle's own order was not checked here." >&2
else
  SPARKLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FW/Resources/Info.plist" 2>/dev/null || echo "?")
  tmp=$(mktemp -d)
  cat > "$tmp/order.swift" <<'EOF'
import Foundation
import Sparkle
// Each argument is newer than the one before it, by Sparkle's comparator.
let versions = Array(CommandLine.arguments.dropFirst())
let comparator = SUStandardVersionComparator.default
var bad = 0
for i in versions.indices {
    for j in versions.indices where j != i {
        let got = comparator.compareVersion(versions[i], toVersion: versions[j])
        let want: ComparisonResult = i < j ? .orderedAscending : .orderedDescending
        if got != want { print("WRONG Sparkle orders \(versions[i]) vs \(versions[j]) as \(got.rawValue), want \(want.rawValue)"); bad += 1 }
    }
}
exit(bad == 0 ? 0 : 1)
EOF
  dir=$(dirname "$FW")
  if swiftc -F "$dir" -framework Sparkle -Xlinker -rpath -Xlinker "$dir" "$tmp/order.swift" -o "$tmp/order" 2>"$tmp/err"; then
    if "$tmp/order" "${ORDER[@]}"; then
      echo "   Sparkle $SPARKLE_VERSION agrees on the order of ${#ORDER[@]} versions"
    else
      echo "WRONG Sparkle $SPARKLE_VERSION disagrees with this order (above)"
      failures=$((failures + 1))
    fi
  else
    echo "!  Could not build the Sparkle check:"; cat "$tmp/err"
    failures=$((failures + 1))
  fi
  rm -rf "$tmp"
fi

if [ $failures = 0 ]; then echo "==> version numbers: ok"; else echo "==> version numbers: $failures wrong"; exit 1; fi
