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
  (`240164f`). A rename to Terminaal was built on 2026-07-29 and not merged:
  the name stayed Wortel.
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
- **2026-11-23. New Terminal at Home, on the same condition.** With an agent
  in the field, ⌥⌘N starts it in a folder of its own, and the plain shell at
  home that ⌥⌘N used to be took a ⌃⌘N and a `cd`. It is ⌥⌘N minus the typed
  line, as New Terminal is ⌘N minus it: in the Session menu and the
  sidebar's +, on ⌃⌥⌘N (⌃ for "without the command", ⌥ for "at home"). The
  + menu is in three groups by where the session lands: where you are
  (session, terminal, worktree), at home, and Open Folder. Its items show
  no keys: that was tried the same day, to teach them, and taken out for
  making a short menu wide and busy. The Session menu has them. Its worktree item is "New Worktree…", as a folder's menu has
  it; the Session menu keeps the full "New Worktree Session…".
- **2026-09-29. "Wortel has no tabs" was reversed.** Tabs in three fixed places:
  the main area, a side column, a bottom strip. Still no splits and no free
  grid. The terminal engine's own tab and split actions still return
  "unhandled" (`9c864df`, `50ec9ca`).
- **2026-08-08. "Deliberately no CLI" was reversed.** The `wortel` command
  exists so that Wortel never needs a per-agent integration (`76ea9f8`).
- **2026-08-04. No invented benchmark numbers**, on the site or anywhere
  (`a55082b`).
- **2026-11-23. A Mac with no agent is told so once, and offered three.**
  Of the first ten installs that report, three never started an agent and
  none of those came back another day. The permissions popover gets a Setup
  section, there only while something is missing: "An agent" (Claude Code,
  Codex or Pi) and "Git" (`decisions.md`, Git panel). Picking an agent puts
  that agent's own one-line installer on a prompt, unsent
  (`AgentInstall`, `SessionManager.offerCommand`): the person reads it and
  presses Return, in their own shell. Wortel downloads, runs and installs
  nothing, and writes nothing into the agent afterwards, so "the agent is a
  guest" holds. Only agents whose installer needs nothing a new Mac lacks:
  a line starting with `npm` or `brew` is two more installs there. Each
  line was read off the agent's own page that day. Whether the Mac has an
  agent is asked (the usual folders, then the login shell) only until the
  answer has been yes once, or an agent has run in a session, and never
  after. Only the shell's own "none" counts as a no: when it gave no answer
  (too slow, a shell Wortel can't ask) nothing is said, because the folders
  alone miss a version manager's and every alias, and "no agent" in front
  of someone who has had one for a year is worse than silence. A marker
  alone is not an agent either: the shell writes it from the command line,
  for `claude` typed on a Mac without it and for a whole
  `npm install -g @anthropic-ai/claude-code`, so it would have taken the
  row away for good (and waiting five seconds first, tried the same day, is
  outlasted by an install). A marker has the shell asked again; a status
  report is an agent. The line is typed only where it will be
  seen, the terminal in front of its session, and otherwise in a new
  session. The missing agent raises the sidebar's icon until the popover has
  been opened once: someone who uses Wortel as a plain terminal is told one
  time. Not built: the same for updating an agent that is too old. Which
  installer it came from can be guessed wrong, and how often it happens is
  not known yet (`agent_outdated`, below, counts it).

## Window, terminal and keys

- **2026-11-19. Several windows, each with its own sessions.** "One window"
  had been a principle of design, never something tried and taken out. A
  window owns its sessions (`Session.windowID`), its sidebar lists only
  those, and a session moves between windows with its terminal running: a
  drag onto another sidebar, a drag out of every window (a new one there, as
  Safari, Arc and Warp tear off tabs), or Move to New Window / Move to Window ▸
  / Merge All Windows. Two windows showing the same session was the other
  model; it was not chosen, because an NSView has one parent and dragging
  between windows would have meant nothing. Every window is the same fixed
  frame of four places. See `macos/docs/architecture/window-and-sidebar.md`.
- **2026-11-19. Drags between windows: spring-loading, and tabs that move.**
  A drag held over a window behind brings it forward, as in the Finder, on
  the Mac's own spring-loading setting and delay rather than one of ours.
  A file or browser tab let go on another window's row moves into that
  window's session, keeping its page or document. Terminal tabs don't: a
  side shell belongs to its session's folder, and no tab moves between
  sessions inside one window either.
- **2026-11-19. ⇧⌘N is New Window; New Worktree Session is ⌥⇧⌘N.** Apple's
  own apps use ⌘N for a window, but where ⌘N makes something smaller than a
  window (VS Code, Zed, cmux) a window is ⇧⌘N, and Wortel's ⌘N is a session.
  ⌥⇧⌘N keeps the worktree in the N family. A new window starts with a session
  at home, as ⌥⌘N makes, so it is not a fifth way to start a session: it is
  the fourth, somewhere new.
- **2026-11-19. Closing a window closes its sessions, with the usual
  question.** Only while another window stays open; the last one closes as
  the one window always did, the app quitting and every session kept. Moving
  the sessions into another window instead was the safe choice, and was not
  the one chosen: a window you close is work you are done with, as in
  Terminal. Worktree sessions archive, as ⇧⌘W does.

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
- **2026-11-20. A terminal out of sight gives back its surface after a minute,
  whatever its program is doing, and comes back exactly.** The keeper keeps
  the terminal, so the surface (about 70 MB) holds nothing that can be lost:
  shown again, it asks the keeper for a snapshot down its channel and goes on
  from it, 30 to 45 ms. Meanwhile the channel is still read, for the
  program's status and for what the surface would have raised (titles, the
  working directory, progress, a command ending), and a window resize still
  reaches it through the keeper. Memory pressure drops every hidden one at
  once, as before.
- **2026-11-17. A terminal out of sight for ten minutes hibernates.** Every
  **Replaced 2026-11-20:** the keeper keeps every terminal, so a surface out of sight
  goes after a minute and comes back from a snapshot; see "The keeper keeps each
  session's terminal" under Keeper. Kept here for what was measured.
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
  (`2dfae43`, `c20f403`). **Since 2026-11-20 a hidden one follows a window
  resize, once:** see "A terminal out of sight follows its window".
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
  that fix. **2026-11-19:** the too-wide case was not a dropped size at all,
  which is why this net never caught it: the terminal's view was that wide,
  left there by SwiftUI, and was told exactly its size. See the entry on the
  terminal's pane. The too-narrow case was the placeholder grid, also above.
- **2026-11-19. A new terminal starts at the size a session's terminal last
  **Partly replaced 2026-11-20:** the placeholder rule stands; the forced repaint
  (one column narrow and back) is gone, as a relaunched terminal is no longer empty.
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
  `terminal.lastShownSize`; since the same evening that session's own, see
  "A terminal made out of sight is told its own session's size"). Same test after: every pty kept 34x102, and no
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
- **2026-11-19. The terminal's pane is AppKit, and SwiftUI draws only what
  stands in front of it.** The pane was a SwiftUI view with the terminals'
  host inside it as a representable, so SwiftUI decided where the host was.
  On a session switch that brought the side column back, SwiftUI took the
  pane's new width and did not move the host: it applied that placement at
  the next change of size and not before. Until then the terminal was as
  wide as the page without the column, ran under the column and was cut off
  by it, and its program wrapped for a width nobody could see. Seen on
  2026-11-18 (the entry on a terminal checking its size) and in a recording
  on 2026-11-19. Made to happen on demand with `macos/scripts/try-switch.sh`
  (a Debug build switching sessions itself at six paces and writing down
  where the terminal is): 61 of 72 returns ended under the column by its
  full 440 points, with libghostty's frame rule or ours, so not that. The
  split view and the hosting view were right every time; only the host
  inside was a layout behind. Laying the hosting view out again did not
  flush it, a change of its size by one point did. Now
  `TerminalPaneController` holds the host and sizes it by its autoresizing
  mask, and the pages that can stand in for a terminal (no sessions, a
  worktree being made, the attention ring) are a SwiftUI view on top that
  takes clicks only while a page is up. Same script: 0 of 72, the terminal
  in the same place to the point (221,0 438x660 with the column, 879x660
  without), and the keyboard on it after a relaunch. What it saves a step
  of a resize was only measured from a window that was partly covered, so
  it is not given. **The side column followed the same day**
  (`SideColumnController`, built as the strip's `BottomPaneController`
  already was): its terminals were the last ones a SwiftUI view placed. It
  was never caught a layout behind (`try-switch.sh --side`, 0 of 72 before
  and after, with the divider moving on the switch as well), so this is the
  rule being kept, not a fault being fixed. The first try at it took every
  pane to no height: the page's hosting view was pinned to the column, and
  with a terminal in front the page is empty and asked for none. A hosting
  view that fills a pane takes `sizingOptions = []`.
- **2026-11-19. A height kept in defaults is not `@AppStorage`.** With the
  side column open, a plain window resize cost 8.4 ms a step against 4.7
  with it shut, and about 110 steps in 240 ran over the 8.3 ms a frame
  lasts, though the column's width was not changing (counted: 0 of 480
  steps). Logging who asked the column's hosting view for layout named it:
  `UserDefaultObserver.noteChange`, 57 times in a round. A view with an
  `@AppStorage` property is told about every write to defaults, whatever the
  key, and starts a transaction for each; AppKit writes to defaults at
  every step of a resize (the window's frame and the split view's dividers
  are both autosaved); and the source-control panel kept its list's height
  that way. So the panel was laid out at every step for a value nobody was
  changing. The two heights (the changes list, the history list) are now a
  `StoredHeight`: one observable object each, written to defaults when
  dragged. Same benchmark, old and new frame rule turn about, the window on
  screen: 8.4 to 5.2 ms a step with the column open, and the divider 7.5 to
  5.3. **Tried and dropped on the way, each measured:** `safeAreaRegions =
  []` on the panes' hosting views (their insets are 0 on all sides, so it
  cannot move anything, and it changes nothing: 7.4 and 8.0 against 7.5 and
  7.9); setting the column's maximum width only when it would bite instead
  of at every step (8.4 to 9.7 against 8.4 to 9.3).
- **2026-11-19. A benchmark's window is on screen, or it is not a
  measurement.** A window that is covered is cheaper: SwiftUI lays nothing
  out for one nobody can see. The same build read 5.5 ms a step with the
  copy's window behind another and 8 ms with it in front, minutes apart, and
  most of a day's figures for this work had been taken from a copy behind
  the windows of whoever was working: a change that did nothing looked like
  3.5 ms a step, and went as far as a commit. `ResizeBench` now floats the
  copy's window over everything, on every Space, for the seconds a round
  takes, counts the steps it was on screen for, and a round seen for fewer
  than all of them prints "NOT A MEASUREMENT". Every figure in the entries
  around this one is from a window on screen; where one is not, it says.
- **2026-11-19. A woken terminal is written into only once it has its
  **Replaced 2026-11-20:** nothing is written back into a woken terminal; it is
  restored from the keeper's snapshot (still waiting for its size first).
  size.** A new surface is 45 columns by 15 rows, libghostty's own, whatever
  it is told as it is made: libghostty gathers resizes for 25 ms and takes
  the size on its IO thread, while what the host writes is parsed at once.
  A wake wrote the saved screen and what had been missed about 6 ms after
  making the surface, so into 45 columns. A saved screen survives that (its
  lines re-wrap when the size lands), which is why this passed every check
  that read a woken screen back. What a program wrote meanwhile does not:
  an agent draws in place, and at 45 columns a line of 78 is two rows, so
  "up three and clear" clears a line and a half. Found by
  `macos/scripts/try-hibernate-screen.sh`, a stand-in agent whose screen is
  compared with what it drew: woken as it began to write, with nothing lost
  (422 + 3167 bytes), it had 3 lines of 120 missing and 18 left over, its
  status line cut at exactly column 45. That is the picture of the session
  seen mid-turn on 2026-11-19, more than the 512 KB below: its second wake
  that day replayed 17 KB, well inside what is kept. Now the wake asks the
  terminal itself for its grid (the cursor sent to the far corner, read
  back with `ghostty_surface_ime_point`; `ghostty_surface_size` only knows
  what was told) every millisecond and writes nothing until it is the grid
  it was told, a quarter of a second at the most
  (`SurfaceView.waitForGrid`). Same script after: every line, once, in
  order, and "its size after 26.6 ms" in the log. The cost is those 26 ms
  on every wake, on that session's queue only. **And a woken terminal's
  program is no longer made to repaint.** It was asked to, like a relaunched
  one, by going one column narrow and back, on the belief that a snapshot
  lacks what had scrolled off; it holds all of it (a shell's `seq 1 300`
  read back whole after a wake, 303 lines for 303). The repaint cost a
  moment at the wrong width and had Claude Code clear the terminal and print
  its conversation again over a screen that was already right. Checked with
  a real Claude Code: its pty stays 34x102 through a wake and its screen
  reads the same before and after. Only the two wakes that cannot be
  trusted are still asked, by the wake itself once it knows
  (`PtyHost.repaintNow`): one whose missed output outran what is kept, so
  its start is gone, and one whose terminal never took its size within the
  quarter second. **A relaunch's replay waits the same way since the same
  evening**: see the next entry but one.
- **2026-11-19. A terminal made out of sight is told its own session's size,
  **Partly replaced 2026-11-20:** each session's own size stands; there is no
  keeper replay to wait.
  and the keeper's replay waits for it.** After a relaunch, scrolled up, an
  agent's conversation was wrapped at 70 columns in a window of 114, and at
  the very top of the scrollback was its footer in pieces. The running app's
  log: a minute after launch every hidden terminal hibernated at 70x37. Two
  causes. One size was kept for every session, the last one shown, and that
  one had its side column open: every agent out of sight was given 70
  columns, and Claude Code answers a relaunch's repaint by printing its whole
  conversation again at the width it is given; shown later at its own width
  it redraws only the screen, so everything above stayed at 70. And the
  keeper's replay, what an agent drew while the app was gone, was written
  into the new surface before it took its size, into 45 columns, where
  drawing in place lands in pieces: the wake's fault (above), on the other
  path. Now each session's own size on screen is kept as well
  (`SurfaceView.shownSizes`, by session, in defaults, let go with the
  session), and a terminal made or woken out of sight is told its own, the
  shared one only for a session never shown; and the replay waits on the
  pty's queue until the terminal has been told a size and taken it
  (`SurfaceView.waitForToldGrid`, a quarter second at most). New test,
  `macos/scripts/try-relaunch-size.sh`: a session shown wide, another shown
  last with the column open, a stand-in agent drawing in place while the
  copy is quit. Main before: the wide one was given 49 then 50 columns, and
  the drawing came back as 361 lines for 61. After: 101 then 102, and every
  line once. **No longer true by the next morning:** a relaunched terminal
  started empty, so scrolling up stopped at the relaunch; see "Every
  terminal's screen is kept through a relaunch".
- **2026-11-20. Every terminal's screen is kept through a relaunch.** A
  **Replaced the same day, by the next build:** nothing is saved at quit; the
  keeper keeps every terminal (`SavedScreens` removed).
  relaunched terminal started empty: all it got was what the keeper buffered
  while the app was gone, then its program was made to repaint by a change of
  width. A shell's scrollback was lost at every update, and an agent's screen
  was whatever it printed again, with what it had printed before laid out as
  it was then (the same message twice, once narrow, seen the same evening).
  Now each session's own terminal writes its screen and scrollback to the
  data folder as the app quits (`SurfaceView.saveScreenForQuit`, the
  hibernation dump; for a hibernated one its snapshot and what it missed),
  after its pty stops being read, so what comes later is the keeper's. At
  the next launch the screen is written back first, at the size it was saved
  at, then the keeper's replay, and nothing is asked of the program: no
  repaint (`SavedScreens`). Used only when it can be trusted, the old way
  otherwise: the app that saved it is the last one that ran on the data
  folder (`InstanceLock.previousOwner`, read before the lock is written), the
  Mac is in the same light or dark, and the keeper's replay did not lose its
  start. A side terminal is not saved: it is told no size until it is shown.
  The files are 0600 in the data folder, taken once, and whatever is left a
  minute after launch is deleted. A woken terminal is now told the size it
  went to sleep at, for the same reason, and its view's size after.
  `macos/scripts/try-relaunch-size.sh`: a shell awake at the quit and one
  asleep each keep all their numbered lines through a relaunch (200 and 250;
  before, none), a stand-in agent's screen from before the quit is there
  with what it drew meanwhile under it, and the hidden session is not made
  to repaint. A real Claude Code: the same 21 lines before the quit and after
  the relaunch, its conversation once, its pty untouched; saved in the other
  appearance, not used, and repainted the old way. Saving five screens at
  quit took 8 ms.
  **After its review, the same day:** the save is a hibernation, not a dump
  of its own. At quit every session's terminal is put to sleep the way one
  out of sight is (`hibernateForQuit`, shown or not), and what is saved is
  that sleep: the modes it was in, its screen with palette colours kept as
  the palette's (a dump of its own wrote them as fixed colours, so restored
  text stayed in the theme of the day), and what it missed. Nothing waits on
  the main thread, which the terminals' own work needs (the 2026-10-07
  deadlock): the quit is answered later, looks every 10 ms, and gives up
  after 1.5 s on what is not done, which then comes back the old way
  (`SavedScreens.saveAll`). At launch the screen is used only at the grid it
  was saved at (a different display scale or font size makes another grid
  of the same pixels), else the old way with a repaint. Files of sessions
  still there are kept until their terminal is made; only those of sessions
  gone are deleted. `try-relaunch-size.sh` checks a palette colour is saved
  as the palette's, and that a hidden session given no size had its screen
  put back (the log says so), not just nothing. A saved grid changed by hand
  to 999 columns: refused, repainted. Saving five screens took 25 ms.
- **2026-11-20. An agent with background work still going is busy until it
  ends.** A Claude Code turn that ended while a command it started in the
  background was still running dropped the spinner, and said "finished",
  though Claude Code carries on by itself when the command ends. Claude Code
  reports each background command, monitor and remote agent as a child
  record, `working` until it ends; they were kept and ignored. Now a `done`
  said while a piece of work is unfinished (working, or blocked on a
  question) holds the turn open (`ProgramRecords.standing`, `finishHeld`),
  and it is announced finished 3 s after the last piece ends, since Claude
  Code carries on with what the command left. Chosen by the person over
  announcing the turn's end and keeping the spinner, and over a quieter mark
  of its own, knowing a monitor that runs for hours keeps the spinner on for
  hours. Narrowed after its review: only a `done` holds (Esc's `idle` does
  not), work listed after a turn was over changes nothing, a background
  agent's question does not end the turn, and sleep, a typed draft's
  protection and what a relaunch remembers go by the root alone.
  `verify-agent-status.py` has four scenarios for it: main before failed the
  first two, after passed 50 of 50. A real Claude Code 2.1.329 ending its
  turn with a 25 s command in the background stayed working until it
  replied to the result, then was finished once.
- **2026-11-21. Of Claude Code's background work, only a subagent keeps its
  turn open; a server does not.** A dev server Claude Code started in the
  background is a child record `working` for as long as it runs, so the rule
  above kept the row's spinner on for hours and no turn of that session was
  ever announced finished. A server already has its place in the running
  processes popover. Read in Claude Code 2.1.330's own code: its root
  already says `working` ("1 shell still running") for a command it waits
  on, one started since your last message that it does not read as a server
  or watcher (`vite`, `next dev`, `npm run dev`, `serve`, `uvicorn`…), and
  for a monitor, and says `done` beside a server. And its record ids name
  the kind of task: a letter and eight of `[0-9a-z]`, `a`, `r`, `t`, `w` for
  its agents, `b` for a background command. So a `working` piece of Claude
  Code's work holds the turn only when its id is an agent's
  (`ProgramRecords.holdsTurnOpen`), and the root speaks for the rest. A
  piece blocked on a question still holds, and another program's pieces are
  held as before. Chosen by the person: only subagents are busy. What it
  gives up: a server Claude Code does not read as one (`python3 -m
  http.server`, `rails s`) is still a command it says it waits on, so the
  spinner stays until your next message. Deep sleep is unchanged: an agent
  with a server running is not put to sleep, since ending it would end the
  server. `verify-agent-status.py`: three new scenarios (a server beside a
  finished turn, a question after it, a command Claude Code waits on), the
  background command ones now use agent ids, 53 of 53 pass. With `--real`,
  the real Claude Code 2.1.330 waiting on a `sleep 20` it started stayed
  working until it ended and was then finished once, and beside the
  `npm run dev` it started it was finished with the server still up. Found
  in the review: a replay put the root before the work, so a turn held by a
  subagent came back from a relaunch as finished; the work now goes first
  when it held the turn.
- **2026-11-20. A terminal out of sight follows its window, once a resize
  ends.** It kept its size while hidden, so what its agent printed after a
  window resize was laid out for a width it would never be shown at, and
  stayed so in the scrollback. The rule against it was for a storm: every
  hidden terminal took the shown one's size at every session switch. Now a
  session's own terminal that is out of sight takes the window's change of
  size, 0.4 s after the window stops changing, on top of its own size
  (`SurfaceView.followWindow`): the panes beside it keep their width, so
  that is the size it will be shown at. One SIGWINCH a window resize, none
  for a switch. `macos/scripts/try-hidden-resize.sh`: two drags of 20 steps,
  and the hidden session was given one size after each, after the drag, the
  same as the shown one. Its view keeps that size, so a change of display
  or scale passes on the followed size, not the old one. **Not covered:** a terminal made at launch and not
  shown since is not in the window and does not follow; it is told its own
  last size when it is made.
- **2026-11-19. An agent at work keeps its terminal.** A hibernated terminal
  **Replaced 2026-11-20:** nothing is lost by dropping a terminal now, so one
  whose agent is at work goes like any other.
  keeps what its program writes meanwhile, up to 512 KB. An agent's output
  is drawing, each piece placed from where the last ended, so with the start
  gone the rest lands on an old screen in pieces. Seen: a Claude Code
  hibernated mid-turn by a memory warning, away nine and a half minutes,
  woken with exactly 512 KB of the more it had written, its screen scattered
  words until the turn ended and the repaint of 2026-11-19 put it right. So
  a terminal whose agent is at work is not hibernated, by the clock or by a
  memory warning, and hibernates when the turn is over. And a hibernated one
  whose agent starts a turn by itself (a task of its own finishing, a
  wake-up, another session writing to it) is woken out of sight once half
  of what can be kept is used, while nothing is lost yet, and goes back on
  the clock (`HibernationPolicy.outrunning`). A shell printing a log is left
  asleep: what it loses is the oldest lines. Verified in a test copy with a
  six second clock: a Claude Code at work for 45 s stayed awake and
  hibernated 7 s after it finished; a hibernated one stayed asleep through
  5.8 KB written while resting, was woken on reporting work and writing
  more (the limit set to 6 KB), stayed awake while working and hibernated
  again when it rested. The cost is the terminals of agents at work, about
  70 MB each, for as long as they work.
- **2026-11-19. A terminal's new size waits for its frame only when it is
  one change, not a drag.** libghostty's layer draws a frame on the main
  thread at every change of its bounds and waits for the GPU to finish it.
  That is right for one change (a session switch, a pane landing): the frame
  is in the same commit as the size. Under a drag it is paid at every step,
  and a step has 8.3 ms at 120 Hz. Measured with `macos/scripts/bench-resize.sh`
  (a Debug build resizing its own window 480 times at 120 Hz, the time the
  run loop is awake per step, old and new turn about in one app, the window
  on screen): with a frame at every step, 6.8 ms a step with the column shut
  and one step in eight too late, 6.9 ms with it open, 7.3 ms dragging the
  divider. Now a size that follows another within 50 ms skips the frame and
  takes the renderer's own a frame later, a frame of an older size stays up
  for 30 ms at most, and the drag's last size is checked once it ends
  (`SurfaceView.frameForNewSize`). Same benchmark: 4.5 ms and one step in
  eighty, 5.2 ms, 5.3 ms. A pane sliding open or shut, held at its size as
  before, had 10 to 15 turns of the run loop over 8.3 ms and has 1.
  The
  frame that was dropped rarely showed anything new: the terminal re-wraps
  on its own thread after it is told, so the frame in the same commit was
  mostly the old screen at the new size, which the layer shows anyway by
  pinning what it has to the top left. **Tried and dropped the same day:**
  a frame only when a row or a column is gained (the average fell, the late
  steps did not: they are the ones with a new column); never a frame (a drag
  in step with the renderer loses every one of its frames to libghostty's
  size check, 391 of 480 steps began on an old one); a `GeometryReader`
  around the changes list and the diff replaced by a height reading (no
  change measured, taken out). And a guess that did not hold: a change of
  pixels alone does not reach the program, SIGWINCH came only with a new
  grid (125 for 123 changes over 480 steps). **What is left** with the
  column open is not the terminal: over half of a step is SwiftUI, in the
  column's panel and in the view the terminal sits in. A new terminal
  engine would not touch that either.
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
  **Replaced 2026-11-20:** a snapshot keeps every cell's style as it is.
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
- **2026-11-21. A program never reads the clipboard; the user's paste is
  still not confirmed.** Every clipboard confirmation was approved, so an
  OSC 52 read in any output (a `cat`ed file, an ssh host) had the clipboard
  written back into the pty. Now only a paste is approved; an OSC 52 or kitty
  read is refused through `ghostty_surface_deny_clipboard_request`, which
  answers the program (empty, or EPERM) so nothing waits. In code, not as
  `clipboard-read = deny` in wortel.conf: that would answer nothing at all.
  OSC 52 writes stay on, so planted text can reach the clipboard; the paste
  approval of 2026-08-10 stands because a paste is the user's keystroke,
  bracketed paste (zsh, fish, bash 5.1, the agents) makes a newline harmless
  and ESC is stripped from every paste. A shell without bracketed paste is
  the case left open.
- **2026-11-23. Text from an input method is typed, not pasted.** Dictation,
  the emoji picker and an input method's commit went to libghostty as a
  paste (`ghostty_surface_text`), so an agent with bracketed paste on showed
  dictated words as "[Pasted text]". They now go through the key encoder,
  ported from Ghostty.app (ecbeb60ca, 751a60df6), with its fixes for keys
  that commit or edit a composition and for DEL as key text. Wortel's
  `doCommand` no longer scrolls to the top or bottom on ⌘↑/⌘↓: it overrode
  libghostty's previous and next prompt (Ghostty 30fdc8f4c). Not ported:
  Ghostty.app's split focus clicks and its menu shortcut translation, which
  Wortel has no equivalent of.
- **2026-11-24. The terminal font is the Mac's own SF Mono, reached by API.**
  `font-family = SF Mono` found the font only on a Mac with Apple's separate
  SF Mono download in `/Library/Fonts`; everywhere else the terminal quietly
  drew Ghostty's embedded JetBrains Mono. macOS ships SF Mono only as a
  hidden system UI font, and CoreText refuses it by name: a family search
  for `.SF NS Mono` with a style returns every font of that style, and
  `CTFontCreateWithName` returns Times New Roman. `wortel.conf` now names
  `system-mono`, which a Ghostty patch (`GhosttyKit/Patches/0101`) resolves
  through `NSFont.monospacedSystemFont`, the font the diff view and Markdown
  code already use. Considered and not chosen: bundling SF Mono (its licence
  forbids redistribution), Menlo (always there, but not the system's look),
  and keeping `SF Mono` first with `system-mono` as a fallback (the owner's
  Mac would then draw the 2022 download while everyone else drew the system
  copy).

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
- **2026-11-21. A folded section with a session at work shows the three
  dots.** Its header showed only the loudest attention dot of what it hid, so
  a folder of working agents looked like one of idle shells. Now, when
  nothing in it is louder, the header has a row's working dots after its
  chevron (`SessionManager.isWorking(inFolder:)`, and for Pinned and
  Sessions). A dot still wins, as on a row. A pinned session is spoken for by
  Pinned only, no longer by its folder too, and a header speaks only for its
  own window's sessions: folding is shared by every window, and the dot of a
  folder folded in two windows showed what the other window was hiding.
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
- **2026-11-19. Greys in the sidebar's list are NSColor's label colours,
  never SwiftUI's `.secondary` or `.tertiary`.** Those two are drawn
  vibrantly, blended with the glass, and the list's fade mask (on while the
  rows run past the window) takes the blend away: the section headers went
  dark grey on dark. Plain `tertiaryLabelColor` is what DESIGN.md already
  named for headers and branch lines, mask or not.
- **2026-11-19. Section headers have a grey of their own, between the
  tertiary and the secondary.** Still hard to read after the fix above, said
  the person using it, and measured so: on the sidebar, in a capture of a
  copy with the list running past the window, the tertiary grey was 2.2:1 in
  dark and 1.9:1 in light, where the session names are 10.8 and 8.0. The
  secondary (4.5:1, 3.9:1) was tried and was too light: the headers came too
  close to the rows. Halfway, white at 45% in dark and black at 38% in light
  (`Chrome.sectionHeader`), measures 3.2:1 and 2.6:1, chosen by eye in the
  running app. Branch lines stay tertiary: a small second line under a name,
  read after it.
- **2026-11-23. Closing the session you're in goes back to the one you were
  in before it**, in that window, replacing "otherwise the row above" from
  2026-11-18. The rows' order says little about what you were doing: new rows
  go on top, folders come first, and the row above was often unrelated. The
  "just made" rule is now one case of it: the session ⌘N was pressed in goes
  on the way back however short the visit. Any other visit goes on it only if
  it lasted 3 seconds or you typed, clicked or scrolled in it, so clicking
  past rows or stepping with ⌥⌘↓ leaves nothing behind. With no way back
  (after launch, or it was closed, moved or folded away) the row below, which
  slides into the closed row's place so the selection stays put on screen, as
  in Finder and Mail; the bottom row's is the one above. Closing several
  selected rows at once follows the same rule, stepping over all of them.
  Attention plays no part: going to whatever is waiting is ⌘⌥]'s to do, when
  asked, and a close never seeks it out. The cost is a ⌘W sweep, which walks
  back through where you were rather than down the list
  (`SidebarStep.afterClosing`, `SessionWindow.trail`).

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
- **2026-11-24. A new session opens on an empty page until its program is
  up.** A session made with a line to run (Settings' line, `wortel new --`)
  showed the whole start: the prompt, the line typed on it, the agent's
  interface popping in. Measured that day on one Mac: the shell 0.1 to 0.3 s,
  then Claude Code 0.3 to 0.8 s, Codex 0.3 s, Pi 0.8 to 1.2 s. None of it is
  Wortel's to make faster, so it is kept out of sight: the terminal is under
  a page of its own colour, at its full size and being drawn into, and the
  page comes off in one cut (`StartCover`, `TerminalHostViewController`).
  The rule reads the session's own output. Nothing counts before the shell
  marks the line started (`OSC 133;C`), because zsh sets bracketed paste at
  its own prompt. After it, a mode a full-screen program sets, then 50 ms of
  quiet (at most 0.3 s), is the first frame: at that moment the screen was
  whole for all three agents. The agent's marker lands 3 to 7 ms after the
  mark, so a line with no marker and no mode by 0.15 s is not an agent and
  is shown (`wortel new -- npm run dev`). The line ending first, or the
  shell never starting it in 2.5 s, lifts the page on the shell; 2 s without
  an interface lifts it anyway. That wait was 4 s for an hour, and a spinner
  on the page was considered for it: both hide a slow start, which is the
  one worth seeing (an update, a login, a shell that is stuck), so the page
  comes off sooner and the terminal is its own progress. **2026-11-26: the
  page gets a spinner after 0.75 s after all.** Not for the slow start past
  the cap, which is still shown, but for an ordinary one under it: Pi's up
  to two seconds of empty page read as a hang. Claude Code and Codex are
  usually up before 0.75 s and keep the plain page. The delay counts from
  the start, so switching back to a session that has been starting a while
  shows it at once.
  **What is typed under the page is held, and goes only to the program.**
  Lifted on the shell, it is dropped: a sentence meant for an agent is a
  command to a shell. **A Return that was held is never typed, nor anything
  after it:** it was pressed at a screen nobody had seen, and Codex put
  "Update now" up a quarter second after its first frame, with Return as
  yes. The text is left in the program's input to be read and sent. Return
  is caught as the key, before it is encoded: a program that has just asked
  for the kitty keyboard protocol is sent `CSI 13 u` for it, which no rule
  about bytes would know. A paste and `wortel send` wait for the start to be
  over instead, since the program has not asked for bracketed paste before
  then. The paste goes in only to an interface that came up, after the held
  keys (the order between them is not kept), and is dropped otherwise.
  `wortel send` types whatever came of the start, as it was told to, which
  makes `wortel new -- claude` followed at once by `wortel send --enter`
  arrive as one prompt; its Return is the script's own, and lands on
  whatever the program shows first. The waits add up to under `send`'s five
  seconds of patience. Review, the same day, found five ways it was wrong
  as first built: a line left on a prompt unsent (the Setup row's install
  line) was covered for three seconds and its Return thrown away, so only a
  line that ends in a newline is covered; a paste was typed raw when the
  page lifted without an interface; a start given up on (closed, attached
  to again) typed its held keys; a shell that died under the page stayed
  hidden until the wait ran out; and the marker wait could run out on a
  busy main thread with the news of the marker still queued, so the marker
  is read from disk once before that answer is given. A second review
  (2026-11-25) found a middle-click paste or dropped text did not wait as
  ⌘V does, and went in with its Returns: one write with a line break in it
  now ends the hold like a Return and is dropped whole, since cutting it at
  the break could hand over a bracketed paste's opening without its end. Only zsh and bash, whose marks were seen working; fish joins
  when its marks have been checked on a Mac that has it. Left out: a resume
  after a lost keeper, agent sleep's wake and `wortel cd` (each comes back
  to a screen worth reading), a plain terminal, and keeping a spare agent
  warm, which would be instant and would cost memory, hooks and MCP servers
  for a session nobody may open.

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
- **2026-11-23. Notifications are asked for when there is one to show, not
  at launch.** macOS puts the question once. At launch it was answered before
  anyone had seen what a notification from Wortel is for: of the first ten
  installs that report, seven had them off at their latest launch (a count
  that includes allowed with every way of showing one turned off). Now the
  prompt comes with the first banner (a session out of sight that finished
  or needs you) or the first reminder set, and that banner is posted once it
  is answered, if the session still wants anyone. Reminders handed to
  Notification Center again at launch and at quit never put the question:
  that had it back at every launch for anyone who let the prompt slide away
  with a reminder still pending. Until then the permissions
  icon is in the sidebar with its Grant button, as it is for a no. Not
  checked: the Dock badge before the question has been put, which needs a
  signed build on a Mac that was never asked.

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
  **Reversed 2026-11-20:** the keeper reads every pty and forwards it; below.
  bytes.** Exactly one reader per pty. Throughput measured the same as a local
  pty (`2f5f2f1`).
- **2026-09-14. Repaint after a reattach by a real size change.** SIGWINCH
  **Gone 2026-11-20:** a reattached terminal is restored, not repainted.
  alone repainted one session in nine (`9eb98e5`).
- **2026-09-17. Terminal modes are recorded by the app and declared again
  **Replaced 2026-11-20:** modes travel in the keeper's snapshot
  (`macos/docs/terminal-modes.md`).
  before the replay.** The keeper cannot do it: while attached, the app is the
  one reading (`cd53f94`, `e14c917`).
- **2026-10-07. The replay is written off the main thread** (`2c3303d`).
- **2026-11-20. The keeper keeps each session's terminal, and the app shows a
  copy.** Every terminal bug of 2026-11-18/20 was in a path that rebuilt a
  terminal in the app: the keeper's 512 KB replay, hibernation's VT dump,
  screens saved at quit, forced repaints. Each could land at the wrong size or
  moment, and an agent never redraws its history, so the damage stayed. Now
  the keeper reads every pty, always, into a libghostty-vt terminal per
  session at the pty's own size, and the app's surface is restored from an
  exact snapshot of it (Wortel's Ghostty patch,
  `ghostty_surface_restore_snapshot`) and fed the same bytes over a framed
  channel. Nothing is replayed, saved or repainted; `ReplayAnswers`,
  `SavedScreens`, the hibernation dump and the forced repaints are gone. The
  keeper answers the program's queries, with or without the app; the
  surface answers nothing. Options weighed: the keeper rendering into an
  IOSurface, and the app rendering a state it does not own; libghostty offers
  neither without forking its renderer. Measured on Release builds: `cat` of
  64 MB through a shown session 99 to 110 MB/s against 97 to 103 before (the
  keeper parses in parallel), 0.46 s more CPU per 64 MB in the keeper; a
  keystroke's round trip 42 µs at the median against 28; the keeper 0.5 MB a
  session idle, a full 10 MB scrollback compressed to about 2 MB once quiet.
  Verified with `macos/scripts/try-app-crash.sh` (an agent drawing in place
  through a `kill -9`, a quit and a dropped terminal, read back exactly) and
  real vim, Codex, Pi and Claude Code through a `kill -9`. **What it costs:** a
  keeper crash now loses the terminals as well as the shells (accepted;
  saving snapshots to disk is the follow-up if it matters).
- **2026-11-20. Protocol "2", and the update that brought it ended every shell,
  once.** A protocol 1 keeper cannot serve an app that no longer reads the pty.
  Moving running sessions onto a new keeper live (passing each pty across,
  then `SIGKILL` to the old one) was weighed and not chosen: the person chose a
  clean restart over migration code, with agents resumed by their exact
  conversation and the release note saying so.
- **2026-11-20. Ghostty is built here, from source.** The snapshot format is only
  defined within one Ghostty commit, so the app's GhosttyKit and the keeper's
  libghostty-vt are built from one patched tree (`macos/scripts/build-ghostty.sh`:
  Ghostty `5ebe501`, libghostty-spm's patch stack, Wortel's patch). Moving from
  Ghostty 1.3.1 changed the old rebuild paths' results (a replayed in-place
  drawing gained three stray lines), so the upgrade ships only with the
  keeper's terminal. `scrollback-limit-bytes` is pinned at 1.3's 10 MB.
  **A keeper of another Ghostty commit is replaced**, like one of another
  protocol (it reports its commit in `ping`): its snapshots would not read,
  and a keeper holding sessions outlives an update. So any release that
  moves Ghostty restarts running shells once, agents resumed; say so in its
  note.
- **2026-11-25. Ghostty is moved to its tags, and a weekly check says when.**
  Nothing told anyone a Ghostty fix existed: the pin was moved when someone
  remembered. `.github/workflows/ghostty-watch.yml` (Linux, Mondays; the work
  is `macos/scripts/ghostty-watch.sh` and `ghostty-news.py`) keeps one issue
  with what changed since the pin that reaches Wortel, sorted by what each
  change asks for, and opens a draft pull request for the newest `v*` or
  `vt-*` tag past the pin (one, if two came in a week) that moves only the
  pin, with `macos.yml` started on it. That run is linked in a comment on
  the pull request: one started by workflow_dispatch is on the commit but
  not in the pull request's checks (pull request 4, the first). A token of
  its own would make the pull request's own CI run, at the cost of a secret
  to keep; the link was enough. Tags rather
  than Ghostty's main branch: every move restarts the user's shells once
  (above) and needs the review in the `update-ghostty` skill, so it is done
  at the points upstream calls stable, or at once for a security fix. The
  review is not automated on purpose: the move to 5ebe501 built and passed
  every test and still shipped dead links, because a callback's answer and
  two defaults had changed meaning. The report names no Ghostty pull request
  as `#n` or by link: this repository is public, and each mention would land
  in that pull request's timeline every week. An advisory counts only when
  the fix it names is not in the pin: Ghostty publishes them hours after the
  release that fixes them, so the date alone reported fixes Wortel had.
  Renovate was not used: it can follow a git ref, but not sort the changes
  or open the issue, and it would be a second place the rules live.
- **2026-11-20. A quiet terminal's scrollback is compressed by the keeper**,
  after a 15 s look that finds it unchanged. 108 MB to 23 MB for ten full
  scrollbacks; decompressed when touched.
- **2026-11-20. The agent status question (`OSC 7501 ; ?`) is the keeper's to
  answer, not the app's.** The app answered it at first, as it had before the
  keeper kept the terminal. But the keeper now answers everything else, at
  once, and Claude Code sends DA1 right behind its question and reads a DA1
  answer that comes first as "no". The app's answer, a round trip later, came
  second every time it was measured, and agents started in a dropped terminal
  or resumed from sleep stayed silent and showed the "update Claude Code"
  triangle. libghostty-vt answers it itself, in order, once a
  `program_status` callback is set. Its reply lists the states and kinds
  rather than the bare `?` Wortel sent; the lists are the same ones. A side
  effect: an agent started while Wortel is closed is answered too.
- **2026-11-20. A keeper that ends on a signal kills its shells; one replaced
  by the app has its shells killed by the app first.** **Replaced the same day,
  below:** a killed shell never saves its history. The protocol 2 update
  resumed none of the agents that were running: four of four lost in a copy
  going from 2026.47.2 to this build, and seven sessions on a real machine.
  The old keeper hung its shells up, each agent ended cleanly, its shell
  reached a prompt, and the prompt hook removed the agent's marker, as when
  the person quits it. A second cause in the same place: a busy agent took
  two seconds to end, and the app, restoring meanwhile, saw it running and
  owed it nothing. With the shell killed first, the marker stays, and an agent
  whose shell is dead counts as gone however long it takes to exit. Closing
  one session still hangs it up: that is the person's choice, and nothing is
  owed. Verified with four real Claude Codes across the update and across a
  keeper stopped while the app was closed: four of four resumed both times.
- **2026-11-20. An agent that never wrote its conversation starts afresh; a
  saved id for this run beats a guess by start time.** With that fix, four
  Claudes opened in one folder, one used, all came back in the used one's
  conversation. The three unused ones had never written theirs (Claude writes
  its transcript at the first message, though its process file names the id
  from the start), so the next evidence was tried: a transcript born within two
  minutes of their start, which was the used one's, and failing that "continue
  the latest", which is too. Now what the agent said it was in decides; one
  never written means it starts again with its own command line. And the id
  saved at quit is used before the start-time guess, but only for the same
  run, by its start time (`runningStartedAt`, new), so a crash that left a
  marker for a later run still falls through to the guess. Verified: the same
  four, across the update and a keeper stop, came back one in its own
  conversation and three started afresh; then, with a second one used, two
  in their own.
- **2026-11-20. The agent under a shell is the match nearest the shell.**
  Claude Code runs its helpers (its grep) as its own binary, whose path names
  `claude` too, and `AgentLiveness.locate` took the first match in the process
  table, which lists the newest first: during a turn, a helper. A helper has
  no `~/.claude/sessions/<pid>.json`, so the conversation went unread exactly
  when it is read, and a session started with a bare `claude --resume` was
  saved with the id Claude has before a conversation is picked, never
  written, and came back to the picker. Measured on the live session: the
  helper before, Claude itself and its conversation after.
- **2026-11-20. Shells are hung up as always, and the agents' markers are put
  back after.** Replaces killing the shells outright, which a review found
  costs every session's command history at each update and logout (zsh and
  bash write it as they exit; macOS's `/etc/zshrc` appends nothing before
  that) and leaves background jobs running without their shell. Now the
  keeper ending on a signal, and the app replacing an older keeper, read every
  agent marker, end the shells the polite way, wait for them (3 s at most,
  past the SIGKILL `PtyHost.stop` sends at two), and put back each marker a
  last prompt removed, never over one that is there (`AgentMarkerHold`).
  The same review, also fixed: of several processes naming Claude, the one
  with its own process file is the agent, so a wrapper (`caffeinate -i
  claude`) is passed over as a helper is; a fresh start drops `--continue`
  and `--resume`; a session restored with no marker is not given the
  start-time guess; a terminal still being restored is not dropped, and
  closing one tells whoever waits on it.
  A second review then found the wait was for `login`, which the keeper forks,
  while an interactive zsh puts itself in a process group of its own,
  outlives `login`, and reaches its last prompt after: the markers were put
  back too early and removed again. The wait is now for the shells the held
  markers name (`shellpid=`), 5 s at most. The test's stand-in shell had the
  same blind spot (`sh -c` stays in `login`'s group); it is now shaped like
  zsh, and failed before the change.
- **2026-10-07. Tried and dropped, twice: moving the keeper out of the app's
  reach.** As a launchd agent, then as a background-only helper app. The Dock
  still offered "Stop Running in Background" both times. Real separation needs
  private API, which is not used. The answer is recovery (`da09bc4`/`0066004`,
  `6a09af8`/`3500073`, `198a870`).
- **2026-10-07. The protocol version stays "1".** A bump ends every running
  **Bumped 2026-11-20 to "2"**, on purpose; below.
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
- **2026-11-24. `check-ignore` runs without `GIT_LITERAL_PATHSPECS`.** Every
  git has had it since `45f5f2a` (2026-11-09: a path with brackets means
  that file only), and `check-ignore` refuses the `literal` magic outright,
  so from then nothing was ever reported ignored: the Files pane stopped
  greying ignored files. It reads each line as one path, never a glob, so
  leaving it out for this one command names no other file. Pinned by
  `FileListingTests.testCheckIgnoreAnswers`.
- **2026-10-06. Only the repository on screen does git work.** Every git gets
  `core.fsmonitor=false`. Other worktrees are read when asked, never on a timer
  (`c20f403`, `9b366bb`).
- **2026-10-06. git runs in its own process group with a time limit**
  (`bf6d719`).
- **2026-10-13. Tried and dropped: a pull-request button.** It made a network
  call every minute (`c80edaf`, `3c0646b`).
- **2026-10-21. The panes show the session's own folder**, not where its shell
  or its agent has gone inside the same repository (`8ffb707`, `c704b8a`).
- **2026-11-21. Every diff git prints for us is git's own:
  `--no-ext-diff --no-textconv`.** git runs in any folder a terminal reports
  (OSC 7, which any output can send), and a repository's config can name a
  program for git to run on a diff. A binary file shows as binary even where
  the user configured a textconv for it; that is the price. Filter and merge
  drivers (`git status`, `merge-tree`) can't be turned off by a flag and are
  not covered.
- **2026-11-21. Every git we run gets `log.showSignature=false`**, so a
  repository can't make `log` and `show` start its own `gpg.program`.
  `gpg.program` is not blanked: the Commit button signs with the user's. The
  filter-driver gap stays, as for any git-aware prompt
  (`macos/docs/architecture/git-panel.md`).
- **2026-11-23. Git is never started on a Mac that has none.** `/usr/bin/git`
  is always there, and without Xcode or Apple's command line tools it is a
  stub that raises macOS's installer. Wortel runs git unasked (a row's
  branch, the Changes pane), so that dialog would have come at a moment
  nobody chose. Whether git can run is read from the disk first
  (`DeveloperTools`, the way `xcode-select` resolves a developer directory),
  and while it can't, the git panes say "Git is not installed" with an
  Install… button and the permissions popover has a Git row. Both open
  Apple's own installer (`xcode-select --install`): Wortel downloads and
  installs nothing itself. A git of the person's own (Nix, MacPorts) is used
  when Apple's is absent. One more state, for an Xcode that was selected
  and then deleted: the tools are on the disk, git fails on the selection,
  and the installer only says "already installed". There the button is Fix,
  and it types `sudo xcode-select --reset` on a prompt for the person to
  run, since it needs an administrator. That runs inside Wortel, so for a
  few minutes after it the disk is read every two seconds: nothing else
  would tell the panes it worked. Not reproduced on a Mac without the tools: the
  detection is tested, the stub's dialog is Apple's documented behaviour.

- **2026-11-24. The diff under the Changes list can be put away**: drag its
  divider to the bottom (less than the diff's 120pt minimum left, it snaps
  shut) or untick View ▸ Show Diff in Changes; both are the same switch. A
  checkmark, not a Settings row, because it is flipped while working. While
  it's hidden a selected row runs no `git diff` (`StoredFlag.changesDiff`,
  checked in `GitRepoModel.loadDiff`). It was kept rather than removed for
  reading a diff without the main area changing.

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
- **2026-11-23. Every ⌘-clicked link in a terminal is opened by the app**, not
  handed back to libghostty. Its Oct 2026 change makes the macOS fallback
  refuse matched URLs and OSC 8 links, so in 2026.47.4 no web link opened.
  Web and mail links open directly; another app's scheme asks first, as a
  page's does; a link with hidden characters does nothing.
- **2026-11-24. A link an agent broke over rows is put back together by the
  app, from the rows around the click, not by a patch to Ghostty.** Agents
  wrap their own text, so a long path arrives as two rows with a line break
  and an indent, and libghostty matches one row: the click opened half a
  path, or nothing. A path is joined only when the join exists on disk, which
  is what makes joining safe. cmux patched its Ghostty to join rows that end
  in certain punctuation instead, and has open bugs for each shape that rule
  misses (a break inside a `%XX`, an indented row; its #8583, #9866,
  #24990). Web addresses have no disk to ask, so a row is only followed when
  it was full, and an OSC 8 link (Claude Code's and Codex's prose) is left
  as the program tagged it. Cost: on ⌘-hover a half libghostty doesn't match
  shows no underline, though the click opens it.
- **2026-11-23. A selection goes to a pasteboard of Wortel's own.** Ghostty's
  1.4 defaults on macOS (`copy-on-select = primary`, `middle-click-action =
  primary-paste`) only work with a selection clipboard, so Wortel has one, as
  Ghostty.app does: selecting no longer replaces what ⌘C copied, and a middle
  click pastes the selection. Until 2026.47.4 a selection went to the system
  clipboard because the old Ghostty fell back to it, not because it was
  chosen; on the new one it went nowhere. When Claude Code has the mouse it
  copies a selection itself (OSC 52), which still reaches the clipboard.
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
- **2026-11-21. A browser tab hands only a web address to another app.** A
  page's response the tab can't show went to `NSWorkspace.open` whatever its
  scheme, so a local page linking to a `.command` file would have run it.
  Now `http` and `https` go to the browser, a `file:` is shown in the
  Finder, and anything else stays put. `mailto:` never reaches this point:
  it is asked about before it loads (2026-11-09).
- **2026-11-25. An `.html` file opens as the page it makes, in a browser
  tab**, from `wortel open` and a ⌘-clicked path, and loads again when the
  file changes on disk. A browser tab and not a Rendered mode of the file
  tab (as Markdown has): the page needs links, scripts, the inspector, and
  later mark-up and an agent's commands, which are a browser tab's. Files,
  Changes and ⌘P still open the file's own tab, because those lists are for
  reading a change and the preview tab only works with file tabs; that tab
  has an "Open as Page" button. `index.html:42` is the file at its line.
  This is the one place a ⌘-click runs what a file holds: the page's scripts
  run, in WebKit's sandboxed process, as a page behind a ⌘-clicked
  `localhost` link's do. It was weighed against the 2026-11-19 rule that a
  click never launches anything. That rule is about a program started as
  you (a `.command` in Terminal); a page can't do that. Measured 2026-11-25:
  a page opened from a file could not read another file, beside it or
  elsewhere, by `fetch`, `XMLHttpRequest` or a frame. What it can do is
  what any page can: use the network, and so tell a server it was opened.
  Not done: a store of its own without the tab's sign-ins, scripts off, or
  read access cut to the file's folder (a page then loses a stylesheet one
  folder up). The spike for phase 3 looks at a separate store anyway.
- **2026-11-25. A page's source shows in the same tab, behind a Page ·
  Source switch**, chosen by the owner over a file tab opened beside it.
  Nothing moves but the content: no second tab, the switch is under the
  pointer both ways, and the page stays loaded under the source. The cost is
  two places a file's text can show (this, and its file tab), and no Diff
  here: the diff is the file tab's, from Changes.
- **2026-11-25. The address field takes a file.** `file:` was refused there
  with the other non-web schemes (2026-09-29). A tab shows files now, the
  field shows the file it is on, and only a person types in it. Scripts
  (`javascript:`, `data:`) are still refused.
- **2026-11-25. A download in a browser tab is saved to `~/Downloads`, and
  nothing downloaded is opened.** This replaces the 2026-11-21 rule for web
  addresses: a response a tab couldn't show went to the default browser,
  which is signed out of the site that offered the file. A `file:` is still
  only shown in the Finder. The list is a button in the tab's header with a
  popover, as Safari has, chosen over a line under the page (no way back to
  an earlier download) and over no sign at all (a click on a download link
  looked like nothing happened). One list for the app, not saved: a history
  of downloads is a browser's job, and the files are in the folder. No
  question before a download, as the browser plan decided for an agent's
  shell: asking adds no safety when nothing is opened. A partial file from a
  stopped or failed download is removed, not moved to the Trash: Wortel made
  it seconds ago and it is half a file.
- **2026-11-26. A `download` link in a frame from another site saves
  nothing.** A response from such a frame was already refused; a link with
  the `download` attribute was not, and a frame can click its own link from
  script with no person involved, so the rule had a way round it. The link
  is now held to the same rule, by the frame it is in and not by where it
  points: a frame from another site can point a link at the page's own host.
  It is cancelled, not loaded instead. The cost is a real download button
  inside another site's embed, which does nothing; the file is a click away
  on that site itself.
- **2026-11-25. Find in a page is WebKit's public find behind the file tab's
  own bar**, with Safari's keys (⌘F, ⌘G, ⇧⌘G, ⌘E). One find bar in the app,
  not the system's `NSTextFinder` bar beside Wortel's. The cost is the count:
  the public call says found or not, so a page's bar says "Not found" where
  a file's says "3 of 12". The count and every match lit at once are behind
  private calls (`_countStringMatches`), left out for the reason the plan
  leaves out a view of network requests. ⌘F reaches the page in front from
  the terminal, as ⌘R does.
- **2026-11-24. A preview tab: a file looked at from Changes or Files while
  a file is in front takes the place of the one before it**, in one tab with
  an italic title, as in Xcode and VS Code. A click or ↑/↓ in the list does
  it, Space opens it (Finder's key) or closes it when it's in front, and so
  does a double-click in the list, from anywhere: a double-click that opened
  a kept tab made the next click open a second tab beside it. A double-click
  on the file the preview already shows keeps it, as in VS Code (with a
  file in front that is any double-click, since its first click put the file
  there); so do a double-click on the italic tab, a drag, or Open in the
  row's menu. With the
  terminal (or a page) in front a click only selects: the main area also
  holds the agent you're watching, and a click to stage a file must not
  cover it. Why this isn't the follow-the-selection window dropped on
  2026-08-06: that was a window with a pin, and nothing on screen said which
  window would change; here the italic title says it, it's the convention
  people already have from their editors, and it never comes up over a
  terminal by itself. Selecting several rows never moves it. After a
  relaunch it is an ordinary tab (`WorkspaceTabs.peek`).
- **2026-11-24. ⌘P finds files, close to Zed's file finder.** Once something
  is typed, a Files section sits under the sessions and over the commands;
  with nothing typed ⌘P is as it was, so ⌘P then Return still goes back. In a
  repository the list is git's index (`ls-files`: 20 ms for the Linux tree's
  97k files, no walk), plus the untracked files the git panel's status
  already has, or one `ls-files --others` the first time, queued behind the
  other background scans. Zed walks repositories too; with several worktrees
  of a 500k-file monorepo open, where `git status` takes 7 s, each would pay
  that walk. Elsewhere it is Zed's walk: five levels, VCS folders and
  `node_modules` skipped, no symlinks, a repository inside listed by git, and
  never from `/`, the home folder or a volume's top. Kept live by FSEvents,
  one changed folder re-read at a time. Matching is fzf's v2 scoring with
  the file name a tier above the path (VS Code's and Zed's rule): measured
  optimised at 487k paths, 1 to 12 ms a key. Debug builds are about 40 times
  slower at this, which only shows on a repository that size.

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
- **2026-11-21. Both sockets serve only this user.** The CLI's and the
  keeper's socket are owner-only from the moment they are bound (the umask is
  narrowed around `bind`; a chmod after it left a window, and a Unix socket
  can't be fchmod'ed first), and a connection whose peer is another user, or
  can't be named, is closed unread (`getpeereid`).

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
- **2026-11-23. Upstream shell fixes are ported by hand, and a new terminfo
  reaches hosts already set up.** Ghostty's fixes after v1.3.1 (a directory
  name could inject escape sequences, `SetEnv` clobbered the user's ssh
  config, bash's exit status and PROMPT_COMMAND bugs) went into Wortel's
  copies, not a re-vendor: upstream's ssh is now a binary Wortel does not
  ship. bash's title is printed with control bytes removed rather than put in
  PS1 as `\w`, which passes them through. The ssh cache entry carries a
  checksum of the bundled terminfo and the remote step always runs `tic`, so
  the 5ebe501 entry (overline, `Se` to the default cursor) replaces an old one.
  The list is in `macos/docs/debugging.md`.
- **2026-11-23. `~/.local/bin` is on the PATH of every shell Wortel starts,
  last.** Claude Code's own installer puts `claude` there, a Mac that never
  had a dotfile does not look there, and the installer's note about adding
  a line to `~/.zshrc` is missed: the first thing a new session said was
  "command not found: claude" (reported 2026-11-23, from a new Mac).
  Appended by the shell integration after the person's own startup files,
  so it never wins over anything already found and a PATH set there is
  kept. Added whether or not the folder exists, because the shell that runs
  the installer is the one that has to find the result (checked in zsh and
  bash: not found, install, found, same shell). The cost, on purpose:
  `claude` then runs in Wortel and not in another terminal until that line
  is added. The shell Settings asks which agents this Mac has
  (`AgentDiscovery`) has no integration, so its question adds the folder
  too, or an agent that runs in every session would be missing there. fish and elvish have the same lines and were not run.
- **2026-11-24. Claude Code opens fullscreen in Wortel, unless the person
  chose otherwise.** Seen on a small window: the side column open, the
  terminal at its 320pt minimum (44 columns), Claude made an edit, and after
  the column closed that diff stayed 44 columns wide, broken mid-word. Claude
  Code's inline renderer redraws only the visible screen at a new width.
  Measured with 2.1.331 in a pty harness, 44 to 100 columns: the visible
  rows came back wide, everything above stayed at 44, Ctrl+L the same, and
  only `claude --continue` reprinted it all. Its fullscreen renderer redraws
  the whole conversation at any width and for either appearance, so every
  shell Wortel starts gets `CLAUDE_CODE_NO_FLICKER=1` (`ClaudeRenderer`).
  Claude reads that variable before its `tui` setting and before its own
  safety switch (fullscreen turned off on a Mac where it failed to start
  several times, which names this variable as the override), so it is left
  out when Claude's user settings name a `tui` (a `/tui classic` stays
  classic), when Claude's global config holds `fullscreenAutoDisabled`,
  when the inherited environment sets it or
  `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN`, and when the settings file is not
  JSON. Looked at at each shell's start (read again only when a file
  changed), so a choice holds from the next new shell. Project settings are
  not read. Only a screen reader still turns fullscreen off ahead of the
  variable; tmux's control mode, which Claude would otherwise leave inline,
  does not. Not done: restarting
  an inline Claude when its terminal widens, as is done for a change of
  appearance; it would restart the agent at every peek at Changes and leave
  the narrow copy above the reprint. A shell the keeper kept from before
  this has no variable until it is replaced.

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
- **2026-11-20. Restart to Update quits Wortel itself if Sparkle hasn't
  after 3 seconds.** On a laptop a click did nothing: Sparkle's installer had
  the click, but the quit request its helper sends never arrived, and only a
  ⌘Q finished the update. The cause did not reproduce in test copies, so
  the click no longer depends on that request. The fallback quits from a
  run-loop timer: started from a `Task` it deadlocked against the deferred
  quit.
- **2026-11-24. The website downloads a DMG; Sparkle keeps the zip.** A
  plain disk image: the app beside a link to Applications, large icons, no
  toolbar, no background picture, nothing branded
  (`macos/scripts/make-dmg.sh`). It is notarized and stapled on its own and
  goes up as `Wortel-latest.dmg` and `Wortel-<version>.dmg`, never into
  `macos/releases/`, where `generate_appcast` would sign it into the feed as
  a second archive. `Wortel-latest.zip` is still uploaded every release,
  because the old link is pasted in places nobody can edit. The site's build
  links the zip (and its steps) until a HEAD finds the DMG, so a deploy before
  the first release that uploads one can't put a 404 behind the button.

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
- **2026-11-23. A hang is reported like a crash.** The first hang a user sent
  (twelve hours stuck in SwiftUI layout at 30 GB) had read only as
  `previous_exit: unclean`, and nothing in the numbers said where. After an
  unclean run the head of macOS's `.hang` report is reduced to `app_hung`:
  closed sets, buckets and offsets into our binary, the same bargain as
  `app_crashed`. MetricKit's hang diagnostics were not used, for the same
  reason as for crashes: the `.hang` file is the one the person can open.
- **2026-11-23. `agent_outdated` counts the warning triangle.** An agent
  that can report its state ran in a version too old to: which agent, from
  the fixed list, once per run that stays silent. Three of the first seven
  people who started an agent never got a status from it and nothing said
  why. It decides whether helping with an update is worth building.

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
- **2026-11-21. The homepage tells the hybrid: a real terminal first, agents
  one key away.** A stage of its own shows a shell, an agent typed into it,
  the field in Settings that names it, and ⌘N starting it. The agents take
  turns on the page (Claude Code, Codex, Pi), so it never reads as a Claude
  terminal; Codex was captured from a real run, Pi from its source and theme
  because it could not run here. Dropped: the worktree and survival stages
  (every agent app keeps its sessions; they are tiles now), the specs list
  (merged into the bento), a wordmark in the bento's middle (read as a logo),
  a photo behind the whole bento (read as wallpaper), and a compact window for
  the panes film's Terminal chapter. The bento follows Apple's keynote summary
  slides: one piece of the real product per tile, tiles of uneven size.
- **2026-11-23. Every release has a page of its own**, at
  `/updates/<version>`, so one release can be linked, shared and found by a
  search, and the changelog is also an Atom feed at `/feed.xml`. The
  changelog shows the newest release in full and every earlier one as a row
  under its month: twelve in full made a page twelve screens long that
  nobody could scan, and the same text twice for a search engine. "What's
  new" in the hero goes to the changelog, not to the release's page, because
  from there the rest is one scroll away. `/updates#<version>` keeps working,
  since the app links that way. Every Download button goes to `/download`
  and the download starts on arrival, so nobody gets a zip without the three
  steps that say what to do with it; a plain visit to that page only shows
  the button.
- **2026-11-23. Only the first screen's pictures come with the page.** The
  homepage fetched all five photos and the browser pane's screenshot at
  once, 1.8 MB, and on a phone (4x slower CPU, slow 4G, measured with
  Playwright against the built site) the hero's photo showed at 6.7 s because
  it waited behind the other four. Now the hero's photo is preloaded, every
  other stage asks for its photo when it comes within a screen and a half,
  screens up to 900px get a 1600-wide WebP copy, and the 80px icons use a
  256px file, not the 512px one. Measured the same way afterwards: 292 KB and
  2.1 s on the homepage, 38 KB and 0.6 s on `/docs`, no layout shift on any
  page. The desktop photos are the same JPEGs as before: WebP was not used
  there because the fog is where its banding would show.
- **2026-11-23. What the app windows show is not the page's content.** The
  file preview in a window has headings of its own, which gave the homepage
  three `<h1>`s, two of them a made-up plan's title. They are plain blocks
  now (`AppContent.astro`), and every window carries `data-nosnippet`.
- **2026-11-23. One row opens every section on every page, and headings are
  light and short.** A hairline, the heading at the left in two lines (the
  claim in ink, its other half in grey), one paragraph and a link from the
  middle of the page; then the stage. Inner pages are made of the same row.
  The grey half of a homepage heading used to be the caption of the chapter
  playing: it changed every few seconds and the reader had to chase it, so the
  words now stay and the chapter tabs are the only thing that names a chapter.
  The hero's second button stayed (the newest release). A button to the
  source on GitHub is in the nav and in the closing call, not in the hero,
  where a third button crowded the two that matter there, and
  the questions moved into the right
  column beside their heading. This reverses "one left edge" from 2026-11-11:
  the text now starts beside its heading, not under it. On the homepage that
  is the middle of the page. Inner pages were first given the same split, and
  a whole page of text in the right half read as a sidebar with an empty page
  next to it, so they went back to the measure they had: the name in three
  columns, the text in eight.
  The first pass was modelled on polar.sh and its field guide, and read as
  theirs. Tried and dropped from it: section numbers and a margin index in
  mono, links in mono brackets, grey photographs with film grain, 8px corners,
  a list of the page's sections beside the hero. Also dropped: the two-tone
  heading set as one long line across the page.
- **2026-11-24. On a phone a window is a small window, not a cropped one.**
  This reverses "it stays at its real size and the stage crops it". Cropped,
  three quarters of what a phone showed was the sidebar, the terminal was a
  strip a few words wide, and in the panes film the column each chapter is
  about was off screen. Now the window is as wide as the stage with its
  sidebar folded (a state the app has: the main pane's minimum is 80 points)
  and the terminal wraps, as a terminal does. It is still never scaled. The
  panes and agents films, which are about two parts of the window, keep a
  wider window and pan. Three liberties, taken so the session's name stays
  readable in the bar: no Back and Forward there, one tab in the hero, and
  Settings at the stage's width. Tried on the way: the real bar with all
  three buttons, which left the name two letters ("Qu…"), and Settings at its
  380 points, which cut every switch in half at the stage's edge.
- **2026-11-24. A phone is not handed the download.** Every Download button
  leads to `/download`, which started the download on arrival, on a phone
  too: a Mac app in a phone's Downloads. There the page now offers to send
  itself to the Mac (the share sheet, so AirDrop is one tap) and keeps the
  download, the disk image or the zip, a link away.
- **2026-11-24. No page scrolls sideways on a phone.** `/docs` did: the
  commands table was as wide as its longest command. A table of terms is a
  list there, and `/compare` shows Wortel and one other app, each question
  over its two answers, instead of five columns to scroll through with the
  question out of sight.
- **2026-11-24. A terminal on the site scrolls; it does not drop rows.**
  The films print lines into a full terminal, and the rows that no longer fit
  were taken out of the page, which moved every row under them. Chrome counts
  that as layout shift: 0.036 on a phone while the terminal was a strip, and
  0.108 once it was a whole window there, past the 0.1 that search treats as
  good. The rows now stay, unseen, and the terminal's box is scrolled past
  them to a row's edge. It looks the same and measures 0, on a phone and on
  a wide screen (which was at 0.012).
- **2026-11-24. A photo always covers its stage.** A closer crop was a
  background width (`200%`), which says nothing about height: on a phone,
  where a stage is taller than the photo's shape, the photo ended early and a
  band of the stage's flat colour showed under it (pale, or near black with
  the dark veil). That was the Start stage, the closing photo on `/compare`
  and `/about`, and one bento tile at 360px and under. A crop is now a number
  (`data/photo.ts`): the photo's layer is that many times the stage's width
  and the photo covers the layer, so it is that wide or as tall as the stage,
  whichever is more. Wide screens draw the same crop as before. Since the
  photo now fills a narrow closing stage, what lies behind its words is no
  longer always fog, so the fog there holds through the words before it fades.
  A stage that has not asked for its photo yet keeps its veil, so in dark mode
  it is not a pale box.
- **2026-11-24. Nothing but the stage clips a window.** On a phone the box
  around the window was given its own clip, for the wider windows that pan.
  It also cut the window's shadow off in a straight line above the window,
  which read as a pale band across the top of the photo (a dark one at
  night). The stage clips at its own edges already, so the inner clip is
  gone, and the pan and the two overlays measured against that box (Settings,
  the notification) are measured against the plain one.
- **2026-11-25. The panel under the bento is the site's grey, not a beige
  of its own.** It was `--fog-2`, a cream that nothing else on the site
  used. It is now `--btn-2`, the grey the quiet buttons and a chosen row are
  filled with, and `--fog-2` and `--fog-3` are gone so the beige cannot come
  back by name.
- **2026-11-25. The closing photo has no version line.** "Version 2026.47.4
  · 27 MB" sat beside the buttons as small grey print on the landscape, where
  it could not be read. It is gone at every width (a phone had already lost
  it). The download page says the version and the size.

## Contributing

- **2026-11-21. A Debug build is its own app unless the Mac opted in.** Out
  of a fresh clone it uses `Wortel Dev` and the bundle id
  `com.gielcobben.Wortel.dev`, so it can't adopt an installed Wortel's
  sessions, replace its keeper (which ends every shell when the protocols
  differ) or prune its UserDefaults. The maintainer's daily Wortel is a Debug
  build from whichever worktree was built last, so the way back is one file
  per Mac, `debug-builds-share-this-folder` in the usual data folder, read by
  `DataDirectory` (the app, the keeper and the `wortel` command) and by
  `scripts/debug-bundle-id.sh` (the bundle id, at build time). Not a
  gitignored file in the checkout: every worktree Wortel makes would lack it.
  Not an environment variable: a launch from the Dock or Finder doesn't carry
  one, and the keeper and the command must reach the same answer as the app.
  Not a bundle id from an `xcodebuild` variable: that would be a second
  opt-in to keep in step with the first.
- **2026-11-21. `bench/measure.sh` measures a throwaway copy.** It used to
  `pkill -9` every running Wortel, the one running the script included. A
  copy with its own bundle id and data folder is stopped by path and pid.
- **2026-11-21. Contributions are under the project's licence,
  GPL-3.0-or-later, and there is no contributor licence agreement.** What
  comes in goes out under the same terms (`CONTRIBUTING.md`).
- **2026-11-21. Wortel is GPL-3.0-or-later.** Chosen over MIT so nobody can
  ship a closed fork of the whole app, and it sits with the three shell
  integration scripts that are GPL already (from Kitty, via Ghostty). The name
  and icon stay outside the licence (`TRADEMARKS.md`); the official builds
  stay free for any use. The Terms said "not open source" and "you may not
  sell it" until this day; the GPL allows selling, so that line went.
- **2026-11-21. The tests get a data folder of their own.** `WortelTests`
  compiles `DataDirectory` with `WORTEL_TESTS`, which points it at a per-run
  folder in `$TMPDIR` unless `WORTEL_DATA_DIR` says otherwise. Before, a test
  that drove a terminal reached `TerminalModeRecorder.shared`, which loaded
  and saved `terminal-modes.json` in the real folder and pruned it to the
  test's sessions: every test run rewrote the running Wortel's file.
- **2026-11-23. CI leaves out `KeeperTerminalProtocolTests`, for now.** The
  first CI runs failed it every time, a different two of its nine tests each
  run, always the same way: a second attach to a live session got a channel
  that ended with no snapshot and no output, and the keeper logged nothing
  (none of `attachTerminal`'s three logged exits). It reproduces on `main`
  (9e7f675) on this Mac with the class run under `taskpolicy -b`: two of four
  runs failed. So it is a keeper race that load exposes, possibly what a blank
  terminal after a reattach is, and it is open. CI skips the class through
  `XCODEBUILD_FLAGS` in `.github/workflows/macos.yml`; `./scripts/check.sh`
  still runs it. Remove the skip with the fix.
- **2026-11-23. CI runs only what a change touches.** The first day of CI
  used about 75 macOS minutes, which a private repository bills at ten times
  a Linux minute, and GitHub warned about the monthly limit. The one
  workflow became two with path filters: `macos.yml` (the app, `check.sh`,
  the licence files) and `web.yml` (`web/`, `updates/`), so docs and site
  changes never start a Mac. A newer push cancels the run before it, on
  `main` too. The Ghostty build is saved as soon as it exists rather than
  only when every test passes: no run had reused one, so every run spent
  five minutes building it again. A hung run stops at 30 minutes, not 60.
- **2026-11-24. An agent closes its own session with `wortel close`.** Told
  "delete this worktree", an agent reached for `git worktree remove` from
  inside the worktree, lost the path between messages twice, and needed
  `--force` for the untracked files it had copied in, while closing the row
  in Wortel would have kept the worktree for those same files. Now it runs
  `wortel close` and finishes its reply: the session closes when the turn
  ends (not cut off mid-sentence, as `cd` waits), and the worktree goes as a
  click's would, except that uncommitted files are asked about at once on
  the session's window instead of keeping it, and a yes trashes the files
  shown (by path; a new one keeps it). Return keeps: the sheet arrives
  unasked, so trashing takes a click. Trash, never `rm`, and the branch only when Wortel made it
  and nothing on it is unique. One verb, no `--force` and no `--session`: a
  flag the agent picks would be the agent deciding to throw away files, and
  the question puts that with the person.
- **2026-11-24. A new worktree session is two lines from the start.** Named
  for its placeholder branch (`brave-river-1a2f`), the row was one line until
  the agent's title came, then grew its branch line and pushed every row below
  it down. Started with a known agent it is now called for the agent
  ("Claude") with the branch underneath while it prepares, so the title
  replaces words and nothing moves. A plain shell keeps the branch as its
  name: nothing will title it, and "Terminal" over its branch would say less.
- **2026-11-26. CI keeps no Zig cache.** `mlugg/setup-zig` saved its own
  cache of about 400 MB after every macOS run, a new entry each time (four
  on `main` in two days), and a repository keeps 10 GB of caches, dropping
  the least recently used. That puts the 32 MB Ghostty build at risk, and
  losing it costs the five-minute build. Zig is only needed when that build
  misses, so `use-cache: false`. The Ghostty cache was checked first: it
  restores in 4 s and the build step then takes 1 s, so CI does not rebuild
  Ghostty per commit.
