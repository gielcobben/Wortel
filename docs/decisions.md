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
  checkmark menu item (`c770301`, `14764bd`). The window half was reversed on
  2026-11-18, below; the `wortel.conf` half stands.
- **2026-11-18. "No settings window, ever" was reversed.** There is one, on
  ⌘,, and it is kept short. A row is for something **decided once that truly
  differs per person**: the commit box in Source Control, where a server
  opens, automatic updates, anonymous usage data. Their checkmarks left the
  menus (the usage-data switch is still in the sidebar's ⓘ too). What is
  flipped while working stays a checkmark in the View menu (Sort Unread
  First, which side the column is on). What the app can know for itself gets
  no switch. Fonts, colours, keys and scrollback are still decided once, and
  font size is still ⌘+ and ⌘−. Why now: people who never file their sessions
  needed to say what a new session starts, and the answer that needed no
  setting (start the agent of the session you are on) could not be predicted
  by the person pressing ⌘N. A new row needs the same argument: who differs,
  and why can't the app know? The window is drawn as Wortel's own are (its
  titlebar row with two tabs, rows in boxes on a page), chosen the same day
  over the system's preferences window, which was built and used first
  (`macos/docs/architecture/settings.md`).
- **2026-11-18. A new session starts what Settings says, and nothing unless
  it says so.** Settings ▸ New sessions start with is one line, typed into
  the new shell as its first command (the way `wortel new -- <command>` is):
  `claude`, `claude --model opus`, anything. Empty, which is how it ships,
  is a terminal. The field has a pull-down of the agents found on the Mac,
  asked of the login shell when the window opens. All four ways in follow it.
  `wortel new` does not (a script says `--` when it wants a command), and
  neither does the session made at launch. Tried first and dropped before it
  shipped: starting the agent of the session you are on, which nobody could
  predict, and a menu of agents, which was more than the one line. Asking
  once at first launch was put off until it is shown to be needed.
- **2026-11-18. New Terminal (⌃⌘N) exists only while Settings names a
  command.** It is ⌘N without that line, in the Session menu, the sidebar's
  + and a folder's menu. With the field empty it would be a second New
  Session, so it is absent. This is the answer the "four ways" entry below
  asks for: not a fifth place to start, the same place minus one typed line.
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
  with no blur.** Blur costs the compositor every frame (`1206fcc`). Since
  2026-11-19 the terminal is opaque and draws the page itself, in the page's
  own colour, so the contrast floor can measure against it (below). Still no
  blur.
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
- **2026-11-17. A terminal out of sight for ten minutes hibernates.** Every
  hidden terminal kept its frames and scrollback, about 70 MB a session, so the
  app's memory grew with the number of sessions. Now the surface is freed (on
  a macOS memory warning, every hidden one at once) and the shell keeps
  running; the app keeps reading its pty, so the keeper is never involved. The
  screen is saved with libghostty's `write_screen_file:copy,vt` and written
  into a new terminal when shown, followed by what came meanwhile.
  `SignalScanner` reads titles, OSC 9;4, notifications, bells and OSC 133;D off
  the output while there is no terminal, so the dots keep working. Nothing
  answers a program's terminal queries meanwhile, so a running agent keeps
  its terminal unless it has been watched through a hibernation (only
  Claude Code so far). Waking takes 10 to 30 ms, and the switch waits for it
  (half a second at most), so "a switch in one frame" now holds for sessions
  seen in the last ten minutes. A
  hibernated terminal's coloured scrollback keeps the theme it was saved in.
  Side terminals don't hibernate. Measured on a test copy: 252 to 128 MB with
  seven of eight terminals hibernated. A terminal made at launch and not yet
  shown (every session gets one, for its dots and resume) hibernates after a
  minute instead, so a relaunch doesn't hold every session's frames for ten.
- **2026-09-29. A terminal resizes once per pane animation and never while
  hidden.** Every resize re-wraps the screen and sends SIGWINCH to the agent
  (`2dfae43`, `c20f403`).
- **2026-11-18. A session switch lays out the column and strip before it shows
  the terminal.** SwiftUI showed the terminal first, in the previous session's
  layout, and the column followed 10 to 85 ms later: the terminal was drawn
  too small, then grew, sometimes resized twice. Now the switch runs in the
  same turn as the selection, with resizes held, and the terminal is shown
  once at its final size. Measured with the old and new paths alternating on
  the same clicks: unchanged when the column stays put; when it opens or
  closes, the first frame comes with the column (60 to 110 ms) instead of a
  wrong frame first. Opening or closing the column itself is that cost.
- **2026-11-18. A terminal checks its size against its view whenever things
  settle.** Seen three times in a day: the terminal drawn at an old size and
  pinned top left, so either cut off by the side column (too wide) or sitting
  in a corner of its page (too narrow, once at the 45 by 15 a terminal has
  before it is told anything, for twelve minutes after a relaunch). A size
  reaches a terminal when its view is resized, and is put off while a pane
  animates or the view is hidden, to be applied by whatever ends that. Each
  hand-off can drop one, and a dropped size stayed dropped until the window
  was resized. So the terminal now remembers what it was last told
  (`toldSize`) and compares it with its view (`reconcileSize`) after a hold
  is released, after it is shown, woken or joins a window, and when its area
  is laid out, and once more 0.3 s after things settle (one check for
  however many of those come together). A stretch of holding that lasts two
  seconds is let go, whatever holds and releases happened inside it. **Which hand-off drops the size is
  not known**: it was not reproduced in a test copy (three relaunches, right
  size each time). Every catch is logged in the `layout` category with what
  it found, so the next one names its cause; this entry should be replaced by
  that fix.
- **2026-11-19. A new terminal starts at the size a session's terminal last
  had on screen, and its pty ignores it until it is told one.** Agents in
  sessions not looked at since a relaunch printed everything 45 columns wide,
  in a full-width page, for good (an agent wraps its own output, so nothing
  reflows it). Measured: eight of twelve Claude Code ptys at 15x45. A surface
  reports libghostty's placeholder grid (45 by 15) as soon as it exists, the
  pty passed it on, and a hidden terminal is never resized, so the agent
  worked at that width until shown. Reproduced in a test copy: after a
  relaunch the two sessions not on screen were sent 15x45. Now
  `PtyHost.ignoreSizesUntilTold` drops a new surface's reports until
  `setSurfaceSize`, and a surface made or woken out of sight is told the last
  size a session's terminal was shown at (kept in defaults,
  `terminal.lastShownSize`). Same test after: every pty kept 34x102, and no
  program was ever told 15x45. It may also be the "too narrow" case above.
  **The placeholder was also what repainted a relaunched terminal**, which
  starts empty: 45 then the real width was a change of width, and Claude Code
  answers one by printing its whole conversation again. (Measured again on
  2026-11-19 with 2.1.329's inline renderer under a pty harness: a width
  change of one column redraws the visible screen, not the conversation.
  Enough to repaint an empty terminal, not to recolour scrollback.) Without it the first
  builds left idle agents blank (in the running app, and 4 of 6 in a copy).
  So a relaunched or woken terminal's first size is a forced repaint
  (`PtyHost.resize`): one column narrower, and the true width back once the
  program has been quiet for 0.3 s. A brand-new session is not asked; it has
  nothing to repaint. Side terminals are told no first size: their page is
  the column's. Back to back the two reached a program as
  one SIGWINCH at the old size; back after a fixed 150 ms, or at the first
  output, they cut a reprint short and left only the coloured words on
  screen. Verified in a copy: seven idle Claude Codes, six out of sight, came
  back after a relaunch with the same text at the same width, and the one on
  screen was screenshotted correct.
- **2026-11-18. A session switches on mouse-down**, as in Finder's sidebar.
  It switched on mouse-up, after AppKit had ruled out a drag, so the time the
  button was held (115 ms a click on average, sampled) came before every
  switch. ⌘ and ⇧ still act on mouse-up, and so does a press inside a
  selection of several, which may be the start of dragging them.
- **2026-11-18. Tried and dropped: opening the column at the session's width
  by setting its frame before uncollapsing.** It saved the second layout of
  the column's content (23 ms), but the frame no longer matched the split
  view's own layout: the main pane was seen running under the column until
  the window was resized. Done properly it has to go through the split view.
- **2026-10-07. ⇧⌘[ and ⇧⌘] are tabs**, the system's convention. Sessions are
  ⌥⌘↑ and ⌥⌘↓ (`c87fd17`).
- **2026-10-20. A reload of the config is applied synchronously on the main
  thread**, as Ghostty.app does. Applied a turn later, a program asking for the
  background colour got the old one. See `incidents.md` (`3d8e922`).
- **2026-11-12. A performable libghostty binding goes before the menu**, as in
  Ghostty.app, so ⌘C with nothing selected reaches the program (`24559b1`).
  Libghostty's defaults on keys the menu owns and Wortel never handles (⌘J,
  ⇧⌘T, ⌘F, ⌘G, ⇧⌘G) are unbound in `wortel.conf`: otherwise each one does
  nothing and goes on to the program, and ⌘J typed `j` into Claude instead of
  opening the strip. To list what is still performable, ask
  `ghostty_surface_key_is_binding` for its flags; `ghostty_config_trigger`
  doesn't report performable bindings.
- **2026-11-16. The main window is movable only while fn-⌃ is held, a menu
  is open or the pointer is outside it** (`WindowMovability`). Not any
  modifier: ⌃ and ⌘ are down half the time in a terminal. Replaces
  "off only while the pointer is over the titlebar band" (`83f29e0`), which
  hung on the band's `mouseEntered` arriving before the press: the first grab
  of a tab just opened from the Files pane often moved the window. A busy main
  thread after the open and tracking areas rebuilt with `.assumeInside` can
  each lose it; neither was caught in the act. The pointer starts as inside:
  read from the frame before the saved one was applied, it left the window
  movable from launch (`e83bbd6` for why it's off at all).
- **2026-11-19. Light and dark have one source and one place.** The source is
  the app's appearance; the place is `GhosttyRuntime.syncColorScheme`, which
  tells the app handle and every terminal view there is, in a window or not.
  Before, each view told its own terminal from its own appearance, which a
  view outside a window never hears: every session not yet looked at since
  launch kept the old theme. A view's appearance is now only a reason to look
  again, as are waking, unlocking and becoming active. Ghostty.app made the
  same move (its PR #9360). `macos/docs/appearance.md`.
- **2026-11-19. The app-level config reload is answered with nothing.** It
  amends the 2026-10-20 entry, which still holds for a surface's reload.
  `ghostty_app_update_config` re-applies the config to every surface with the
  scheme that surface still holds, and each re-apply ends in a theme report:
  a program was told the old theme first, then the new one twice. Measured
  with Claude Code, which answered the first by reading a background that had
  not changed yet. A new surface takes its scheme from the app handle, so the
  call has nothing left to do here. To check again on a libghostty update:
  `macos/scripts/try-appearance.sh`.
- **2026-11-19. A hibernated screen keeps its palette colours as palette
  colours.** It reverses the last line of the 2026-11-17 hibernation entry
  ("keeps the theme it was saved in"). libghostty's dump writes them as the
  24-bit values of the moment, so the palette is swapped for marker colours
  for the dump and the markers are turned back into indices on waking
  (`SnapshotPalette`). Considered and not done: matching the dump's colours
  against the theme's palette, which also catches a program's own white.
- **2026-11-19. Text is never drawn unreadable: `minimum-contrast = 2`.** A
  program that read the colours once goes on painting the old theme after a
  change, and Codex's input box became near-white text on a near-white band.
  Below a ratio of 2 the renderer draws the text black or white. Not higher:
  the faintest colours anyone chose measure 2.28 and up, the unreadable pairs
  1.1 (`macos/docs/appearance.md`). **Taken out the same day:** with
  `background-opacity = 0` libghostty measures against a transparent, so
  black, background, and every default-foreground character on the light
  theme was drawn white on the white page. Seen in the running app, then
  reproduced in a test copy and gone with only that line removed. Back the
  same evening over an opaque page: the next entry.
- **2026-11-19. The terminal draws the page, and the floor is back at 1.9.**
  An agent with Remote Control on is never restarted at a change (above and
  below), and people who use it keep it on in most sessions, so for them the
  restart left almost everything unreadable: a hibernated inline Claude Code
  woke dark text on the dark page. The floor's measure was the bug, not the
  floor. In Ghostty 1.3.1's shader (`cell_text_vertex`) the background a cell
  is measured against is the terminal's background premultiplied by
  `background-opacity`, so at 0 it is black. Now `background-opacity = 1`
  and each bundled theme's `background` is the page colour
  (`Chrome.content`: the dark theme's `#0d1117` became `#1f1f1f`), so the
  terminal draws the page under its text and the floor measures against it;
  `PageColourTests` keeps the two equal. 1.9, measured: what a change leaves
  is 1.0 to 1.6 (Claude Code's text colour 1.27 on the dark page and 1.00 on
  the light one, its dark warning 1.63 and permission 1.88 on white), and the
  faintest colours meant to be seen are GitHub Dark's black on the dark page
  (1.99) and Claude Code's `subtle` on its own page (2.04, 2.19). Looked at
  in a test copy in light and dark, with a row of each colour and a Codex
  and an inline Claude left in the other theme: readable, plain text
  unchanged, no seam at the terminal's edge. Not looked at: a window being
  resized, where a frame pinned at its old size meets the page. Also: a program asking for the background is now told
  the colour it is on (it was told `#0d1117` on a `#1f1f1f` page). A program
  that sets the background (OSC 11) now changes what is shown, as in any
  terminal.
- **2026-11-19. An idle agent is restarted into its conversation when the
  appearance changes.** Codex reads the colours once, at startup, and keeps
  them for the life of its process; Claude Code can leave what it already
  drew. A new terminal does not help (tried: Codex redrew the old band into
  it), and a resize or a focus report changes neither (both projects'
  trackers), so a new process is the only thing that repaints. The rule: at a
  change, the idle agent in front is restarted where it stands once it has
  rested five seconds, an idle one out of sight for twenty seconds is ended
  and resumed when selected (deep sleep's mechanism, under its checks), and
  one that is working, waiting on an answer, running something, reachable by
  Remote Control or has had text typed into it since it last set to work is
  left until it next comes to rest out of sight. "Painted for the other
  appearance" is the appearance at the agent's start against the one now, so
  a change there and back restarts nothing. A click or a scroll is not text:
  reading an answer must not keep it unreadable.
  **Amended the same day: not an agent that repaints itself.** Claude Code's
  fullscreen renderer (`tui: fullscreen`, on the alternate screen) repaints
  every cell it coloured when it is told of the change, and a hibernated one
  is told when its terminal wakes. Measured in a copy, 2.1.329: hibernated in
  light, the copy turned dark, woken; its next snapshot held only the dark
  theme's colours. Restarting it only ended the process (seen: two seconds
  after it had repainted). So an agent on the alternate screen with `?2031`
  on is not painted for the other appearance
  (`TerminalModes.repaintsItselfOnSchemeChange`), by the record as it is:
  a woken terminal reports only a `?2031` on record. Known limit: the
  recorder does not see a full reset (`ESC c`, which `reset` sends), so after
  one, or after a program killed on the alternate screen, an inline Claude
  can read as fullscreen and is not restarted; the floor keeps it readable. Its inline renderer cannot:
  what it printed stays in the old colours, and a width change reprints only
  the visible screen (measured, 2.1.329), so inline Claude and Codex are
  still restarted, under the same holds. With the floor above, what they
  leave is readable until then.
  **Which agents: Claude Code and Codex.** Claude by its own record, as for
  deep sleep. Codex by its status reports (OSC 7501, 0.164 and later), the
  only word it gives on being idle; an older Codex says nothing and is left,
  with the contrast floor. Pi follows a change by itself, and no Pi that
  reports was at hand to check, so it is not in the list.
  **Codex does not say which conversation it is in**, and a `/new` inside it
  moves it without a word, so the one Wortel knows could be one it has left.
  Moving takes keys. So text that went in after the last sign of it being in
  the known conversation (its command line naming it, or a write to its
  rollout) leaves it alone (`AgentConversation.lastSeenIn`).
  **Codex has no handler for any signal**: SIGTERM, SIGHUP and SIGINT each
  end it at once with the alternate screen, mouse reporting and its keyboard
  flags left on (measured in a pty, 0.170). So what an agent switched on is
  taken back by Wortel before the signal (`TerminalModes.undo`), and put back
  if the agent does not go.
  Run in a copy of the app the same day, Codex 0.170 and Claude Code 2.1.328,
  one turn each, the copy changed between light and dark: the Codex in front
  was ended and back in its conversation 0.4 s later, painted for dark; a
  Codex and a Claude out of sight were ended, left a shell on the primary
  screen, and came back in their conversations when asked for; a Claude and a
  Codex with a prompt half written, a Claude at work, and a Codex moved to
  another conversation with `/new` were not touched; and the Claude at work
  was ended once it said it was idle and eight seconds had passed (the clock
  shortened for the test). Not seen: Remote Control keeping one awake for
  this, a real change of the Mac's appearance, and a change during a relaunch.
  A review of the code afterwards found what a test that sends text by
  script could not: a key coming up counted as text, so the release of the
  Return that sent a prompt, landing after the agent said `working`, held the
  agent for the whole turn; and the agent in front, at work when the Mac
  changed, would have been restarted five seconds into the answer it then
  gave. Both fixed, by reading, with no person at a keyboard in a test.
  Known limits: after a relaunch an agent has to take one turn before it can
  be repainted, since when it last set to work was not saved and anything
  typed since it started counts; and zsh says `terminated` for a Codex ended
  this way, which is true.

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
- **2026-11-17. A folded section keeps no gap under it.** The 14pt between
  sections sets an open section's rows apart from the next; under a folded one
  it only spread the headers out. Folded folders now stack as rows do. The
  gap is the bottom of a section's last row, so it folds with the rows, and a
  press or hover in it belongs to no row. As room above the next header it had
  to change that header's height beside the fold, and the two animations made
  the title jump.
- **2026-11-17. One sidebar toggle and one pair of arrows, over all the rows.**
  There were three sets (the sidebar's row, and the main area's or the
  column's once it was collapsed), swapped with `isHidden`: the arrows were
  clipped by the closing sidebar's edge and the next row's set popped in at
  the end. Now `SidebarControls` sits over the titlebar, the toggle never
  moves, the arrows ride the sidebar's edge and stop beside the toggle, and
  the rows to the right are pushed along by the same number every frame.
- **2026-11-18. A new session at the top level goes on top.** It went after
  the selected row, so in a list nobody arranges a new row turned up in the
  middle. Now that list reads newest first, as a list of chats does. In a
  folder nothing changed: after the selected row, or at the folder's end.
  ⌘N, do the thing, ⌘W still lands where it started, by a rule of its own:
  closing a session you just made and never left selects the one it was made
  from, as a browser tab does. Otherwise the row above, as before.
- **2026-11-19. The folders come before the sessions in no folder.** Pinned,
  then the folders, then Sessions, as ChatGPT, Claude and Codex put projects
  above the loose chats. Someone who never files a session sees no change;
  someone with many open folders folds them to reach the loose list. With no
  folderless session yet, a session is taken out of its folder by a drop in
  the empty space under the list, or, since that space is gone once the list
  overflows, at the top: the gap under Pinned's last row, or the top edge of
  the first folder's header (found in review the same day, after the top
  zones had been taken out with the section above them).
- **2026-11-19. Each section sorts itself, Recent unless you say
  otherwise.** Sort By in a folder's "…", and in the Sessions header's:
  Recent, Created, Name, Manual (one word each, as the
  submenu of Sort By needs no more; "Recent Activity" and "Date Created"
  were tried first). Every section starts on
  Recent, the ones that existed too; Manual is the order you dragged, kept
  underneath all along, so it comes back exactly. Pinned stays by hand.
  **Activity is a Return of yours** (or the session being made): not a click,
  not a scroll, not `wortel send`, and not the agent working, because rows
  that move while you aim at them is what the "Needs You" section was
  dropped for. A sorted order still waits while the pointer is on a row.
  **A drop into a sorted section goes into it**, as in a sorted Finder
  window: its header lights up, there is no line between rows, and the
  session takes its sorted place. A place in a list only exists in Manual.
  This narrows 2026-11-18's "goes on top" to Manual sections; in a sorted one
  a new session is on top by Recent or Created anyway. Sort
  Unread First still puts its band over whichever order a section has. The
  choice is view state, like a fold, not a setting.

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
  without answering that (`b447405`). `wortel cd` came back on 2026-11-19
  for agents only, with no menu item (below).
- **2026-11-16. Remind Me, as Slack has it.** Row menu, Session menu, ⌘P and
  `wortel remind`: Slack's own choices, In 30 Minutes, In 1 Hour, In 3 Hours,
  Tomorrow at 09:00, Monday at 09:00 (the next one), Custom…. A row's menu
  calls it Edit Reminder while one is set, with Cancel Reminder under it. When
  it's due the session gets the unread ring and a banner, or only a flash of
  the ring if you're looking at it. While it waits the row says when on a small
  grey line under the name ("Tomorrow at 09:00"), where a worktree's branch
  is. A row with a branch has both on that line, the time first and
  written short there ("Tue 09:00"), so the branch isn't squeezed out; a
  line that still doesn't fit slides on hover, as the name does. (Tried first, in order:
  nothing on the row, with the time greyed at the top of the submenu, which
  made a menu a place to look things up; a small clock in the status slot,
  which said nothing without a hover it couldn't get, since the slot becomes
  the "×"; that clock as a third hover button; the time as grey text in the
  status slot, which had to hide whenever a dot, a ring or the working dots
  were there. That slot is for what a session is doing now.) The row is a
  line taller for it, which a second line was once taken out for; that one
  came and went each time an agent finished, and this one comes when you set
  a reminder and goes when it reminds you. There
  is no note: the session's name is the note. One wall-clock timer, for the earliest. The banner is also left
  with Notification Center a minute late, so it still comes with Wortel quit;
  a running Wortel takes that one back and posts its own. Closing a session
  ends its reminder, archived or not. Custom… is the system's alert holding
  a month to pick a day from and a menu of times on the half hour. The
  calendar is Wortel's own (`ReminderPicker`): the system's date field, with
  its drop-down calendar, stepper and selection, was tried inline, in a sheet
  and wrapped to match the alert's buttons, and never sat with them; macOS has
  no other (SwiftUI's compact one is iOS only). A typed box (`fri 9am`) was
  tried and taken out: a calendar was what was wanted. `wortel remind` kept
  the words it learned for it. The alert shows no icon and no title: the month is the
  heading, and an icon, "Remind Me" and the session's name made a header
  taller than the thing it headed. (The title is still set, for VoiceOver.) It is a sheet on the
  window, as Close's question is: the window dims under it. It is laid out with the picker short and then grown, with the
  icon hidden: an alert that would be taller than about five thirds of its
  width (measured, macOS 26) lays itself out sideways and twice as wide, and
  one 292pt wide to stay under that read as not quite an alert.

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
- **2026-11-19. A program that reports its own state is taken at its word.**
  Codex, Claude Code and Pi now say `working`, `blocked`, `done` and `error`
  themselves (the Program Status Protocol, OSC 7501). For a session that
  reports, nothing is guessed: no title, no screen, no word in a notification.
  Wortel answers the protocol's question, which is all Claude Code and Pi wait
  for. Reported 2026-11-19 by a Codex user who had gone back to another
  terminal: four in five Codex turn ends were arriving as "needs input".
- **2026-11-19. Still nothing installed into an agent.** Hooks were weighed
  for this and left out. Since Codex 0.157 its hooks run in a shared
  background process with the environment of whichever terminal started it
  first, and the trackers of the terminals that install hooks are a list of
  the ways they fail: a stop hook that never arrives, a banner per approved
  tool call, a user's own hooks overwritten.
- **2026-11-19. For a program that never says `done`, going idle ends the
  turn.** opencode reports `working`, `blocked` and `idle` only. Read
  literally, its finished turns would be silent, and nothing else listens to
  a session that reports. Not for the agents read to say `done` (Codex, Claude
  Code, Pi, crush), whose `idle` is an interrupt or servers starting.
- **2026-11-19. Nothing is guessed any more.** An agent says what it is doing
  in a status report, or Wortel does not claim to know. Taken out: reading a
  title for a spinner or "Action Required", hashing every agent's screen once
  a second, reading the end of progress as the end of a turn, and asking the
  agent's conversation file whether any of that had been a turn. Each was
  right most of the time, and each incident about a dot in `incidents.md` is
  one of them being wrong. About 1,500 lines and a once-a-second timer went
  with them. For a few hours the same day they were kept as a fallback for
  agents that don't report, and then cut: the product is for where agents are
  going, eight of them report already, and in three weeks of usage data
  nobody had started one that doesn't. This replaces the lines above from
  2026-08-05 to 2026-11-10 about the screen tier, liveness in that tier, the
  conversation-file check and the answer already read.
- **2026-11-19. What that costs, on purpose.** Gemini CLI, goose, aider, cline
  and cursor-agent show no spinner and no turn end until they report, and
  neither does an older Codex, Claude Code, Pi, opencode or crush. Those five
  get a mark that says to update. A notification or a bell of a program's own
  still arrives, sorted by how it opens, never by a word somewhere in it.
- **2026-11-19. The sidebar never takes the keyboard, and pressing the
  session you are in puts you back in its terminal.** Any press in the list
  that didn't switch sessions left the keyboard in it, invisibly. Ending a
  rename hands it back to the terminal too, not to nobody.
- **2026-11-19. A program's notifications are read by Wortel, not by the
  terminal core.** The core allows one a second for the whole app and drops a
  repeat inside five seconds, so two sessions notifying in the same second
  were one notification. Wortel holds the pty and reads them there, one banner
  a second per session.
- **2026-11-19. An agent too old to report gets a warning triangle, on its
  row and in the sidebar's bar, with a popover.** Its session shows nothing
  otherwise, and nothing else says why. The row's triangle sits where the
  status would be; the bar's opens a popover with the version needed and a
  Release Notes button. A grey line under the session's name was built first
  and taken out: it read as disabled and was cut off. The session's menu
  starts with "Update Pi…", which opens the popover, so the row's triangle is
  not a dead end. No button that runs the update: Wortel can't know whether
  the agent came from npm, Homebrew or its own installer.
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
- **2026-11-18. An idle agent is put to sleep, and resumed when its session
  is selected.** Fourteen idle Claude Code processes on one Mac held 3.1 GB
  (130 to 395 MB each); hibernation frees only the terminal's 70 MB. So an
  agent that has finished its turn, in a session that is not the selected
  one, is ended after an hour, and its exact conversation is typed back into
  the shell when the session is selected. One waiting on you (a question, a
  plan, a permission prompt), or with a command of its own still running, or
  with keys typed and not sent, gets eight hours. A working agent and the
  selected session never sleep. A memory warning shortens only the first
  clock, to ten minutes. No switch, never named in the UI, and the row looks
  as it did. This is the chosen exception to two rules, and it was chosen
  knowing both: "the agent is never killable" (running-processes.md) and
  "nothing destructive without you choosing it". What it costs is what the
  agent had started (it is ended with it), a pending question after its eight
  hours, and a second or two when you come back. What it keeps is the
  conversation, the shell, its directory and its environment.
  How it stays honest: which clock comes from the agent's own word
  (`~/.claude/sessions/<pid>.json`: `idle`, `waiting`, `shell`; anything
  else never sleeps), the agent is the terminal's foreground group and never
  a command line, every doubt leaves it awake, SIGTERM and never SIGKILL, and
  an agent that does not go is simply still awake. Claude Code only until
  another agent has been checked the same way (`AgentSleep.enabledAgents`).
  Seen with Claude Code 2.1.327 in a test copy, clocks at 30 and 90 s: asleep
  32 s after its session was left; gone in 0.13 s with status 143 and the
  terminal a shell's again; kept awake while selected; held to the long clock
  with `python3 -m http.server` running under it, and that server ended with
  it; resumed on the same conversation by selection and by `wortel send`;
  still asleep after a quit and relaunch; no dot raised by any of it. Not
  seen: the memory-warning path, and a wake by a click in a window (only by
  the selection a launch makes). Known limits: an agent on a scheduled loop
  with nothing running looks finished and sleeps at its hour; a server that
  had already detached itself from the agent is left running; nothing sleeps
  while Wortel is quit.
- **2026-11-18. An agent with Remote Control on gets the long clock.** Remote
  Control lives in the agent's process, so a sleeping agent is offline on the
  phone, and nothing there can wake it: only a click on the Mac does. A
  session in use from the phone never sleeps (each message is a turn, which
  restarts the clock); the loss was the one left an hour and then picked up
  from somewhere else. So `bridgeSessionId` in Claude's own record, which it
  writes when Remote Control links and sets to `null` when it goes (read in
  2.1.327's code), puts the agent on the eight-hour clock, the same one as a
  question waiting on you, and a memory warning does not shorten it. Not
  "never": with Remote Control on at launch for every session, deep sleep
  would never run for exactly the people with the most sessions open. Seen on
  this Mac the same day: a slept session woken by a click had its Remote
  Control link again. Not yet seen: the link going to `null` when Remote
  Control is turned off by hand. Turning it off doesn't shorten a clock
  already armed for eight hours; the agent sleeps then, which errs awake.
- **2026-11-19. An agent in the home folder never sleeps.** Claude Code
  never records its trust answer for the home folder ("Yes lasts for this
  session only"; `hasTrustDialogAccepted` stays `false` for `~` in
  `~/.claude.json`, and 2.1.328's own messages say home trust is
  session-only). So a resume there stopped at "Is this a project you
  trust?" instead of coming back. Seen on this Mac: a session slept and
  woken by a click came up at that question for `~`. Any other folder an
  agent already ran in had its answer recorded when it started, so the home
  folder is the one case, and the rule is that one path (by its real path),
  not a copy of Claude's trust lookup, which also walks up to a git root and
  maps a worktree to its main checkout. Answering the question for the
  person was not considered: it is a safety prompt. A home-folder session
  that was already asleep before this still asks once when woken. Nor is it
  restarted to repaint after a light or dark change: that is the same
  restart, and would stop at the same question.
- **2026-11-19. An agent session headed for the home folder gets a folder
  of its own, `~/Wortel/<day>/<n>`.** The other half of the entry above:
  on this Mac 7 of 21 sessions were Claude in `~` (⌘N with Settings'
  command, people using the list as chats), so never sleeping there would
  have kept most of what deep sleep was for. The Codex app does the same for
  a thread with no project (`~/Documents/Codex/<date>/<slug>`, per its
  issue tracker). Decided with the user: agents only (a plain terminal
  still opens at `~`), ⌥⌘N included; `~/Wortel`, not `~/Documents` (a macOS
  permission prompt, and iCloud syncs it) and not hidden (it is where the
  agent's files are); day and number, since Claude files a conversation
  under its folder's path and the folder can never be renamed after the
  session. Trust: a trusted folder covers every folder under it (Claude's
  own lookup outside git, and seen in this Mac's config: twenty folders
  under one trusted `~/Developer`, none asked). So until `~/Wortel` is
  trusted, a Claude session starts in `~/Wortel` itself and Claude asks its
  own question once; Wortel only reads `~/.claude.json`. Rejected: Wortel
  writing the trust record (another app's security setting, in a file every
  running Claude rewrites), and Claude asking in each new folder. Existing
  home sessions were left where they are.
- **2026-11-19. `wortel cd` is back, for the agent only.** Cut on 11-09 with
  Change Directory; back because agent sessions now start in a folder of
  their own on purpose (above), so moving to the project the chat turned
  into is the expected next step, and without it the git panel showed the
  chat folder while the agent worked in Opmaak. No menu item, so the four
  ways in stay four. The agent asks first: `~/Wortel/CLAUDE.md`, written by
  Wortel when missing, tells it to offer the move and run `wortel cd` once
  the person agrees. Built on deep sleep's road rather than restoring the
  old `SessionMove` (about a thousand lines, written before sleep existed):
  wait for the turn to end, end the agent as a sleep does (the selected
  session included), type `cd` and the exact resume, file the row as ⌘O
  would. Claude only. Seen 2026-11-19 with Claude Code 2.1.328 in a test
  copy: told "move this session to b", the agent ran `wortel cd`, was told
  "Not moved yet", finished its reply, quit, and came back in `b` on the
  same conversation (it remembered a word from before), the row filed under
  a new folder "b". In a second session, asked only to work on a README in
  `b`, it offered "Should I move this session to b first?" on its own, the
  guide read from the folder above where it started. Not seen: the hour's
  give-up, a move of a session made by ⌘N in `~/Wortel` itself. The guide
  only reaches agents started under `~/Wortel`: one in a project folder
  told the person a move was impossible and suggested `/add-dir`. Wortel
  doesn't write into a person's own `~/.claude/CLAUDE.md`; a paragraph there
  (when `$WORTEL_SESSION_ID` is set, offer the move, run `wortel cd`) is what
  reaches every session, and it is theirs to add. The guide is also written
  at launch when `~/Wortel` exists, for a folder an earlier build made.
- **2026-11-19. Wortel installs a Claude Code skill, `wortel`.** What the
  `wortel` command can do, for the agent running in a session
  (`Resources/wortel-skill.md`, `AgentSkill`). A skill and not CLAUDE.md:
  only its description is in every conversation, the rest is read when it
  applies. A Mac app has no install step, so it goes in at launch, when
  `~/.claude` exists: once, then kept up to date with each update for as
  long as the file is exactly what Wortel last wrote (a digest in the
  defaults). Edited, it is left alone; deleted, it stays deleted. No menu
  item: deleting the folder is the way to say no. The user's call, against
  "Wortel doesn't write into an agent's own folders" above: a skill is a
  file of Wortel's own in a folder made for them, not a change to the
  person's instructions or settings. Claude Code only; other agents that
  read the same format are not checked yet.
- **2026-11-19. From the review of the four above.** `~/Wortel` is used
  only when Wortel made it (a `.made-by-wortel` file): someone's own
  `~/Wortel`, or `~/wortel` on a case-insensitive disk, was about to get a
  guide saying "it is not a project" and day folders inside it. A move has
  a deadline once the agent is ended (two minutes to arrive), is called off
  when the resume gives up or the session closes, and `wortel cd .` cancels
  a waiting one instead of quitting and resuming the agent in place. A move
  waits on the same "working" sleep does, pending debounce included. Smaller:
  Claude's trust is remembered once given instead of `~/.claude.json` read on
  every ⌘N, a second session made while the first is at the trust question
  gets its own folder, `devx claude` counts as Claude, a skill file
  identical to Wortel's but unrecorded (a synced `~/.claude`) is adopted so
  updates still reach it, and a moved row's name is made unique in its new
  folder. Seen again in a test copy with a real Claude: `wortel cd b` then
  `wortel cd .` from the agent left it in `a` ("Move cancelled"); a move of
  the idle agent from outside landed in `b`; a second ask said "Already
  in".

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
- **2026-11-19. A ⌘-clicked path in a terminal is resolved by the app and
  opens in the preview**, at its line: against the terminal's folder, the
  session's, their repository roots and one folder below (only when a single
  folder has it, never a guess between two), with sentence punctuation and
  `:line` taken off. Relative paths from agents opened nothing before, and
  any other file went to its default app, where a click could run a script.
  A `localhost` address opens in a tab beside the terminal unless servers
  go to the browser (Settings). "Open in" a file's editor uses its default
  app, so there is no editor setting. Tried and dropped the same day: a menu
  on a right-clicked link. libghostty finds links only for ⌘-click, so the
  app had to read the cell under the pointer itself, the menu didn't appear
  when tried, and ⌘-click plus the editor button already cover it.
- **2026-11-09. A page or a document never opens another app without a yes**
  (`fd2d45c`).
- **2026-09-29. Files and browsers are tabs.** The Markdown preview moved from
  the column to a window to a tab. The browser was a pane, was removed as
  unused after six days, and came back as a tab. The separate browser window
  was dropped (`0e13607`, `6ee3e30`, `09ce308`).
- **2026-11-17. A file opens in the main area until you put one elsewhere.**
  The column was the default, and the habit is per session, so every new
  session sent files back to the narrow column. Now a file starts in the main
  area, dragging one onto a row (between rows, out of a list, or a preview
  window docking) teaches where files go, and ⌥ means "the other place"
  rather than "the main area". The habit stays per session.
  Browsers still start in the column, beside what they show.
- **2026-11-16. A preview window has the main window's chrome**: its own 40pt
  row on the glass, the file tab's header in it, and a file button of its own
  in place of the system's proxy icon. No system window tabs for previews.
- **2026-11-16. A file tab dragged out of the window becomes a preview
  window** where it's let go, as Safari's tabs do, and a preview window
  dragged by its row onto a tab row becomes a tab again. Files only:
  terminals and browsers have no window of their own. Only the rows take a
  window, never the drop zones, so moving one over the main window does
  nothing.
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
- **2026-11-19. The canvas is brought level in batches, not at every
  release.** Redrawing it from the app is hours of capturing and comparing,
  and releases go out several times a week, so a standing step would be
  skipped or done badly. A marker names the commit the canvas shows, the
  release skill reports how many drawing commits have landed since, and the
  `sync-visuals` skill does the work. That day the site matched the canvas
  byte for byte and the canvas was 52 such commits behind the app.
