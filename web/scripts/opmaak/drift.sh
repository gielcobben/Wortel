#!/bin/bash
# How far the app has moved since the design canvas last showed it.
#
# A maintainer-only tool, for keeping the private design canvas current.
# Contributors don't need it: the generated web/src/app/gen is committed.
#
#   scripts/opmaak/drift.sh           the commits since, in two lists
#   scripts/opmaak/drift.sh --count   only the size of the first list
#
# The canvas is drawn by hand from the app, so nothing keeps it current by
# itself. `synced`, beside this script, names the commit it was last checked
# against, and this lists what has landed in the app since.
#
# The first list is commits that touch code that draws: views, menus, the
# Settings window, the terminal's config. The second is the rest of the app,
# where a change can still show (a new sort order, a row's name, a status dot)
# and only its subject line can tell you. Neither list is a verdict. Read them.
# Reads git only: no network, no canvas.
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

marker=web/scripts/opmaak/synced
app=$(awk '$1 == "app" {print $2}' "$marker")
date=$(awk '$1 == "date" {print $2}' "$marker")
[ -n "$app" ] || { echo "✗ no app line in $marker" >&2; exit 2; }
git merge-base --is-ancestor "$app" HEAD 2>/dev/null || {
  echo "✗ $app from $marker is not in this branch's history" >&2; exit 2; }

DRAWS=(macos/Wortel/UI macos/Wortel/Settings macos/Wortel/Preview macos/Wortel/Markdown
       macos/Wortel/Browser macos/Wortel/Files macos/Wortel/Git macos/Wortel/MainMenu.swift
       macos/Resources/wortel.conf)
APP=(macos/Wortel macos/Resources)

commits() { git log --no-merges --format='%h %ad %s' --date=short "$app..HEAD" -- "$@"; }

draws=$(commits "${DRAWS[@]}")
count=$(printf '%s' "$draws" | grep -c . || true)
if [ "${1:-}" = "--count" ]; then echo "$count"; exit 0; fi

# By the hash in the first field only: a subject can quote another commit's hash.
rest=$(commits "${APP[@]}" | awk 'NR == FNR { if (NF) seen[$1]; next } !($1 in seen)' <(printf '%s\n' "$draws") -)
[ -n "$draws" ] || rest=$(commits "${APP[@]}")

echo "The canvas shows the app at $(git rev-parse --short "$app") ($date)."
echo
echo "Touches code that draws ($count):"
[ -n "$draws" ] && printf '%s\n' "$draws" | sed 's/^/  /'
echo
echo "The rest of the app ($(printf '%s' "$rest" | grep -c . || true)):"
[ -n "$rest" ] && printf '%s\n' "$rest" | sed 's/^/  /'
exit 0
