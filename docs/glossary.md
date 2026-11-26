# Glossary

The words this project uses, and what each one means here. Several are ordinary
words with a narrower meaning than you would guess. Use them the same way in
code, docs and copy.

## The window

**Session.** One row in the sidebar: a named shell in a directory, with its own
terminal, tabs and git panel state. The unit of everything. Not a tab.

**Folder.** A group of sessions in the sidebar. A session is in a folder when
its name has a slash: the folder is the part before the last one. A folder also
carries a directory (its **folder root**), where new sessions in it start. It is
not a folder on disk, which is why the menu says "Ungroup Sessions".

**Main area.** Everything in the window beside the sidebar
(`MainAreaController`). It is a tree of columns and rows, and each part of it
is a split. The word has an older, narrower meaning that is still about: the
middle place only, which is now the main row. The released app and older docs
use it that way. Where it matters which, say "main row".

**Split.** A part of the main area with a row of tabs and the page under it.
One of them is the **main row**: the split with the session's own terminal,
which never leaves it and cannot be closed. The main row is always there.
Every other split is there only while it has tabs. You make one with ⌘D or
⇧⌘D, or by letting go of a tab on a split's edge. Wortel opens two for you,
the side column and the bottom strip. In code a split you made is
`TabRegion.pane(id)` and the tree is `SplitLayout`: that "pane" means a split,
not the pane defined below. Splits are on the branch `flexible-panes` since
2026-11-26 and not released.

**Start cover.** The empty page over a new session's terminal while the line
it was made with is still starting. What is typed under it is held.

**Side column.** Where Changes and Files open when nobody says where: a split
at the outer edge of the main area, on the right, at the width you last chose
(⌥⌘B opens them there and closes them again). That is all the word means
now. It is a split like any other: it is there while it holds a tab, and it
cannot be hidden. No menu or tooltip uses the word since 2026-11-26. In the
released app it is a fixed place that ⌥⌘B hides and shows. The code also says
**side split**, and older docs and some code **inspector**.

**Bottom strip.** Where ⌘J's terminal opens: a split under the main row, at
the height you last chose. Also only a default place now, and a split like any
other. In the released app ⌘J hides and shows it.

**Tab.** One thing in a split's row: a terminal, a pane, a file, a browser,
or an **empty tab**, which is none of those yet. A row's "+" opens an empty
tab, and its page lists what it can become.
The session's own terminal is a tab too, named after the session, in the main
row. It has no close button. The terminal engine has no tabs and no splits of
its own. These are Wortel's.

**Pane.** One of the three git and file views: Changes, History, Files.

**Workspace.** A session's whole arrangement: the tabs in each split's row,
and how the main area is divided among the splits (`WorkspaceTabs`).

**Surface.** One libghostty terminal, and the view that hosts it
(`SurfaceView`). Created lazily, then kept alive and hidden, never rebuilt.

**Preview.** A file opened to look at: source, diff, rendered Markdown, or
Quick Look. A tab by default.

## Sessions and their life

**Origin cwd.** The directory a session was born in. It never moves. `cwd`
follows the shell around; new sessions inherit the origin, not the drift.

**Worktree session.** A session whose directory is a git worktree of its own,
so an agent in it cannot disturb another.

**Archive.** What closing a worktree session does: the shell ends, the worktree,
branch and conversation are kept, and ⌘P brings it back. Only a worktree with
nothing worth keeping (Wortel's own, clean, its work already elsewhere) goes to
the Trash instead.

**Owned.** A worktree or branch Wortel made, recorded by a marker in git, never
guessed from a path. Wortel only ever removes what it owns.

**Window.** A main window: a sidebar of its own sessions, and the main area
beside it. With Changes beside the terminal and a terminal below it reads as
four places, which is what older docs call it.
A session is in exactly one window and moves between them with its terminal
running. The **active window** is the one last in front; the commands act on
its session. Not a preview window, which shows one file.

**Lead.** In a multiple selection, the one item that is "the" selection: the
session on screen, or the file whose diff is showing.

**Data folder.** `~/Library/Application Support/Wortel`, or whatever
`WORTEL_DATA_DIR` names. A Debug build uses `Wortel Dev` instead, unless the
Mac opted in (`macos/docs/building.md`). Sessions, the keeper's socket and
agent markers live there. One running Wortel per data folder.

## Survival

**Keeper.** `wortel-keeper`, the small process that holds every pty so shells
are not the app's children. Never named in the UI.

**Attach.** The app asking the keeper for a session: its terminal's channel
(a snapshot, then the output) and its pty to type into. There is no detach:
the connection closing is the app gone. The keeper is every pty's one reader.

**Snapshot.** The keeper's terminal for a session, whole, as libghostty-vt
encodes it: what an app's surface is restored from. Only readable by a Ghostty
built from the same commit.

**Dropped** (in code still `hibernate`). A session whose terminal's surface,
the app's copy of it, was freed after a minute out of sight, or on a memory
warning. The keeper keeps the terminal itself and the app still reads the
output; shown, the surface is restored from the keeper exactly. Never named in
the UI.

**Asleep.** A session whose agent was ended to give its memory back, after an
hour at rest out of sight (eight, if it was waiting on you, had something
running, or could be reached by Remote Control). Its shell stays, and the
agent's exact conversation is resumed when the session is selected. Deeper
than a dropped terminal, which only frees the app's copy of it. Never named in
the UI.

**Resume.** Typing an agent's own "continue this conversation" command back
into a session after a relaunch or a recovery, or when a session whose agent
was asleep is selected, by exact conversation id.

## Agents

**Agent.** A coding agent's command-line program running in a session: Claude
Code, Codex, Pi and the like. A guest. Wortel installs nothing into it.

**Marker.** A small file in the data folder, written by the shell integration
while an agent runs, saying which agent and since when. It exists only during a
run.

**Busy.** The session is working: three small dots in a wave, in the sidebar.

**Attention.** The session wants you: a dot, the Dock badge, a notification. It
has a kind, loudest first: **needs input**, **failed**, **turn done**,
**finished**. A louder kind is never downgraded to a quieter one.

**Turn.** One prompt and the agent's whole answer to it. The agent says when
one ends, in a report.

**Report.** A program saying what it is doing, itself: working, blocked on
you, done, failed (the Program Status Protocol, OSC 7501). Codex, Claude Code,
Pi, opencode and others send them. It is the only way Wortel knows what an
agent is doing: one that sends none shows no spinner and no turn end.

**Signal.** Something a program says about itself through the terminal: a
report, a notification escape, a bell, OSC 9;4 progress. Wortel acts on what
is said and infers nothing from a title or a screen.

**Away.** The Mac has not been touched for a minute. Changes what an attention
signal does.

**Viewing.** Wortel frontmost, the session's window on screen, the session in
front in it, and not away. With two windows side by side, two sessions are
viewed. Attention is not raised for a session being viewed.

## The command

**`wortel`.** The command-line interface, bundled in the app and on the `PATH`
of every shell Wortel starts. It exists inside a session and nowhere else.

**Reach.** The four verbs that act on another session: `list`, `read`, `send`,
`wait`.

## Configuration and releases

**Settings.** The one Settings window (⌘,) with the few switches that differ per
person. Everything else is decided once: there is no user config file, and
`wortel.conf` is read-only inside the app. Older notes call this zero-config.

**`wortel.conf`.** The bundled, read-only Ghostty config that is the whole
configuration. No inline comments: a `#` after a value becomes part of it.

**Version.** `<ISO year>.<ISO week>.<nth release that week>`, such as
`2026.46.5`. Derived from the date and the live feed. Nobody picks one.

**Release note.** One Markdown file per version in `web/src/content/releases/`.
The changelog and the update dialog both render from it.

**Appcast.** The Sparkle feed at `updates.wortel.sh/appcast.xml`.

## The site

**The lake.** The foggy-lake photograph the site's colours are sampled from, and
by extension the site's look.

**Stage.** A scene on the homepage: a heading, then a real app window standing
on a photo, with chapter tabs over it.

**Chapter, film.** A stage plays through chapters by itself, like a short film.
Each chapter puts the window in a state.

**The canvas.** The design file the app's panes are drawn on. The site's windows
are generated from it and never edited by hand.

**1:1.** The app shown at its real size. Never scaled.
