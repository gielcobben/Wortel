#!/bin/zsh
# Betas and releases through real Sparkle: which update each Mac is offered,
# and that the release replaces a beta whole.
#
#   scripts/try-beta-updates.sh [--keep]
#
# Builds the app twice, as `release.sh --publish` stamps it (a release,
# 2026.48.4, and a beta, "2026.48.4 beta 1" / 2026.48.4b1 with the beta
# channel, icon and name), makes the other versions from those two, and
# publishes them one at a time into a local feed the way a release does:
# generate_appcast, with --channel beta for a beta. The feed is signed with a
# throwaway key and served on 127.0.0.1, so nothing leaves this Mac.
#
# Each case installs one version into a throwaway copy (its own bundle id,
# data folder and keeper), points it at the feed as it stood after some
# publish, launches it and reads which zip its Sparkle downloads. Two cases
# then quit the copy, let Sparkle install, and read what is on disk after.
#
# Needs the screen unlocked: each copy is a real app, launched in the
# background. Takes about ten minutes.
set -u
keep=0
[[ ${1:-} == --keep ]] && keep=1

here=${0:A:h}/..
cd $here
. scripts/version.sh

work=$(mktemp -d /tmp/wortel-bt.XXXXXX)
data=$HOME/.wbt-$$                                 # short: the sockets live here
copy=$work/Wortel.app                              # where Sparkle installs to
feed=$work/feed
bundle=com.gielcobben.Wortel.betatest
port=$(( 20000 + RANDOM % 20000 ))
failures=0
mkdir -p $feed $data

ok() { print "ok    $*"; }
wrong() { print "WRONG $*"; failures=$((failures + 1)); }
tree() {
  ps -axo pid=,ppid= | awk -v root=$1 '{p[$1]=$2} END {s[root]=1
    for (n = 0; n < 8; n++) for (x in p) if (p[x] in s) s[x]=1
    for (x in s) printf "%s ", x}'
}
stop_copy() {
  pkill -f "$copy/Contents/MacOS/" 2>/dev/null
  for _ in {1..20}; do pgrep -f "$copy/Contents/MacOS/" >/dev/null || break; sleep 0.25; done
  pkill -9 -f "$copy/Contents/MacOS/" 2>/dev/null
  for k in $(pgrep -f "$copy/Contents/Resources/bin/wortel-keeper"); do kill -9 $(tree $k) 2>/dev/null; done
  pkill -f "$work/.*Autoupdate" 2>/dev/null
  pkill -f "Sparkle.*$bundle" 2>/dev/null
}
cleanup() {
  stop_copy
  [[ -n ${server:-} ]] && kill $server 2>/dev/null
  defaults delete $bundle >/dev/null 2>&1
  rm -rf "$HOME/Library/Caches/$bundle" "$HOME/Library/Application Support/$bundle" 2>/dev/null
  (( keep )) && print "kept $work and $data" || rm -rf "$work" "$data"
}
trap cleanup EXIT

locked=$(swift -e 'import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]; print((d["CGSSessionScreenIsLocked"] as? Int) ?? 0)' 2>/dev/null)
[[ $locked == 1 ]] && { print -u2 "the screen is locked; unlock it and run again"; exit 2; }

# --- Build: a release and a beta, stamped as release.sh stamps them --------
derived=$HOME/Library/Developer/Xcode/DerivedData/Wortel-betatest
build() { # version, then any extra build settings
  local v=$1; shift
  xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug -derivedDataPath $derived \
    -onlyUsePackageVersionsFromResolvedFile \
    "MARKETING_VERSION=$(version_display $v)" "CURRENT_PROJECT_VERSION=$v" "$@" build \
    > $work/build-$v.log 2>&1 || { print "FAIL: the build of $v (log: $work/build-$v.log)"; tail -20 $work/build-$v.log; keep=1; exit 1; }
  rm -rf $work/built-$v.app
  cp -Rc $derived/Build/Products/Debug/Wortel.app $work/built-$v.app
}
xcodegen generate --quiet
# The Sparkle that ships, as release.sh pins it, not the newest there is.
resolved=Wortel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p $resolved && cp Package.resolved $resolved/Package.resolved
# A build folder made against another Sparkle fails on its stale modules.
pinned=$(awk '/"identity" : "sparkle"/ { s = 1 } s && /"version"/ { gsub(/[",]/, "", $3); print $3; exit }' Package.resolved)
had=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $derived/Build/Products/Debug/Sparkle.framework/Resources/Info.plist 2>/dev/null)
[[ -n $had && $had != $pinned ]] && rm -rf $derived
print "building the release and the beta (a few minutes)…"
build 2026.48.4
build 2026.48.4b1 WORTEL_UPDATE_CHANNEL=beta ASSETCATALOG_COMPILER_APPICON_NAME=AppIconBeta "WORTEL_DISPLAY_NAME=Wortel Beta"

# What release.sh checks after its build, and what xcodebuild made of a
# marketing version with spaces in it.
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null }
shown_name() {
  plutil -extract CFBundleDisplayName raw "$1/Contents/Resources/en.lproj/InfoPlist.strings" 2>/dev/null || plist $1 CFBundleDisplayName
}
b=$work/built-2026.48.4b1.app r=$work/built-2026.48.4.app
pinned=$(awk '/"identity" : "sparkle"/ { s = 1 } s && /"version"/ { gsub(/[",]/, "", $3); print $3; exit }' Package.resolved)
linked=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $r/Contents/Frameworks/Sparkle.framework/Resources/Info.plist)
[[ $linked == $pinned ]] && ok "built with Sparkle $linked, the one release.sh ships" \
  || wrong "built with Sparkle $linked, but release.sh ships $pinned"
[[ $(plist $b CFBundleShortVersionString) == "2026.48.4 beta 1" && $(plist $b CFBundleVersion) == 2026.48.4b1 ]] \
  && ok "the beta is stamped \"2026.48.4 beta 1\" (2026.48.4b1)" \
  || wrong "the beta is stamped \"$(plist $b CFBundleShortVersionString)\" ($(plist $b CFBundleVersion))"
[[ $(plist $b WortelUpdateChannel) == beta && $(plist $b CFBundleIconName) == AppIconBeta && $(shown_name $b) == "Wortel Beta" ]] \
  && ok "the beta has the beta channel, icon and name" || wrong "the beta's channel, icon or name is wrong"
[[ $(plist $r CFBundleShortVersionString) == 2026.48.4 && $(plist $r CFBundleVersion) == 2026.48.4 && -z $(plist $r WortelUpdateChannel) \
   && $(plist $r CFBundleIconName) == AppIcon && $(shown_name $r) == Wortel ]] \
  && ok "the release is 2026.48.4, named Wortel, with no channel" || wrong "the release is stamped wrong"

# --- A throwaway key, and every version as a signed zip ----------------------
# Sparkle's key is the 32-byte Ed25519 seed, base64; the public key the raw 32.
openssl genpkey -algorithm ed25519 -out $work/key.pem 2>/dev/null
openssl pkey -in $work/key.pem -outform DER 2>/dev/null | tail -c 32 | base64 > $work/key.sparkle
pubkey=$(openssl pkey -in $work/key.pem -pubout -outform DER 2>/dev/null | tail -c 32 | base64)

# A version made from one of the two builds: what the copy is, and the zip
# it is published as. Only Info.plist differs, which is all Sparkle reads.
make_version() { # version, from build, to path
  rm -rf $3
  cp -Rc $2 $3
  local p=$3/Contents/Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle" \
    -c "Set :CFBundleShortVersionString $(version_display $1)" -c "Set :CFBundleVersion $1" \
    -c "Set :SUFeedURL http://127.0.0.1:$port/appcast.xml" -c "Set :SUPublicEDKey $pubkey" $p
  codesign --force --deep --sign - $3 2>/dev/null
}
SPARKLE_BIN=$(ls -d $derived/SourcePackages/artifacts/sparkle/Sparkle/bin)
# The beta's ancestors were betas with regular numbers (2026.48.2, .3), so .3
# is made from the beta build. The rest from the build of their own kind.
typeset -A from=(2026.48.1 $r 2026.48.3 $b 2026.48.4b1 $b 2026.48.4b2 $b 2026.48.4 $r 2026.48.5b1 $b)
typeset -A isbeta=(2026.48.1 0 2026.48.3 1 2026.48.4b1 1 2026.48.4b2 1 2026.48.4 0 2026.48.5b1 1)
publish() { # version: into the feed, then a copy of the feed as it now stands
  make_version $1 ${from[$1]} $work/stage/Wortel.app
  ditto -c -k --norsrc --keepParent $work/stage/Wortel.app $feed/Wortel-$1.zip
  local args=(--maximum-deltas 0 --ed-key-file $work/key.sparkle --download-url-prefix "http://127.0.0.1:$port/")
  (( ${isbeta[$1]} )) && args+=(--channel beta)
  $SPARKLE_BIN/generate_appcast $args $feed > $work/appcast-$1.log 2>&1 || { print "FAIL: generate_appcast for $1"; cat $work/appcast-$1.log; exit 1; }
  cp $feed/appcast.xml $work/appcast-after-$1.xml
}
mkdir -p $work/stage
for v in 2026.48.1 2026.48.3 2026.48.4b1 2026.48.4b2 2026.48.4 2026.48.5b1; do publish $v; done
grep -q '<sparkle:version>2026.48.4b1</sparkle:version>' $work/appcast-after-2026.48.4b1.xml \
  && grep -q '<sparkle:shortVersionString>2026.48.4 beta 1</sparkle:shortVersionString>' $work/appcast-after-2026.48.4b1.xml \
  && ok "the feed lists the beta as 2026.48.4b1, shown as \"2026.48.4 beta 1\"" || wrong "the feed's beta entry is wrong"
# generate_appcast keeps three versions a channel (its default, which
# release.sh has always used) and drops a beta once a release has passed it:
# what is left must still be every release, untagged, and the betas tagged.
channels=$(awk '/<item>/{c=""} /<sparkle:channel>/{c="beta"} /<sparkle:version>/{gsub(/.*<sparkle:version>|<.*/,""); v=$0} /<\/item>/{printf "%s:%s ", v, c}' $feed/appcast.xml)
[[ " $channels " == *" 2026.48.4: "* && " $channels " == *" 2026.48.1: "* && " $channels " == *" 2026.48.5b1:beta "* \
   && " $channels " == *" 2026.48.4b2:beta "* ]] \
  && ok "after it all, the feed is $channels" || wrong "channels in the feed: $channels"

# --- The feed, served here -------------------------------------------------
# A request log with the agent, so the zip each copy takes can be read off it.
cat > $work/serve.py <<'EOF'
import http.server, sys, os
root, port, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def log_message(self, *a): pass
    def do_GET(self):
        with open(log, "a") as f: f.write(f"{self.path}\t{self.headers.get('User-Agent', '')}\n")
        super().do_GET()
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
python3 -I $work/serve.py $feed $port $work/requests.log &
server=$!
sleep 1

# --- The cases ---------------------------------------------------------------
# Installs `have`, serves the feed as it stood after `after`, and waits for
# the copy's Sparkle to fetch a zip. Prints the version it took, or "none"
# when it checked and took nothing.
offered() { # have, beta (on/off/unset), after
  local have=$1 beta=$2 after=$3
  stop_copy
  defaults delete $bundle >/dev/null 2>&1
  rm -rf "$HOME/Library/Caches/$bundle"
  defaults write $bundle SUEnableAutomaticChecks -bool true
  defaults write $bundle SUAutomaticallyUpdate -bool true
  defaults write $bundle SUHasLaunchedBefore -bool true
  defaults write $bundle WortelAutomaticUpdatesOn1 -bool true
  # An older last-run version, so the first launch looks again within a
  # minute (Updater.noteVersionChange), whatever Sparkle's own schedule says.
  defaults write $bundle WortelLastRunVersion 2026.1.1
  case $beta in
    on) defaults write $bundle WortelBetaUpdates -bool true ;;
    off) defaults write $bundle WortelBetaUpdates -bool false ;;
  esac
  make_version $have ${from[$have]} $copy
  cp $work/appcast-after-$after.xml $feed/appcast.xml
  : > $work/requests.log
  open -g -n --env WORTEL_DATA_DIR=$data --env DO_NOT_TRACK=1 $copy
  local took="" checked=0
  for _ in {1..240}; do   # two minutes
    took=$(awk -F'\t' '$1 ~ /^\/Wortel-.*\.zip$/ {sub(/^\/Wortel-/, "", $1); sub(/\.zip$/, "", $1); print $1; exit}' $work/requests.log)
    [[ -n $took ]] && break
    if grep -q '^/appcast.xml' $work/requests.log; then
      (( checked == 0 )) && checked=$SECONDS
      (( SECONDS - checked > 15 )) && { took=none; break; }
    fi
    sleep 0.5
  done
  print ${took:-"no check"}
}
agent() { awk -F'\t' '$1 ~ /^\/appcast.xml/ {print $2; exit}' $work/requests.log }

expect() { # what, have, beta, after, want
  local got=$(offered $2 $3 $4)
  [[ $got == $5 ]] && ok "$1: offered $5" || wrong "$1: offered $got, want $5"
}

expect "a regular Mac, with betas out"            2026.48.1   unset 2026.48.4b2 none
expect "a regular Mac, at the release"            2026.48.1   unset 2026.48.4   2026.48.4
expect "today's beta (2026.48.3), at beta 1"      2026.48.3   on    2026.48.4b1 2026.48.4b1
ua=$(agent)
[[ $ua == "Wortel Beta/2026.48.3 Sparkle/"* ]] && ok "the beta's agent is \"$ua\"" || wrong "the beta's agent is \"$ua\""
expect "beta 1, at beta 2"                        2026.48.4b1 on    2026.48.4b2 2026.48.4b2
ua=$(agent)
[[ $ua == "Wortel Beta/2026.48.4 beta 1 Sparkle/"* ]] && ok "beta 1's agent is \"$ua\"" || wrong "beta 1's agent is \"$ua\""
expect "beta 1, betas turned off, at beta 2"      2026.48.4b1 off   2026.48.4b2 none
expect "the release, on the channel, betas of it out" 2026.48.4 on  2026.48.4   none
expect "the release, on the channel, at the next beta" 2026.48.4 on 2026.48.5b1 2026.48.5b1

# The question that matters: does the release replace a beta, whole?
installed() { # have, beta: offered the release, then quit, then what is on disk
  local got=$(offered $1 $2 2026.48.4)
  [[ $got == 2026.48.4 ]] && ok "$1 with betas $2: offered the release" || { wrong "$1 with betas $2: offered $got, not the release"; return; }
  # Downloaded from 127.0.0.1 at once; unzipped, checked against the key and
  # handed to Updater to install at the quit within seconds more.
  sleep 15
  osascript -e "tell application \"$copy\" to quit" >/dev/null 2>&1
  for _ in {1..120}; do [[ $(plist $copy CFBundleVersion) == 2026.48.4 ]] && break; sleep 0.5; done
  if [[ $(plist $copy CFBundleVersion) != 2026.48.4 ]]; then
    wrong "$1 with betas $2: after the quit, $copy is still $(plist $copy CFBundleVersion)"; return
  fi
  [[ $(plist $copy CFBundleShortVersionString) == 2026.48.4 && -z $(plist $copy WortelUpdateChannel) \
     && $(plist $copy CFBundleIconName) == AppIcon && $(shown_name $copy) == Wortel ]] \
    && ok "$1 with betas $2: installed 2026.48.4, named Wortel, regular icon, no channel" \
    || wrong "$1 with betas $2: installed, but it says $(plist $copy CFBundleShortVersionString), $(shown_name $copy), $(plist $copy CFBundleIconName), channel '$(plist $copy WortelUpdateChannel)'"
}
installed 2026.48.4b2 on
installed 2026.48.4b2 off

print "$failures wrong"
(( failures == 0 ))
