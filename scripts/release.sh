#!/bin/bash
# Build, sign, and install a proper Release build of Wortel so it runs like a
# real installed app — which is what makes macOS notifications, LaunchServices
# registration, and Gatekeeper behave (an ad-hoc Debug build in DerivedData
# does not register with the notification daemon).
#
#   ./scripts/release.sh              signed Release -> /Applications -> launch
#   ./scripts/release.sh --notarize   + hardened runtime, notarize, staple, .dmg
#
# The signing identity is auto-detected (Developer ID Application, else Apple
# Development). Override with WORTEL_SIGN_IDENTITY. Notarization uses a stored
# notarytool keychain profile named by WORTEL_NOTARY_PROFILE (setup at bottom).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
mkdir -p build

NOTARIZE=0
[ "${1:-}" = "--notarize" ] && NOTARIZE=1

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
# Build a universal binary so it runs on both Apple Silicon and Intel Macs.
# (A single-arch build shows "app is damaged" on the other architecture.)
if ! xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Release \
      ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
      clean build > build/xcodebuild.log 2>&1; then
  echo "Build failed — last lines:" >&2
  tail -30 build/xcodebuild.log >&2
  exit 1
fi

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -name 'Wortel-*' | head -1)/Build/Products/Release/Wortel.app
[ -d "$APP" ] || { echo "Release .app not found (see build/xcodebuild.log)" >&2; exit 1; }
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
