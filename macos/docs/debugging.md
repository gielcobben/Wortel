# Debugging

What to reach for when something doesn't behave, and the traps that have cost
an hour each. Paths are relative to `macos/`.

The rule under all of it: **measure before the second guess.** Three fixes for
"typing `wortel` launches a second app" shipped on reasoning about what the
shell should have had on its `PATH`. One dump of what it did have settled it in
a minute.

## First, which build is running

A Debug build in DerivedData and `/Applications/Wortel.app` are different apps.
On a Mac that shares its data folder with Debug builds (`building.md`) they
share one data folder and one keeper; anywhere else the Debug build keeps to
`Wortel Dev`. The Dock and Spotlight open the installed one.

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

The two PATH lines (Wortel's own `bin` first, `~/.local/bin` last) are in all
three and in the elvish file too. Test a change to them the same way: `sed`
the block out, `source` it under `env -i` with a throwaway `HOME`, and read
`$PATH` back.

They are pure classifiers, so test them without the app: extract the function
with `sed`, source it in the real shell, and run a table of command lines
against expected verdicts.

**The fish copy often cannot be run before it ships**, because fish is not on
every machine this is built on. A syntax error there breaks every fish user at
shell startup, which is worse than any bug it fixes. So keep a fish change
small, mirror the zsh version line for line, run it in fish when you can, and
say in the commit when you could not.

**They are Ghostty v1.3.1's copies, plus Wortel's hunks, plus fixes ported by
hand** from later Ghostty, never a wholesale re-vendor: upstream moved its ssh
wrapper into a `ghostty +ssh` binary that Wortel does not ship (the
`Resources/ghostty/bin/ghostty` stub answers only `+ssh-cache`). Wortel's own
hunks are marked `Wortel:` or `WORTEL:`. Ported on 2026-11-23, against the
5ebe501 pin: escape-sequence injection through a directory name (6eb24a0f0,
also applied to elvish, and to bash's title, which Wortel now prints with
control bytes removed instead of putting `\w` in PS1, because `\w` passes them
through), ssh `SendEnv COLORTERM` instead of `SetEnv` (69554f414), bash's
PROMPT_COMMAND fixes (1f3a3b41f, 2a952b4df, 4b9324f48, ed7f046ee, a4031c8e3,
591ccacbd; 4dfa44ecd was already a Wortel hunk), bash's ble.sh mark
(b1ad24e24) and zsh's trailing `%` in PS1 (43f3dc5f1). Nothing changed in shell integration from
5ebe501 to vt-1.0.2 (checked 2026-11-25). Not ported: bash-preexec
0.7.0 (5d6615fc4), zsh's `133;P` secondary prompt (3e0d434e8), and the `+ssh`
rewrite. The ssh wrappers' remote step now always runs `tic` into
`~/.terminfo`, and falls back to an entry already on the host only when it has
no `tic`, so a newer terminfo replaces an older one.

To test a change to the escape sequences, drive the real script under
`script -q /dev/null` (the integration writes to the tty, not stdout), `cd`
into a directory whose name holds a raw ESC and BEL (`$'x\e]52;c;SGk=\a'`) and
one with them as backslash text (`'y\a\e]52;c;SGk=\a'`), and look at the bytes:
nothing between `ESC ]7;` and its BEL may be a control byte.

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
| `scripts/try-keeper-loss.sh` | a change to keeper recovery. Kills a throwaway copy's keeper the way the Dock does. |
| `scripts/try-update-restart.sh` | a change to the keeper protocol, before a release that bumps it. Runs an older build (give its .app) with `pi` in a session, quits it, replaces the copy with the new build as an update does, and checks the old keeper was replaced and `pi` resumed in its conversation. |
| `scripts/try-appearance.sh` | a change to appearance handling, to dropping terminals out of sight, or a Ghostty update. Changes a throwaway copy's appearance (not the Mac's) and checks every state a terminal can be in. About a minute, on a Debug build. |
| `scripts/check-theme-reports.py` | by hand, in a real session, while changing the Mac's appearance. |
| `scripts/check-terminals.sh` | merging anything that touches a terminal: `Wortel/Ghostty/`, a terminal's host or pane, dropping terminals out of sight, the keeper, appearance, a Ghostty update. Runs the tests below that are about terminals (switching, a crash and a quit, dropped terminals, a window resize, light and dark, panes sliding) and says ok or FAILED for each. About 8 minutes. Not run as a whole on the build where the side column and the strip are splits (2026-11-26). Of its tests, the two session-switch runs with a side terminal passed there (`try-switch.sh --side --widths`, 0 of 72) before the slide and the exact size for a session out of sight went in, and nothing was run again after. |
| `scripts/try-app-crash.sh` | a change to the keeper, its channel, the snapshot restore, or dropping terminals. A stand-in agent drawing in place, a shell with 3000 lines and a program logging its sizes, through a `kill -9` of a throwaway copy, a quit, and a terminal dropped while it draws; every line must come back exactly, and no program be resized. |
| `scripts/try-switch.sh` | a change to how a pane is laid out, hosted or shown on a session switch. A Debug build switches sessions itself, 72 returns at six paces, and writes down where the terminal ended up: under the side column, at a size it was not told, or on a frame of another size. `--side` holds a terminal in the side column to the same, `--widths` gives the sessions different column widths, `--pages` says what a click lands on when a page is in front of the terminal. Since 2026-11-26 the side column is a leaf of the window's tree of splits, and `SwitchProbe` measures through the tree: it finds `SplitTreeView` above the terminal, reads the side column's frame from it, and for `--widths` drags the tree's divider beside it. Before that fix it looked for the column as a pane of the window's split view, found none, and would have called every return right: a probe that reports no faults on a layout it cannot see is the thing to check first when the views change. |
| `scripts/try-splits.sh` | a change to the splits, the side column and the strip among them: `SplitLayout`, `SplitTreeView`, `SplitLeafView`, a split's row or host, a tab drag's landing, where the keyboard goes, ⌥⌘B and ⌘J. A Debug build splits its own window in a throwaway copy, step by step, and writes down each split's frame and tabs, each terminal's view against its split and against the size it was told, and who has the keyboard; a terminal outside its split, at a size it was not told, or holding the keyboard out of sight is a fault. With no steps it runs a tour: two splits right, one down, a zoom and back, a divider drag, equalize, the keyboard by direction, a session switch away and back, a new tab, a tab moved, every split closed. Steps of your own go on the command line (`right down zoom drop:1.left`; `SplitProbe.swift` lists them). For the empty tab: `blank` is the "+" of the row you're in, `blank-right` and `blank-down` are the titlebar's two split buttons (a split with an empty tab in it), and `pick-terminal` and `pick-changes` choose that row on the empty tab's page (`GitPanelModel.fill`). They call what the click calls, not the click: the page's own keys and the buttons under a pointer are not covered. `key:<chord>` (`key:shift+cmd+f`, parts joined by `+`: `cmd`, `shift`, `ctrl`, `alt` and a letter or digit the step knows) presses a key without sending it through the system, and says who took it: "the menu", or a FAULT when the session's terminal would take it ahead of the menu or nothing takes it, which the script counts. It is the check for a new menu key (`docs/architecture/command-menus-hotkey.md`). `reset` is View ▸ Reset Layout, sent as the menu sends it: after it every terminal should be a tab of the main row, still inside its split and told its size, and Changes, History, Files and browsers in one split at the outer edge. The ones for the side column and the strip: `column` is ⌥⌘B, so it opens Changes and Files at the outer edge and, sent again, closes them (`column tab column` leaves a terminal behind in that split, which then stays); `strip` is ⌘J, so it makes the terminal below, then goes back to the main row, then to the strip again, and never closes it. Neither hides anything since the afternoon of 2026-11-26. `swap` flips the side the column opens on. It was ⇧⌥⌘B, which is no longer in any menu, so the step now calls `GitPanelModel.setColumnLeading` itself: a leftover, kept for checking that a column on the left still lays out and that the leftmost titlebar row clears the window's controls. `sidebar` hides or shows the sidebar (so the leftmost titlebar row has to make room for its controls), and `resize:<w>x<h>` takes the window to that size in twenty steps, which is how to see that every split keeps its share. `column right` is ⌘D from the side column, and `drop:<n>.<where>` counts the side column and the strip among the splits, in reading order. Opening with `column` or `strip` slides, and the probe waits 1.2 s after each step, so what it writes down is the layout after the slide has landed and the held resize was let go. The script deletes its copy's defaults before each run: they go by bundle id and outlive the copy, and a sidebar an earlier run had hidden (`sidebar`) started the next run hidden. `--relaunch` quits the copy as a person does, starts it again and checks the same splits are back with the same tabs. `--picture` leaves the window as its views draw it in `$TMPDIR/wortel-splits.png` (terminals come out as their page colour; it is for the rows, tabs and dividers). `--keep` leaves the copy running. Needs the display awake. |
| `scripts/bench-resize.sh` | a change to anything in the window that follows its size. What a step of a resize costs the main thread, against the 8.3 ms a frame lasts. `--column` adds the side column and a divider drag, `--panes` times the column and the sidebar sliding open and shut and checks the terminal took its one size after. Since 2026-11-26 the side column is a split of the window's tree and `ResizeBench` reads the tree: it finds `SplitTreeView` above the terminal, takes the divider on the side column's inner edge and moves it with `SplitTreeView.moveDivider(_:to:)` (Debug only), and `--panes` times the tree's own slide for the column. Sizes are shares, so the side column now changes width at every step of a window round, where it used to keep it: the count of those steps is every step, not 0. At first that day the bench still looked for the column among the panes of the window's split view, found none and left the divider round out without saying so. Not run since it was mended. |
| `scripts/try-hidden-resize.sh` | a change to how a terminal out of sight is sized. Resizes a copy's window like a drag, twice; a hidden session must be given one size after each, the shown one's. With `HIBERNATE_AFTER=2`, the hidden one has no surface by then and follows through the keeper. |
| `scripts/symbolicate.sh` | reading a crash: turns the offset a crash report carries back into a function and line, from that release's archived dSYM. |
