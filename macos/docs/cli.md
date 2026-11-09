# The `wortel` command — design

Why the command line tool is built the way it is. For how to *use* it — every
verb, the scripting contract, hook recipes — see
[wortel-command.md](wortel-command.md).

A command line's way into the running app. A handful of verbs, one socket,
no plugin system.

```sh
wortel open src/PreviewWindow.swift      # a preview window for a file
wortel new --branch fix/1482             # a session, in its own worktree off trunk
wortel rename "1482 login redirect"      # this session
wortel notify "Tests failed"             # this session wants you
wortel send tests "fix it" --enter       # another session, as if typed there
wortel wait tests --idle                 # until its agent's turn is over
wortel read tests --lines 80             # what it said
```

## The job it exists for

**So Wortel never has to know which agent you use.**

That is the whole argument. Every terminal aimed at agents faces the same fork:
ship an adapter per agent, or expose a surface each agent can drive. cmux took
the first road and now maintains integrations for six agents while explicitly
skipping ten more — Gemini, Copilot, and whatever ships next quarter. Each one
is a thing to write, a thing to keep working, and a thing that is subtly wrong
for someone's setup.

Wortel ships none. Anything that can run a command can drive the app: an agent
that just wrote a file opens a preview of it, a `SessionStart` hook you wrote
names the session after the ticket you're on, a `make` that finishes raises
attention. The integration is yours, which also means it is exactly what you
wanted rather than what we guessed.

## Installation: there isn't any

The binary ships inside the app bundle, at `Contents/Resources/bin/wortel`.
`GhosttyRuntime` exports its directory as `WORTEL_BIN_DIR` per surface, and the
bundled shell integration prepends that to `PATH`. Inside a Wortel session the
command is simply there.

**Why a variable of our own rather than just setting `PATH`.** libghostty's
`env_vars` can only *add* to the environment it hands the shell — a key that
already exists keeps its inherited value, so setting `PATH` there does nothing
at all. That failed silently and in the worst possible way; see below.

`InheritedEnvironment` strips `WORTEL_*` from the launching process's
environment, which is what makes the add-only rule safe here: without it, a
Wortel launched from a Wortel session would inherit the *old* bundle's
`WORTEL_BIN_DIR` and be unable to replace it.

This is the decision most worth defending, because two more conventional answers
were on the table:

- **A "Install Command Line Tool…" menu item** (Xcode's and VS Code's model),
  symlinking into `/usr/local/bin`. It works, but `/usr/local` is root-owned on
  Apple Silicon, so it means an admin prompt — and it adds an installer to an app
  whose entire pitch is that there is nothing to configure.
- **Dropping it into `/usr/local/bin` on first launch.** The same admin prompt,
  arrived at without asking.

Both solve a problem the app doesn't have. Essentially all of this command's use
is *inside* a Wortel session — that's where agents run, where hooks fire, where
you type. Putting it on the session's `PATH` covers that completely and costs
nothing.

The integration runs after `path_helper`, so prepending there actually puts the
directory at the front — which is what we want: the command that ships with
*this* app is the one that speaks this app's protocol, and it should beat an
older copy someone symlinked into `/usr/local/bin`.

### Why typing `wortel` used to launch a second Wortel

Three things had to line up, and each was invisible on its own.

1. Setting `PATH` through libghostty's `env_vars` **did nothing**, because that
   API only adds keys and `PATH` already existed. So the bundled command was on
   no `PATH` at all.
2. Upstream's shell integration has a `path` feature that appends
   `$GHOSTTY_BIN_DIR` — `Contents/MacOS` — so its own `ghostty` command works.
   Wortel ships no binary there, so the only thing that directory contributes is
   **the app's own executable, named `Wortel`**.
3. The disk is case-insensitive. `wortel` matched `Wortel`.

So the command launched a second copy of the app, which then failed to bind the
socket the first copy was holding:

```
wortel: CLI socket unavailable: bind: Address already in use
```

**And `no-path` in the config does not remove the directory.** Measured from
inside a session: with `shell-integration-features = …,no-path` the shell gets
`GHOSTTY_SHELL_FEATURES=ssh-env,ssh-terminfo,title` — the feature really is off —
and `Contents/MacOS` is on `PATH` anyway, because the core puts it there
independently of the shell-side feature.

So the fix is in our copies of the integration scripts, and it is two steps:
prepend `$WORTEL_BIN_DIR`, then **remove `$GHOSTTY_BIN_DIR`**. Winning on
ordering alone isn't good enough when the failure mode is "launches a second
copy of the app" rather than "command not found" — anything that ever perturbs
the order turns a typo into a second instance fighting for the socket. Nothing
in `Contents/MacOS` is meant to be run by name, so it comes off entirely.

Two smaller traps found on the way, both worth knowing before trusting anything
here:

- The upstream guards read `[[ "$GHOSTTY_SHELL_FEATURES" == *"path"* ]]`, and the
  string `no-path` would match that glob just as happily as `path` would. It
  never gets the chance: measured from inside a session, the core exports only
  the features that are **on** — `ssh-env,ssh-terminfo,title` — so a disabled
  one is absent rather than negated. Config negation therefore does work, here
  and for `no-cursor`; it just wasn't enough, because the directory arrives from
  the core rather than from this block. Worth re-measuring rather than assuming
  if upstream ever changes what it exports.
- The removal is done in the zsh and bash copies, which can be checked here.
  fish and elvish get the prepend only — the same rule the shell-integration
  changes have followed before, since neither can be run on this machine.

This is the *same* hazard as the build-time one below, from the same cause — a
lowercase command and a capitalised app on a case-insensitive disk — and it bit
in two completely unrelated places within an hour.

What it doesn't cover is driving Wortel from *outside* Wortel: Raycast, a script
in Terminal.app, a launchd job. If that turns out to matter, the answer is the
menu item above, added then — for the people who need it, rather than for
everyone.

## The protocol

One JSON object per line over a Unix domain socket at
`~/Library/Application Support/Wortel/cli.sock`, one command per connection.
Line-delimited rather than length-prefixed because both ends are Swift talking to
a local socket, and being able to drive the whole surface from `nc` while working
on it is worth more than the parsing.

`WortelCommand` and `WortelResponse` are compiled into **both** binaries, so the
two ends cannot drift apart silently. They ship together — but a hand-installed
symlink can outlive its app, which is why a command the app can't decode is
*answered* ("this Wortel doesn't understand that command") rather than dropped.
A closed connection reads as "the app is broken"; a sentence reads as "these two
don't match".

### Two streams

Anything a person reads goes to **stderr**. The one machine-readable value goes
to **stdout** (for `list` and `read`, the answer itself). That is what makes

```sh
id=$(wortel new --cwd ~/Developer/wortel)
```

give you an id rather than an id and a sentence. Exit codes split the same way:
`2` means you typed it wrong, `1` means the app said no, `0` means it happened,
and `124` is a `wait` that ran out of time (the reply carries it as `status`,
since only the app knows which kind of "no" it is).

`list` and `read` answer with JSON in `value` whatever the caller asked for,
and the CLI decides how it reads: a table or the text by default, the JSON
re-encoded with sorted keys under `--json`. `--json` never crosses the wire;
the app has one answer and the presentation is the CLI's business.

### `--version` answers two questions

```
$ wortel --version
wortel 2026.32.1 (/Applications/Wortel.app)
Wortel 2026.32.1 (412)
```

The first line is the bundle this binary shipped in — a command line tool has no
`Info.plist` of its own, so it walks up from its own executable (through any
symlink) to find the `.app` it lives in. The second is whatever actually
answered the socket, asked over the wire rather than read off disk.

They are the same app in every ordinary install, which is why the app's path is
printed **only when it differs**:

```
Wortel 2026.31.0 (398) at /Users/x/Downloads/Wortel.app
```

That line is the drift this protocol otherwise can only complain about after it
has caused a failure — a `wortel` symlinked onto someone's `PATH` that has
outlived the app it came from. Repeating a matching path in the common case
would bury it.

A Sparkle update replaces the bundle in place, so the `PATH` entry an open
session is carrying keeps pointing at the right directory and picks up the new
command with no relaunch.

## Two rules that make it safe to leave wired up

**It never steals focus.** Every window a command opens is ordered front; the app
is never activated. Typed in Wortel — already frontmost — that looks exactly like
you'd expect. Fired by a hook while you're in another app, it leaves the window
waiting instead of yanking you out of what you were doing. An agent finishing a
background task must not be able to take your keyboard.

**A command means the session it was run in.** `rename` and `notify` take no
session argument: the shell already knows which one it is, via
`$WORTEL_SESSION_ID` (exported per surface, and the same variable the agent
marker files are keyed on). Identity comes from where you ran the command rather
than from something you have to look up and could get wrong. Run from outside
Wortel, those two say so rather than guessing at a session.

`notify` deliberately goes down the *same* path as a program's own OSC 9/777 —
same classification of the text, same dot, same badge, same one-per-session
notification. To the person across the room, `make && wortel notify "Build done"`
and an agent emitting the escape sequence itself are the same event, so they
should look the same.

That rule has one deliberate exception, the next section: four verbs whose
whole point is another session.

**`new --branch` forks from trunk, not from where you are.** The other two rules
say identity comes from where the command ran; this is the one place that would
be wrong. The repository still comes from the caller's directory — a script in
one repo must not open a worktree of whichever repo the sidebar points at — but
the *base* of a new branch does not. `rev-parse --show-toplevel` answers with the
linked worktree when the command is run inside one, so a base of `HEAD` meant a
hook firing from a worktree on `update-website` forked `update-website`, silently
and with nothing to see. A ref resolves identically in every worktree of a
repository, so naming one takes the caller's location back out of the answer.
`--from` overrides it, and `--from HEAD` is how you ask for the old behaviour on
purpose. The sidebar's dialog resolves the same default into a visible field, so
both ends of the app answer this the same way.

## Reaching other sessions: `list`, `read`, `send`, `wait`

bb lets an agent list, read, type into and wait on any terminal, which is what
lets one agent run and watch others. Wortel has the same reach, built from the
doors a person uses rather than from a protocol each agent would have to speak:
the screen (`read`), a paste and the Return key (`send`), and the attention
tracking the sidebar's dots already run on (`list`, `wait`). That keeps the
first argument of this document intact: nothing here knows which agent is on
the other end.

**No prompt, no label.** `send` doesn't ask you first, and nothing marks the
text as typed by a program. Both were considered and turned down:

- *A prompt* ("tests wants to type into website: Allow?") would break the job
  this exists for. An agent that runs another one sends dozens of prompts
  while you're away, and a dialog per send means nothing happens until you
  come back, which is the problem it was meant to solve. It would also teach
  you to click Allow without reading, which is worse than no prompt.
- *A label* (a prefix like `[from tests]`, a colour, a line in the sidebar)
  changes what the receiving agent reads. A prompt with a header in front of it
  is a different prompt, and an agent told that its input came from another
  program reasonably treats it differently. The point is that the second agent
  can't tell, and doesn't need to.

**The trust boundary is your own sessions.** The binary is on the `PATH` only
inside Wortel's shells, and the socket is a file only your user can open
(`0600`), so everything that can `send` is already something you started in a
terminal of yours, with your keyboard's authority over every other terminal
of yours. And it shows: the text is on the receiving screen and in its
agent's transcript, and the session is in the sidebar for you to watch.

**Naming another session.** `<session>` is an id or a name (exact, then exact
ignoring case, then a unique prefix of a name or of the id), and a tier that
matches two sessions is an error listing both, never a pick (`WortelSessionAddress`).
A prompt typed into the wrong agent can't be undone, so convenience stops at
the first sign of doubt. The short id `list` prints is the first block of the
UUID, accepted as a prefix from four characters, the way git takes a short
hash. `rename`, `notify` and `mark` accept `--session` too, because labelling a
session from elsewhere is as harmless as labelling your own.

**`read` reads the active screen, not the viewport.** The active area is what
the program last drew; the viewport is wherever the person at the keyboard has
scrolled. An agent asking what another session says means the first.
`--lines N` keeps the last N lines, read off the active screen when it holds
more than N, and otherwise off the whole scrollback: libghostty's read takes
the active screen, the viewport or everything (an exact row is clamped to the
screen's height), so there's no reading "the last N" of the scrollback alone.
N is capped at 10000, which bounds the answer, not that read.
Trailing spaces and the empty rows under the last line are the grid, not the
output, and are trimmed.

**`send` is a paste, then a key.** The text goes through
`ghostty_surface_text`, which is what ⌘V does: bracketed when the program
turned that on, so a multi-line prompt lands in an agent's input as one input
rather than one submission per line. `--enter` is a Return keypress through
libghostty's key encoder, not a `\r` written to the pty: a program on the kitty
keyboard protocol expects the key's own encoding. It comes 200 ms after the
paste, as a person's would, because Codex reads keys arriving in a burst as a
paste, and a Return inside one as a newline. Both reach the pty by the same
road typing does, so `PromptTap` (session naming) and a move's `DraftTap` see
them as typing. What they are not is *you*: `SurfaceView.sendText(scripted:)`
keeps them out of `lastUserInputAt` and away from an attention raised while you
were away (`raisedWhileAway`), which only your own input or selecting the
session answers. An agent driving a session from elsewhere is not someone back
at the keyboard.

**A session not shown since launch is warmed, not refused.** Surfaces are
lazy, so `read`, `send` and `wait` on a restored session create its terminal
the way the warm-up does: no selection, no focus. They then wait for the pty
queue to drain (`SurfaceView.afterPendingOutput`), because the keeper's replay
and the saved modes arrive there first. Read before that, the screen is blank;
paste before that, and the terminal doesn't yet know the program asked for
bracketed paste. `send` also waits out a reattach's muted answers, which can
take seconds while a big replay is written, but only for `WortelCLI.sendPatience`
(half the CLI's ten-second deadline, derived from it): past that it fails and
types nothing, because text typed after the CLI has already reported failure is
sent twice by a script that retries.

**`wait` holds the connection, not the main thread.** The reply simply comes
later, as `new --branch`'s does. While any wait is open, a quarter-second timer
looks at each one: a few dictionary reads for `--idle` and `--exit`, and for
`--for` a read of the active screen only when the pty's output counter has moved
since the last one, at most twice a second (`PtyHost.outputGeneration`). A wait
on a quiet session costs a counter comparison. The scrollback is read once, when
the wait starts, and again only when more than a screenful has gone by between
two looks, at most every three seconds (below): it can be 10 MB, and the read
holds the lock the terminal's IO thread needs. When the CLI goes away (^C), the server
tells the app (`WortelCLIServer.Caller.hasHungUp`), so a wait with no timeout
doesn't outlive the shell that asked.

**What `wait` counts.**

- `--for` counts only text that is **new**: the occurrences in the scrollback
  and screen when the wait starts are the baseline, and the wait ends when there
  are more. "Already on the screen" was the wrong default for the job: after a
  `send`, the answer to the last question is usually still there and would end
  the wait at once. `--from-start` is bb's name for the other reading. After the
  start a look reads only the active screen and lines it up with the last look
  (`NewTextWatch`): the text is new when the screen has more of it than the
  rows of the previous screen still on it, so text scrolling up, out of the
  top, or moved down a row by a line inserted above it, is not. When nothing of
  the previous screen is left (a flood, a resize, a `clear`), text may have gone
  by unseen, and the next look counts the whole terminal against the whole
  count, as the first design did on every look. A count that drops there (a
  `clear`, scrollback trimmed at its limit) lowers the baseline, so text printed
  after that still counts.
- `--idle` is the sidebar's own reading: not working, not settling, or asking
  for action. The trap is a wait that starts right after a `send`, before the
  agent has shown it started: quiet then means "not yet". So quiet is believed
  only after a turn has been seen (a start reported after the wait began, or
  the session seen working), and otherwise only once nothing has been typed
  into the session, and its shell hasn't started, for five seconds. Once a turn
  has been seen, it's over when the turn ended with a signal of its own (the one
  that raises the dot), or after a second of quiet, longer than the gap between
  two tools.
- Because the dot is never raised for the session you're looking at, and is
  cleared when you look, `SessionManager` keeps how each session's last stretch
  of work ended (`turnOutcomes`) apart from the dot, set before the viewing gate
  and cleared the moment work is reported starting again, before the busy
  debounce: a turn shorter than the debounce never shows as busy, and its
  predecessor's outcome would otherwise answer for it. That is also what
  `list`'s state column
  reads, so the CLI and the sidebar can't disagree.

## Failure modes worth knowing

- **Nothing listening** — "Wortel isn't running", for both a missing socket and a
  refused connection, because at a prompt they mean the same thing.
- **A socket file left by a crash.** A Unix socket's name is a file and it
  outlives the process. The next launch takes the name over — but only after
  *proving* it's stale by failing to connect to it, because deleting it
  unconditionally is how two running copies would steal it from each other.
- **A slow answer.** `new --branch` shells out to git first, so the reply is
  asynchronous and one slow command must not hold up the next. Accept and serve
  are on separate queues; `WortelCLIServerTests` pins that with a command parked
  in the handler while a second one is answered.
- **An answer nobody is waiting for.** A `wait` can be answered minutes after a
  ^C ended the CLI, and writing to a socket whose peer has gone raises SIGPIPE,
  whose default ends the process: here, the app. Every accepted connection is
  `SO_NOSIGPIPE`.
- **A long answer.** `read --lines` can be a long stretch of scrollback, so a
  reply may be up to 16 MB, while a command stays capped at 2 MB (`send`'s text
  at 256 KB, which fits even JSON-escaped). Two limits, because the two
  directions carry different things. The app answers from the main thread,
  and a reply is never written there: a CLI suspended with ^Z stops reading,
  and 16 MB written in place froze the app, terminals and all. The server
  encodes and writes it on its own queue, one connection's stuck reader
  holding up nobody else's.

## The build

The target is called **`WortelCLI`** and its product is called `wortel`. That
split is not cosmetic: a target's name is its intermediates directory, and the
filesystem is case-insensitive, so a target named `wortel` shares `Wortel.build`
with the app and the two overwrite each other's object files. What that looks
like from the outside is an app bundle whose executable *is the CLI* — it
launches, prints the usage, and exits.
