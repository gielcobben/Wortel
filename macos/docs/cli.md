# The `wortel` command — design

Why the command line tool is built the way it is. For how to *use* it — every
verb, the scripting contract, hook recipes — see
[wortel-command.md](wortel-command.md).

A command line's way into the running app. Four verbs, one socket, no plugin
system.

```sh
wortel open src/PreviewWindow.swift      # a preview window for a file
wortel new --branch fix/1482             # a session, in its own worktree
wortel rename "1482 login redirect"      # this session
wortel notify "Tests failed"             # this session wants you
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

- The upstream guards read `[[ "$GHOSTTY_SHELL_FEATURES" == *"path"* ]]`, which a
  feature list containing **`no-path` matches just as happily** as one containing
  `path`. Whatever the core exports today, a negation cannot be relied on to
  disable a block written that way. The same goes for `no-cursor` against
  `*"cursor"*`.
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
to **stdout**. That is what makes

```sh
id=$(wortel new --cwd ~/Developer/wortel)
```

give you an id rather than an id and a sentence. Exit codes split the same way:
`2` means you typed it wrong, `1` means the app said no, `0` means it happened.

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

## The build

The target is called **`WortelCLI`** and its product is called `wortel`. That
split is not cosmetic: a target's name is its intermediates directory, and the
filesystem is case-insensitive, so a target named `wortel` shares `Wortel.build`
with the app and the two overwrite each other's object files. What that looks
like from the outside is an app bundle whose executable *is the CLI* — it
launches, prints the usage, and exits.
