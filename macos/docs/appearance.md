# Light and dark

What follows the Mac's appearance, by which road, and what cannot. Read this
before touching anything that tells a terminal, a program or a layer whether
it is light or dark.

## Who follows what

| What you see | Drawn by | Follows because |
| --- | --- | --- |
| The window, sidebar, tabs, panels | AppKit and SwiftUI | Dynamic `NSColor`s (`Chrome`, the system's), resolved at draw time |
| The page behind the terminal | AppKit (`Chrome.content`) | The same. The terminal draws no background of its own (`background-opacity = 0`) |
| The terminal's text, cursor, selection and its 256 palette colours | libghostty | `theme = light:…,dark:…` in `wortel.conf`, switched by `GhosttyRuntime.syncColorScheme` |
| What a program paints with palette colours ("ANSI green") | libghostty | They are the palette |
| What a program paints with its own 24-bit colours | The program | Only if the program repaints. See "What Wortel cannot do" |

The second and third rows are two systems that have to agree. When they
don't, it is light text on a white page.

## The rule

**One source, one place.** Light or dark is `NSApp.effectiveAppearance`
(`GhosttyRuntime.systemIsDark`), and the only code that tells libghostty is
`GhosttyRuntime.syncColorScheme`. It tells the app handle and then every
terminal view there is, from a list each view joins when it is made.

It is safe to call at any time, as often as wanted: libghostty does nothing
for a scheme it already has. So everything that could have missed a change
calls it, and nothing else decides anything:

- the app's appearance changing (KVO on `NSApp.effectiveAppearance`), which is
  the real notice;
- a terminal being made, woken from hibernation, restarted, or joining the
  window;
- a view's `viewDidChangeEffectiveAppearance`, as a second witness;
- the app becoming active, the Mac or the display waking, the screen being
  unlocked (`com.apple.screenIsUnlocked`; NSWorkspace has no notice for it),
  the user being switched back to.

The last group is insurance. macOS on Auto changes appearance only after the
Mac has been idle for a while, so the change tends to land as the display
sleeps or the screen locks. Nothing found says a notice is lost then, in our
testing or in any other terminal's tracker, and each of these costs one
comparison. A change found by one of them rather than by the notice is logged
as an error under the `appearance` category, so if it ever happens it is seen.

Not used, on purpose:

- **A view's own `effectiveAppearance`.** It is not told at all while the view
  is outside a window, and it moves when a window is given an appearance of
  its own. Ghostty.app decided from it until its PR #9360 and stopped for that
  reason.
- **The `AppleInterfaceStyle` default.** Absent in light mode and late or stale
  under Auto.

## What was wrong (measured 2026-11-19)

Light and dark reached a terminal by two roads: the app's appearance told the
app handle, and each view's `viewDidChangeEffectiveAppearance` told its own
surface. Measured on a test copy with a probe in each session and Claude Code
2.1.328 under a byte logger:

1. **A terminal not yet in the window was never told.** Every session gets a
   terminal at launch and joins the window when first shown. After a change,
   every session not looked at since launch kept the old theme, and its
   program was not told, until it was shown.
2. **Every program that listens was first told the old theme.** The app road
   ran first and re-applied the config to surfaces still holding the old
   scheme, and libghostty ends every config change with a `?997` report. So a
   change to dark sent `light, dark, dark`. Claude Code answered the first by
   asking the background colour and got the old one. It came right on the
   later reports, in the tests. Upstream has the same three reports
   (ghostty discussion #15116).
3. **A hibernated screen was saved in the colours of the day** and kept them.
   See below.
4. **A hibernated agent's terminal woke without the modes it had been assumed
   to have.** A reattach put a running agent's startup modes into the new
   terminal but did not write them down; hibernation takes its prelude from
   what is written down. `TerminalModeRecorder.assume` now records them.
5. **The image preview's backing** was a `cgColor` taken once.

Now a change sends each program `dark, dark` and nothing else, every terminal
changes at once whether or not it has ever been shown, and a session started
after a change comes up in the new theme.

## What a program hears

A program that turned on `?2031` gets `CSI ? 997 ; 1 n` (dark) or `; 2 n`
(light). The order inside libghostty, for one surface:

1. `ghostty_surface_set_color_scheme` sets the surface's scheme and raises a
   soft `RELOAD_CONFIG`.
2. Wortel answers it **synchronously** with `ghostty_surface_update_config`
   (`GhosttyRuntime.handleAction`). The new colours are queued to the IO
   thread.
3. libghostty queues the report behind them, and the config change queues a
   second one. Hence two.

Step 2 being synchronous is what keeps the order. Most programs treat the
report as "ask again" and read the background through OSC 11 (Claude Code,
Pi, opencode, neovim, lazygit and tmux do), so the colours have to be in
place first (`../../docs/incidents.md`, 2026-10-20).

The app-level `RELOAD_CONFIG` is answered with nothing. `ghostty_app_update_config`
re-applies the config to every surface with the scheme that surface still
holds, which is where the report naming the old theme came from, and it is a
second reload of every surface per change. A new surface takes its scheme
from the app handle's state, not from a config the app holds (`Surface.init`
in Ghostty 1.3.1), so nothing is lost. **Check this again when libghostty is
updated**: `scripts/try-appearance.sh` fails if a new session comes up in the
old theme.

A resumed or woken session whose program listens is also sent one report, of
the appearance now (`docs/terminal-modes.md`).

## Hibernated screens

A terminal's cells hold two kinds of colour: a place in the palette, which
follows light and dark, and a fixed 24-bit colour. libghostty's screen dump
writes palette cells as the 24-bit value they have at that moment, and the
binding gives no way to ask otherwise. Written back on waking, a prompt saved
in dark was the dark theme's green for good, and the dark theme's white on a
white page cannot be read.

`SnapshotPalette` swaps the palette for 256 marker colours just before the
dump (`OSC 4`, on the pty's queue) and turns the markers back into palette
indices before the dump is written into the new terminal. A terminal that
turns out not to hibernate gets its palette back (`OSC 104`).

Known limit: a palette entry a program changed itself (`OSC 4`) is the theme's
again after a hibernation, and after one that was called off at the last
moment (the session selected between the markers going in and the dump), since
`OSC 104` gives back the theme's palette and not the program's.

## Readable, whatever was painted

`minimum-contrast = 2` in `wortel.conf`. Where text and what is behind it are
closer than that, libghostty draws the text black or white, whichever reads.

It is for the programs in the "no" rows below. Codex blends its input box from
the background it read at startup; after a change that band is the old theme's
and what you type in it is the new theme's text, near-white on near-white
(seen in a test copy, 2026-11-19). With the floor the band is still the wrong
colour and the text can be read.

Two and no higher, measured the same day: the faintest colours meant to be
seen are the dark theme's black on its page (2.28), Codex's orange on white
(2.67) and Claude Code's grey on white (2.85), and the unreadable pairs are at
1.1. At 3 the floor starts redrawing colours somebody chose.

## What Wortel cannot do

A terminal cannot recolour what a program painted with its own 24-bit colours,
and cannot make a program look again. Read from each project's source or
tracker on 2026-11-19:

| Program | Follows a change while running |
| --- | --- |
| Claude Code | With its theme on Auto: yes, for what it draws from then on. What it has already drawn can keep its colours (its tracker has this open). With a fixed theme: no |
| Codex | No. It reads the colours once, at startup, and has no `?2031`. Restarted, below |
| Pi, opencode | Yes, with their system theme |
| neovim, lazygit, tmux, zellij | Yes |
| vim, bat, delta, fzf, shell prompts | No. One look at startup, or configuration only |

For a program in the "no" rows the answer is a new process. Nothing a terminal
sends changes that: a resize does not (both Claude Code's and Pi's trackers
say so), neither do focus reports, and neither does a new terminal (tried: a
relaunched test copy gave Codex a fresh terminal, and it drew the old band
into it). Codex keeps the colours it read at startup for the life of the
process.

So Wortel gives an agent a new process, when that costs nothing: see the
next section. Anything else in the "no" rows stays readable (above) and is put
right by restarting it by hand.

Also not Wortel's: a colour a program set with `OSC 10` or `OSC 11` stays
until the program resets it, across a change of theme.

## Agents that are restarted

Claude Code and Codex (`AgentSleep.repaintAgents`). The decision, why these
two and what was seen are in `../../docs/decisions.md` (2026-11-19); the code
is deep sleep's (`architecture/sessions.md`), with a second reason to end an
agent.

- **Painted for the other appearance** is `Session.agentPaintedDark`, the
  appearance when the agent started, against `GhosttyRuntime.isDark`. Saved
  with the session, because an agent outlives a quit.
- **At a change** (`GhosttyRuntime.appearanceDidChange`, posted once every
  terminal has been told) each such agent is looked at once, from one process
  table (`SessionManager.appearanceChanged`). At rest and out of sight for
  `repaintAfter` (20 s): ended, and resumed when its session is selected. In
  front: ended and resumed at once, when it has rested 5 s. Otherwise a timer
  for when it may.
- **Left alone:** working, waiting on an answer, something running under it,
  Remote Control on, or text gone in since it last set to work (a key going
  down, a paste, a drop, a script's text: `SurfaceView.onTextInput`. A click,
  a scroll, a key coming up, a modifier alone and a copy are not text).
  Looked at again when it stops working or its session is left. In front it
  is only ever restarted at the change itself: one that could not be then (at
  work, say) is not restarted under the answer it gives next, and nor is one
  in which anything has happened since.
- **At rest** is the agent's own word: Claude Code's record of itself, Codex's
  status report (`idle` or `done` with nothing blocked and no piece of work
  still going). An agent that says nothing is never ended: a Codex older than
  0.164.
- **The terminal is put right by Wortel**, before the signal
  (`TerminalModes.undo`): Codex is gone the moment it is signalled and would
  leave the shell on the alternate screen with the mouse reported.

Why an agent was or was not restarted is in the log:

```sh
/usr/bin/log show --last 1h --info --predicate 'process == "Wortel" AND category == "sleep"'
```

There is no script for this part. It takes real agents, their accounts and a
conversation on disk to come back to. By hand, in a copy (the `test-copy`
skill) started with `WORTEL_REPAINT_AFTER=8`: an agent in each of two
sessions, one turn each, then change the copy's appearance as below and read
the log.

## Checking it

```sh
scripts/try-appearance.sh          # about a minute, on a Debug build
```

It runs a throwaway copy with a probe in each session, changes that copy
between light and dark, and reads what each terminal answered and what each
program was told: on screen, out of sight, never shown since launch, started
after the change, and hibernated. Run it after any change here and after a
libghostty update.

A Debug build can be told its appearance without touching the Mac's
(`AppearanceTestHook`), which is what the script uses. By hand, for a copy
whose pid you know:

```sh
osascript -l JavaScript -e 'ObjC.import("Foundation");
  $.NSDistributedNotificationCenter.defaultCenter
   .postNotificationNameObjectUserInfoDeliverImmediately(
     "sh.wortel.test.appearance.<pid>", "dark", $(), true)'
```

`dark`, `light`, or `system` to hand it back. `scripts/check-theme-reports.py`
is the probe to run by hand in a real session while changing the Mac's
appearance; `scripts/appearance-probe.py` is the one the script uses.

What the script cannot reach, and nothing here has tested: a change that
happens while the Mac is asleep or the screen is locked.

## A new layer colour

A `cgColor` is a fixed colour. Set one in `updateLayer` or in
`viewDidChangeEffectiveAppearance`, inside
`effectiveAppearance.performAsCurrentDrawingAppearance`, never once at
creation. `FilledView` does it for a plain fill.
