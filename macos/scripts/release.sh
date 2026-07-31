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
#                                         the appcast, upload to the
#                                         wortel-updates R2 bucket (Sparkle
#                                         feed), and redeploy web/ so wortel.sh
#                                         shows the new version. Implies
#                                         --notarize.
#   ./scripts/release.sh --publish 2026.30.1   force a specific version
#   ./scripts/release.sh --publish --no-install   publish, but leave the
#                                         installed app alone
#
# --no-install exists for one specific hazard: the install step below quits
# Wortel, and a release is often cut from a shell running *inside* Wortel. That
# quit kills the shell — and with it this script, somewhere between the
# `rm -rf /Applications/Wortel.app` and the `cp` that replaces it, which can
# leave no installed app at all. Publishing itself never touches the running
# app, so skip the install and take the update through Sparkle
# (Wortel ▸ Check for Updates…) like any other user would.
#
# Versioning is CalVer (Framer-style): <ISO-week-year>.<ISO-week>.<Nth release
# that week>, e.g. 2026.28.3 — auto-derived from the date, so there's no version
# to pick per release. Sparkle's update check compares CFBundleVersion, which we
# stamp = this string (verified against its comparator: numeric components, week
# and year rollovers, and the 0.3.x -> 2026.x transition all rank forward, so the
# sequence never regresses). CFBundleShortVersionString is stamped to the same
# value, so the update dialog reads "2026.28.3 is available — you have 2026.27.1".
# The Nth counter is derived from the *live appcast* (falling back to the
# releases/BUILD record), because that feed is the only state shared by every
# machine that can publish — see the comment at the derivation.
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
INSTALL=1
VERSION=""
BUILD_FILE="$RELEASES_DIR/BUILD"        # tracked record: last published version string
# Lift --no-install out of the argument list before the positional parse below,
# so it can be passed in any position — including after a forced version.
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
case "${1:-}" in
  --notarize) NOTARIZE=1 ;;
  --publish)
    PUBLISH=1
    NOTARIZE=1                          # publishing a non-notarized zip fails Gatekeeper on other Macs
    VERSION="${2:-}"
    # What's actually out there. `releases/BUILD` is only ever *this checkout's*
    # memory of it: a release cut from another machine or a worktree, or one
    # whose commit was discarded, leaves it stale — and then the counter below
    # re-derives a number that is already taken and overwrites it in the bucket.
    # That is not hypothetical: 2026.31.2 shipped twice, as two different
    # binaries, because BUILD still said 2026.31.1. Everyone on the first one was
    # stranded, since Sparkle only offers a *strictly greater* version.
    #
    # The appcast is the one piece of state every machine shares, so ask it and
    # take whichever is higher. A cache-buster because the feed is served through
    # Cloudflare, and `|| true` throughout so an unreachable feed degrades to the
    # old BUILD-only behaviour rather than restarting at .1 over a live release.
    recorded=$(cat "$BUILD_FILE" 2>/dev/null || echo "")
    published=$(curl -fsS --max-time 15 "$FEED_BASE/appcast.xml?t=$(date +%s)" 2>/dev/null \
      | sed -n 's/.*<sparkle:version>\([^<]*\)<.*/\1/p' | sort -V | tail -1 || true)
    if [ -z "$published" ]; then
      echo "!  Could not read $FEED_BASE/appcast.xml — falling back to releases/BUILD (${recorded:-none})." >&2
      echo "   If a release was published elsewhere, this run can silently reuse its version." >&2
    fi
    last=$(printf '%s\n%s\n' "$recorded" "$published" | grep -v '^$' | sort -V | tail -1 || true)
    if [ -n "$published" ] && [ "$published" != "$recorded" ]; then
      echo "==> Live feed is at $published; releases/BUILD says ${recorded:-none} — counting from $last"
    fi
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
    # Now that `last` includes the live feed, this also catches an explicit
    # --publish <version> that collides with a release cut somewhere else.
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

  # Redeploy the landing page. It reads the version number out of the appcast at
  # *build time* (see web/src/pages/index.astro), so a publish alone never
  # changes what wortel.sh says — the site had drifted three releases behind
  # before this ran automatically. It goes after the uploads above so the build
  # reads the feed we just pushed (that URL is served uncached, cf-cache-status
  # DYNAMIC, so there's no stale-read window to design around).
  #
  # A failure here does not fail the release: by this point the zip and appcast
  # are already live and users are being offered the update. Exiting would skip
  # the install below and imply the publish came apart, which isn't true — so
  # say loudly what's wrong and carry on.
  WEB="$ROOT/../web"
  if [ -d "$WEB" ]; then
    echo "==> Deploying the website (wortel.sh)"
    (
      cd "$WEB"
      [ -d node_modules ] || npm install --silent
      npm run deploy
    ) || {
      echo "!  Website deploy failed. The release itself is published and live;" >&2
      echo "   wortel.sh will keep showing the previous version until you run:" >&2
      echo "     cd web && npm run deploy" >&2
    }
  else
    echo "!  No web/ directory beside macos/ — skipping the website deploy." >&2
  fi

  echo "==> Published $VERSION"
  echo "    Appcast:         $FEED_BASE/appcast.xml"
  echo "    Latest download: $FEED_BASE/Wortel-latest.zip"
  echo "    Website:         https://wortel.sh"
fi

# --- Install + launch -------------------------------------------------------
if [ "$INSTALL" = 0 ]; then
  echo "==> Skipping install (--no-install); the running app is untouched."
  echo "    Built: $APP"
  if [ "$PUBLISH" = 1 ]; then
    echo "    Take the update in-app: Wortel ▸ Check for Updates…"
  fi
  exit 0
fi

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
