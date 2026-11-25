# Terminal modes across a reattach

Why a pasted paragraph arrived as one message per line, and what keeps a
resumed session's terminal honest.

## The bug

Paste a few lines into an agent's prompt and each line became its own queued
message. Intermittent: most sessions were fine, some were not, and the same
session stayed broken once it was.

Nothing was wrong with paste. A terminal only wraps a paste in `ESC[200~` …
`ESC[201~` when the program has switched **bracketed paste** on, and that
wrapping is what tells an agent "this is text, not Enter". Measured from the
real programs, on startup:

| Program | Sets |
| --- | --- |
| Claude Code | `?1004` focus reporting, `?2004` bracketed paste, keyboard flags `>5u` |
| Pi | `?2004`, keyboard flags `>7u` |
| vim | `?1` application cursor keys, `?1049` alternate screen, `?2004` |
| zsh | `?1`, `?2004` |

**A session survives the app; its terminal does not.** The keeper holds the
shell, so the program never restarts and goes on believing everything it set is
set. A relaunch builds a *new* libghostty surface whose modes are all at their
defaults. Neither side is told they now disagree, and the first thing that
disagreement costs is a paste going through raw.

The intermittency was the keeper's replay buffer: it holds the last 512 KB the
shell wrote while nobody was attached, and if the `?2004h` was recent enough to
still be in that tail, the replay set the mode again on its way through. Quiet
sessions worked. Busy ones did not, permanently, because nothing writes that
sequence a second time — an agent declares its modes once, at launch, and then
runs for days.

The lost keyboard flags (`>5u`) are the same bug wearing different clothes: they
are how the agent and the terminal agree about shift+enter, so losing them turns
a newline in the prompt back into a submit.

**And so is the agent that stopped following light and dark.** `?2031` is how a
program subscribes to theme changes: with it on, the terminal sends
`ESC[?997;1n` for dark and `ESC[?997;2n` for light whenever the Mac's appearance
changes, and ghostty checks that mode before sending anything
(`Surface.reportColorScheme`). Claude Code turns it on at startup when its theme
is `auto`, reads the background once via `OSC 11`, and then never asks again —
it has no reason to. A resumed terminal never heard the subscription, so ghostty
stayed quiet and the agent went on painting the palette it picked hours earlier:
dark-background diff blocks on a white screen, or a white prompt box on a dark
one. Intermittent for the same replay-tail reason, and permanent once it hit.

## What it does now (since 2026-11, protocol 2)

**The modes live in the keeper's terminal, and travel with it.** The keeper
reads every byte the program writes into a terminal of its own
(`docs/architecture/keeper.md`), and an app's surface is restored from a
snapshot of that terminal: every mode, current, saved and default, the kitty
keyboard stack on both screens, the alternate screen and what is on it, and
whatever sequence the program was in the middle of. Nothing is recorded to be
declared again, and there is no replay, so the bug above cannot happen: a
terminal restored after a quit, a crash or being dropped out of sight
believes exactly what the program believes.

**The answers are the keeper's.** A program's queries (cursor position, device
attributes, OSC 10/11, `?996n`, DECRQM, XTVERSION) are answered by the
keeper's terminal, with the app open or not, and the app's surface answers
nothing (`ghostty_surface_set_responds`, `write_buffer_replay`). The old
problem of a replay's stale answers landing in an agent's prompt
(`ReplayAnswers`, removed) has no road to happen on.

**Light and dark, too.** The app tells the keeper its colours and light or
dark (`KeeperCommand.appearance`); a program subscribed with `?2031` is sent
the report by the keeper when it changes, whether or not its terminal has a
surface, and answered the truth when it asks.

**The record stays, for its readers in the app.** `TerminalModeRecorder` is
still fed the live output (`KeptTerminalFeed`) and kept on disk
(`TerminalModeStore`), because four things read it: whether to bracket a
prompt Wortel inserts (`insertPrompt`), whether an agent that says nothing is
at its prompt, whether an agent repaints itself on a theme change, and what to
take back from an agent agent sleep ends (below). It no longer restores
anything. Moving those readers to the keeper's terminal (`KeeperCommand.modes`)
and deleting the record is the next step.

**A new session's start reads modes too, by itself.** `StartScanner`
(`Sessions/StartCover.swift`) watches the output of a session made with a
line to run, for the first mode the line's program sets, which is when the
page over the terminal comes off. It does not use the record: what it needs
is the order of a mode and the shell's `OSC 133;C` inside one read, and the
record keeps states, not order. It lives for the seconds a start takes.

## The scanner

`CSIScanner` finds `ESC [ … <final>` in a byte stream that arrives in arbitrary
pieces. Two things about it are load-bearing, and both are pinned by
`TerminalModesTests`:

- **It is incremental.** A pty read ends where it ends, and a real stream split
  `ESC[?2004` from its `h` across two reads. A scanner that restarted per chunk
  would miss exactly the sequence this exists to catch.
- **It does not read inside a DCS, APC, PM or SOS string.** `tmux`'s
  passthrough wraps a sequence in a DCS precisely so the terminal in between
  does *not* act on it, and recording one would claim a mode this terminal was
  never in.

It is not a terminal emulator and must not become one: libghostty is the
emulator, this only needs to know what to say again.

## Taking modes back

The same record says what to take back from a program that is ended and does
not tidy up. Codex has no handler for any signal, so ended by one (an agent
restarted to repaint it, `appearance.md`) it leaves the shell on the alternate
screen with mouse reporting and its keyboard flags on. `TerminalModes.undo`
turns off every mode on record as on, the alternate screen last, pops the
keyboard flags on both screens, shows the cursor and turns the wheel's
scrolling of a pager (`?1007`) back on. It goes through the keeper (`KeeperCommand.inject`), so its terminal and
the app's copy both hear it, and it is written before the signal, so
the shell's next prompt, which switches bracketed paste on for itself, comes
after it; and if the program does not go, the prelude puts it all back the same way.

An agent's startup modes are written down for as long as it runs, seen or not
(`TerminalModeRecorder.assume`). When its marker goes, the ones still on
record as on are taken off it (`forgetStartupModes`): an agent that was
killed, or never set them (`claude -p`), would otherwise have focus reporting
and theme reports put back into a plain shell's terminal by a later undo.
Bracketed paste stays, which the shell has on at its prompt itself.

## Known limits

- **Keyboard flag stacks, in the record.** `CSI > flags u` is recorded; a
  `CSI < u` pop leaves flags the record cannot know, so it claims none. The
  keeper's terminal has the whole stack; only the app's record is short of it.
- **A mode set before the record started** (a shell older than the update
  that brought it) is not in the record. The terminal has it.
