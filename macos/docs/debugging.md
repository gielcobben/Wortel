# Debugging

What to reach for when something doesn't behave, and the traps that have cost
an hour each. Paths are relative to `macos/`.

The rule under all of it: **measure before the second guess.** Three fixes for
"typing `wortel` launches a second app" shipped on reasoning about what the
shell should have had on its `PATH`. One dump of what it did have settled it in
a minute.

## First, which build is running

A Debug build in DerivedData and `/Applications/Wortel.app` are different apps
that share one data folder and one keeper. The Dock and Spotlight open the
installed one.

```sh
ps -axo pid=,comm= | grep Wortel          # which bundle the running app is
defaults read /Applications/Wortel.app/Contents/Info CFBundleVersion
```

For any "no spinner" or "no dot" report, confirm the version first.

## Nothing draws, or there are no sessions

- **Is the screen locked?** With no display libghostty cannot make a
  Metal-backed surface. Every terminal is blank, no surface reads its pty, and
  shells block on output. That is not a bug in Wortel.

  ```sh
  ioreg -n Root -d1 -r -w0 | grep -c ScreenIsLocked
  ```

- **Is there a window?** An exception during launch is swallowed by AppKit and
  the app runs on with no window. A live pid proves nothing. Look for an
  on-screen window (`CGWindowListCopyWindowInfo`, `kCGWindowIsOnscreen`), and
  `sample <pid> 1` showing `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`
  means setup threw.
- **Blank terminals from a fresh worktree's build** were seen once (2026-09-29)
  with the same commit drawing fine from another folder. The cause was never
  found. If it comes back, suspect something at runtime that depends on where
  the build lives, and make sure a release build draws before it is published.

## Busy state and attention

Every busy and attention decision is logged at debug level, which is not kept
on disk. `log show` returns nothing afterwards. Stream it live:

```sh
/usr/bin/log stream --level debug --style compact \
  --predicate 'subsystem == "com.gielcobben.Wortel" AND category == "agent-status"'
```

- Spell it `/usr/bin/log`. zsh has a `log` builtin that shadows it.
- Start the stream against an app that is already running. A stream opened
  before a relaunch has gone silent for the whole subsystem. Don't plan a check
  that relaunches the app and reads its debug log in one sitting.
- An agent's marker is in `~/Library/Application Support/Wortel/agents/<session id>`
  only while the agent runs. Look during a turn, never after.
- For a turn long enough to watch, ask the agent to run `sleep 40 && echo done`.
- `agents/exits.log` records how agents ended. A status of 129 or more is a
  signal. Claude exits 0 on SIGHUP.
- What to read, in order, for "no notification": `status …` (what the agent
  reported), `attention … kind=` (what that came to), `attention raised …
  banner= sound=` or `attention not raised` (whether it went out), and
  `banner handed to Notification Center … allowed= banners=` (what macOS made
  of it). A program's own words are never in these lines.
- `scripts/verify-agent-status.py` runs all of this against stand-in agents in
  a throwaway copy, and reads these lines to judge it.

The full map of signals per agent is `docs/agent-signals.md`.

## What a session's shell has in its environment

`ps -E` prints nothing useful for a shell: it is an Apple platform binary and
the kernel withholds its environment.

- **For a program that is not Apple's** (node, bun, deno, a Homebrew python):
  `sysctl(CTL_KERN, KERN_PROCARGS2, pid)` returns the arguments and then the
  environment it was `exec`ed with. `ProcessTable.sessionTag` reads
  `WORTEL_SESSION_ID` this way.
- **For the shell itself, after `.zshrc`**: add a dump to the bundled zsh
  integration, rebuild, relaunch and open a new session. Shells that were
  already running are held by the keeper across the relaunch and do not run it
  again. Remove it before committing.

  ```sh
  # Resources/ghostty/shell-integration/zsh/ghostty-integration,
  # inside _ghostty_deferred_init
  { builtin print -r -- "PATH=$PATH"
    builtin print -r -- "wortel=$(command -v wortel 2>/dev/null)"
  } > "/tmp/wortel-path-dump.$$" 2>/dev/null
  ```

## The shell integration is three copies

`zsh/ghostty-integration`, `bash/ghostty.bash` and
`fish/vendor_conf.d/ghostty-shell-integration.fish`, under
`Resources/ghostty/shell-integration/`. A change to busy or agent detection
goes into all three, in both the interactive classifier (the synthetic spinner)
and the agent classifier (the resume marker).

They are pure classifiers, so test them without the app: extract the function
with `sed`, source it in the real shell, and run a table of command lines
against expected verdicts.

**The fish copy often cannot be run before it ships**, because fish is not on
every machine this is built on. A syntax error there breaks every fish user at
shell startup, which is worse than any bug it fixes. So keep a fish change
small, mirror the zsh version line for line, run it in fish when you can, and
say in the commit when you could not.

## A permission that is on and still refused

Screen Recording, Accessibility or Full Disk Access shows as granted in System
Settings, and the call is refused. The grant was made to an ad-hoc or dev build
and is pinned to that binary's hash; the installed app is signed differently and
matches nothing.

```sh
db="/Library/Application Support/com.apple.TCC/TCC.db"   # reading it needs Full Disk Access
sqlite3 "$db" "select service from access where client='com.gielcobben.Wortel'"
sqlite3 "$db" "select hex(csreq) from access where client='com.gielcobben.Wortel' \
  and service='kTCCServiceScreenCapture'" | xxd -r -p | csreq -r - -t
# a requirement that is a bare cdhash is the stale one
```

The fix is to remove Wortel from the list with the minus button and add
`/Applications/Wortel.app` again. A shell inside Wortel is judged by Wortel's
grants, because the keeper makes Wortel its responsible app.

## Light on dark, or dark on light

`docs/appearance.md` says what follows the appearance and by which road. Start
with `scripts/try-appearance.sh`: it changes a throwaway copy between light and
dark and reads what every terminal answered and what every program was told.
If it passes, the terminal is right and the question is the program: Codex
never looks again, and Claude Code leaves what it has already drawn.

An agent that paints a light diff on a dark screen is judging the background
through OSC 11. `scripts/check-theme-reports.py` is the probe to run by hand in
a real session while changing the Mac's appearance (`../docs/incidents.md`,
2026-10-20). A change that nobody announced and a second look found is logged
as an error:

```sh
/usr/bin/log show --last 1d --predicate 'process == "Wortel" AND category == "appearance"'
```

An agent still in the old colours after a change was not restarted, and the
`sleep` category says why (`docs/appearance.md`, "Agents that are restarted"):
`held` is text typed, something running under it, a question or Remote
Control; `restUnknown` is an agent that does not say it is idle, which for
Codex means older than 0.164.

## Modes after a reattach

To see which terminal modes a surface has without driving the UI, have a program
in the session ask for them: DECRQM (`CSI ? n $ p`) and `CSI ? u`. Ghostty
answers on the pty. `docs/terminal-modes.md` has the rest.

## Packages won't resolve in a new worktree

"Revision … for libghostty-spm … does not match previously recorded value": the
package's `1.2.9` tag is re-pointed upstream, and SwiftPM's fingerprint pins the
revision it first saw. Deleting the fingerprint accepts new binary content
without anyone looking at it. Build against a copy of packages that already
resolved instead:

```sh
cp -Rc <an existing DerivedData>/SourcePackages /tmp/wortel-sp
xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug \
  -clonedSourcePackagesDirPath /tmp/wortel-sp build
```

`../scripts/check.sh` takes the same flag through `XCODEBUILD_FLAGS`. Moving to
the newer revision is a decision for the maintainer, and goes through
`Package.resolved` (`docs/building.md`).

## The scripts that test against a real machine

| Script | Run it before |
| --- | --- |
| `scripts/verify-running-jobs.py` | releasing a change to `Wortel/Processes/`. 44 real spawn shapes, about 5 minutes. Add a shape when a new miss is found, not only a fixture. |
| `scripts/try-git.sh` | a release touching `Wortel/Git/`. Builds a repo with every situation the panel handles, and a checklist. |
| `scripts/try-replay-modes.sh` | a change to the keeper's replay or to `TerminalModes`. Declares a fullscreen agent's modes while a throwaway copy is quit, floods past the replay, and asks the reattached terminal which modes it has. |
| `scripts/try-keeper-loss.sh` | a change to keeper recovery. Kills a throwaway copy's keeper the way the Dock does. |
| `scripts/try-appearance.sh` | a change to appearance handling, to hibernation, or a libghostty update. Changes a throwaway copy's appearance (not the Mac's) and checks every state a terminal can be in. About a minute, on a Debug build. |
| `scripts/check-theme-reports.py` | by hand, in a real session, while changing the Mac's appearance. |
| `scripts/symbolicate.sh` | reading a crash: turns the offset a crash report carries back into a function and line, from that release's archived dSYM. |
