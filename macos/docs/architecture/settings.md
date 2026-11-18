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
| Open servers in default browser | `AppSettings.opensServersInDefaultBrowser`, `browser.opensServersInDefaultBrowser` | `RunningJobsPopover`, whose row menu has the same switch |
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
  menu, closing the window), not per keystroke, so ⌘N pressed mid-word
  starts what was last saved (`CommandRow` in `SettingsView.swift`).
- **One place decides who gets it**: `SessionStart`, which every way of
  making a session must name, with no default. The app's own ways in pass
  `.preferred`; `wortel new` passes its own line or `.plain`; the session
  made at launch and New Terminal pass `.plain`. `makeSession` reads the
  setting once, when the row is made, and uses the mechanism `wortel new --`
  already had (`Session.startupInput`: the keeper types it before the shell
  has read a byte; a worktree session gets it once git is done).
- **New Terminal** (⌃⌘N) is hidden unless the field holds a command, in the
  Session menu (shown and hidden from `AppSettings.onNewSessionCommandChange`,
  as Restart to Update is by the updater), the sidebar's + menu and a
  folder's menu.
- **The menu at the field's end** holds the known agents this Mac has, and
  Terminal, which empties the field. It is absent until there is an agent to
  offer (`AgentDiscovery`):
  the login shell is run once when the window opens, off the main thread,
  with `command -v` between two sentinel lines so nothing its startup files
  print can get in, and three seconds to answer. If it doesn't, the usual
  install folders are scanned instead. Nothing runs while the window is
  closed. The names are `AgentCommands`, which a test holds against the
  shell integration's six copies of the same list.

## How it is built

- **`AppSettings`** holds only what is plain `UserDefaults`, is `@Observable`
  so a view follows a change at once, and takes its `UserDefaults` in `init`
  so `AppSettingsTests` can run it on a throwaway suite. Sparkle's and
  telemetry's preferences each have one owner already and are not copied here.
- **The window is drawn as Wortel's own windows are**
  (`SettingsWindowController`): the titlebar row on the window's glass, an
  opaque page under its hairline (`BackdropController`,
  `ChromePaneController`, as the main and preview windows). The row holds
  the switch between the two tabs, **General** (what a new session starts,
  the commit box, where servers open) and **Updates** (automatic updates,
  usage data): the app's own `PillSwitch`, which the preview window uses for
  Diff · Source · Rendered. The window keeps its width and takes the height
  of the tab in front, on the app's motion curve. Made when asked for and
  released when closed, so nothing of it exists off screen.
- **This look is an experiment (2026-11-18)**, to be compared with the
  system's preferences window it replaced: an `NSTabViewController` with
  icon tabs and the system's grouped form, which is commit `37b52e6`.
  Whichever stays, this entry should say only that one. Tried before both:
  one pane with no toolbar, which is what the guidelines say for five rows
  and read as a dialog rather than as settings.
- **The page** (`SettingsPage` in `SettingsView.swift`) is the app's type and
  numbers: 13pt names, 12pt grey lines, hairlines between groups, small
  switches, and a 28pt field with 8pt corners. Each row is a name and one
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
