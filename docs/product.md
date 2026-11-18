# Product

What Wortel is, who it is for, what it believes, and how to tell whether a
change belongs in it. Read this before proposing a feature.

## What it is

Wortel is a native macOS terminal for working next to coding agents. It runs
Ghostty's engine, unmodified, and the rest of the window is arranged around it:
a sidebar of named sessions, a git worktree per agent, the diff of what each one
did beside it, and shells that keep running when the app quits.

It is free, signed and notarized, for macOS 14 or later, and it updates itself.
It is made in the Netherlands by one person.

## Who it is for

Someone who keeps several agents going at once, in several checkouts, on a Mac.

For that person the terminal stopped being about typing. The hard part became
knowing which agent is waiting, what each one changed, and not losing any of it
when the lid closes. The tools that grew up around this are mostly apps with a
terminal tucked inside. Wortel goes the other way: it is the terminal, and
everything else earns a place around it.

## What it is held to

Three things, in this order. A change that costs one of them needs a very good
reason.

1. **Fast.** Throughput and latency are Ghostty's, by construction. Wortel's
   job is to add nothing on top: a 7 MB bundle, a cold launch of 55 to 57 ms, a
   session switch in one frame (to a session seen in the last ten minutes; one
   out of sight longer has hibernated and takes 10 to 30 ms to wake, see
   `decisions.md`). Numbers on the site and in the docs are
   measured, never estimated. `macos/bench/BENCHMARKS.md` has the method.
2. **Native.** Swift and AppKit, Metal, the system's own controls. No web view
   under the terminal, no runtime underneath.
3. **Built for agents.** The window is for working beside programs that work
   by themselves: telling them apart, keeping them out of each other's way,
   and keeping them alive.

## What it believes

Six things it will not trade away. They are on the site at `/about`, and each
one decides real questions.

**Native, or nothing.** Where macOS already has a way to do something, Wortel
uses it, and behaves the way a Mac user expects. Selection follows Finder's
rules. Deleting goes to the Trash. Shortcuts follow the system's conventions
before anyone else's (`macos/docs/shortcuts.md` records which app each one is
borrowed from).

**Decided once.** Fonts, colours, keys and scrollback were chosen carefully and
then left alone. There is no user config. When something looks like it needs a
preference, the work is to find the right answer. If it truly varies per
person, it becomes a checkmark in a menu when it is flipped while working, or
one of a handful of rows in Settings (⌘,) when it is decided once.

**Calm by default.** Nothing moves unless something happened. A dot, not a
siren. A notification only for a session you are not looking at, and never for
an answer you have already read. False alarms are treated as bugs of the first
rank, because one of them teaches you to ignore the rest.

**The agent is a guest.** Nothing is installed into an agent and nothing is
written into its configuration. Wortel reads the screen, as you do, takes an
agent's word where it gives one, and may read the files an agent keeps for
itself (its conversation, to resume it exactly). It never asks an agent to
change. Detection has to work for an agent Wortel has never heard of: a
terminal that only understands six agents by name is wrong about the seventh.
Going the other way, the `wortel` command is the whole interface, so anything
that can run a command can drive the app.

**Your work outlives the window.** Quit, crash, update: the shells keep running
and come back with what they printed. And nothing destructive happens without
you choosing it. Closing archives. Removing goes to the Trash. When Wortel is
not sure, it keeps the thing.

**Less, until it is right.** Every feature has to earn its place in the window,
and most of the work is taking things out. Several features were built, shipped
and removed. That is the process working, not churn. `docs/decisions.md` keeps
the list so nobody builds them a third time.

## What it does not do

These are not gaps. Returning "unhandled" for them is how the design is
enforced.

- **No splits.** A session has tabs in three fixed places (the main area, a
  side column, a strip under the terminal). Never a free grid of panes.
- **No user config, no themes, no plugins.** Settings (⌘,) has a handful of
  switches and none of them is about how the terminal looks. The terminal's
  whole configuration is the read-only `macos/Resources/wortel.conf` inside
  the app. Font size is the one thing about the look a user changes.
- **Nothing installed into an agent:** no hooks, no plugins, no config
  written. And no AI chat box of its own.
- **No search in the terminal's scrollback.** It was built and removed the same
  day: agents run in the alternate screen, so it only ever saw one screen.
- **No setup or run scripts for worktrees.** Files only (`.worktreeinclude`).
- **Nothing that needs the network to draw a row.** No pull request or CI state
  in the sidebar. A pull-request button was shipped and removed for making a
  network call on a timer.
- **No account, no sign-in, no cloud.**

## Does this change belong?

Ask these before building, and say the answers when you propose it.

1. **What does it cost when it is off screen?** Cost tracks the window on
   screen, never the size of the repository or the number of sessions. No git
   per row, no timers, no watch on something nobody is looking at.
2. **Does it need a setting?** Then it probably isn't decided yet. A row in
   Settings is only for something decided once that truly differs per person,
   and each one has to be argued for.
3. **Does it need anything from the agent's side?** A hook, a config line, a
   wrapper. Then no.
4. **Does anything about the user's work leave the machine?** Then no. See the
   privacy rule in `AGENTS.md`.
5. **Is there already a Mac way to do it?** Use that one.
6. **Is it another way to do something there is already a way to do?** Starting
   a session has four ways in and only four. Seven was more than anyone kept
   apart.
7. **If it is wrong, what is lost?** Design it so the wrong answer keeps the
   work: archive, Trash, "unknown counts as running".
8. **Can it be taken out again?** Things get tried here. Build it so removing
   it is one commit.

## Where it sits

- **Ghostty** is the engine and a fine terminal. Wortel is a different app
  around the same engine: one window, named sessions, worktrees, survival, no
  configuration.
- **Agent manager apps** hold worktrees, diffs and a review queue, with a
  terminal as a detail inside. Wortel is the terminal, with the worktrees and
  diffs in it, and its shells do not depend on the app being open.
- **Multiplexers** keep sessions alive inside whatever terminal you bring.
  Wortel keeps them alive the same way and adds the window a multiplexer has no
  room for.

`/compare` on the site puts Wortel beside named apps. Two rules keep that page
honest: every claim is read off that product's own site, docs or repository,
and "unknown" is a real answer, never rounded down to "no".
