#!/bin/bash
#
# The bundle id of a Debug build, set as the app's last build phase
# (project.yml), before Xcode signs it.
#
# A Debug build is com.gielcobben.Wortel.dev on its own data folder
# (`Wortel Dev`), so a build from a fresh clone never meets the installed app:
# not its sessions, not its keeper, not its UserDefaults. See DataDirectory.
#
# On a Mac where the usual data folder holds the file below, Debug builds are
# the daily Wortel: they use that folder (DataDirectory reads the same file)
# and get the released app's bundle id here, so its UserDefaults go with it.
# A file in the data folder rather than in the checkout, because Wortel makes
# worktrees on the fly and a new one would not have it.
#
#   touch ~/Library/Application\ Support/Wortel/debug-builds-share-this-folder
#
# Set every build, both ways: Xcode only rewrites Info.plist when its inputs
# change, so a file added or removed since the last build would otherwise not
# be seen until a clean build.
set -euo pipefail

[ "${CONFIGURATION:-}" = Debug ] || exit 0

plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
want="$PRODUCT_BUNDLE_IDENTIFIER"
if [ -e "$HOME/Library/Application Support/Wortel/debug-builds-share-this-folder" ]; then
    want="${PRODUCT_BUNDLE_IDENTIFIER%.dev}"
fi

have=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
if [ "$have" != "$want" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $want" "$plist"
    echo "Debug bundle id: $want"
fi
