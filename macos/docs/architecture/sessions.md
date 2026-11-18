# Sessions

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

**`Session`** (`Wortel/Sessions/Session.swift`) — one sidebar entry = one shell
= one surface. The `SurfaceView` is created **lazily** (`ensureSurfaceView`) and
then kept alive until the session closes; switching sessions never rebuilds a
view.

**`SessionManager`** (`Wortel/Sessions/SessionManager.swift`) — `@Observable
@MainActor`, the single source of truth for the session list, `selectedID`, and
inline-rename `editingID`. Setting `selectedID` (from a click *or* a menu
shortcut) is the one code path that lazily spawns the selected surface. On
launch, `restore()` spawns only the selected session's shell before the first
frame, then `warmRemainingSurfaces()` warms the rest one-per-runloop-turn so
launch stays lean. `wire()` connects each surface's callbacks (title/pwd/bell/
close) back to session state.

**Where a new session starts** is `SessionManager.newSession`, and it is the one
piece of session handling with a rule worth stating. A sidebar **folder carries a
directory** (`folderRoots`, UserDefaults beside the other three folder keys) —
before that it was purely the part of a name before the last slash, so "New
Session in “GFPC”" filed a session under GFPC and started it wherever the
*selected* session was standing, which looked exactly like it had worked. The
resolution order is: an explicit `cwd` (the CLI, a worktree, ⌘O), then the named
folder's directory, then the selected session's **`originCwd`**, then that
session's folder's directory, then nil so `wortel.conf`'s `working-directory =
home` answers. Two things about it are load-bearing:

- **`originCwd`, not `cwd`.** `cwd` tracks the shell's pwd reports, so
  inheriting it meant a session opened beside one you had taken three levels
  deep started three levels deep too, and the next one inherited the drift
  again. The birth directory is the deliberate answer and never moves.
- **Each remembered path is `stat`ed before it is used** (`existingDirectory`),
  because `chdir` is best-effort: a project that moved on disk would otherwise
  silently start the shell somewhere else instead of falling through to the next
  answer. The stored root is *not* cleared when that happens — an unmounted
  volume must not look like lost configuration.

`FolderRoot` (pure, in `WortelTests`) holds the path handling: containment that
respects component boundaries, the deepest-root match ⌘O files into, and the
one-time derivation that gives folders predating the feature a directory from
where their sessions already are.

**`SessionStore`** (`Wortel/Sessions/SessionStore.swift`) — debounced JSON
persistence of the session list (order, names, cwds and origin cwds, selection,
git-panel visibility) to `~/Library/Application Support/Wortel/sessions.json`.
This is *app state*, not user config — Wortel stays zero-config. Decoder
tolerates older files missing fields. `saveNow` runs synchronously on
termination.

**Terminal modes across a reattach** (`Wortel/Ghostty/TerminalModes.swift`) —
the keeper keeps a session's shell alive across a relaunch, so the *program*
never restarts, but its terminal does: a new libghostty surface starts with
every mode at its default while the program still believes what it set. That
costs a paste its brackets (`?2004`), and each pasted line then arrives as
Enter. So the app watches the output it already handles, records the sticky
modes, persists them per session, and re-declares them into the new surface
*before* the keeper's replay. **The watching cannot live in the keeper**: while
a session is attached the app reads the pty itself, which is exactly when a
program declares its modes. The replay's own queries get answered by the new
surface, long after the program stopped waiting, so those answers are dropped
(`ReplayAnswers`, `PtyHost.writeFromTerminal`) until a marker query parsed
after the replay comes back: libghostty writes answers from its IO thread a
moment after parsing, so "the replay was written" is not "its answers are out".
See `docs/terminal-modes.md`.

**Attention** (`SessionManager`'s Attention section, `docs/agent-signals.md`)
— a session that wants you gets a dot, the Dock badge and a notification,
unless you're looking at it: Wortel frontmost, window on screen, session
selected, **and the Mac touched in the last minute** (`userIsAway`, the
window server's idle time, read when a signal arrives). An attention raised
on the session on screen while you were away is cleared only by your input in
its terminal or selecting it, never by activation, the window uncovering or
a `wortel send` (`raisedWhileAway`, `sendText(scripted:)`). A turn end's notification body is the start of the
agent's last answer (`AgentAnswer`, from Claude's transcript, Codex's rollout
or Pi's session file), with the old fixed text as the fallback.

**Session naming** (`Session.NameSource`, `Wortel/Sessions/AgentTitle.swift`,
`Wortel/Sessions/PromptCapture.swift`, `Wortel/Ghostty/PromptTap.swift`,
`SessionNameGenerator`) — a row's name comes from the best source that has
spoken, in this order: a user rename, the agent's own terminal title (Claude
Code titles its conversation from the first prompt and pushes `✳ <title>` as
the terminal title, which `AgentTitle` parses), a title the on-device model
makes from the first prompt the user typed into the agent (a `PromptTap` on
`PtyHost.write` reads it back for any agent, no hooks or config files
involved), the model's screen summary, and the placeholder (the directory, or
the branch for a worktree session). Worktree sessions are named for their task
and carry the branch on a second row line. See `docs/session-naming.md` for
the reasoning, the privacy scoping of the tap, and what the other tools do.

**Deep sleep** (`AgentSleep`, and the "Deep sleep" section of `SessionManager`)
ends an idle agent and resumes it when its session is selected. The rule and
what was seen with a real agent are in `docs/decisions.md` (2026-11-18); how
it is built:

- **`AgentSleep.decide`** is the whole decision as values, tested alone. The
  two clocks are constants, shortened for a test by `WORTEL_SLEEP_AFTER` and
  `WORTEL_SLEEP_WAITING_AFTER`, which `main.swift` reads before the launch
  environment is scrubbed (read later, a test's thirty seconds is the hour).
- **No polling.** One timer per session with a resting agent, armed when it
  stops working (`clearBusy`) or its session is left, cancelled when it works
  or is selected. The process table is read when the timer fires.
- **`sleepCandidate`** establishes the agent from one process table: the
  marker on disk is this run's, its shell is this terminal's, the group in the
  terminal's foreground (the table and `PtyHost.foregroundProcessGroup` must
  agree) is led by a child of that shell, and a process in it has Claude's own
  record (`AgentResumeStore.claudeProcessState`), which gives the conversation
  and the status that picks the clock. Any miss leaves the agent alone and
  says why in the `sleep` log.
- **`Session.sleep`** (`awake`, `ending`, `asleep`) is apart from `owedResume`
  on purpose: an owed resume is typed when a terminal is made, and launch
  makes them all. It is not observed, so no view can draw it. Saved as
  `agentAsleep` beside `runningAgent`, before the signal is sent; a build
  from before the field resumes at launch instead.
- **Waking** (`wake`, which says what it came to: `AgentWake`): the selection
  staying 0.3 s, then the terminal back, the shell holding its own terminal
  with nothing under it and no marker, and the resume typed with
  `SurfaceView.typeCommand`. A shell not yet at a prompt is asked again for
  five seconds, because one made a moment ago for a restored session is
  still reading its startup files. The typed resume is an `owedResume` with
  `typedAt`, so the agent starting is confirmed as any typed resume is, and
  the session stays `asleep` until then. A resume that never starts is typed
  again when the session is next asked for, three times at most; after that
  the session is a plain shell, since one that says it is bringing an agent
  back for ever is worse.
- **The seconds between the signal and the agent going** are a state of
  their own (`.ending`). A session selected or sent to in them is remembered
  (`wantsWake`) and brought straight back once the agent has gone, and
  `wortel send` types nothing, as for one asleep. Whether it went is asked
  of the process, not of the marker, which is the shell's to remove at its
  next prompt and can lag by more than the ten seconds given.
- **Whose record.** The agent's own word comes from the process that has the
  terminal; through a wrapper, from the one process in its group that has a
  record, and from none if there are two.
- **Typed and not sent** is `lastTypedAt`, saved with the session, so a
  relaunch (the agent lives on in the keeper) does not move a half-written
  prompt from the long clock to the short one.
- **A memory warning** looks at the process table and the markers once for
  every agent and saves once before the first signal.

**Prompt history** (⌘Y, `PromptHistory`, `PromptHistoryStore`,
`PromptHistoryModel` in `SessionSwitcher.swift`) is ⌘P's panel in a fourth
mode: everything typed to Claude Code, Codex or Pi, the session's project
first (its repository home, so every worktree of it counts), and Return types
the pick into the session's own terminal **unsent**, as a paste
(`SurfaceView.sendText`, bracketed when the program asked for `?2004`; when it
didn't, the lines are joined, since an unbracketed newline is Return). Wortel
stores nothing for it: the agents' own files are read when the panel opens,
off the main thread, from their tail (4 MB a file; Pi's newest conversations
within a 16 MB budget), cut at 5000 entries, and kept only in memory keyed by
size and modification date. That memory is a value (`PromptHistoryStore`),
not a locked shared object: the model keeps it on the main actor and a load
reads with a copy and hands the copy back, so the main-thread rule holds. Ranking runs off the main thread too, the
previous one cancelled per keystroke. No index on disk, ever: that would be
Wortel keeping the user's prompts, which `docs/session-naming.md` promises it
doesn't.

Claude keeps a conversation resumed from another folder in the *old*
folder's project directory and appends there, so
`AgentResumeStore.claudeTranscript(id:cwd:)` looks in every project folder when
the session's own has nothing.
