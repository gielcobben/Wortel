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

## What it does now

`TerminalModes` watches the output the app is already handling, records the
modes worth restoring, and re-declares them into the new terminal on reattach.

**In the app, not the keeper.** While a session is attached the app reads the
pty itself and the keeper sees none of those bytes — which is exactly when a
program declares its modes. So the watching happens where the bytes are, and
`TerminalModeStore` writes the result to
`Application Support/Wortel/terminal-modes.json`, because the process that knows
is the one about to exit. It is rewritten only when something changes, which in
practice is once per agent launch.

**And in the keeper, for what it throws away.** While nobody is attached, the
keeper's replay holds only the last 512 KB, and a program started then declares
its modes in the first bytes it writes. Codex resumed while Wortel wasn't
attached turns on the alternate screen, the mouse (`?1000`, `?1002`, `?1003`,
`?1006`) and the keyboard protocol, then reprints a long conversation, which
pushes all of that out of the buffer before anyone reads it. Reattached, the
terminal had none of them: scrolling and selecting in Codex did nothing, since
in fullscreen Codex does both itself from the mouse reports. So `ReplayBuffer`
reads the modes out of the bytes it drops and puts them in front of the replay
it hands over, after the app's prelude (they are newer) and before the tail
(which is newer still). A keeper started before this keeps the old behaviour
until it is replaced, which is not on an update: one holding sessions is kept.

**Modes first, then the replay.** The prelude goes in before the replayed
output, so anything the program changed while nobody was attached wins over what
was recorded before it detached — a vim that was quit while you were away sends
its `?1049l` in that replay.

**An allowlist, and a short one.** A mode replayed into a terminal that never
asked for it is as wrong as a mode lost. `TerminalModes.restorable` holds the
sticky ones whose loss you can see: application cursor keys, mouse reporting,
focus reporting, the alternate screen, bracketed paste, theme reports, the
keyboard shape.
Deliberately not `?25` (cursor visibility), `?12` (blink) or `?2026`
(synchronised output) — a TUI toggles those every frame, so recording them would
mean writing to disk continuously to restore a state that is already one frame
old.

**A mode nobody mentioned is not mentioned.** Absent, not false: the default
belongs to the terminal, and `ESC[?1l` for a mode no program ever touched is
noise that can only do harm.

**And, for `?2031` alone, what the appearance is now.** Re-declaring the mode
only re-subscribes the program; it says nothing about what changed while nobody
was attached, and a Mac left on "Auto" flips at sunset. So a resumed session
whose program wants theme reports is also sent one, matching the current
appearance. This is the only thing here written to the *program* rather than to
the terminal, which is why it goes after the replay has been read for modes: a
program that turned reporting off while detached said so in there, and must not
be written to.

It is sent on every resume rather than only when the appearance changed.
Tracking what each program was last told would mean persisting a second belief
about the far side and being silently wrong about it, which is the shape of the
bug this whole file exists for, and a report a program already agrees with costs
it nothing — it sets the theme it is already painting. Note that a fresh
surface's conditional theme is `.light` (ghostty's default), so on a *light* Mac
ghostty's own `set_color_scheme` sees no change and reports nothing: without
this the light case would never resync at all.

## The terminal's answers to the replay

The replay goes through libghostty's parser like any output, so every query in
it is answered: a cursor position report for `ESC[6n`, device attributes for
`ESC[c`, the colours for OSC 10/11, XTVERSION, the kitty keyboard flags. With a
host-managed pty those answers go straight into the program
(`receive_buffer` → `PtyHost`). They are old: the program asked while nobody
was attached, got no answer (the keeper answers nothing), and moved on. One
arriving now is read as typed input, which is how `^[[24;1R` or an OSC 11 reply
could land in an agent's prompt after a relaunch. bb handles the same thing by
dropping the terminal's writes while it replays.

So, for a resumed session with a replay, `PtyHost.writeFromTerminal` drops what
the terminal sends from just before the prelude until the replay's answers are
known to be out (`ReplayAnswers`). Wortel's own writes (the theme report above,
a resume typed again) go to `PtyHost.write` and are never held, and neither
does anything dropped reach the prompt taps (`PromptTap`, `DraftTap`).

- **Closed by a marker, not a timer.** libghostty doesn't answer from inside
  `ghostty_surface_write_buffer`: the parser queues the answer for the surface's
  IO thread, which writes it a moment later (Ghostty 1.2's
  `StreamHandler.messageWriter`). So after the replay we parse one query of our
  own, a DECRQM for a mode no terminal has (`ESC[?64738$p`, answered
  `ESC[?64738;0$y`). The queue is in order, so its answer coming back means
  everything the replay produced has gone by; it is dropped too, and anything
  after it is live. A 2s deadline covers a marker that never comes back.
- **Not after a replay cut mid-sequence.** The replay and the first live read
  are one stream; a program drawing as the keeper handed over can leave a
  sequence half in each. The marker's `ESC` would cut it short and its tail
  would print as text, so `ReplayAnswers.endsCleanly` checks the replay's last
  escape (and UTF-8 character) first. If it isn't clean, no marker: the window
  closes 250ms after the replay was written instead.
- **Keys can't be told apart**, since they take the same queue as answers, so a
  key pressed while the replay is being parsed is dropped with them. That is
  the few milliseconds a surface takes to be built, before it was on screen.
- **Three reports go through**, because they describe the terminal *now* and
  the program wants them unasked: focus (`ESC[I`/`ESC[O`, which the prelude's
  `?1004h` itself produces), the `?2048` size report, and the `?2031` light/dark
  report.
- **Not covered: answers that go via the main thread.** An OSC 52 clipboard
  read, a title report (`CSI 21 t`) and the `?996n` theme query are answered by
  the app after a hop through the surface's mailbox, and can come back after
  the marker. The theme answer is harmless (it is the report above). The other
  two are rare in agents; a late one still goes through.
- **A fresh shell is never muted**: its few replayed bytes were written a
  moment ago, and whatever it asked it is still waiting on.

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

## Known limits

- **What the program changed and never announced.** Only modes are restored:
  cursor position, scroll region, the screen's contents, the palette and any
  `DECSTBM` are still whatever the replay draws.
- **A mode set before this shipped.** The record starts when a session's output
  is first watched, so a shell that was already running at the update has
  nothing written down until the next time a program declares something. In
  practice that means the first paste in a session that predates the fix can
  still go through raw.
- **Keyboard flag stacks.** `CSI > flags u` is recorded; a `CSI < u` pop leaves
  flags this cannot know, so it claims none rather than asserting what it saw
  pushed.
- **A theme report reaches the foreground process group**, which is normally
  the agent. A session resumed with `vim` or a pager in front hands those nine
  bytes to that instead, exactly as a live appearance change already would. And
  a `?2031` recorded as on for a program that has since exited writes them at a
  shell prompt, the same risk the prelude already takes for every other mode.
