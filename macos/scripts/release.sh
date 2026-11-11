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
#   ./scripts/release.sh --publish --no-notes     publish without a release note
#   ./scripts/release.sh --publish 2026.33.1 --republish
#                                       replace the version already published,
#                                         same bytes-key, same appcast <item>.
#                                         Strands anyone who already took it,
#                                         so it is only for a release nobody
#                                         has downloaded yet. Version required.
#   ./scripts/release.sh --publish --allow-dirty  publish with uncommitted
#                                         changes in the tree. Emergencies only:
#                                         the release is then not rebuildable.
#   ./scripts/release.sh --publish --no-tests     skip WortelTests and the
#                                         updates/ tests that run before the
#                                         build. Emergencies only.
#
# Publishing requires a release note: web/src/content/releases/<version>.md, one
# Markdown file whose name is the version. It is checked before anything is
# built, and it feeds two places at once — the changelog at wortel.sh/updates,
# and the notes Sparkle shows in the in-app update dialog.
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
WEB="$ROOT/../web"                      # the landing page; also holds the changelog
# One Markdown file per release, named for the version. It is both what
# wortel.sh/updates renders and, via web/src/pages/release-notes/, what Sparkle
# shows in the update dialog — so publishing without one ships an update whose
# dialog says nothing about what changed. See web/src/content.config.ts.
NOTES_DIR="$WEB/src/content/releases"

# --- Args -------------------------------------------------------------------
NOTARIZE=0
PUBLISH=0
INSTALL=1
NOTES=1
REPUBLISH=0
ALLOW_DIRTY=0
RUN_TESTS=1
VERSION=""
BUILD_FILE="$RELEASES_DIR/BUILD"        # tracked record: last published version string
# Lift the flags out of the argument list before the positional parse below, so
# they can be passed in any position — including after a forced version.
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --no-notes) NOTES=0 ;;
    --republish) REPUBLISH=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --no-tests) RUN_TESTS=0 ;;
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
    # What ships is what is committed. A publish from a tree with uncommitted
    # changes is a release no commit can rebuild or bisect. Checked first,
    # while stopping is free.
    if [ "$ALLOW_DIRTY" = 0 ] && [ -n "$(git -C "$ROOT/.." status --porcelain)" ]; then
      echo "✗ Uncommitted changes. Commit them (the release note included), or pass --allow-dirty." >&2
      git -C "$ROOT/.." status --short >&2
      exit 1
    fi
    # The uploader is needed at the very end, after notarization. Find out
    # now whether it can be installed.
    [ -x "$ROOT/../updates/node_modules/.bin/wrangler" ] || ( cd "$ROOT/../updates" && npm ci --silent )
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
    # Remembered before the derivation below fills it in, because --republish
    # is only ever an explicit act: a derived version is by definition the next
    # one, which is the opposite of replacing this one.
    EXPLICIT_VERSION=$([ -n "$VERSION" ] && echo 1 || echo 0)
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
    if [ "$REPUBLISH" = 1 ]; then
      # Deliberately replacing what is already out there, bytes and all. The
      # zip goes back to the same key, generate_appcast rewrites that version's
      # <item> with the new length and signature, and BUILD does not move.
      #
      # THE COST IS PERMANENT AND ONLY ONE WAY: Sparkle offers a *strictly
      # greater* version, so anyone who already downloaded the first build of
      # this version is stranded on it and will never be offered the second.
      # That is the 2026.31.2 incident described above, chosen on purpose
      # instead of stumbled into — which is the only reason this flag exists,
      # and why it will not derive a version for you.
      [ "$EXPLICIT_VERSION" = 1 ] || { echo "✗ --republish needs the version spelled out: $0 --publish <version> --republish" >&2; exit 1; }
      [ "$VERSION" = "$last" ] || { echo "✗ --republish is for replacing the last published version ($last), not $VERSION" >&2; exit 1; }
      echo "!  Republishing $VERSION over the copy already in the bucket."
      echo "   Anyone who has already taken $VERSION will never be offered this build."
    elif [ -n "$last" ]; then
      newest=$(printf '%s\n%s\n' "$last" "$VERSION" | sort -V | tail -1)
      { [ "$VERSION" != "$last" ] && [ "$newest" = "$VERSION" ]; } || { echo "✗ Version $VERSION is not newer than the last published $last" >&2; exit 1; }
    fi
    # The release note is checked here, before anything is built, signed or
    # uploaded — a release that stops halfway is only cheap while it is still
    # this early. Writing the note is also the last chance to notice that the
    # thing you are shipping has no one-sentence description.
    if [ "$NOTES" = 1 ] && [ ! -f "$NOTES_DIR/$VERSION.md" ]; then
      echo "✗ No release note for $VERSION." >&2
      echo "  Write web/src/content/releases/$VERSION.md (frontmatter: date, title, summary)," >&2
      echo "  then re-run. It becomes both wortel.sh/updates and the in-app update dialog." >&2
      echo "  To publish without one anyway: $0 --publish --no-notes" >&2
      exit 1
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
command -v xcodegen >/dev/null || { echo "✗ xcodegen not found (brew install xcodegen). Building without it would build a stale project." >&2; exit 1; }
xcodegen generate
# The versions every package resolves to are the tracked ones
# (macos/Package.resolved), not whatever is newest today. The project is
# generated and ignored, so its own copy is put back each time.
RESOLVED_DIR="Wortel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$RESOLVED_DIR"
cp "$ROOT/Package.resolved" "$RESOLVED_DIR/Package.resolved"
# The suite is 85 seconds and a publish is permanent.
if [ "$PUBLISH" = 1 ] && [ "$RUN_TESTS" = 1 ]; then
  echo "==> Running tests"
  if ! xcodebuild -project Wortel.xcodeproj -scheme WortelTests -onlyUsePackageVersionsFromResolvedFile test > build/xcodebuild-test.log 2>&1; then
    echo "✗ Tests failed. Last lines (full log: build/xcodebuild-test.log):" >&2
    tail -40 build/xcodebuild-test.log >&2
    echo "  To publish anyway: --no-tests" >&2
    exit 1
  fi
  (
    cd "$ROOT/../updates"
    [ -d node_modules ] || npm ci --silent
    npm test --silent
  ) || { echo "✗ updates/ tests failed." >&2; exit 1; }
fi
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
      -onlyUsePackageVersionsFromResolvedFile \
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
# Nested command-line tools first, explicitly, and this is not optional:
# `codesign --deep` treats a bare Mach-O in Contents/Resources as a *resource*
# rather than as nested code, so `wortel` and `wortel-keeper` keep whatever Xcode
# gave them — a development signature, with get-task-allow, no secure timestamp
# and no hardened runtime. The app still passes `--verify --deep --strict`, which
# is exactly what makes this so easy to believe is handled; notarization is the
# thing that disagrees, and it rejects the whole app for it.
#
# Signed before the app, because changing anything inside a bundle invalidates
# the enclosing signature. Inside-out is the rule.
for tool in "$APP"/Contents/Resources/bin/*; do
  [ -f "$tool" ] || continue
  echo "    signing $(basename "$tool")"
  codesign --force --timestamp ${RUNTIME[@]+"${RUNTIME[@]}"} --sign "$IDENTITY" "$tool"
done
# The app alone gets the entitlements: the hardened-runtime exceptions that let
# a program in a session be asked for the camera, contacts and the rest (see
# Wortel.entitlements). Without them, notarized Wortel refuses all of it unasked.
codesign --force --deep --timestamp ${RUNTIME[@]+"${RUNTIME[@]}"} --sign "$IDENTITY" "$APP"
codesign --force --timestamp ${RUNTIME[@]+"${RUNTIME[@]}"} --entitlements "$ROOT/Wortel.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
# Verify each one on its own terms. `--verify --deep` on the app does not check
# these — it passed happily while both tools carried a development signature —
# so the only honest check is per-tool, and the authority beyond it is the notary
# service itself.
for tool in "$APP"/Contents/Resources/bin/*; do
  [ -f "$tool" ] || continue
  codesign --verify --strict "$tool"
  codesign -dvv "$tool" 2>&1 | grep -E "^(Authority=Developer ID|Timestamp=)" | sed 's/^/    /'
done

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

  # Keep this build's dSYMs. The app reports a crash as an offset into its own
  # binary and nothing else (see Telemetry/CrashReport.swift), so turning that
  # number back into a function needs the dSYM of exactly this build — and the
  # next `clean build` deletes it. Local only and git-ignored: R2 is served
  # publicly by the updates Worker, so they never go there. Not fatal: a
  # missing dSYM costs symbolication later, not the release.
  DSYM_DIR="$RELEASES_DIR/dsyms/$VERSION"
  mkdir -p "$DSYM_DIR"
  for dsym in "${APP%/Wortel.app}"/Wortel.app.dSYM "${APP%/Wortel.app}"/wortel-keeper*.dSYM; do
    [ -d "$dsym" ] && ditto "$dsym" "$DSYM_DIR/$(basename "$dsym")"
  done
  [ -d "$DSYM_DIR/Wortel.app.dSYM" ] \
    && echo "==> Archived dSYMs in $DSYM_DIR" \
    || echo "!  No Wortel.app.dSYM beside $APP; crashes in $VERSION can't be symbolicated." >&2

  # Sparkle's CLI tools ship inside the resolved SPM artifact bundle.
  # From the build that made $APP, so the tools match the linked Sparkle.
  SPARKLE_BIN="${APP%/Build/Products/*}/SourcePackages/artifacts/sparkle/Sparkle/bin"
  [ -d "$SPARKLE_BIN" ] || SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path '*artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -1)"
  [ -n "$SPARKLE_BIN" ] || { echo "✗ Sparkle tools not found. Open Wortel.xcodeproj in Xcode once to resolve packages." >&2; exit 1; }

  mkdir -p "$RELEASES_DIR"
  ZIP="$RELEASES_DIR/Wortel-${VERSION}.zip"

  # --norsrc keeps AppleDouble (._*) xattr entries out of the zip; without it
  # Gatekeeper rejects the extracted app ("unsealed contents present…").
  echo "==> Packaging $ZIP"
  rm -f "$ZIP"
  ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

  # Release notes for the update dialog. The site build renders every file in
  # web/src/content/releases/ to a standalone HTML fragment; the one for this
  # version goes next to the archive, named after it, which is how
  # generate_appcast finds it (it embeds a same-named .html as CDATA, so the
  # notes travel inside the feed and render with no network fetch).
  #
  # This is the site's *first* build of the run. It is not wasted work being
  # done twice: the deploy at the end has to build again anyway, because only
  # then does the appcast it reads its version line from mention $VERSION.
  if [ "$NOTES" = 1 ] && [ -d "$WEB" ]; then
    echo "==> Rendering release notes for the update dialog"
    (
      cd "$WEB"
      [ -d node_modules ] || npm install --silent
      npm run build --silent
    ) || { echo "✗ Could not build the site to render release notes for $VERSION." >&2; exit 1; }
    NOTE_HTML="$WEB/dist/release-notes/$VERSION.html"
    [ -f "$NOTE_HTML" ] || { echo "✗ Expected $NOTE_HTML after the build; the note exists but rendered nothing." >&2; exit 1; }
    cp "$NOTE_HTML" "$RELEASES_DIR/Wortel-${VERSION}.html"
  fi

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
  #
  # The wrangler the updates/ lockfile pins, not whatever `npx` finds from a
  # folder with no package.json. This step holds the Cloudflare credentials.
  UPDATES="$ROOT/../updates"
  [ -x "$UPDATES/node_modules/.bin/wrangler" ] || ( cd "$UPDATES" && npm ci --silent )
  WRANGLER="$UPDATES/node_modules/.bin/wrangler"
  [ -x "$WRANGLER" ] || { echo "✗ wrangler not found in updates/node_modules after npm ci." >&2; exit 1; }
  echo "==> Uploading to R2 ($BUCKET)"
  "$WRANGLER" r2 object put "$BUCKET/Wortel-${VERSION}.zip" --file "$ZIP" --content-type application/zip --remote
  "$WRANGLER" r2 object put "$BUCKET/appcast.xml" --file "$RELEASES_DIR/appcast.xml" --content-type application/xml --remote

  # Stable "latest" download for the website: same bytes as the versioned zip,
  # overwritten every release, short TTL, saved by browsers as Wortel.zip.
  "$WRANGLER" r2 object put "$BUCKET/Wortel-latest.zip" --file "$ZIP" \
    --content-type application/zip \
    --content-disposition 'attachment; filename="Wortel.zip"' \
    --cache-control 'public, max-age=300' --remote

  # Record the version only after every upload succeeded, so a failed run
  # doesn't advance the record. Commit this file alongside appcast.xml.
  echo "$VERSION" > "$BUILD_FILE"

  # Mark the release on every PostHog chart, so a change in launches, crashes or
  # retention can be read against the version that caused it. The key is a
  # personal API key with the annotation:write scope and nothing else, kept in
  # the login Keychain (never in the repo: unlike the phc_ token it can write
  # to the project). Add it once with:
  #   security add-generic-password -a "$USER" -s wortel-posthog-annotations -w <key>
  # @current is the key owner's current project, which on a one-project
  # organisation is the only one. Not fatal, like the deploy; the status is
  # printed so a scoping problem (403) is visible rather than swallowed.
  PH_KEY="$(security find-generic-password -s wortel-posthog-annotations -w 2>/dev/null || true)"
  if [ -n "$PH_KEY" ]; then
    PH_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      "https://eu.posthog.com/api/projects/@current/annotations/" \
      -H "Authorization: Bearer $PH_KEY" -H 'Content-Type: application/json' \
      -d "{\"content\":\"Wortel $VERSION\",\"date_marker\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"scope\":\"project\"}" \
      || echo 000)"
    case "$PH_STATUS" in
      2??) echo "==> Annotated $VERSION in PostHog" ;;
      *) echo "!  PostHog annotation failed (HTTP $PH_STATUS); the release itself is fine." >&2 ;;
    esac
  else
    echo "!  No wortel-posthog-annotations key in the Keychain; skipping the PostHog annotation." >&2
  fi

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
