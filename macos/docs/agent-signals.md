# Agent busy/attention signals

How Wortel knows a terminal agent is working (sidebar spinner) or wants you
(attention dot + Dock badge + notification). All agent behavior below was
verified against source or live byte captures on 2026-07-10; versions move,
re-verify before relying on details.

## Wortel's detection channels (SessionManager)

1. **OSC 9;4 progress (ConEmu)** — `9;4;3` (or any non-remove state) = busy;
   `9;4;0` after ≥2s of busy = "stopped working" → attention ~1s later unless
   progress resumes ("progress-quiesce"). This is the emerging cross-tool
   standard (Ghostty 1.2+, Windows Terminal, ConEmu; emitted by Claude Code,
   crush, cargo ≥1.87, systemd v257, mise, winget…).
2. **Title markers** — fallback for agents that only signal via the window
   title. Braille spinner prefix (U+2800–U+28FF; Claude Code, Codex, Amp) or
   `✦`/`⏲` (Gemini) = busy; marker disappearing = same quiesce path;
   `✋` prefix or "Action Required" (Gemini, Codex) = attention immediately.
3. **Desktop-notification escapes** — OSC 9 (non-progress payload), OSC 777,
   OSC 99 are parsed by the libghostty core and forwarded; Wortel relays them
   as attention + macOS notification. Emitted by Codex (default), crush
   (default), Amp (default), Gemini/opencode (opt-in), Pi's official notify
   extension.
4. **Bell** and **command-finished ≥10s while unselected** — classic paths for
   non-agent commands.
5. **Screen activity** (`AgentActivity`) — the backstop under all of the above.
   A watched session's active screen is hashed once a second; a screen that keeps
   changing is an agent working, one that then holds still for 3s is a turn
   ending. For agents that emit nothing (opencode, goose, aider, Pi by default)
   it is the only signal there is; for the rest it is what covers a channel that
   goes quiet when it shouldn't. It is the only *guessing* tier, so it is fenced
   in hard:
   - **It claims busy only when nothing else has, and only ever ends a busy it
     claimed.** Authority is ownership, not identity. It used to stand down
     entirely for any session that had proved it has a channel of its own, and
     that proof was a one-way door: `onProgress` cannot tell an agent's OSC 9;4
     from one emitted by something the agent *ran* (cargo, mise, systemd and
     winget all report progress), so one `cargo build` through a silent agent's
     shell tool retired its only busy signal for the rest of the session. Now
     the tier watches every session with a live marker, stays silent while the
     program owns its own state (`SessionManager.screenInferredBusy` records who
     claimed), and picks the spinner back up the moment nobody does.
   - **The claim reads the working *level*, not the start edge**
     (`AgentActivityTracker.isWorking`). An edge that arrives while the program
     still owns its busy is spent, and a screen that keeps moving produces no
     second edge until it has first gone still — so an edge-triggered claim
     could never recover a turn whose signal dropped halfway, which is the whole
     case this exists for.
   - **A busy it only corroborated is announced late, or not at all.** On a
     session with a channel of its own, the tier's quiesce needs the busy to
     have lasted `minBusyForCorroboratedQuiesce` (10s) rather than 2s before it
     raises anything. Watching those sessions re-exposes the old "two stray
     repaints on an idle TUI look like a short turn" bug for them, and ten
     seconds is past anything a repaint pair produces and short of any turn
     worth a badge. Real work that lost its signal mid-turn is unaffected: the
     re-claim lands inside `busyContinuationWindow`, so the episode keeps its
     original start.
   - **A settle window checks the session is still quiet before it fires.** A
     subprocess's `9;4;0` clears the spinner, the tier re-claims the still-moving
     screen on its next sample (up to a full interval later), and that can land
     after the 1s settle. A session busy again by then, or a debounce away from
     it, did not finish, and the phantom "Finished, your move" is dropped.
   - `speaksForItself` now decides **cost, not authority**. The App Nap
     assertion is held for a session with no channel of its own, for any
     session whose busy this tier *claimed* (a subprocess's progress can make a
     silent agent look like a speaking one; the assertion must not be fooled
     with it), and while a settle window is ticking towards a notification.
     Everyone else gets a spinner, and a spinner nobody is awake to see is not
     worth a wakeup.
   - It never watches a session with no agent marker. It *does* watch the one
     you're looking at (it didn't, once, and a silent agent had no spinner in
     the session you were watching it work in); your own keys, pastes, clicks
     and scrolls re-baseline that tracker (`SurfaceView.onUserInput`) so typing
     a prompt is never read as the agent working.
   - **Two changed samples within 5s** make a working agent; one does not. A
     terminal repaints for reasons that aren't the agent — a window/inspector
     resize re-wraps every session at once, and a focus report makes every agent
     TUI redraw when you ⌘-tab — and each of those is a single frame.
   - Those two events (`SurfaceView.onSizeChange`, app activate/resign, window
     occlusion) also re-baseline every tracker, so the repaint they cause is
     thrown away rather than counted.
   - `AgentPrompt.looksBlocked` decides how loud a turn-end is. "esc to
     interrupt" is a *working* marker and vetoes the blocked reading — it is not
     a prompt affordance, however much it looks like one.

Focus matters: Codex, crush, Amp, and Gemini only notify while the terminal
reports *unfocused* (DECSET 1004). Wortel reports per-surface focus =
first-responder **and** key window (`SurfaceView.updateFocus`), so switching
sessions, ⌘-tabbing away, or minimizing all propagate to the agent.

The bundled shell integration suppresses its synthetic per-command `9;4;3`
for known interactive programs (agents, editors, pagers, REPLs — see
`_ghostty_wortel_interactive` in the zsh/bash/fish integrations), because they
never return to the prompt; the agent's own signals take over.

## Per-agent status (out-of-the-box defaults, terminal = ghostty)

| Agent | Busy | Attention (needs you) |
|---|---|---|
| Claude Code | ✅ OSC 9;4 + braille title | ✅ quiesce on 9;4;0 (permission prompt + turn end) |
| Pi | ⚠️ screen-activity fallback by default — for OSC 9;4 enable `terminal.showTerminalProgress` (`/settings` → Terminal progress, or `~/.pi/agent/settings.json`; off by default since pi 0.7x, [#3588](https://github.com/badlogic/pi-mono/issues/3588)) | ⚠️ same switch → quiesce at turn end; official `notify.ts` example extension adds OSC 777 |
| Codex | ✅ braille title spinner | ✅ OSC 9 notification (turn end + approvals, unfocused only) + "Action Required" title |
| Gemini CLI | ✅ `✦`/`⏲` title | ✅ `✋ Action Required` / `◇ Ready` title edges; opt-in `general.enableNotifications` adds OSC 777 |
| crush | ✅ OSC 9;4 (gated on ghostty XTVERSION) | ✅ OSC 99/777 (permission + turn end, unfocused only) |
| Amp | ✅ braille title spinner | ✅ OSC 777 ("Waiting for Approval" / "Agent is ready", unfocused only) |
| opencode | ❌ nothing (title has no marker) | ⚠️ opt-in `attention.enabled` → OSC 777 |
| aider | ❌ | ⚠️ opt-in `--notifications` (spawns terminal-notifier/osascript itself) |
| goose | ❌ | ❌ (static 🪿 title only) |

## Gotchas learned the hard way

- Claude Code compacts a long conversation on its own while it sits idle (over
  200k tokens, 54 minutes after its last activity, so the summary is written
  before the 1h prompt cache expires; `"idleCompaction": false` turns it off).
  It looks exactly like a turn for 20 to 70 seconds, so every waiting session
  used to get a "Finished, your move" an hour after you left it, and again
  after the next one. The terminal can't tell, the transcript can: an
  `isCompactSummary` entry, or an `informational` system entry starting
  "Compacted while idle", with no assistant entry after it
  (`ClaudeTranscriptTail.Verdict.noTurn`). It takes both, because the note can
  arrive after the settle window, and up to ~950 KB of restored files sit
  between the two, past the tail read. Its sibling, "Compacted using a summary
  written while you were away", is written inside a real turn and means nothing
  here.
- A screen-tier quiesce on a Claude session is checked against the transcript
  too: a turn writes to it, so a guess with no entry since the busy began was
  a repaint, and raises nothing. Seen on 2026-10-30: three sessions idle for
  hours were claimed at 16:02:00 and dotted at 16:02:05. After a relaunch an
  idle session hasn't spoken, so it isn't `speaksForItself`, and the guess
  needed 2s of busy rather than the corroborated 10s. What repainted them is
  unknown, and other agents still get these, having no transcript to ask. The
  session recap
  (`away_summary`, ~3 minutes after a turn while unfocused) raised nothing in
  two live captures.

- Claude Code's OSC 9;4 is gated on `TERM_PROGRAM=ghostty` — captures under
  `xterm-256color` show nothing. Its "auto" notification channel sends **no
  bell and no OSC 9/777** under Ghostty; the 9;4;0 edge is the only signal.
- Pi emits OSC 133;A/B/C zone marks around every message. The libghostty core
  synthesizes a `COMMAND_FINISHED` (small duration) from a mid-session `133;A`,
  which used to clear busy: with progress on, Pi's 1s keepalive re-armed it
  (SessionManager treats a re-arm within 3s as a continuation of the same run
  so the ≥2s attention gate stays honest); with progress off, nothing did, so
  the screen-inferred spinner vanished mid-turn and the turn-end went
  unannounced. `onCommandFinished` now ignores the event entirely while an
  agent marker is live (the shell hasn't come back; the marker vanishing at
  its next prompt is what clears busy instead), and deliberately does *not*
  cancel a pending quiesce raise.
- Ghostty's GTK apprt drops progress not refreshed within 15s ("bad actor"
  protection). Wortel must NOT copy that: Claude Code emits a single `9;4;3`
  per turn with no keepalive. Stuck-busy safety comes from `COMMAND_FINISHED`
  firing at the next shell prompt instead.
- macOS notification banners require a signed `/Applications` build
  (`./scripts/release.sh`); ad-hoc Debug builds only get the sidebar dot and
  Dock badge.
- **Codex blinks its action-required title.** While blocked on the user its
  title alternates "[ ! ] Action Required" and "[ . ] Action Required", a
  retitle per blink for as long as the question stands. `titleChanged` used to
  raise attention on every arrival, and the app layer re-posts the session's
  notification on every raise; a `UNNotificationRequest` with the same id
  *replaces* the delivered one, but each replacement slides a banner in again.
  One pending question was a waterfall of banners (reported from a Codex
  session with a queued mid-turn question, 2026-10-19). Two guards now:
  `titleShowsActionRequired` makes the marker an edge rather than a level, and
  `raiseAttention` drops any signal that says exactly what the standing
  attention already says (same kind, title and body), whichever channel it
  came in on, so a bell every few seconds is one banner too.
- **A failed `KERN_PROCARGS2` read is not an absent agent.** `AgentLiveness`
  finds most agents only by their arguments, because the cheap `p_comm` pass
  misses them: pi, gemini and amp are `node`, aider is `python3`, and Claude
  Code renames itself to its version (`p_comm` reads `2.1.272`, measured). Only
  codex, crush, goose, opencode and cursor-agent ship a binary under their own
  name and skip the read. That read is a size probe followed by a read,
  and a live process can grow its argv in between, so it fails routinely on a
  healthy one. `ProcessTable.arguments` flattened that to `[]`, which looks
  exactly like a process that was searched and didn't match, so the minute
  sweep declared a running Pi gone and deleted its marker — and nothing writes
  a marker again until the shell reaches a prompt the agent is holding. The
  session lost its spinner mid-turn (`refreshAgentActivity` reads a vanished
  marker as the shell returning and clears busy) and never got it back.
  Intermittent and total, but only *visible* on agents with no other channel:
  `markBusy` from OSC 9;4 or a title marker never consults the agent marker, so
  Claude and Codex kept their spinners and lost only resume, the agent badge and
  the `onCommandFinished` suppression. Pi, aider, opencode and goose have
  nothing but the marker-gated screen tier, so they lost everything. Fixed by
  `ProcessTable.argumentsIfReadable` returning nil for "couldn't read", which
  `locate` turns into `.unknown`, plus `sweepsBeforeDroppingMarker` so no single
  reading can delete a marker. Anything else that decides an agent is gone owes
  the same two guarantees.


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

What clears it differs on purpose. A background session's attention is
answered by Wortel coming forward with it selected, or by selecting it. An
attention raised while its session was *already on screen* can't be answered
by being on screen: a display waking from sleep uncovers the window, and
re-activation can happen without anyone reading anything. So such a session is
remembered (`raisedWhileAway`), and `appDidBecomeActive` and
`windowVisibilityChanged` leave it alone; it clears when you type, click,
paste or scroll in its terminal (`SurfaceView.onUserInput`, the hook the screen
sampler already uses), or select it as usual. Coming back and clicking
another session leaves it as any background session's dot.

## What the banner says

A turn that went quiet (`announceTurnEnd`) is announced with the start of the
agent's last answer, not a fixed "Finished, your move": with three agents
going, the fixed text said a turn ended and not which one or how it went.
`AgentAnswer` makes the first paragraph of prose of the final message into
plain text: code blocks, tables, rules, JSON and HTML lines skipped, headings
skipped unless nothing else is left, list markers dropped (each item made a
sentence), emphasis, links, images and code spans unwrapped, whitespace
collapsed, cut to 180 characters at a word with an ellipsis.

Where it is read from, each found the way resume finds the conversation
(`liveConversationID`), only the last 256 KB, off the main thread:

- **Claude**: the transcript (`ClaudeTranscriptTail.lastAnswer`), in the same
  read as the verdict. A pending `AskUserQuestion` gives its first question, an
  `ExitPlanMode` the plan's first paragraph.
- **Codex**: the rollout (`AgentConversation.Codex.file`, by the day its UUIDv7
  id was made): `task_complete`'s `last_agent_message`, else the last assistant
  `message`.
- **Pi**: the session file (`AgentConversation.Pi.file`): the last assistant
  `message`'s text.

The fixed text stays for everything else: another agent, no conversation id,
an answer that is only code, nothing written since the turn began, a tool call
still waiting (Claude's "I'll run the tests" before a permission prompt is not
an answer), an interrupted turn, and errors, whose words are the error's. The
text is the agent's own, so it is quoted as written, dashes and all.

## The name on the banner

A notification is posted with the session's name, and the session is very
often renamed moments later: `progressEnded` raises the attention and then
calls `considerAutoName` on the next line, which runs the on-device model
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
