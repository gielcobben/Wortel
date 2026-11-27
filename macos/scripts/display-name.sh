#!/bin/bash
#
# The name the app shows, set as one of the app's last build phases
# (project.yml), before Xcode signs it: "Wortel Beta" on a beta, from
# WORTEL_DISPLAY_NAME, which release.sh --publish --beta passes.
#
# Not by changing Info.plist. The bundle stays Wortel.app, and with a file
# name that is not its CFBundleDisplayName, macOS shows the file's name in
# the Dock and Finder; CFBundleName "Wortel Beta" only reaches the menu bar.
# What reaches all of them is a localized name: Info.plist keeps "Wortel",
# which matches the file, and the development language's InfoPlist.strings
# says "Wortel Beta". Measured on 2026-11-27 (macOS 27) on a copy named
# Wortel.app: Finder, the Dock, ⌘-Tab and the menu bar all said "Wortel
# Beta" this way, and only ⌘-Tab did with CFBundleDisplayName alone.
#
# Set every build, both ways: the file is written when the name differs from
# Info.plist's and removed when it doesn't, so an incremental build after a
# beta one doesn't keep the beta's name.
set -euo pipefail

resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
lproj="$resources/${DEVELOPMENT_LANGUAGE:-en}.lproj"
strings="$lproj/InfoPlist.strings"
# The source Info.plist, not the built one: Xcode may write that after this
# phase has run, and the first build here read the one before it.
plain=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$SRCROOT/$INFOPLIST_FILE")
name="${WORTEL_DISPLAY_NAME:-$plain}"

if [ "$name" = "$plain" ]; then
    rm -f "$strings"
    rmdir "$lproj" 2>/dev/null || true
    exit 0
fi

mkdir -p "$lproj"
rm -f "$strings"
plutil -create xml1 "$strings"
# Both keys: the display name is what the Dock, Finder and ⌘-Tab show, and
# the bundle name is the menu bar's bold app menu title.
plutil -insert CFBundleDisplayName -string "$name" "$strings"
plutil -insert CFBundleName -string "$name" "$strings"
echo "Display name: $name"
