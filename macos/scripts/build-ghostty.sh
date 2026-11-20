#!/bin/bash
#
# Build Ghostty from source: GhosttyKit.xcframework (the app's renderer and
# runtime) and ghostty-vt.xcframework (the keeper's headless terminal), from
# the one patched tree, into macos/GhosttyKit/Frameworks/.
#
# Why from source, and why both at once: the keeper keeps each session's
# terminal and hands the app a snapshot of it, and the snapshot format is only
# defined within one Ghostty commit. Building both from the same checkout,
# with the same patches, is what makes the snapshot exact.
#
# The inputs are tracked in macos/GhosttyKit/: ghostty.ref (Ghostty commit),
# spm.ref (libghostty-spm commit, whose build scripts and patch stack are
# used), zig.version, and Patches/ (Wortel's patches, applied after
# libghostty-spm's). A build is cached by a hash of all of them, shared by
# every checkout on this Mac, so a second worktree costs a copy, not a build.
#
#   scripts/build-ghostty.sh            build if needed, then install
#   scripts/build-ghostty.sh --force    build even if a cached one exists
#
# Needs Zig (zig.version) and Xcode's Metal toolchain
# (xcodebuild -downloadComponent MetalToolchain). A full build is about
# four minutes on Apple silicon.

set -euo pipefail

cd "$(dirname "$0")/.."
PKG="$PWD/GhosttyKit"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

ref() { tr -d '[:space:]' < "$PKG/$1"; }
GHOSTTY_REF=$(ref ghostty.ref)
SPM_REF=$(ref spm.ref)
ZIG_WANTED=$(ref zig.version)

if ! command -v zig >/dev/null 2>&1; then
    echo "[!] Zig $ZIG_WANTED is needed: brew install zig" >&2
    exit 1
fi
if [ "$(zig version)" != "$ZIG_WANTED" ]; then
    echo "[!] Zig $ZIG_WANTED is needed, found $(zig version)" >&2
    exit 1
fi

CACHE="${WORTEL_GHOSTTY_CACHE:-$HOME/Library/Caches/sh.wortel.ghostty}"
SRC="$CACHE/src"
KEY=$(
    {
        echo "$GHOSTTY_REF" "$SPM_REF" "$ZIG_WANTED"
        for p in "$PKG"/Patches/*; do echo "$(basename "$p")"; cat "$p"; done
        cat "$0"
    } | shasum -a 256 | cut -c1-16
)
OUT="$CACHE/builds/$KEY"
DEST="$PKG/Frameworks"

install_build() {
    rm -rf "$DEST"
    mkdir -p "$DEST"
    cp -Rc "$OUT/GhosttyKit.xcframework" "$OUT/ghostty-vt.xcframework" "$DEST/"
    echo "$KEY" > "$DEST/.key"
    echo "[*] Ghostty $KEY installed in $DEST"
}

if [ "$FORCE" -eq 0 ] && [ "$(cat "$DEST/.key" 2>/dev/null)" = "$KEY" ]; then
    echo "[*] Ghostty $KEY is up to date"
    exit 0
fi
if [ "$FORCE" -eq 0 ] && [ -f "$OUT/.complete" ]; then
    install_build
    exit 0
fi

# One build at a time across checkouts: they share the source trees.
mkdir -p "$CACHE"
LOCK="$CACHE/lock"
until mkdir "$LOCK" 2>/dev/null; do
    echo "[*] waiting for another Ghostty build ($(cat "$LOCK/pid" 2>/dev/null || echo '?'))"
    sleep 5
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# Another checkout may have built this key while we waited.
if [ "$FORCE" -eq 0 ] && [ -f "$OUT/.complete" ]; then
    install_build
    exit 0
fi

checkout() { # <dir> <url> <ref>
    if [ ! -d "$1/.git" ]; then
        git clone --quiet "$2" "$1"
    fi
    if ! git -C "$1" cat-file -e "$3^{commit}" 2>/dev/null; then
        git -C "$1" fetch --quiet --tags --force origin
    fi
    # The patch stack edits the tree in place; start from the commit itself.
    git -C "$1" reset --quiet --hard "$3"
    git -C "$1" clean --quiet -fdx
}

mkdir -p "$SRC"
checkout "$SRC/libghostty-spm" https://github.com/Lakr233/libghostty-spm "$SPM_REF"
checkout "$SRC/ghostty" https://github.com/ghostty-org/ghostty "$GHOSTTY_REF"
cp "$PKG"/Patches/* "$SRC/libghostty-spm/Patches/ghostty/"

started=$(date +%s)
echo "[*] GhosttyKit: Ghostty ${GHOSTTY_REF:0:9}, libghostty-spm ${SPM_REF:0:9}, Zig $ZIG_WANTED"
(
    cd "$SRC/libghostty-spm"
    BUILD_CACHE_ROOT="$CACHE/zig-cache" ./build.sh --source "$SRC/ghostty" --platforms macos --skip-tests
) > "$CACHE/build-kit.log" 2>&1 || {
    tail -30 "$CACHE/build-kit.log" >&2
    echo "[!] GhosttyKit failed; the whole log is $CACHE/build-kit.log" >&2
    exit 1
}

# The patch stack is applied by now, so libghostty-vt is built from exactly
# the tree GhosttyKit was.
echo "[*] libghostty-vt"
(
    cd "$SRC/ghostty"
    zig build -Demit-lib-vt -Demit-xcframework=true -Doptimize=ReleaseFast
) > "$CACHE/build-vt.log" 2>&1 || {
    tail -30 "$CACHE/build-vt.log" >&2
    echo "[!] libghostty-vt failed; the whole log is $CACHE/build-vt.log" >&2
    exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT"
cp -Rc "$SRC/libghostty-spm/BinaryTarget/GhosttyKit.xcframework" "$OUT/"
cp -Rc "$SRC/ghostty/zig-out/lib/ghostty-vt.xcframework" "$OUT/"
touch "$OUT/.complete"
echo "[*] built in $(( $(date +%s) - started )) s"
install_build
