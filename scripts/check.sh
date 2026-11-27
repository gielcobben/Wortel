#!/bin/bash
# Does everything still work? The three apps' own checks, in one go:
#
#   ./scripts/check.sh            all three
#   ./scripts/check.sh macos      one of: macos, updates, web
#
# Nothing here deploys, signs or publishes. XCODEBUILD_FLAGS is passed to
# xcodebuild as given, for a machine that needs e.g.
#   XCODEBUILD_FLAGS="-clonedSourcePackagesDirPath /tmp/wortel-sp"
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
only="${1:-all}"

run() { [ "$only" = all ] || [ "$only" = "$1" ]; }

if run macos; then
  echo "==> macos: tests"
  (
    cd "$ROOT/macos"
    command -v xcodegen >/dev/null || { echo "✗ xcodegen not found (brew install xcodegen)" >&2; exit 1; }
    # Ghostty, from source, if this checkout has no build of the pinned one
    # yet (a cached build is a copy; a new one is about five minutes).
    scripts/build-ghostty.sh
    xcodegen generate --quiet
    # The packages a release builds against (macos/Package.resolved), as
    # release.sh pins them: the project is generated, so its copy is put back.
    resolved=Wortel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
    mkdir -p "$resolved" && cp Package.resolved "$resolved/Package.resolved"
    # shellcheck disable=SC2086
    xcodebuild -project Wortel.xcodeproj -scheme WortelTests ${XCODEBUILD_FLAGS:-} test -quiet
    # The release version numbers, held to Sparkle's comparator. After the
    # build, so a fresh machine has the pinned Sparkle to ask; on CI a missing
    # one fails rather than warns.
    scripts/test-version.sh
  )
fi

if run updates; then
  echo "==> updates: typecheck + tests"
  (
    cd "$ROOT/updates"
    [ -d node_modules ] || npm ci --silent
    npm run --silent typecheck
    npm test --silent
  )
fi

if run web; then
  echo "==> web: typecheck + tests + build"
  (
    cd "$ROOT/web"
    [ -d node_modules ] || npm ci --silent
    npm run --silent check
    npm test --silent
    npm run --silent build
    # No em-dash in anything that ships (web/README.md's rule).
    if grep -rl '—' dist/ ; then echo "✗ em-dash in the built site (files above)" >&2; exit 1; fi
  )
fi

echo "==> ok"
