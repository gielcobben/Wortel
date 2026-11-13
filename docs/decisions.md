# Decisions

What was decided, why, and what was tried and taken out. Its job is to stop a
deliberate choice being undone by someone who didn't know it was one, and to
stop a dead end being walked a second time.

Look here before changing how something works. If what you want to build is
listed under "tried and dropped", the reason it was dropped is the thing to
answer first.

Each entry has a date, the decision, the reason, and the commit where the
reasoning is written out in full (`git show <hash>`). Add to it in the same
commit as the change: one entry, newest last within its section. An entry is
never deleted; a reversal gets a new entry that names the old one.

Deeper records for single areas: `macos/docs/worktrees.md`,
`macos/docs/file-preview.md`, `macos/docs/session-naming.md`,
`macos/docs/cli.md`, `macos/docs/telemetry.md`, `macos/docs/running-processes.md`.

## The product

- **2026-07-10. The name is Wortel.** It was Vellum for the first two days
  (`240164f`). A rename to Terminaal was built on the branch
  `rename-to-terminaal` on 2026-07-29 and parked there. `main` is Wortel.
- **2026-07-08. Configuration is the bundled `wortel.conf` and nothing else.**
  The user's Ghostty config is never loaded, and neither are CLI arguments,
  which on macOS means Xcode's debug flags (`0197ac4`).
- **2026-09-03. No settings window, ever, and `wortel.conf` cannot grow keys.**
  libghostty rejects keys it doesn't know. A preference becomes a command or a
  checkmark menu item (`c770301`, `14764bd`).
- **2026-09-29. "Wortel has no tabs" was reversed.** Tabs in three fixed places:
  the main area, a side column, a bottom strip. Still no splits and no free
  grid. The terminal engine's own tab and split actions still return
  "unhandled" (`9c864df`, `50ec9ca`).
- **2026-08-08. "Deliberately no CLI" was reversed.** The `wortel` command
  exists so that Wortel never needs a per-agent integration (`76ea9f8`).
- **2026-08-04. No invented benchmark numbers**, on the site or anywhere
  (`a55082b`).

## Window, terminal and keys

- **2026-07-08. The window paints the background; the terminal is transparent
  with no blur.** Blur costs the compositor every frame (`1206fcc`).
- **2026-07-14. The shell is AppKit split panes hosting SwiftUI.** It went
  AppKit, then SwiftUI `NavigationSplitView`, then back. A SwiftUI inspector is
  a fixed thickness and resizes the window instead of its siblings (`2cc5b81`).
- **2026-07-08. ⌘A clears the input line; Select All is ⇧⌘A.** It flips to ⌘A
  only while a text field or web view has the keyboard (`338b28c`, `abc2146`).
- **2026-07-10. `mouse-hide-while-typing = false`.** It hid the pointer across
  the whole app, not only over the terminal (`8c89a2f`).
- **2026-08-10. A multi-line paste is not confirmed.** Pasting an agent's
  output back is the central gesture here (`fed9ce4`).
- **2026-09-04. The global hotkey is a Carbon hot key, hardcoded.** An event
  monitor would need the Accessibility permission, which a zero-config terminal
  should never ask for (`84fe389`).
- **2026-09-29. Tried and dropped: search in the terminal's scrollback.** Added
  and removed the same day. Agents run in the alternate screen, so it saw one
  screen (`39cc6fa`, `07b4af6`).
- **2026-09-29. A terminal resizes once per pane animation and never while
  hidden.** Every resize re-wraps the screen and sends SIGWINCH to the agent
  (`2dfae43`, `c20f403`).
- **2026-10-07. ⇧⌘[ and ⇧⌘] are tabs**, the system's convention. Sessions are
  ⌥⌘↑ and ⌥⌘↓ (`c87fd17`).
- **2026-10-20. A reload of the config is applied synchronously on the main
  thread**, as Ghostty.app does. Applied a turn later, a program asking for the
  background colour got the old one. See `incidents.md` (`3d8e922`).

## Sidebar

- **2026-07-13. No SwiftUI double-tap or `.contextMenu` on a list row.** A
  double-tap gesture holds every single click for the double-click interval.
  Use AppKit's `doubleAction` and the click catchers (`f4ea301`, `643fe42`).
- **2026-07-28. A row is one line.** The path subtitle and the running-agent
  subtitle were both dropped (`b14563c`, `4b70440`). The one exception since is
  a worktree row, which carries its branch on a second line.
- **2026-09-08. A folder carries a directory, and a new session in it starts
  there.** Where there is none, it starts where the selected session was born,
  not where its shell has wandered (`e032078`).
- **2026-09-09. A generated name can never create a folder.** Its slash is
  replaced with a look-alike. Only a slash typed by hand moves a session
  (`6759a87`).
- **2026-09-29. Tried and dropped: a "Needs You" section.** Removed the same
  day: rows appeared twice and the list jumped. A second line on waiting rows
  replaced it and went too. What stays is the dot, a tooltip, View ▸ Sort
  Unread First, and ⌥⇧⌘↓ (`02403df`, `eb55c35`, `3e03d28`).
- **2026-09-29. "Delete Folder" is "Ungroup Sessions"**, so it cannot read as
  touching the disk (`6965cd7`).
- **2026-10-15. Tried and dropped: an Archived fold under each folder.** A day
  of it was clutter. ⌘P finds what is put away (`af02d49`, `290d46f`).
- **2026-11-09. ⌘1 to ⌘9, ⌥⌘↑/↓ and the row picked after a close follow the
  rows as drawn**, not the stored order (`24697f0`, `653029d`).

## Sessions

- **2026-09-08. A name comes from the best source that has spoken:** the user,
  the agent's own title, the first prompt, the on-device model, a placeholder.
  The prompt is read off the pty, never through a hook in an agent's config
  (`d25e1da`, `9707353`).
- **2026-09-29. Nothing is saved before the session file has been read.** An
  unreadable file is set aside, never overwritten. See `incidents.md`
  (`229f024`, `d024540`).
- **2026-09-30. One Wortel per data folder.** A second copy brings the first
  forward and exits. Test builds get their own folder (`f9de25c`).
- **2026-10-14. A session gets a block of ten ports.** `WORTEL_PORT` holds the
  first, and `CONDUCTOR_PORT` is set to the same. `PORT` is left alone on
  purpose (`f580fad`).
- **2026-11-09. Four ways to start a session, and only four:** ⌘N, ⌥⌘N at
  home, ⇧⌘N on a branch, ⌘O somewhere else. Cut that day: Fork Session, Open
  Branch (⇧⌘O), New Folder, Move To, Change Directory, `wortel fork` and
  `wortel cd`. Seven ways in was more than anyone kept apart. Don't add a fifth
  without answering that (`b447405`).

## Attention and agent detection

- **2026-07-10. Take the agent's own signal; fall back to the screen.** No
  list of per-agent screen patterns, no sniffing the Enter key. Those are what
  make the indicator flaky elsewhere.
- **2026-07-13. Attention has kinds, and a louder kind is never downgraded.**
  A sound plays for a fresh episode or a jump to a louder kind, and "finished"
  is silent (`dd7615a`, `7973141`).
- **2026-08-05. Trust in a self-reporting agent has no timeout.** Claude sends
  one progress report per turn and no keepalive, so a timeout made a thinking
  agent look silent. And one changed frame is never work: it takes two within
  five seconds, re-baselined on resize and activation (`a40d7b8`).
- **2026-09-09. An agent is found by its process name first, then by its
  arguments, and liveness fails open.** Unknown counts as running, and a marker
  needs several misses before it is removed (`4c62c74`, `b09005a`). The
  argument pass accepts any path component equal to the name, so a tool running
  out of `/tmp/claude-501/…` reads as Claude. That is why it is never used to
  pick a process to signal.
- **2026-09-17. For the jobs list the match is strict:** an argument counts
  only as the program's own file or its package directory.
  `claude-demo/server.js` was being read as an agent, and a false positive
  there hides a real server (`fb118d7`).
- **2026-10-30. For Claude Code and Codex, a turn end must be backed by the
  agent's own conversation file.** An idle compaction, a recap or a spinner at
  startup is not a turn. An agent that keeps no such file, and a file that
  cannot be read, keep the older signals (`ea8fc85`, `b9da818`).
- **2026-11-02. A minute without input counts as away**, and scripted input
  from `wortel send` is not the user coming back (`38fd58b`, `61aab5e`).
- **2026-11-10. No notification for an answer already read** (`bfab785`).
- **2026-09-10. The screen fallback stays for Pi.** An upstream request for it
  to report progress was declined.

## Agent resume

- **2026-07-22. The running agent is recorded at quit**, because the shell's
  last prompt deletes its marker (`588c518`).
- **2026-10-07. Resume by exact conversation id.** Guessing by file time (the
  first transcript born after the agent started) put three sessions into one
  conversation (`a94573c`, `c7e95d5`).
- **2026-10-07. A marker is renamed into place whole, and a shell clears only
  the marker it wrote** (`1f5f80b`, `7e715c7`).
- **Never signal a process found by matching its command line.** Take the
  agent from the terminal's foreground process group.

## Keeper

- **2026-08-09. The keeper passes the pty's descriptor and never forwards
  bytes.** Exactly one reader per pty. Throughput measured the same as a local
  pty (`2f5f2f1`).
- **2026-09-14. Repaint after a reattach by a real size change.** SIGWINCH
  alone repainted one session in nine (`9eb98e5`).
- **2026-09-17. Terminal modes are recorded by the app and declared again
  before the replay.** The keeper cannot do it: while attached, the app is the
  one reading (`cd53f94`, `e14c917`).
- **2026-10-07. The replay is written off the main thread** (`2c3303d`).
- **2026-10-07. Tried and dropped, twice: moving the keeper out of the app's
  reach.** As a launchd agent, then as a background-only helper app. The Dock
  still offered "Stop Running in Background" both times. Real separation needs
  private API, which is not used. The answer is recovery (`da09bc4`/`0066004`,
  `6a09af8`/`3500073`, `198a870`).
- **2026-10-07. The protocol version stays "1".** A bump ends every running
  shell on update. Every addition is optional, both ways (`c9b9713`).
- **2026-10-08. A keeper holding shells is never replaced because a ping
  failed or its build is older.** Only when it answers and names another
  protocol.

## Worktrees

`macos/docs/worktrees.md` is the full record, with the survey behind it.

- **2026-08-07. Worktrees live outside the repository by default**, in
  `~/.wortel/worktrees`. A repository can name another place with
  `wortel.worktreePath` (`7d8d057`). Removal is never forced (`205a1da`).
- **2026-08-10. A new branch forks from the default branch's remote ref**, not
  from where you stand. `--from HEAD` stacks on purpose (`698ce52`, `323d4a6`).
- **2026-10-06. Cleanup inspects first, moves to the Trash, and never runs
  `git worktree prune`**, which would forget a worktree on an unmounted volume
  (`0949df6`).
- **2026-10-14. Ownership is a recorded marker, not a path.** Wortel removes
  only what it made, and never locks a worktree. The old default paths still
  count, for worktrees made before the marker (`614c303`).
- **2026-10-14. Closing a worktree session archives it**, into its own file, so
  an older build never starts it as a live shell (`af02d49`).
- **2026-10-27. ⇧⌘N has its sheet back**, with Return as the instant path. It
  was sheetless for two weeks, and choosing the base and the place was missed
  (`e1ec96b`, `7d8d057`).
- **2026-10-14. Pull requests are plain git refs.** No `gh` (`36f4a57`).
- **Dropped on purpose:** a Spotlight exclusion marker, a Time Machine
  exclusion (worktrees hold uncommitted work), diff stats on rows (git per row).

## Git panel

- **2026-07-15. `git log` runs without `--topo-order`** and the window is
  re-sorted in-process: 870 ms against 20 ms on a large repository. Adding the
  flag back "for correctness" is the trap (`283d943`).
- **2026-07-15. History is read-only and HEAD-only. Checkout never forces**
  (`96d8a5f`, `c5fd8d7`).
- **2026-09-14. Pull is fast-forward only.** There is no conflict UI
  (`ace5ace`).
- **2026-10-06. Only the repository on screen does git work.** Every git gets
  `core.fsmonitor=false`. Other worktrees are read when asked, never on a timer
  (`c20f403`, `9b366bb`).
- **2026-10-06. git runs in its own process group with a time limit**
  (`bf6d719`).
- **2026-10-13. Tried and dropped: a pull-request button.** It made a network
  call every minute (`c80edaf`, `3c0646b`).
- **2026-10-21. The panes show the session's own folder**, not where its shell
  or its agent has gone inside the same repository (`8ffb707`, `c704b8a`).

## Files, previews, browser

`macos/docs/file-preview.md` is the full record.

- **2026-07-31. The file tree is read-only and lists only expanded
  directories**, with one watch per open directory. Move to Trash is the one
  exception, because `rm` has no Trash (`93e1ddb`, `45a2d8c`).
- **2026-08-06. Tried and dropped: a preview that follows the selection, with
  a pin.** Two gestures made three states.
- **2026-08-07. Tried and dropped: a TextKit Markdown renderer.** It won
  selection across blocks and lost everything else (`5681398`).
- **2026-08-10. Remote images in Markdown are not fetched, and links go
  through a scheme allowlist** (`6717464`).
- **2026-11-09. A page or a document never opens another app without a yes**
  (`fd2d45c`).
- **2026-09-29. Files and browsers are tabs.** The Markdown preview moved from
  the column to a window to a tab. The browser was a pane, was removed as
  unused after six days, and came back as a tab. The separate browser window
  was dropped (`0e13607`, `6ee3e30`, `09ce308`).
- **2026-11-13. Markdown front matter renders as a YAML code block**, not as
  a table like GitHub's (front matter nests) and not hidden (it is part of the
  file). Detection is strict, because `---` is also a rule and a setext
  underline.

## Running processes

- **2026-09-14. A job is a tree of processes inside a process group, usually
  the whole group. Memory is footprint, not RSS. An agent is never a row you
  can kill. No probing ports over HTTP** (`23deb3b`, `474be65`).
- **2026-09-17. A detached server is tied to its session only when its group
  holds a listening port.** Excluding `.app` bundles instead hid Electron dev
  builds (`fb118d7`).

## The command

`macos/docs/cli.md` is the full record.

- **2026-08-08. No installer, no symlink.** The binary is in the bundle and on
  the `PATH` of every shell Wortel starts (`c5e4c42`). The target is
  `WortelCLI`, because a target named `wortel` collides with the app's in the
  build intermediates on a case-insensitive disk (`76ea9f8`).
- **2026-08-08. It never activates the app.**
- **2026-10-14. A new verb or flag is its own case on the wire**, so an older
  app refuses it instead of half-doing it (`e1ec96b`).
- **2026-11-03. `wortel send` has no prompt and no label**, like a person
  typing. Replies are never written on the main thread (`c065094`).
- **Rejected when the reach verbs were planned:** usage meters and rate-limit
  auto-continue (agents show that themselves), nested child sessions,
  user-named sections.

## Shell integration

- **2026-07-10. The start of a command is a real event**, an OSC 9;4 emitted
  from the bundled integration's preexec hook, because libghostty has no
  "command started" action. Long-lived interactive programs are skipped.
- **2026-07-15. OSC 7 reports `localhost`, not `$HOST`** (`fcf5052`).
- **2026-07-29. A change goes into all three shells.** The fish copy often
  cannot be run before it ships. That fix left fish out for that reason
  (`aa715d5`); later ones went in marked untested. Say which in the commit.
- **2026-08-08. PATH is set through `WORTEL_BIN_DIR`, and `Contents/MacOS` is
  removed from it in zsh and bash.** fish and elvish get the prepend only.
  libghostty's `env_vars` only adds and was silently ignored (`b24f2bb`).

## Release and updates

- **2026-07-10. Versions are the date:** `<ISO year>.<ISO week>.<n>`. It went
  semver, integer, then this, in one day (`fb2fdd1`, `b1edbd3`).
- **2026-07-13. No Sparkle deltas.** Full zips only (`3e6aa5f`).
- **2026-07-30. The version comes from the live feed, not a local file.** See
  `incidents.md` (`10c089d`).
- **2026-08-09. One Markdown note per release; publishing without one is
  refused** (`677a75c`).
- **2026-08-10. `updates/` is its own Worker.** The update channel must not go
  down with a bad site build. Serving comes before counting (`5e40cea`).
- **2026-10-07. Updates download quietly, with a one-click restart.** A
  "What's new" icon after an update was dropped (`9c72bcf`, `5f99cb2`).
- **2026-11-09. A publish runs the tests, refuses uncommitted changes, and
  builds against tracked package versions** (`1f55136`, `38a56b0`).

## Telemetry and privacy

`macos/docs/telemetry.md` is the full record.

- **2026-08-10. No event takes a `String`.** Opt-out, off in one menu item,
  silent under `DO_NOT_TRACK`, in a Debug build and in a locally built Release.
  No buffer on disk (`30606e7`).
- **2026-08-10. The notice is a popover with a switch, not a consent dialog**
  (`e57d111`).
- **2026-08-10. The site's analytics store nothing on the device.** Country
  only, no location from the IP (`4ea8d49`, `fbd7a9a`).
- **2026-08-10. The privacy page lists every event**, and says that update
  checks cannot be opted out of (`ccdaa86`).

## Website

- **2026-08-04. No em-dashes in anything served or generated** (`d4297da`).
- **2026-08-11. Tried and dropped: scroll snapping**, even `proximity`
  (`3ca76ee`, `1aeddd4`).
- **2026-08-11. Tried and dropped: a raster screenshot of the app on the
  page.** At that size the text turns to texture (`64254b8`, `2dd3400`).
- **2026-08-09. A deploy runs the npm build**, which strips the local pixel
  tools. See `incidents.md` (`fe5eb95`).
- **2026-10-08. Tried and dropped: a pinned window with scroll-driven
  chapters.** It takes the scroll away from the reader. Plain scroll; the films
  play by themselves.
- **2026-11-11. The launch design: light, one container, one left edge.**
  Rejected on the way: an icon drawn for the site, an all-dark centred rewrite,
  a row of steps under the window, windows wider than the app really is. The
  photo behind the windows was removed and then restored
  (`1c68eca`, `3d2a7e3`, `bdbabd3`).
- **The app on the site is 1:1 and generated from the canvas.** Never scaled,
  never hand-edited.
