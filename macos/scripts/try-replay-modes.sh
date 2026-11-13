#!/bin/zsh
# Does a terminal mode declared while nothing was attached, and then pushed
# out of the keeper's replay, survive a reattach?
#
#   scripts/try-replay-modes.sh [path/to/Wortel.app]
#
# This is what a fullscreen agent does when Wortel resumes it in a session
# nobody is looking at: it turns on the alternate screen, the mouse and the
# keyboard protocol, then reprints a long conversation. Before the replay read
# the modes out of what it drops, the reattached terminal had none of them, and
# scrolling and selecting in Codex did nothing (docs/incidents.md, 2026-10-21).
#
# Runs a throwaway copy beside yours, never your Wortel: its own bundle id, its
# own data folder and keeper, telemetry off. A small program in a session of
# the copy waits for the copy to quit, declares the modes, writes 1.2 MB after
# them, and once the copy is back asks the terminal which modes it has
# (DECRQM, and the keyboard flags). Passes when all five are set and the flags
# are not zero.
#
# Needs the screen unlocked: with it locked there is no display, libghostty
# cannot make a surface, and nothing answers. Run it before releasing a change
# to Wortel/Keeper/ReplayBuffer.swift or Wortel/Ghostty/TerminalModes.swift.
set -u

here=${0:A:h}/..
src=${1:-}
if [[ -z $src ]]; then
  src="$(xcodebuild -project "$here/Wortel.xcodeproj" -scheme Wortel -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')/Wortel.app"
fi
[[ -d $src ]] || { print -u2 "no app at $src"; exit 2 }

locked=$(swift -e 'import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]; print((d["CGSSessionScreenIsLocked"] as? Int) ?? 0)' 2>/dev/null)
[[ $locked == 1 ]] && { print -u2 "the screen is locked; unlock it and run again"; exit 2 }

base=$HOME/.wrm-$$                       # short: the sockets live here
copy=$base/WortelRM.app data=$base/d p=$base/p
# Every pid under $1, and $1.
tree() {
  ps -axo pid=,ppid= | awk -v root=$1 '{p[$1]=$2} END {s[root]=1
    for (n = 0; n < 8; n++) for (x in p) if (p[x] in s) s[x]=1
    for (x in s) printf "%s ", x}'
}
cleanup() {
  for a in $(pgrep -f "$copy/Contents/MacOS/Wortel"); do kill $a 2>/dev/null; done
  sleep 1
  for k in $(pgrep -f "$copy/Contents/Resources/bin/wortel-keeper"); do kill -9 $(tree $k) 2>/dev/null; done
  rm -rf "$base"
}
waitfor() { local s=$1; shift; for _ in $(seq 1 $((s * 2))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1 }

mkdir -p "$data" "$p"
cp -Rc "$src" "$copy"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.gielcobben.Wortel.replaytest' "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null

cat > "$base/probe.py" <<'PY'
import os, sys, tty, termios, time, select
d = sys.argv[1]
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
def w(s): os.write(1, s.encode())
def ask(q, end):
    w(q); buf = b""; t = time.time() + 2
    while time.time() < t and not buf.endswith(end):
        if select.select([fd], [], [], 0.2)[0]: buf += os.read(fd, 4096)
    return buf.decode(errors="replace").replace("\x1b", "ESC")
try:
    open(f"{d}/started", "w").close()
    while not os.path.exists(f"{d}/go"): time.sleep(0.2)
    # What a fullscreen agent declares at startup, while nobody is attached.
    w("\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[>7u")
    # Then more output than the keeper's replay keeps.
    line = "x" * 78 + "\r\n"
    for _ in range(16000): w(line)
    open(f"{d}/flooded", "w").close()
    while not os.path.exists(f"{d}/ask"): time.sleep(0.2)
    while select.select([fd], [], [], 0.3)[0]: os.read(fd, 4096)
    res = []
    for m in (1049, 1000, 1002, 1003, 1006):
        res.append(f"?{m}: {ask(f'{chr(27)}[?{m}$p', b'$y')}")
    res.append(f"keyboard flags: {ask(chr(27) + '[?u', b'u')}")
    open(f"{d}/result", "w").write("\n".join(res) + "\n")
finally:
    w("\x1b[<u\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?1049l")
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
PY

W="$copy/Contents/Resources/bin/wortel"
launch() { open -g -n --env WORTEL_DATA_DIR="$data" --env DO_NOT_TRACK=1 "$copy" }
launch
waitfor 20 pgrep -f "$copy/Contents/MacOS/Wortel" || { print "FAIL: the copy did not start"; cleanup; exit 1 }
waitfor 20 env WORTEL_DATA_DIR="$data" "$W" list || { print "FAIL: the copy never answered its command"; cleanup; exit 1 }
WORTEL_DATA_DIR="$data" "$W" new --cwd "$p" -- python3 "$base/probe.py" "$p" >/dev/null 2>&1
waitfor 30 test -e "$p/started" || { print "FAIL: the probe never started"; cleanup; exit 1 }

# Quit it properly, by path: a kill skips the save, and the session is then
# gone from sessions.json when the copy comes back.
app=$(pgrep -f "$copy/Contents/MacOS/Wortel" | head -1)
osascript -e "tell application \"$copy\" to quit" 2>/dev/null
waitfor 15 zsh -c "! kill -0 $app 2>/dev/null" || { print "FAIL: the copy would not quit"; cleanup; exit 1 }

touch "$p/go"
waitfor 60 test -e "$p/flooded" || { print "FAIL: the flood never finished (is the keeper draining?)"; cleanup; exit 1 }
sleep 1
launch
waitfor 20 pgrep -f "$copy/Contents/MacOS/Wortel" || { print "FAIL: the copy did not come back"; cleanup; exit 1 }
sleep 8
touch "$p/ask"
waitfor 30 test -e "$p/result" || { print "FAIL: the terminal never answered (was the session attached?)"; cleanup; exit 1 }

print "$(defaults read "$copy/Contents/Info" CFBundleVersion 2>/dev/null):"
cat "$p/result"
set=$(grep -c ';1\$y' "$p/result")
flags=$(grep 'keyboard flags' "$p/result" | grep -o '[0-9]*u' | tr -d u)
cleanup
if [[ $set == 5 && ${flags:-0} != 0 ]]; then print "PASS"; exit 0; fi
print "FAIL: $set of 5 modes set, keyboard flags ${flags:-none}"
exit 1
