#!/bin/bash
# Make the drag-to-install DMG: the app on the left, a link to /Applications on
# the right, large icons, no toolbar, no sidebar, no background picture. Plain
# on purpose: nothing branded beyond the app's own icon.
#
#   scripts/make-dmg.sh <path/to/Wortel.app> <out.dmg>
#
# Finder lays the window out (window size, icon size, positions), which it
# saves in the volume's .DS_Store. That needs the app running this script to be
# allowed to control Finder (System Settings > Privacy & Security >
# Automation); macOS asks once. Without it the script fails rather than ship a
# DMG in Finder's default window.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <out.dmg>}"
OUT="${2:?usage: make-dmg.sh <app> <out.dmg>}"
NAME="$(basename "$APP" .app)"
VOLNAME="$NAME"

# Window geometry, in points. Icons sit on one row, centred in their halves.
WIN_W=560
WIN_H=340
ICON=128
APP_X=150
APPS_X=410
ROW_Y=150

WORK="$(mktemp -d)"
RW="$WORK/rw.dmg"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
# Finder and Spotlight let go of a volume they just used a moment late, so a
# first detach often says "Resource busy". Retry, then force.
detach() {
  for _ in 1 2 3 4 5; do
    hdiutil detach "$1" >/dev/null 2>&1 && return 0
    sleep 2
  done
  hdiutil detach "$1" -force >/dev/null
}
trap cleanup EXIT
# hdiutil now prints a deprecation line on every call. Its real errors still
# come through.
hdiutil() { command hdiutil "$@" 2> >(grep -v 'is deprecated' >&2); }

# A volume with this name already mounted would make Finder lay out the wrong
# window, or the new one would mount as "Wortel 1".
if [ -d "/Volumes/$VOLNAME" ]; then
  echo "error: /Volumes/$VOLNAME is already mounted; eject it first" >&2
  exit 1
fi

mkdir "$WORK/stage"
ditto "$APP" "$WORK/stage/$NAME.app"
ln -s /Applications "$WORK/stage/Applications"

# Read-write first, so Finder can write its layout; compressed at the end.
hdiutil create -volname "$VOLNAME" -srcfolder "$WORK/stage" -fs HFS+ \
  -format UDRW -ov "$RW" >/dev/null
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" \
  | awk -F'\t' '/\/Volumes\//{print $NF}')"
if [ "$MOUNT" != "/Volumes/$VOLNAME" ]; then
  echo "error: the image mounted at '${MOUNT:-nowhere}', not /Volumes/$VOLNAME" >&2
  exit 1
fi
# Keep Spotlight off it: an index is nothing anyone wants inside the DMG, and
# indexing holds the volume busy.
mdutil -i off "$MOUNT" >/dev/null 2>&1 || true

if ! osascript >/dev/null <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set w to container window
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set sidebar width of w to 0
    set bounds of w to {200, 120, 200 + $WIN_W, 120 + $WIN_H}
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to $ICON
    set text size of o to 13
    set label position of o to bottom
    set shows item info of o to false
    set shows icon preview of o to true
    set position of item "$NAME.app" of w to {$APP_X, $ROW_Y}
    set position of item "Applications" of w to {$APPS_X, $ROW_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  echo "error: Finder could not lay out the DMG window. Allow the app running" >&2
  echo "       this to control Finder (System Settings > Privacy & Security >" >&2
  echo "       Automation) and run it again." >&2
  exit 1
fi

# Finder writes .DS_Store when it gets to it. Wait for it, then drop what
# Finder or Spotlight left behind that nobody should see.
for _ in $(seq 1 20); do
  [ -f "$MOUNT/.DS_Store" ] && break
  sleep 0.5
done
if [ ! -f "$MOUNT/.DS_Store" ]; then
  echo "error: Finder never saved the window layout (.DS_Store) on the image" >&2
  exit 1
fi
sync
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" "$MOUNT/.Spotlight-V100" 2>/dev/null || true
detach "$MOUNT"
MOUNT=""

rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "$OUT"
