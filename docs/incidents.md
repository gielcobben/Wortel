# Incidents

The failures that shaped the code. Each one left a rule behind, and the rule
looks arbitrary until you know what happened. Read the ones for the area you
are about to change.

Oldest first. Each entry: what was seen, the cause as it was measured, what
changed, and the rule it left. Add one when a failure teaches something the
code alone will not tell the next person.

## 2026-07-08. Notifications that were sent and never shown

**Seen:** the whole chain fired, the system reported `granted`, posting
returned no error, and no banner ever appeared.

**Cause:** an ad-hoc-signed build run from DerivedData is not registered with
the notification daemon. macOS accepts the post and drops it.

**Rule:** anything about notifications is tested in a signed build in
`/Applications`. An ad-hoc build's authorisation status proves nothing.

## 2026-07-22. Resume that never resumed

**Seen:** agents were not picked back up after a relaunch.

**Cause:** on ⌘Q the shell printed one last prompt, and the prompt hook deleted
the marker that said an agent was running.

**Rule:** the running agent is recorded at quit, before anything else gets to
run (`588c518`).

## 2026-07-30. One version, two binaries

**Seen:** 2026.31.2 was published twice, as different builds.

**Cause:** the version counter came from a local file that had not been
committed, so the next run derived the same number from it. Sparkle only offers a
version strictly greater than the one installed, so everyone who took the first
build was stranded on it.

**Changed:** the version is derived from the live feed, the only state every
machine that can publish shares (`10c089d`). Replacing a published version
needs `--republish` with the version spelled out, and only the last one
published can be replaced (`4960108`).

**Rule:** never publish the same version twice. Ship the next one.

## 2026-08-05. Dots on sessions nobody had touched for days

**Seen:** attention dots and notifications on idle sessions.

**Cause:** three things in the screen-watching fallback. Trust in a
self-reporting agent expired after 60 seconds, and Claude sends one progress
report per turn with no keepalive. A single changed frame counted as work, and
a resize or a focus change redraws every agent once. And "esc to interrupt",
Claude's working footer, was on the list of text that means blocked.

**Rule:** trust holds for the agent's whole run. Work needs two changed samples
within five seconds, re-baselined on resize, activation and occlusion. A
working marker vetoes a blocked reading (`a40d7b8`).

## 2026-08-08. Typing `wortel` opened a second app

**Seen:** inside a session, `wortel` launched another copy of the app.

**Cause:** libghostty's core puts `Contents/MacOS` on the `PATH` whatever the
config says, and on a case-insensitive disk `wortel` there is `Wortel`, the
app. Three fixes shipped on reasoning about what the `PATH` should have been.
One dump of what it was settled it.

**Rule:** measure before the second guess (`macos/docs/debugging.md`). The
directory is stripped from `PATH` in zsh and bash (`c5e4c42`, `b24f2bb`).

## 2026-08-09. Notarization rejected

**Cause:** `codesign --deep` treats a bare Mach-O in `Contents/Resources` as a
resource and does not sign it properly. `--verify --deep` does not catch it.

**Rule:** nested tools (`wortel`, `wortel-keeper`) are signed one by one,
inside out, before the app (`6497090`).

## 2026-08-09. 6.6 MB of reference screenshots went live

**Cause:** the site was deployed without the npm build that strips the local
pixel-comparison tools out of `dist/`.

**Rule:** keeping local tools off the site must not depend on anyone
remembering. The build deletes them, and a deploy always runs the build
(`fe5eb95`).

## 2026-09-17. A paste arrived one line at a time

**Seen:** after a relaunch, text pasted into an agent was sent as separate
messages, one per line. Later, agents stopped following light and dark.

**Cause:** the keeper keeps the program alive, so the program never restarts,
but its terminal does. The new terminal starts with every mode at its default
while the program still believes what it set. Without bracketed paste, each
newline is Return.

**Changed:** the app records the sticky modes a program declares and declares
them again in the new terminal, before the replay. `macos/docs/terminal-modes.md`.

**Rule:** a session outlives the app; its terminal does not. Everything the
program still believes has to be said again.

## 2026-09-29. A launch with no window saved an empty session list

**Seen:** the app started with no window. On quit, every session was gone.

**Cause:** a layout constraint was activated before its view was in the
hierarchy. AppKit swallowed the exception mid-launch, the app ran on without a
window, and at termination it saved its (empty) state over the real file.

**Rule:** nothing is saved before the session file has been read. An unreadable
file is set aside, never overwritten. And after any relaunch, check for a
window on screen, not for a pid (`229f024`, `d024540`).

## 2026-09-30. A second copy wrote stale state back

**Seen:** state quietly went back to an older version of itself. It is how
agents lost their light and dark subscription.

**Cause:** a test build ran beside the real app on the same data folder. Each
wrote its own view of it on quit.

**Rule:** one Wortel per data folder, enforced with a lock. A copy for testing
gets its own folder and its own bundle id (`f9de25c`, the `test-copy` skill).

## 2026-10-07. The Dock ended every shell, and the relaunch hung

**Seen:** every session's shell and agent ended at once. The next launch froze.

**Cause, the kill:** macOS shows a quit app as "Running in Background" while
processes attributed to it are alive, and "Stop Running in Background" stops
them. Those processes are the keeper and everything under it.

**Cause, the hang:** the replay was written into the terminal from the main
thread. That call parses on the calling thread and blocks when the surface's
64-slot mailbox is full, and only the main thread drains the mailbox.

**Cause, the wrong conversations:** resume picked the newest transcript in the
folder, which put several sessions into one conversation.

**Changed:** the replay is fed off the main thread. Resume uses the exact
conversation id. An agent that died in a surviving shell gets its resume typed
again. Agent exits are logged. Shipped in 2026.41.5 (`2c3303d`).

**Tried and dropped:** running the keeper as a launchd agent, then as its own
background app. The Dock still offered to stop it both times.

**Rule:** never write a replay on the main thread. Don't reach for launchd to
protect the keeper. Test resume with real sessions: the fixtures passed through
both bugs found that day.

## 2026-10-08. The keeper was killed while the app was open

**Seen:** terminals stopped. The app noticed nothing for seven minutes, and the
next launch resumed nothing.

**Cause:** a browser started from a shell inside Wortel inherited the keeper's
process coalition instead of getting its own. The Dock attributed the whole
coalition to that browser, and force-quitting its tile killed the keeper, every
shell and every agent. Recovery only covered a keeper lost while the app was
gone, and by the time the app quit, its liveness sweep had already dropped the
dead agents' resume plans.

**Changed:** the app watches the keeper's pid and restarts dead terminals in
place, with the exact resume and an explanation. A keeper is replaced only on
a confirmed protocol mismatch, and its life is logged at a level that is kept
on disk. Shipped in 2026.41.7 (`198a870`).

**Again on 2026-10-10:** a second kill showed a resume could still be lost. A
resume is now owed until the agent is seen running, and any failed reply from
the keeper retires the connection. Shipped in 2026.41.9 (`c7e95d5`).

**Still true:** a shell's coalition is inherited and cannot be separated
without private API. Something outside can always kill the keeper. Recovery is
the design.

## 2026-10-20. A light diff on a dark screen

**Seen:** for weeks, on a Mac set to Auto, an agent would paint light colours
on a dark terminal after the appearance changed.

**Cause:** the agent ignores the light or dark value in the terminal's
appearance report. On each report it asks for the background colour and judges
by its luminance. Wortel applied the new config one main-queue turn after the
report went out, so the answer was the old background.

**Changed:** the config is applied synchronously, as Ghostty.app does
(`3d8e922`). Earlier fixes had only covered the reattach path, because the live
path was assumed fine.

**Rule:** when it comes back, run `macos/scripts/check-theme-reports.py` and
flip the appearance before touching anything.

## 2026-10-21. No scrolling or selecting in a resumed agent

**Seen:** in a fullscreen agent, the mouse sometimes did nothing after a
relaunch.

**Cause:** the agent turns on the alternate screen, mouse reporting and
keyboard flags at startup, then scrolls and selects by itself from the mouse
reports. Resumed in a session that was not attached, it reprinted a long
conversation, which pushed those startup bytes out of the keeper's bounded
replay. The reattached terminal had the modes off.

**Changed:** the replay reads the modes out of the bytes it drops and puts
them in front of what it hands over (`7a6db22`). Because it lives in the
keeper, it reaches a user only when their keeper next restarts.

**Verified (2026-11-12):** a program in a throwaway copy declared the modes
while nothing was attached, wrote 1.2 MB after them, and asked the reattached
terminal which modes it had. The release before the fix answered reset for all
five and no keyboard flags. The fixed build answered set for all five, and the
flags.

**Related, shipped in 2026.46.4:** while a program owns the mouse, ⌘-click
opens a link and ⌘-drag makes a terminal selection.

## 2026-10-27. Sessions named after a colour

**Cause:** the terminal's own answer to a colour query came back through the
same path as typed input, and the first-prompt reader took it for what the user
had typed.

**Rule:** the terminal's answers are told apart from the user's keys before
anything reads "what was typed". Shipped in 2026.44.2.

## 2026-11-09. Every Codex session dotted at once

**Seen:** nearly every background Codex session showed a dot at the same time,
with nothing new in any of them.

**Cause:** after 30 minutes unfocused, Codex writes a recap. Every background
session in Wortel is unfocused, so they recapped in a wave, and the screen
changing and going still again looked like a turn. A spinner while it starts
its servers did the same.

**Changed:** a quiet Codex counts as a finished turn only when its own
conversation file has a turn written since the busy began. Shipped in
2026.46.1. The same rule already held for Claude.

**Follow-up, 2026.46.3:** a banner arrived for an answer that had been read to
the end before switching away. Wortel now remembers that an answer was on
screen while you were looking, and raises nothing for it.

**Rule:** where an agent keeps a record of its turns, a turn end is checked
against it. The screen alone is the fallback, for agents that keep none.

## 2026-11-17. Half a gigabyte of old screens

**Seen:** the Mac ran out of memory. Wortel was 943 MB with 13 sessions, and
1.2 GB two hours later with the same sessions. `footprint` put the growth in
"Malloc Small" (307 MB, then 564 MB); `heap` showed it as ~110,000 untyped
blocks of 3 and 5 KB.

**Cause:** every `ghostty_surface_read_text` leaked the text it returned. A test
copy under `MallocStackLogging=1` traced the live blocks to
`activeScreenDigest` (the screen tier, once a second per agent session) inside
libghostty's allocator, and `lldb` showed a leaked block holding the screen's
text. Wortel did call `ghostty_surface_free_text(surface, &text)`, as ghostty.h
declares it, but in the linked Ghostty 1.2 the function takes one argument:
the disassembly reads the text from the first register. Given the surface, it
read the surface's own memory as the text and freed nothing. Fixed upstream in
Ghostty's 4803d58.

**Changed:** every read is freed through `ghosttyFreeText`, which passes the
text in both argument places, right for this library and the fixed one.
Measured on a test copy: libghostty's live blocks went from +62 a minute to
none, and stayed flat through 200 `wortel read`s.

**Rule:** a C function whose declaration and implementation can disagree is
checked against the binary (`lldb … disassemble -n`) before trusting the
header. Memory that grows with time, not with sessions, is a leak: find it
with `heap` on the running app and `malloc_history` on a test copy started
with `MallocStackLogging=1`.
