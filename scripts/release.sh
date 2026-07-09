#!/bin/bash
# Build, sign, and install a proper Release build of Vellum so it runs like a
# real installed app — which is what makes macOS notifications, LaunchServices
# registration, and Gatekeeper behave (an ad-hoc Debug build in DerivedData
# does not register with the notification daemon).
#
#   ./scripts/release.sh              signed Release -> /Applications -> launch
#   ./scripts/release.sh --notarize   + hardened runtime, notarize, staple, .dmg
#
# The signing identity is auto-detected (Developer ID Application, else Apple
# Development). Override with VELLUM_SIGN_IDENTITY. Notarization uses a stored
# notarytool keychain profile named by VELLUM_NOTARY_PROFILE (setup at bottom).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
mkdir -p build

NOTARIZE=0
[ "${1:-}" = "--notarize" ] && NOTARIZE=1

# --- Signing identity -------------------------------------------------------
IDENTITY="${VELLUM_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/{print $2; exit}')
  [ -z "$IDENTITY" ] && IDENTITY=$(security find-identity -v -p codesigning | awk -F\" '/Apple Development/{print $2; exit}')
fi
[ -n "$IDENTITY" ] || { echo "No codesigning identity found. Set VELLUM_SIGN_IDENTITY." >&2; exit 1; }
if [ "$NOTARIZE" = 1 ] && ! printf '%s' "$IDENTITY" | grep -q "Developer ID"; then
  echo "Notarization needs a 'Developer ID Application' identity (have: $IDENTITY)." >&2
  exit 1
fi
echo "==> Signing identity: $IDENTITY"

# --- Build ------------------------------------------------------------------
echo "==> Regenerating project + building Release"
command -v xcodegen >/dev/null && xcodegen generate
if ! xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Release \
      clean build > build/xcodebuild.log 2>&1; then
  echo "Build failed — last lines:" >&2
  tail -30 build/xcodebuild.log >&2
  exit 1
fi

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -name 'Vellum-*' | head -1)/Build/Products/Release/Vellum.app
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
  # not to Vellum). Override with VELLUM_NOTARY_PROFILE if you use another name.
  PROFILE="${VELLUM_NOTARY_PROFILE:-notary}"
  echo "==> Notarizing with keychain profile '$PROFILE' (a few minutes)…"
  ditto -c -k --keepParent "$APP" build/Vellum.zip
  xcrun notarytool submit build/Vellum.zip --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  # Prove it: the staple is attached and Gatekeeper accepts it offline.
  xcrun stapler validate "$APP"
  spctl -a -vv --type exec "$APP"
  rm -f build/Vellum.dmg
  hdiutil create -volname Vellum -srcfolder "$APP" -ov -format UDZO build/Vellum.dmg >/dev/null
  echo "==> Notarized + stapled. Distributable: build/Vellum.dmg"
fi

# --- Install + launch -------------------------------------------------------
echo "==> Installing to /Applications"
osascript -e 'tell application "Vellum" to quit' 2>/dev/null || true
sleep 1
rm -rf /Applications/Vellum.app
cp -R "$APP" /Applications/Vellum.app
open /Applications/Vellum.app
echo "==> Done. Vellum is signed and running from /Applications."

# ----------------------------------------------------------------------------
# One-time notarization setup (only for --notarize). This keychain profile is
# tied to your Apple ID + team, so ONE profile notarizes ALL your apps (Vellum,
# Opslan, …). Get an app-specific password at appleid.apple.com -> Sign-In &
# Security -> App-Specific Passwords, then:
#
#   xcrun notarytool store-credentials "notary" \
#     --apple-id "you@example.com" --team-id 76D2KX7X2M \
#     --password "abcd-efgh-ijkl-mnop"
#
# After that, releasing is just:  ./scripts/release.sh --notarize
