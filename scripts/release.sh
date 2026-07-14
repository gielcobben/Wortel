#!/bin/bash
# Build, sign, and install a proper Release build of Wortel so it runs like a
# real installed app — which is what makes macOS notifications, LaunchServices
# registration, and Gatekeeper behave (an ad-hoc Debug build in DerivedData
# does not register with the notification daemon).
#
#   ./scripts/release.sh                signed Release -> /Applications -> launch
#   ./scripts/release.sh --notarize     + hardened runtime, notarize, staple, .dmg
#   ./scripts/release.sh --publish      full release: derive a CalVer version,
#                                         notarize, EdDSA-sign a zip, regenerate
#                                         the appcast, and upload to the
#                                         wortel-updates R2 bucket (Sparkle feed).
#                                         Implies --notarize.
#   ./scripts/release.sh --publish 2026.30.1   force a specific version
#
# Versioning is CalVer (Framer-style): <ISO-week-year>.<ISO-week>.<Nth release
# that week>, e.g. 2026.28.3 — auto-derived from the date, so there's no version
# to pick per release. Sparkle's update check compares CFBundleVersion, which we
# stamp = this string (verified against its comparator: numeric components, week
# and year rollovers, and the 0.3.x -> 2026.x transition all rank forward, so the
# sequence never regresses). CFBundleShortVersionString is stamped to the same
# value, so the update dialog reads "2026.28.3 is available — you have 2026.27.1".
# releases/BUILD records the last published version.
#
# The signing identity is auto-detected (Developer ID Application, else Apple
# Development). Override with WORTEL_SIGN_IDENTITY. Notarization uses a stored
# notarytool keychain profile named by WORTEL_NOTARY_PROFILE (setup at bottom).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
mkdir -p build

# --- Sparkle / distribution config ------------------------------------------
BUCKET="wortel-updates"                 # R2 bucket served at updates.wortel.sh
FEED_BASE="https://updates.wortel.sh"
RELEASES_DIR="$ROOT/releases"           # canonical archive store; appcast regenerated from it

# --- Args -------------------------------------------------------------------
NOTARIZE=0
PUBLISH=0
VERSION=""
BUILD_FILE="$RELEASES_DIR/BUILD"        # tracked record: last published version string
case "${1:-}" in
  --notarize) NOTARIZE=1 ;;
  --publish)
    PUBLISH=1
    NOTARIZE=1                          # publishing a non-notarized zip fails Gatekeeper on other Macs
    VERSION="${2:-}"
    last=$(cat "$BUILD_FILE" 2>/dev/null || echo "")
    if [ -z "$VERSION" ]; then
      # CalVer, auto-derived (Framer-style): <ISO-week-year>.<ISO-week>.<Nth
      # release that week>. %G/%V are the ISO week-numbering year and week, so
      # the triple only ever moves forward — Sparkle's comparator ranks it
      # numerically (verified: 09<10, week and year rollovers, 0.3.x < 2026.x).
      YEAR=$(date +%G); WEEK=$((10#$(date +%V)))
      if [[ "$last" == "$YEAR.$WEEK."* ]]; then
        VERSION="$YEAR.$WEEK.$(( ${last##*.} + 1 ))"   # another release this week
      else
        VERSION="$YEAR.$WEEK.1"                        # first release this week
      fi
    fi
    # Explicit override must be dot-separated integers (still CalVer-shaped).
    [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Usage: $0 --publish [version]   version is dot-separated integers, e.g. $0 --publish 2026.30.1 (omit to auto-derive)" >&2; exit 1; }
    # Guard against a version that isn't strictly newer than the last published
    # one — that would make Sparkle silently never offer the update. sort -V
    # orders dotted-numeric versions the same way Sparkle's comparator does.
    if [ -n "$last" ]; then
      newest=$(printf '%s\n%s\n' "$last" "$VERSION" | sort -V | tail -1)
      { [ "$VERSION" != "$last" ] && [ "$newest" = "$VERSION" ]; } || { echo "✗ Version $VERSION is not newer than the last published $last" >&2; exit 1; }
    fi
    echo "==> Publishing $VERSION"
    ;;
  "") ;;
  *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac

# --- Signing identity -------------------------------------------------------
IDENTITY="${WORTEL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/{print $2; exit}')
  [ -z "$IDENTITY" ] && IDENTITY=$(security find-identity -v -p codesigning | awk -F\" '/Apple Development/{print $2; exit}')
fi
[ -n "$IDENTITY" ] || { echo "No codesigning identity found. Set WORTEL_SIGN_IDENTITY." >&2; exit 1; }
if [ "$NOTARIZE" = 1 ] && ! printf '%s' "$IDENTITY" | grep -q "Developer ID"; then
  echo "Notarization needs a 'Developer ID Application' identity (have: $IDENTITY)." >&2
  exit 1
fi
echo "==> Signing identity: $IDENTITY"

# --- Build ------------------------------------------------------------------
echo "==> Regenerating project + building Release"
command -v xcodegen >/dev/null && xcodegen generate
# When publishing, stamp both version fields from the argument so Sparkle (which
# compares CFBundleVersion) sees each release as newer. Otherwise use the
# versions baked into project.yml.
VERSION_ARGS=()
if [ "$PUBLISH" = 1 ]; then
  VERSION_ARGS=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION")
fi
# Build a universal binary so it runs on both Apple Silicon and Intel Macs.
# (A single-arch build shows "app is damaged" on the other architecture.)
if ! xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Release \
      ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
      ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
      clean build > build/xcodebuild.log 2>&1; then
  echo "Build failed — last lines:" >&2
  tail -30 build/xcodebuild.log >&2
  exit 1
fi

# There can be several Wortel-* DerivedData folders (a git worktree gets its
# own), and only one holds this build's Release product — so pick the newest
# Release .app that actually exists, not just the first directory found.
APP=""
while IFS= read -r dir; do
  cand="$dir/Build/Products/Release/Wortel.app"
  [ -d "$cand" ] || continue
  if [ -z "$APP" ] || [ "$cand" -nt "$APP" ]; then APP="$cand"; fi
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -name 'Wortel-*')
[ -n "$APP" ] || { echo "Release .app not found (see build/xcodebuild.log)" >&2; exit 1; }
echo "==> Built $APP"

# --- Sign -------------------------------------------------------------------
# Hardened runtime is only enabled for notarization; a plain local run doesn't
# need it (and it keeps the local path from tripping on entitlements).
RUNTIME=()
[ "$NOTARIZE" = 1 ] && RUNTIME=(--options runtime)
echo "==> Signing"
codesign --force --deep --timestamp ${RUNTIME[@]+"${RUNTIME[@]}"} --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- Notarize (optional) ----------------------------------------------------
if [ "$NOTARIZE" = 1 ]; then
  # Shared across all your apps (the profile is tied to your Apple ID + team,
  # not to Wortel). Override with WORTEL_NOTARY_PROFILE if you use another name.
  PROFILE="${WORTEL_NOTARY_PROFILE:-notary}"
  echo "==> Notarizing the app with keychain profile '$PROFILE' (a few minutes)…"
  ditto -c -k --keepParent "$APP" build/Wortel.zip
  xcrun notarytool submit build/Wortel.zip --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"          # ticket travels inside the .app -> works offline
  xcrun stapler validate "$APP"
  spctl -a -vv --type exec "$APP"

  echo "==> Building, signing, and notarizing the DMG…"
  rm -f build/Wortel.dmg
  hdiutil create -volname Wortel -srcfolder "$APP" -ov -format UDZO build/Wortel.dmg >/dev/null
  # The DMG wrapper needs its OWN Developer ID signature + notarization, or a
  # downloaded .dmg is rejected by Gatekeeper ("no usable signature") even
  # though the app inside is fine. So: sign -> notarize -> staple the dmg too.
  codesign --force --sign "$IDENTITY" --timestamp build/Wortel.dmg
  xcrun notarytool submit build/Wortel.dmg --keychain-profile "$PROFILE" --wait
  xcrun stapler staple build/Wortel.dmg
  xcrun stapler validate build/Wortel.dmg
  spctl -a -vv -t open --context context:primary-signature build/Wortel.dmg
  echo "==> Notarized + stapled. Distributable: build/Wortel.dmg"
fi

# --- Publish to the Sparkle feed (optional) ---------------------------------
# Runs only for --publish. The app is already notarized + stapled above, so we
# just zip it, EdDSA-sign every archive into the appcast, and push to R2.
if [ "$PUBLISH" = 1 ]; then
  # Confirm the build actually picked up the version we stamped.
  BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  [ "$BUILT" = "$VERSION" ] || { echo "✗ Built version ($BUILT) ≠ requested ($VERSION)" >&2; exit 1; }

  # Sparkle's CLI tools ship inside the resolved SPM artifact bundle.
  SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path '*artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)"
  [ -n "$SPARKLE_BIN" ] || { echo "✗ Sparkle tools not found. Open Wortel.xcodeproj in Xcode once to resolve packages." >&2; exit 1; }

  mkdir -p "$RELEASES_DIR"
  ZIP="$RELEASES_DIR/Wortel-${VERSION}.zip"

  # --norsrc keeps AppleDouble (._*) xattr entries out of the zip; without it
  # Gatekeeper rejects the extracted app ("unsealed contents present…").
  echo "==> Packaging $ZIP"
  rm -f "$ZIP"
  ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

  # Regenerate the appcast — EdDSA-signs every archive in RELEASES_DIR using the
  # shared publisher private key in the login Keychain. --maximum-deltas 0
  # disables Sparkle's binary delta patches entirely: every version ships as a
  # single full zip and the appcast stays plain (one <item> per release, no
  # <sparkle:deltas> blocks). Deltas produced an O(n²) pile of tiny patch files
  # in the bucket for negligible benefit on a small app — we don't want them.
  echo "==> Generating appcast"
  "$SPARKLE_BIN/generate_appcast" --maximum-deltas 0 --download-url-prefix "$FEED_BASE/" "$RELEASES_DIR"

  # Upload to R2. --remote is REQUIRED — without it wrangler writes to the local
  # simulator and the custom domain serves nothing (silent 404). Only the full
  # zip + appcast go up; there are no deltas to upload.
  echo "==> Uploading to R2 ($BUCKET)"
  npx wrangler r2 object put "$BUCKET/Wortel-${VERSION}.zip" --file "$ZIP" --content-type application/zip --remote
  npx wrangler r2 object put "$BUCKET/appcast.xml" --file "$RELEASES_DIR/appcast.xml" --content-type application/xml --remote

  # Stable "latest" download for the website: same bytes as the versioned zip,
  # overwritten every release, short TTL, saved by browsers as Wortel.zip.
  npx wrangler r2 object put "$BUCKET/Wortel-latest.zip" --file "$ZIP" \
    --content-type application/zip \
    --content-disposition 'attachment; filename="Wortel.zip"' \
    --cache-control 'public, max-age=300' --remote

  # Record the version only after every upload succeeded, so a failed run
  # doesn't advance the record. Commit this file alongside appcast.xml.
  echo "$VERSION" > "$BUILD_FILE"

  echo "==> Published $VERSION"
  echo "    Appcast:         $FEED_BASE/appcast.xml"
  echo "    Latest download: $FEED_BASE/Wortel-latest.zip"
fi

# --- Install + launch -------------------------------------------------------
echo "==> Installing to /Applications"
osascript -e 'tell application "Wortel" to quit' 2>/dev/null || true
sleep 1
rm -rf /Applications/Wortel.app
cp -R "$APP" /Applications/Wortel.app
open /Applications/Wortel.app
echo "==> Done. Wortel is signed and running from /Applications."

# ----------------------------------------------------------------------------
# One-time notarization setup (only for --notarize). This keychain profile is
# tied to your Apple ID + team, so ONE profile notarizes ALL your apps (Wortel,
# Opslan, …). Get an app-specific password at appleid.apple.com -> Sign-In &
# Security -> App-Specific Passwords, then:
#
#   xcrun notarytool store-credentials "notary" \
#     --apple-id "you@example.com" --team-id 76D2KX7X2M \
#     --password "abcd-efgh-ijkl-mnop"
#
# After that, releasing is just:  ./scripts/release.sh --notarize
