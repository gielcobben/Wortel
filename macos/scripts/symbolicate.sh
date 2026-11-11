#!/usr/bin/env bash
# Turn an app_crashed `site` back into a function and line.
#
#   ./scripts/symbolicate.sh <version> <site> [arch]
#   ./scripts/symbolicate.sh 2026.47.1 1a2b3c          # arm64 by default
#   ./scripts/symbolicate.sh 2026.47.1 1a2b3c x86_64
#
# `site` is what PostHog shows: the hex offset of the topmost frame inside
# Wortel's own binary on the crashed thread (see Telemetry/CrashReport.swift).
# It is an offset from where the binary was loaded, so it is resolved against
# the standard __TEXT address of a macOS executable, 0x100000000, using the
# dSYM release.sh --publish archived for that version. Without that dSYM the
# number cannot be read, which is the point of sending only the number.
set -euo pipefail

[ $# -ge 2 ] || { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
VERSION="$1"
SITE="${2#0x}"
ARCH="${3:-arm64}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DWARF="$ROOT/releases/dsyms/$VERSION/Wortel.app.dSYM/Contents/Resources/DWARF/Wortel"
[ -f "$DWARF" ] || {
  echo "No dSYM for $VERSION at $DWARF" >&2
  echo "Only releases published since dSYMs were archived can be read." >&2
  exit 1
}

LOAD=0x100000000
ADDRESS=$(printf '0x%x' $(( LOAD + 16#$SITE )))
atos -o "$DWARF" -arch "$ARCH" -l "$LOAD" "$ADDRESS"
