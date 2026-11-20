# Light and dark

What follows the Mac's appearance, by which road, and what cannot. Read this
before touching anything that tells a terminal, a program or a layer whether
it is light or dark.

## Who follows what

| What you see | Drawn by | Follows because |
| --- | --- | --- |
| The window, sidebar, tabs, panels | AppKit and SwiftUI | Dynamic `NSColor`s (`Chrome`, the system's), resolved at draw time |
| The page around the terminal | AppKit (`Chrome.content`) | The same |
| The page under the terminal's text | libghostty, in the theme's `background` | The bundled themes' backgrounds are the page's two colours (`PageColourTests`) |
| The terminal's text, cursor, selection and its 256 palette colours | libghostty | `theme = light:…,dark:…` in `wortel.conf`, switched by `GhosttyRuntime.syncColorScheme` |
| What a program paints with palette colours ("ANSI green") | libghostty | They are the palette |
| What a program paints with its own 24-bit colours | The program | Only if the program repaints. See "What Wortel cannot do" |

The page is drawn twice, by AppKit around the terminal and by libghostty
under it, in the same colour. The terminal draws it so that the contrast
floor has the page to measure against (below). AppKit and libghostty have to
agree on light and dark as well: when they don't, it is light text on a
white page.

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
- a terminal being made, restored after being dropped, restarted, or joining
  the window;
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

A program that listens is told by the keeper, not by its surface (below).

## Dropped terminals, and the keeper

The keeper keeps every session's terminal and is the one that answers a
program (`docs/architecture/keeper.md`). So it is told what the app shows
(`KeeperCommand.appearance`: light or dark, the theme's colours, read from the
same files libghostty reads, `TerminalTheme`) when it connects and at every
change. A program that listens (`?2031`) is sent the report by the keeper,
whether its terminal has a surface in the app or not, and a change made while
the app was not running is reported when it next connects. A terminal dropped
out of sight is restored from a snapshot, which keeps each cell's colour as
it is: a palette cell stays a palette cell and follows light and dark. The
`SnapshotPalette` markers this section used to describe are gone.

## Readable, whatever was painted

`minimum-contrast = 1.9`: text below that contrast with what is under it is
drawn black or white instead. It is the floor under everything a change of
appearance leaves behind, in any program, whether or not an agent is
restarted (Remote Control, a question waiting, text typed).

It works only because the terminal draws the page itself
(`background-opacity = 1`). libghostty measures a cell's text against the
cell's own background, or else the terminal's background premultiplied by
its opacity (`cell_text_vertex` in Ghostty 1.3.1's `shaders.metal`). At
opacity 0 that is black: on 2026-11-19 a floor of 2 over a transparent
terminal turned all of the light theme's ordinary text white on the white
page, and was taken out. `PageColourTests` fails if a floor is set over a
background that is not opaque.

Why 1.9, measured against the real pages (`#FFFFFF`, `#1F1F1F`) on
2026-11-19:

| | Contrast |
| --- | --- |
| Claude Code's light text colour left on the dark page | 1.27 |
| Its dark text colour left on the light page | 1.00 |
| Its dark warning and permission colours left on the light page | 1.63, 1.88 |
| GitHub Dark's black (palette 0) on the dark page | 1.99 |
| Claude Code's `subtle`, on its own page | 2.04, 2.19 |
| Plain text in either theme | 14 and up |

The first three are redrawn, the rest are left as they were chosen. A
coloured band a program left (Codex's input box, a diff line) keeps its
colour; the text on it is measured against the band.

What the floor does not do: put the colours right. A light theme's grey on
the dark page (2.87) stays that grey, a light band stays light. That is the
program's to repaint, or a restart's (below).

## What Wortel cannot do

A terminal cannot recolour what a program painted with its own 24-bit colours,
and cannot make a program look again. Read from each project's source or
tracker on 2026-11-19:

| Program | Follows a change while running |
| --- | --- |
| Claude Code, fullscreen (`tui: fullscreen`) | With its theme on Auto: yes, all of it. On the report it repaints every cell it coloured, and a hibernated one when its terminal wakes (measured in a copy, 2.1.329). Not restarted, below |
| Claude Code, inline | With its theme on Auto: only what it draws from then on and its live area. What it printed keeps its colours. With a fixed theme: no |
| Codex | No. It reads the colours once, at startup, and has no `?2031`. Restarted, below |
| Pi, opencode | Yes, with their system theme |
| neovim, lazygit, tmux, zellij | Yes |
| vim, bat, delta, fzf, shell prompts | No. One look at startup, or configuration only |

For a program in the "no" rows the answer is a new process. Nothing a terminal
sends changes that: a resize does not (both Claude Code's and Pi's trackers
say so, and a one-column change makes inline Claude Code 2.1.329 redraw only
the visible screen, measured), neither do focus reports, and neither does a new terminal (tried: a
relaunched test copy gave Codex a fresh terminal, and it drew the old band
into it). Codex keeps the colours it read at startup for the life of the
process.

So Wortel gives an agent a new process, when that costs nothing: see the
next section. Anything else in the "no" rows keeps the other theme's colours,
readable over the floor (above), until it is restarted by hand.

Also not Wortel's: a colour a program set with `OSC 10` or `OSC 11` stays
until the program resets it, across a change of theme.

## Agents that are restarted

Claude Code and Codex (`AgentSleep.repaintAgents`), except one that repaints
itself: on the alternate screen with `?2031` on
(`TerminalModes.repaintsItselfOnSchemeChange`), which is Claude Code
fullscreen. By the record as it is: a woken terminal reports only a `?2031`
on record, so one assumed on is not enough. A record that missed either mode
errs towards the restart; one left stale by a full reset (`ESC c`, which the
recorder does not see) or a program killed on the alternate screen errs
towards no restart, over the floor. The decision, why these
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
after the change, and dropped. Run it after any change here and after a
Ghostty update.

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
