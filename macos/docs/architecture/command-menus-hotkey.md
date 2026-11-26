# The `wortel` command, menus and the global hotkey

Part of the app's architecture record; the index is in `macos/AGENTS.md`.
Paths are relative to `macos/`.

**The `wortel` command** (`Wortel/CLI/`, `WortelCLI/`) — a Unix socket the CLI
speaks JSON at: `open`, `new`, `rename`, `notify`, `mark`, `remind`, `cd`,
`close`, `split`, and `list`, `read`, `send`, `wait`. `docs/wortel-command.md` is
the user-facing guide, `docs/cli.md` the design record; the decisions that
shape the code are that **there is no installer** (the binary
ships in the bundle and `GhosttyRuntime` puts its directory on the `PATH` of
every shell it spawns, so it exists inside a session and nowhere else), that
**it never steals focus** (windows are ordered front, the app is never
activated, so a hook firing behind your back can't take your keyboard), and that
**a command means the session it was run in** (`$WORTEL_SESSION_ID`, not an
argument), except the four that **reach other sessions** by id or name
(`WortelReach.swift`): `read` the screen, `send` a paste and a Return through
the same calls ⌘V and the key take, `wait` for new text, idle or exit with the
connection held open (never the main thread). `send` has **no prompt and no
label**, like a person typing; the trust boundary is the user's own sessions,
since the binary only exists inside them. `list` and `wait --idle` read
`SessionManager.activity(of:)`, the sidebar's own busy and attention state.
`split` puts a terminal in a split beside a session's main row and takes
nothing: `GitPanelModel.splitFromCommand` leaves the keyboard, the area you're
in, a zoom and Back's trail alone, and `SessionManager.startSideTerminal`
starts its shell at once, on screen or not, so its command runs. The point of having it at all is that Wortel then ships no per-agent
integrations: anything that can run a command can drive the app. The CLI target
is named `WortelCLI` and not `wortel` — same-name targets collide in the
intermediates directory on a case-insensitive filesystem, and the app ends up
containing the CLI's executable.

**Menus** (`Wortel/MainMenu.swift`) — built programmatically and kept small
because AppKit scans key equivalents on every keypress. The menu is
**authoritative** for key equivalents, and this interacts with `wortel.conf`
keybinds: e.g. "Select All" is bound to ⌘⇧A precisely so that ⌘A is freed for
the `wortel.conf` keybind that clears the input line. When adding/moving a
keybind, check both files.

**The global hotkey** (`Wortel/GlobalHotkey.swift`) — ⌃⌥⌘. shows and hides the
app from any app on the machine, and it is the one binding the menu does *not*
own. It is a Carbon `RegisterEventHotKey` rather than an
`NSEvent` global monitor for two reasons: a monitor needs the Accessibility
permission, which a terminal with nothing to set up should never have to ask for, and it
only observes the chord instead of claiming it, so the keypress would also land
in whatever app you were in. Registration is hardcoded and unconditional —
it is not something that differs per person, so it has no row in Settings, and
the chord is chosen to be one nothing else wants.

The App menu carries a matching "Show/Hide Wortel" item, which is not a
conflicting second binding: a registered hot key is consumed before AppKit scans
the menu, so that item displays the chord and never fires on it. It becomes the
real (in-app only) binding exactly when registration failed because another app
owns ⌃⌥⌘., which is the only case where a fallback is worth anything.
`AppDelegate.toggleAppVisibility` is the shared action, and it undoes hidden,
buried and miniaturized on the way up, because someone pressing this key means
the same thing by all three.
