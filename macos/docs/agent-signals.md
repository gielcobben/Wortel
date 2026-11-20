# Agent busy/attention signals

How Wortel knows a terminal agent is working (sidebar spinner) or wants you
(attention dot + Dock badge + notification). Written 2026-11-19, when the
guessing was taken out. `docs/incidents.md` has what it cost while it was in.

**A program says what it is doing, or Wortel does not claim to know.** An
agent reports its state itself, in a status report, and is taken at its word.
Nothing is read off a title or a screen to work it out. Beside the reports,
three older things a program can say are still heard, because they are said
and not inferred: a notification of its own, the bell, and progress.

## A program's own report (OSC 7501)

The [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status)
is a program telling its terminal what it is doing:

```
ESC ] 7501 ; state=blocked:kind=permission:app=codex ESC \
```

`state` is `idle`, `working`, `blocked`, `done`, `error` or `clear`; `kind`
(with `blocked`) is `permission`, `question` or `auth`; `msg` is one line of
base64 text. It is what Wortel used to reconstruct from a title, a screen and
a conversation file: every dot incident in `docs/incidents.md` is one piece of
that evidence overruling another.

Which agents report, each read in its own latest source or release on
2026-11-19 (searched by the protocol's name as well as its number: opencode's
own code never spells `7501`, and a search for the number alone called it a
no):

| Agent | Reports | Since | Asks first | Says `done` |
|---|---|---|---|---|
| Codex | yes | 0.163 (2026-10-09); `done`, `error`, `kind` from 0.164 | no | yes |
| Claude Code | yes | 2.1.295; child records and the compaction fix in 2.1.326 | yes | yes |
| Pi | yes | 1.1.0 (2026-10-07) | yes (`PI_PROGRAM_STATUS=1` skips it) | yes |
| OpenCode V2 (`@opencode/cli`) | yes | 2.0.29 (2026-10-14) | no | **no**: `working`, `blocked`, `idle` only |
| opencode 1.x (`opencode-ai`, what `npm i -g opencode-ai` still installs) | no (1.19.6, run here: silent) | | | |
| crush | yes | 2026-10-08 (in 0.101.0) | no | yes |
| Qwen Code | yes | design dated 2026-11-06, in 0.28.0 | no | yes |
| GitHub Copilot CLI | yes, by its changelog and tracker | 1.0.107 | not read (closed binary) | not read |
| Amp | yes, in its binary: the question and a `state=`/`kind=`/`app=`/`msg=` writer | not known | yes | not read |
| Gemini CLI | no (0.69.0); asked for in its #29710, open | | | |
| Kilo | no (7.8.27); asked for in its #14973, open | | | |
| goose, aider, cline, Auggie, Kimi, ollama, llm | no | | | |
| cursor-agent | not checked | | | |

So Gemini CLI, goose, aider, cline and cursor-agent show no spinner and no
turn end, and neither does an agent in a version older than the column above
("What else a program can say", below, is what they still have).

**A program that never says `done`.** opencode reports only `working`,
`blocked` and `idle`, so its turns end by going idle. Taken literally that is
"at rest, no news", and every opencode turn would end in silence. So `idle`
straight after
`working` counts as a turn that ended, after at least 2s of work, for any
program that has not shown it tells a finish from a stop: one not in
`ReportedStatus.saysDone` (codex, claude-code, pi, crush, each read to say
`done`) that has not yet said `done` or `error` in its run
(`SessionManager.saidDone`). The list is what keeps Codex quiet while it
starts its MCP servers, `working` then `idle`, before any first turn. What it
costs: Codex 0.163 exactly, which had no `done` yet, ends its turns silently.

Measured with Claude Code 2.1.328 in a pty that answered the question: `idle`
at start, `working` as the prompt was sent, `done` 1.7s later, `clear` on
exit, and at the trust dialog of an untrusted folder
`blocked:kind=permission:msg=` "trust this folder".

Run for real in a copy of the app on 2026-11-19, each agent's reports read
from the app's log:

- **Codex 0.170**: `idle`, `working` then `idle` as its MCP servers started
  (four seconds once, and nothing was raised), a turn as `working` then `done`
  (announced with its answer), an approval as `blocked/permission` (announced,
  and cleared when it was answered with Enter), `idle` on the next key after
  `done`. Three sessions finishing within a second were three announcements.
  Left idle for 33 minutes after three turns each, past its 30-minute recap:
  see "Tested how".
- **Claude Code 2.1.328**: the above, and its `done` heard from a terminal
  hibernated four seconds earlier, and after being put to sleep and woken.
- **Pi 1.5.2**: answered, then `idle`, `working`, and `error` with its own
  words when its login had expired (announced as failed).
- **OpenCode V2 2.3.2**: `idle` at start; a turn as `working` with a child
  record for its session, that record cleared, then `idle`, announced as a
  finished turn 0.4s later by the rule below.

**What each one sends**, read from its own code on 2026-11-19:

| | Codex 0.170 | Claude Code 2.1.328 | Pi (current) |
|---|---|---|---|
| `working` | a turn, a review, MCP servers starting | busy, or idle with a message queued, or a finished turn still waiting on background work | a run or a compaction |
| `blocked` | approval (`permission`), a question or MCP form (`question`), sign-in (`auth`) | a permission, sandbox or worker request and a goal proposal (`permission`), input needed (`question`), an open dialog (no kind), a failed sign-in (`auth`); `msg` says which | an extension dialog or login; `msg` is its title |
| `done` | a turn completed, until a key or click | a turn completed with nothing awaited | a run finished |
| `error` | a turn that failed | a turn that failed, with the failure as `msg` | an error that is not retried |
| `idle` | at rest, an interrupt, a replayed conversation | no turn yet, or one that was stopped | started, or cancelled |
| child records (`id=`) | none | background commands, monitors and remote agents, each `working` or `blocked`, cleared one by one | none |
| `clear` | exit, suspend, handing the terminal on | exit | |

So three things no title or screen could tell are said outright: a turn that
failed, a finished turn that is still waiting on its own background work, and
why a program is blocked.

**How it is read.** libghostty ignores the sequence, and Wortel owns the pty,
so `ProgramStatusWatch` reads it off the output on its way to the terminal
(`ProgramSignalScanner`: outside a match it only looks for the next ESC). It
answers the question with the same body. A hibernated session is heard the
same way, since the output is read with or without a terminal. A replay (what
the program wrote while Wortel was closed) is old news twice over: a question
in it is not answered, because the program stopped waiting long ago and the
answer would be typed into it. Of the rest, only what it leaves standing is
passed on, marked as replayed: a `clear` if there was one, the last root
report, each child record still there, and the last notification. Not heard
at all: a session on the exec backend (no keeper), where libghostty owns the
pty, and whose notifications libghostty still forwards.

**Records.** A report with no `id` is about the program itself (the root
record); one with an `id` is about a piece of its work. `ProgramRecords` holds
them as the spec has a terminal hold them (64 besides the root, the one
updated longest ago making room). Two things are read from them, apart. The
root says whether the program is working or has finished. The `block` says
whether it wants an answer: the root when that is `blocked`, else a piece of
its work that is, which is the program waiting on you whatever the root says
meanwhile (Claude Code's root reads `done` while a remote agent it started
waits for an answer). They are kept apart so that one changing never looks
like the other: a background task's question, once answered, must not
announce the finished turn behind it a second time. A child that is `working`
keeps the session at work: a root at rest (`done` or `idle`) with any piece of
its work still going is shown working (`ProgramRecords.standing`), and the
turn is announced finished when the last piece ends. Claude Code ends a turn
with `done` while a background command it started still runs, and carries on
by itself when it ends. `blocked` and `error` stand over it: they are news.

**What a report comes to** is `ReportedStatus.effects`, pure and tested:

| Report | What happens |
|---|---|
| `working` | the spinner; a turn's end still settling is dropped; and the "finished" or "failed" dot of the turn before goes, since it is working again and that is no longer the news |
| `idle` | no spinner, nothing said (an interrupt, or `done` once the user touched the program) |
| `blocked` | "needs input", the loud kind, with the program's `msg`, else "Waiting for your approval", "Asking you a question", "Waiting for you to sign in" |
| `done` | "turn done", the soft kind, quoting the agent's last answer (below) |
| `error` | "failed", with its `msg` |
| a block that ends (`working`, `idle`, `done`, `clear` after `blocked`) | the dot that block raised is cleared, whoever answered it |
| the same report again | nothing |
| replayed `blocked`, `done`, `error` | the dot, no banner, no sound |

`blocked`, `done` and `error` are announced once they have stood for 0.4s
(`ReportedStatus.settle`), on the timer the App Nap assertion already covers.
A program can change state as fast as it can write, so a banner that is not
louder than the last one the session put on screen is held to one per 3s
(`reportIsTooSoon`, counted from `lastBanner`, which outlives the attention:
a program that blocks and is answered every second still gets one banner in
three). The dot and the note still change; no banner slides in, and a rename
does not post one later either (`refreshAttentionNotification` only rewrites
a banner that was shown).
A program's line is cut to 180 characters for a banner, and loses direction
overrides and invisible characters before it leaves the terminal.

**Against the spec** (revision 0.4, 2026-10-10), checked line by line on
2026-11-19. Followed: both terminators, the pair grammar, skipped malformed
pairs, the last of a repeated key, base64 with or without padding, every
limit as "discard the whole report", an unknown state ignoring its report, a
bad `id` ignoring its report rather than landing on the root, `kind` only
with `blocked`, `app` outside its character set treated as absent, the reply
to the question written before the terminal's own answers to anything asked
after it, working and blocked records dropped when the program exits or the
shell is back. Not followed, on purpose: a full reset (RIS) does not remove
the records (a reset in the middle of an agent's run would leave the session
with no state until its state next changed), `progress` is not shown, and
the reply does not list states and kinds, which without a list means exactly
the ones read here.

**What a reporting session's other signals come to**
(`SessionManager.reports`): OSC 9;4 from it is ignored (it is a build the
agent ran, not the agent), a bell raises nothing, and a notification of its
own (OSC 9, 777, 99) is never the news. Codex's turn-end OSC 9 is the start of
its answer with no fixed wording, which is how four in five Codex turns
arrived as "needs input" while notifications were sorted by keyword (measured
2026-11-19). Its approval OSC 9 ("Approval requested: npm test") is good
words, so one arriving within 2s of a reported block becomes that banner's
text.

**Its conversation is read for words only.** A finished turn is announced
with the start of the agent's last answer (`announceFinishedTurn`, below). The
file used to be asked for a verdict too: was there a turn at all, was it an
error, a question, an idle compaction. A program that says `done` is not
second-guessed, and a file that can't be found (another `CODEX_HOME`) costs
the quote, never the announcement. What that gives up: Codex says `working`
while it restarts an MCP server and then falls back to a `done` nobody
acknowledged, which is one turn announced twice, and Claude Code 2.1.295 to
2.1.325 said `done` after an idle compaction (fixed in 2.1.326).

**When it ends.** `clear` (the program exited, was suspended, or handed the
terminal on), the agent's marker going, or the shell back at its prompt. A
block goes with the program; what `done` or `error` raised stays, because the
result is still there to look at. Across a relaunch the last state is kept in
`sessions.json` (`reportedState`) and restored for an agent still running,
since it says nothing new until its state changes.

**An agent too old to report.** Codex, Claude Code, Pi, opencode and crush are
known to report (`ReportedStatus.knownReporters`, with the version each needs
and where its release notes are). One of them seen starting, with its
interface up (it turned on bracketed paste, so not `codex exec` or
`claude -p`), that has said nothing after 20s is an old version
(`SessionManager.watchForSilence`). With nothing guessed, such a session shows
no spinner and no dot, so it says why, in two places while the agent runs. Its
row has a small orange triangle in the slot where its status would be, the one
a worktree that failed has. And the sidebar's bar shows an orange warning
triangle beside the update and permissions icons (`AgentUpdateIndicator`); a
click opens a popover with which agent, the version it needs, a Release Notes
button, and that the agent has to be started again after updating. The row's
triangle can't be clicked, so the session's menu (its "…", a right-click, the
titlebar's "…") starts with "Update Pi…", which opens that popover, and so
does Session ▸ Update Pi… for the selected session, which puts it in ⌘P. With
the sidebar hidden there is no icon to hang the popover off, and the item
opens the agent's release notes instead. It was a grey line under the
session's name first, which read as disabled and was cut off at the sidebar's
width. An agent that does not report in any version
(Gemini CLI, goose, aider, cline) gets neither: there is nothing to update to.

**Known limits.** Codex's own (openai/codex issues, read 2026-11-19):
approvals inside background subagent threads are not reported (#61124), a
stalled subagent can hold `working` (#60325), and startup dialogs are not
covered (#61778). A crashed agent leaves `working` until the marker sweep
finds it gone, within about two minutes. And Wortel's: Claude Code and Pi ask
their question once, at startup. One that was already running when a Wortel
that answers was installed asked a Wortel that did not, and says nothing
until it is next started. So does one started while Wortel was closed. Neither
gets the "out of date" triangle, which is only for an agent seen starting.

**Tested how.** `ProgramStatusTests` (the grammar and the records),
`ReportedStatusTests` (every effect), and `ProgramStatusWatchTests`, which
runs a script on a real pty that asks the question, checks the reply byte for
byte, and reports only if it was right. What `SessionManager` does with an
effect is not in the test target, so that half is checked in a running copy
of the app: `scripts/verify-agent-status.py` starts stand-in agents that say
what a script tells them to, under the names the shell integration knows
(`codex`, `claude`, `pi`, `opencode`, `gemini`), and reads the app's log for
what it decided. Forty-four cases: a turn, a block and its answer, timing,
rubbish, programs that never say `done`, old versions, plain programs,
hibernated terminals, and the app closed and reopened around five sessions.
`--real` adds the real Claude Code being put to sleep and woken. `--soak`
is the nearest thing to a day of use: twenty stand-ins, forty random changes
of state each, some standing and some flickering past faster than an
announcement settles, held against the log three ways (every report sent was
heard, in order; everything announced has a state that stood behind it; every
state that stood was announced, and taken back when it ended). Three seeds,
2,400 changes, on 2026-11-19: all held. Run both before a change here ships.

The last step, the banner itself, is not something a log can see. On
2026-11-19 a copy signed with a development certificate (an ad-hoc one is
never shown a banner) posted the three kinds to a person watching: the banner
each time, the soft chime for a finished turn, the alert sound for "needs
input" and "failed". Each post is logged now (`banner handed to Notification
Center … allowed= banners=`), so "the dot came and the banner didn't" can be
told from "nothing was raised".

Writing the script found five things no unit test had:
the terminal core's limit on notifications (below), a finished turn announced
twice after a background task's question, a "finished" dot left on a session
that was working again, a stale "needs you" in `wortel list` after an agent
died while blocked, and the selected session of a Wortel never brought to the
front counting as watched ("Away from the Mac").

To watch it: every report is logged as `status …` in the `agent-status`
category (`docs/debugging.md`).

## What else a program can say

Heard for any session, agent or not, and each of them said outright.

1. **A notification of its own** (OSC 9 with text, OSC 777, OSC 99). It
   raises attention and a banner. Wortel reads it off the pty itself
   (`ProgramSignalScanner`, `TerminalNotificationReader`), where libghostty's
   core would have: the core allows one desktop notification a second for the
   whole app and drops one that says the same as the last inside five seconds
   (`showDesktopNotification` in Ghostty's `Surface.zig`). Right for one
   terminal; in a window of agents, two that finish in the same second were
   one notification, and the other was lost without a trace. Measured
   2026-11-19: three sessions sending the same approval text a second apart,
   one arrival. What the core forwards is now ignored for a terminal whose pty
   Wortel holds, and the limit is kept per session instead: one banner a
   second, the rest changing the dot quietly. One sent while Wortel was
   closed is the dot and no banner.
   This is what a Codex older than 0.163 still sends for a turn end and an
   approval, while it believes its terminal is unfocused. Sorted by how the
   text *opens* (`AttentionKind.classify`): a request leads with its request
   ("Approval requested: …", "Waiting for Approval"), so only the title and
   the first 40 characters of the body are read, and anything else is a turn
   that ended. A word somewhere in the text decides nothing. `wortel notify`
   takes the same path.
2. **The bell** is "needs input".
3. **Progress** (OSC 9;4) is the spinner and nothing more. The bundled shell
   integration sends it as a command starts, except for programs known to stay
   open (agents, editors, pagers, REPLs: `_ghostty_wortel_interactive` in the
   zsh, bash and fish integrations), and tools like cargo send their own. Its
   end clears the spinner. It is not read as a turn that finished.
4. **A command ending** (OSC 133;D) clears the spinner, and after 10s or more
   in a session you are not looking at raises "finished", or "failed" on a
   non-zero exit. Ignored while an agent's marker is live: Pi wraps every
   message it draws in 133 marks, and the core closes a "command" for each.

Focus still matters to an old Codex: it sends its own notification only while
its terminal reports unfocused (DECSET 1004). Wortel reports per-surface focus
as first responder **and** key window (`SurfaceView.updateFocus`), so
switching sessions, ⌘-tabbing away and minimising all reach the agent.

**What is not read, and was.** A title was read for a spinner glyph and for
"Action Required". A screen was hashed once a second per agent, and one that
kept changing and then held still was a turn ending. Progress ending was a
turn ending. A stopped screen was searched for the wording of a prompt. The
agent's conversation file was asked whether any of those guesses had been a
turn. Each was right most of the time, and each incident about a dot in
`docs/incidents.md` is one of them being wrong: a recap read as a turn, a
repaint read as work, "would you like" read as a prompt. They are gone, and
with them the timer that read every agent's screen.

**What that costs.** An agent that reports nothing has no spinner and no
turn-end notification: Gemini CLI, goose, aider, cline, cursor-agent, and any
agent in a version from before it reported. A notification or a bell of its
own still arrives.

## While a terminal is hibernated

A hibernated session (`docs/glossary.md`) has no libghostty surface, so
nothing is parsed by the core. Status reports are heard as always, since
`ProgramStatusWatch` listens to the pty and not the terminal. For the rest,
`SignalScanner` reads the pty instead (OSC 0/2, 7, 9, 9;4, 99, 133;D, 777 and
BEL) and raises the same `SurfaceView` callbacks, then takes those sequences
out of what is written back into the terminal on wake, so nothing is raised
twice. Nothing answers a program's terminal queries while there is no
terminal, so a session running an agent outside
`HibernationPolicy.watchableAgents` (only claude so far) is not hibernated
while that agent runs. And no agent's terminal is hibernated while the agent
is at work (`Session.isBusy`): what it writes then is drawing, and only
512 KB of it is kept for a terminal that is away. One that starts a turn
while hibernated is woken out of sight once half of that is used
(`HibernationPolicy.outrunning`). `../../docs/decisions.md`, 2026-11-19.

## While an agent is asleep

A sleeping session (`docs/glossary.md`) has no agent and no marker, only its
shell. Its dot, ring and unread state are whatever they were: nothing about
going to sleep or waking raises or clears attention. The agent's exit when it
is ended (status 143) is not read as a command that failed
(`SessionManager.sleepIsSettling`), and the resume typed on waking is confirmed
as Wortel's own (`AgentConversation.confirms`), so it is not counted as an
agent someone started. Which clock an agent is on comes from its own record,
not from these signals: Wortel's signals only say "working", which keeps it
awake. To see why an agent is still awake, or that one went:

```sh
log stream --level info --predicate 'subsystem == "com.gielcobben.Wortel" && category == "sleep"'
```

## Still true, and learned the hard way

- macOS notification banners require a signed `/Applications` build
  (`./scripts/release.sh`); ad-hoc Debug builds only get the sidebar dot and
  Dock badge.
- Ghostty's GTK apprt drops progress not refreshed within 15s. Wortel must not
  copy that: a spinner that is still true must not go out. Stuck-busy safety
  comes from the command ending at the next shell prompt instead.
- **A failed `KERN_PROCARGS2` read is not an absent agent.** `AgentLiveness`
  finds most agents only by their arguments, because the cheap `p_comm` pass
  misses them: pi, gemini and amp are `node`, aider is `python3`, and Claude
  Code renames itself to its version (`p_comm` reads `2.1.272`, measured).
  That read is a size probe followed by a read, and a live process can grow
  its argv in between, so it fails routinely on a healthy one. Flattened to
  "no arguments" it looks exactly like a process that was searched and didn't
  match, and the minute sweep once declared a running Pi gone and deleted its
  marker. `ProcessTable.argumentsIfReadable` returns nil for "couldn't read",
  `locate` turns that into `.unknown`, and `sweepsBeforeDroppingMarker` means
  no single reading can delete a marker. Anything else that decides an agent
  is gone owes the same two guarantees. The sweep runs on its own timer, once
  a minute while any agent is running (`updateMarkerSweep`).

## Away from the Mac

A session never raises attention while you are looking at it
(`isActivelyViewing`). That used to mean "Wortel is frontmost, the window is
on screen, the session is selected", so walking away from an agent mid-turn
cost you its turn end: no dot, no banner, because the window was taken for
your eyes.

Now nobody touching the Mac for a minute (`SessionManager.awayAfter`; any key,
click, scroll or pointer move, in any app) counts as not looking. The idle time
comes from `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`
for any input type, which needs no permission, and it is read only when a
signal arrives: no timer. The selected session then raises its dot and banner
exactly like one in the background. Using another app was already "away".

"Frontmost" is AppKit's word (`NSApp.isActive`), not only the flag the app
layer sets on activate and resign. The flag starts out true, so a Wortel that
was never in front (opened in the background, as a login item is, or relaunched
behind another app) took its selected session for watched and raised nothing
for it. Found 2026-11-19, in a copy opened in the background.

What clears it differs on purpose. A background session's attention is
answered by Wortel coming forward with it selected, or by selecting it. An
attention raised while its session was *already on screen* can't be answered
by being on screen: a display waking from sleep uncovers the window, and
re-activation can happen without anyone reading anything. So such a session is
remembered (`raisedWhileAway`), and `appDidBecomeActive` and
`windowVisibilityChanged` leave it alone; it clears when you type, click,
paste or scroll in its terminal (`SurfaceView.onUserInput`, the hook the screen
sampler already uses), or select it as usual. Coming back and clicking
another session leaves it as any background session's dot. A `wortel send`
into it doesn't clear it either (`onScriptedInput`): text typed by another
agent while you're gone is not you coming back.

## What the banner says

A finished turn (`announceFinishedTurn`) is announced with the start of the
agent's last answer, not a fixed "Finished, your move": with three agents
going, the fixed text said a turn ended and not which one or how it went.
`AgentAnswer` makes the first paragraph of prose of the final message into
plain text: code blocks, tables, rules, JSON and HTML lines skipped, headings
skipped unless nothing else is left, list markers dropped (each item made a
sentence), emphasis, links, images and code spans unwrapped, whitespace
collapsed, cut to 180 characters at a word with an ellipsis.

Where it is read from, each found the way resume finds the conversation
(`liveConversationID`), only the last 256 KB, off the main thread:

- **Claude**: the transcript (`ClaudeTranscriptTail.lastAnswer`).
- **Codex**: the rollout (`AgentConversation.Codex.turnReading`, which also
  finds the one a `/new` or `/resume` inside Codex moved to):
  `task_complete`'s `last_agent_message`, else the last assistant `message`.
- **Pi**: the session file (`AgentConversation.Pi.file`): the last assistant
  `message`'s text.

The fixed text stays for everything else: another agent, no conversation id,
an answer that is only code, nothing written since the turn began. The text is
the agent's own, so it is quoted as written, dashes and all.

A block is announced in the program's own words where it gave any (`msg`, or
its notification), else "Waiting for your approval", "Asking you a question",
"Waiting for you to sign in". An error is its `msg`, else "Stopped with an
error".

## The name on the banner

A notification is posted with the session's name, and the session is very
often renamed moments later: `announceFinishedTurn` raises the attention and
then calls `considerAutoName` on the next line, which runs the on-device model
off-main and comes back seconds afterwards. The agent-title path
(`adoptAgentTitle`) renames on the same terms.

Left alone that produces a banner reading "Session 3" beside a sidebar row
reading "Wortel memory usage visualization" — one event described by two
names, which reads as a notification about a different session.

So `SessionManager` remembers what each standing notification says and
re-posts it when the session is renamed. The app layer keys notifications by
session id, so the re-post replaces the banner in place rather than adding a
second one, and it goes out with `alert: false`: the ding belonged to the
original event, and correcting a name is not a new one.

Bounded to a minute (`attentionRewriteWindow`). The renames this exists for
land within seconds; past that the banner has been seen or dismissed, and
putting a fresh one on screen for an event already dealt with would be worse
than the stale name it corrected.
