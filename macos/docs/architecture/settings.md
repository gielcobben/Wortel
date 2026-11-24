# Settings

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

**Settings** (`Wortel/Settings/`) is one small window on ⌘, (Wortel ▸
Settings…). Until 2026-11-18 Wortel had none, on purpose; `docs/decisions.md`
has the reversal and why.

## What a row is for

A row is for something **decided once that truly differs per person**. Before
adding one, each of these has to be answered:

1. **Can the app know the answer?** Then it gets no switch.
2. **Is it flipped while working?** Then it is a checkmark in the View menu
   (Sort Unread First, which side the column is on), as Finder keeps its
   sorting there.
3. **Is it about how the terminal looks or types?** Then it is decided in
   `Resources/wortel.conf`, which is read-only inside the app and cannot grow
   keys. Font size is ⌘+ and ⌘−.
4. **Who differs, and why?** If the honest answer is "someone might want it",
   it is not a row.

A row that survives gets a dated line in `docs/decisions.md`.

## The rows

| Row | Stored in | Read by |
| --- | --- | --- |
| New sessions start with | `AppSettings.newSessionCommand`, `sessions.newSessionCommand`, empty unless set | `SessionManager.makeSession`, through `SessionStart` |
| Commit box in Source Control | `AppSettings.showsCommitBox`, `git.showsCommitBox`, on unless turned off | `SourceControlPanel` |
| Open servers in default browser | `AppSettings.opensServersInDefaultBrowser`, `browser.opensServersInDefaultBrowser` | `RunningJobsPopover`, whose row menu has the same switch, and a ⌘-clicked `localhost` link (`AppDelegate`, `onOpenLocalServer`) |
| Update automatically | Sparkle's own preferences, through `Updater.updatesAutomatically` and `setUpdatesAutomatically` | Sparkle |
| Share anonymous usage data | `TelemetrySettings.isEnabledByUser`, through `Telemetry.setReporting` | `TelemetrySettings.isEnabled` |

The last two are the Updates tab, and are absent on a build where they can do
nothing (a development build has no updater and never reports): absent, not
greyed. The usage-data
switch is also in the sidebar's ⓘ, which is where the first-run notice and
the privacy page point.

## New sessions start with

One line, typed into a new session's shell as its first command. Empty is a
plain terminal.

- **Typed as written, never quoted** (`NewSessionCommand`): `claude --model
  opus` is a command and two arguments. It goes into the person's own login
  shell, so their PATH, aliases and functions apply. A control character
  inside it, a second line, or more than `MAX_CANON` bytes is refused with a
  reason under the field and never saved.
- **Saved when editing ends** (Return, leaving the field, picking from the
  menu, switching tab, closing the window), not per keystroke, so ⌘N pressed
  mid-word starts what was last saved. The text being typed lives in
  `SettingsTabState`, not in the field's view, because the field goes away
  with its tab and with the window: whoever takes it away saves it first
  (`commitCommand`).
- **One place decides who gets it**: `SessionStart`, which every way of
  making a session must name, with no default. The app's own ways in pass
  `.preferred`; `wortel new` passes its own line or `.plain`; the session
  made at launch and New Terminal pass `.plain`. `makeSession` reads the
  setting once, when the row is made, and uses the mechanism `wortel new --`
  already had (`Session.startupInput`: the keeper types it before the shell
  has read a byte; a worktree session gets it once git is done).
- **The start is kept under an empty page** (`StartCover`, in
  `Sessions/StartCover.swift`, with its clock in `Ghostty/StartWatch.swift`).
  `Session.ensureSurfaceView` asks for it for any session made with a line;
  `GhosttyRuntime` grants it when the keeper has just forked the shell and
  typed the line, and the login shell is zsh or bash. Before the first read,
  `SurfaceView.coverStart` holds what is typed (`PtyHost.holdTyping`) and has
  `KeptTerminalFeed` read the output for the start (`StartScanner`, on the
  pty queue, events to the main thread). `SessionManager.refreshAgentActivity`
  says when the marker shows the line is an agent. When the rule ends,
  typing is released or dropped, `afterStart`'s waiters run (a paste,
  `wortel send`), and `TerminalHostViewController` takes its page off. The
  terminal is in the hierarchy and first responder the whole time. To watch
  one: `log stream --level debug --predicate 'subsystem ==
  "com.gielcobben.Wortel" && category == "session-start"'`. The rule, its
  numbers and what was left out are in `../../../docs/decisions.md`
  (Sessions, 2026-11-24).
- **An agent headed for the home folder gets a folder of its own**
  (`ChatFolder`): `~/Wortel/<day>/<n>`, numbered from 1 each day, made when
  the row is made. Only for `.preferred` with a command set, and only when
  the session would otherwise start in `~`, in `~/Wortel` or in a folder
  under it (so ⌘N beside one makes another); ⌥⌘N included. A plain terminal,
  `wortel new` and anything given a directory are untouched. The reason is
  Claude's trust question, which it never saves for `~`: until
  `~/.claude.json` records `~/Wortel` (or a folder above it) as trusted, a
  Claude session starts in `~/Wortel` itself and Claude asks there once;
  after that every one gets its own folder and is never asked. The session
  is called by its command ("Claude") until the agent names it. Nothing
  made there is ever removed. Only a `~/Wortel` that Wortel made is used (a
  `.made-by-wortel` file in it; one holding only day folders and the
  unedited guide, from the first build, is recognised and marked): a folder
  of someone's own at that path, or at `~/wortel`, is never written to, and
  an agent then starts at home as before. Until `~/Wortel` is trusted, only
  one session waits in it at a time; another gets its own folder.
  `~/Wortel/CLAUDE.md` (written when missing,
  `ChatFolder.guide`) tells the agent to offer `wortel cd` when the work
  turns to a project elsewhere. A test copy keeps its own under its data
  folder.
- **New Terminal** (⌃⌘N) is hidden unless the field holds a command, in the
  Session menu (shown and hidden from `AppSettings.onNewSessionCommandChange`,
  as Restart to Update is by the updater), the sidebar's + menu and a
  folder's menu. **New Terminal at Home** (⌃⌥⌘N) is the same for ⌥⌘N, in the
  Session menu and the sidebar's +.
- **The menu at the field's end** holds the known agents this Mac has, and
  Terminal, which empties the field. It opens under the field at the field's
  width (`MenuAnchor`), and is absent until there is an agent to offer
  (`AgentDiscovery`): the login shell is run once when the window opens,
  whichever tab is in front and however often they are switched, off the
  main thread, with `command -v` between two sentinel lines so nothing its
  startup files print can get in. The question adds `~/.local/bin` to that
  shell's PATH first, as the shell integration does for a session, so what
  runs in a session is what is listed. It has four seconds, counted by the
  discovery itself: the command runner waits for the shell's output to
  close, and a startup file that leaves something running keeps it open. If
  no answer comes, the usual install folders are scanned instead, and while
  one shell is still out no second one is started. The same question is
  asked at launch and when the permissions popover opens, only on a Mac
  where no agent has been seen yet (`Permissions.lookForAgent`); there no
  answer is left as no answer, and the folders are not taken for one.
  Otherwise nothing runs while the window is closed. The names are `AgentCommands`, which a test holds
  against the shell integration's six copies of the same list.

## How it is built

- **`AppSettings`** holds only what is plain `UserDefaults`, is `@Observable`
  so a view follows a change at once, and takes its `UserDefaults` in `init`
  so `AppSettingsTests` can run it on a throwaway suite. Sparkle's and
  telemetry's preferences each have one owner already and are not copied here.
- **The window is drawn as Wortel's own windows are**
  (`SettingsWindowController`): the titlebar row on the window's glass, an
  opaque page under its hairline (`BackdropController`,
  `ChromePaneController`, as the main and preview windows). The row holds
  the two tabs in its middle, **General** (what a new session
  starts, the commit box, where servers open) and **Updates** (automatic
  updates, usage data), drawn as every tab in the app is (`SettingsTabStrip`,
  to `SideTabStrip`'s numbers: 28pt, 8pt corners, a glyph and the name, the
  one in front on the band's selection fill). A pill switch like the
  preview's Diff · Source · Rendered was there for an hour and read as a
  control, not as tabs. The window keeps its width and follows the height of
  its rows on the app's motion curve (`SettingsPage.onHeight`). The rows are
  laid over the page from its top and clipped to it, because rows taller
  than a window still growing were centred on it and ran up over the
  titlebar row. Made when asked for and released when closed, so nothing of
  it exists off screen.
- **Why not the system's preferences window.** It was built first and run
  for an afternoon (2026-11-18, commit `37b52e6`): an `NSTabViewController`
  with icon tabs and the system's grouped form. It was correct and felt like
  another app's window beside this one. Before that, one pane with no
  toolbar, which is what the guidelines say for five rows and read as a
  dialog. The owner chose this one after using all three.
- **The page** (`SettingsPage` in `SettingsView.swift`) is the app's type and
  numbers: 13pt names, 12pt grey lines, small switches, and a 28pt field
  with 8pt corners, with the rows that belong together in a box
  (`SettingsBox`: the bottom strip's faint band, 10pt corners, a hairline
  between its rows), as the system groups its own. The page with hairlines
  alone was tried and the boxes were missed. The window is 380pt wide, which
  is as narrow as the longest grey line allows without wrapping. Each row is a name and one
  grey line saying what it does, and a click on either flips the switch
  (`SwitchRow`: the gesture is on the label only, since the switch takes its
  own clicks). A click on the command's name puts the cursor in its field.
- **On a development build the Updates tab stays**, with one line saying
  there is nothing to set, since its two rows are absent there: a window
  whose tabs come and go with the build is a different window to test.
- **It closes with the main window** (`AppDelegate`, the observer that closes
  previews). Otherwise it would be the last window and keep the app up.
- **⌘,** is the menu item's. Ghostty binds the same key to opening its config
  file, so `wortel.conf` unbinds it.
- **⌘P lists "Settings"** because it reads the menu bar.
