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

**Modes first, then the replay.** The prelude goes in before the replayed
output, so anything the program changed while nobody was attached wins over what
was recorded before it detached — a vim that was quit while you were away sends
its `?1049l` in that replay.

**An allowlist, and a short one.** A mode replayed into a terminal that never
asked for it is as wrong as a mode lost. `TerminalModes.restorable` holds the
sticky ones whose loss you can see: application cursor keys, mouse reporting,
focus reporting, the alternate screen, bracketed paste, the keyboard shape.
Deliberately not `?25` (cursor visibility), `?12` (blink) or `?2026`
(synchronised output) — a TUI toggles those every frame, so recording them would
mean writing to disk continuously to restore a state that is already one frame
old.

**A mode nobody mentioned is not mentioned.** Absent, not false: the default
belongs to the terminal, and `ESC[?1l` for a mode no program ever touched is
noise that can only do harm.

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
