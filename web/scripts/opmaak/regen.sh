#!/bin/bash
# The site's app windows, from the design canvas.
#
#   scripts/opmaak/regen.sh            write src/app/gen, fetch new images
#   scripts/opmaak/regen.sh --check    change nothing, say what would change
#
# Every file in src/app/gen is one named layer of one frame on the working
# canvas, run through jsx2astro.mjs. The table below is the whole mapping.
# --check exits 1 when the site and the canvas differ, so it can be scripted.
#
# Needs the `opmaak` command, signed in (`opmaak login`), and `npm install`.
# It only reads the canvas. It is not part of check.sh, which has to pass with
# no network and no login.
#
# Three more things are said either way, because nothing else would say them:
#   - a light pane whose markup differs from its dark twin. The site draws one
#     markup in both colour schemes, so that difference cannot reach the site.
#   - an image in public/app that no generated file uses any more.
#   - a layer name the site's scripts look up that no file defines. That is a
#     layer renamed on the canvas, and a film that quietly stopped working.
set -euo pipefail
cd "$(dirname "$0")/../.."                 # web/

PROJECT=2v3opz6osv                         # the working canvas, see web/README.md
CANVAS="Canvas 1"

# file | frame on the canvas | layer in it | the frame's light twin, or -
TABLE='
Sidebar|Pane · Sidebar · Dark|Sidebar|Pane · Sidebar · Light
Terminal|Pane · Terminal · Dark|Terminal pane|Pane · Terminal · Light
TerminalNarrow|Pane · Terminal, beside a column · Dark|Terminal pane|Pane · Terminal, beside a column · Light
Changes|Pane · Changes · Dark|Changes pane|Pane · Changes · Light
History|Pane · History · Dark|History pane|Pane · History · Light
Files|Pane · Files · Dark|Files pane|Pane · Files · Light
FileColumn|Pane · File, in the column · Dark|File pane|Pane · File, in the column · Light
FileMain|Pane · File, in the main area · Dark|Main pane|Pane · File, in the main area · Light
Code|Pane · Code · Dark|Main pane|Pane · Code · Light
Browser|Pane · Browser · Dark|Main pane|Pane · Browser · Light
BottomStrip|Pane · Bottom strip · Dark|Bottom strip|Pane · Bottom strip · Light
Palette|Pane · Command palette · Dark|Command palette|Pane · Command palette · Light
HeroWindow|Foggy Lake|Window|-
'

check=0
case "${1:-}" in
  --check) check=1 ;;
  "") ;;
  *) echo "usage: scripts/opmaak/regen.sh [--check]" >&2; exit 2 ;;
esac

command -v opmaak >/dev/null || { echo "✗ opmaak not found. It is the design canvas's command line." >&2; exit 2; }
[ -d node_modules/@babel/parser ] || { echo "✗ run npm install in web/ first" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/gen" "$work/light"
: > "$work/ids"

# One frame as JSX. The command prints a line or two of its own first.
dump() {
  opmaak tree "$1" --project "$PROJECT" --canvas "$CANVAS" | sed -n '/^</,$p' > "$2"
}
# The same pane with its pictures taken out, to compare light with dark.
no_pictures() { sed -E 's#/app/[0-9a-f]{32}\.png##g' "$1"; }

changed=0 notes=0
while IFS='|' read -r file frame layer light; do
  [ -n "$file" ] || continue
  dump "$frame" "$work/$file.jsx"
  node scripts/opmaak/jsx2astro.mjs "$work/$file.jsx" "$work/gen/$file.astro" \
    --select "$layer" --assets "$work/ids" >/dev/null

  if cmp -s "$work/gen/$file.astro" "src/app/gen/$file.astro" 2>/dev/null; then
    echo "  same     $file"
  else
    changed=$((changed + 1))
    if [ $check = 1 ]; then
      echo "  differs  $file   ($frame)"
    else
      cp "$work/gen/$file.astro" "src/app/gen/$file.astro"
      echo "  written  $file   ($frame)"
    fi
  fi

  [ "$light" = - ] && continue
  dump "$light" "$work/$file.light.jsx"
  node scripts/opmaak/jsx2astro.mjs "$work/$file.light.jsx" "$work/light/$file.astro" \
    --select "$layer" >/dev/null
  if cmp -s "$work/light/$file.astro" "$work/gen/$file.astro"; then
    :
  elif [ "$(no_pictures "$work/light/$file.astro")" = "$(no_pictures "$work/gen/$file.astro")" ]; then
    notes=$((notes + 1))
    echo "  note     $file: the light pane has a picture of its own. The site shows the dark one in both."
  else
    notes=$((notes + 1))
    echo "  note     $file: the light pane's markup differs from the dark one ($light)."
  fi
done <<< "$TABLE"

# A generated file with no row above was made some other way.
for f in src/app/gen/*.astro; do
  name=$(basename "$f" .astro)
  [ -f "$work/gen/$name.astro" ] || { notes=$((notes + 1)); echo "  note     $name.astro has no row in this script's table."; }
done

# Images. The canvas serves each by id, and an id never changes its bytes.
sort -u "$work/ids" | grep . > "$work/need" || true
while read -r id; do
  [ -f "public/app/$id.png" ] && continue
  changed=$((changed + 1))
  if [ $check = 1 ]; then
    echo "  new      public/app/$id.png"
  else
    curl -fsS "https://opmaak.dev/a/$id" -o "public/app/$id.png"
    echo "  fetched  public/app/$id.png"
  fi
done < "$work/need"
for f in public/app/*.png; do
  id=$(basename "$f" .png)
  grep -qx "$id" "$work/need" || { notes=$((notes + 1)); echo "  note     $f is not used by any generated file. Remove it in the same commit."; }
done

# Layer names. Looked up: [data-name="X"] and named(root, 'X'). Defined: the
# generated files, markup the components write, and names the scripts set.
gen_dir=src/app/gen
[ $check = 1 ] && gen_dir="$work/gen"
{
  grep -rhoE '\[data-name="[^"$]+"\]' src/scripts src/components src/pages src/styles | sed -E 's/^\[data-name="//; s/"\]$//'
  grep -rhoE "named\([^,()]+, '[^']+'" src/scripts src/components | sed -E "s/.*, '//; s/'\$//"
} | sort -u > "$work/looked-up"
{
  grep -hoE 'data-name="[^"]+"' "$gen_dir"/*.astro | sed -E 's/^data-name="//; s/"$//'
  grep -rhoE '[^[]data-name="[^"$]+"' src/components src/pages | sed -E 's/^.data-name="//; s/"$//'
  grep -rhoE "dataset\.name = '[^']+'" src/scripts | sed -E "s/.*= '//; s/'\$//"
} | sort -u > "$work/defined"
while read -r name; do
  notes=$((notes + 1))
  echo "  note     the site looks up a layer named \"$name\", and nothing has one."
done < <(comm -23 "$work/looked-up" "$work/defined")

echo
if [ $check = 1 ]; then
  if [ $changed = 0 ]; then echo "The site's windows match the canvas."; else echo "$changed to regenerate. Run it without --check."; fi
else
  if [ $changed = 0 ]; then echo "Nothing to write: the site's windows match the canvas."; else echo "$changed written. Look at the site in light and dark before committing."; fi
fi
[ $notes = 0 ] || echo "$notes to read above."
[ $check = 1 ] && [ $changed != 0 ] && exit 1
exit 0
