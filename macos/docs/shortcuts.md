# Keyboard shortcuts

Wortel's shortcuts follow the apps people already have in their fingers, so the
layout works the way you'd guess from day one. Where apps disagree, the choice
goes to what most of them share, and nearly every shortcut is Command-based.
The few Control keys are the ones the editors all use (⌃Tab, ⌃`, ⌃⇧G).
Control and Option with a letter always stay with the shell.

A few rules cover most of it:

- **The layout is an editor's.** ⌘B is the sidebar, ⌥⌘B is Changes and Files
  beside the terminal, ⌘J is the terminal below: the three keys VS Code,
  Cursor, Zed and Codex use for their three areas.
- **What you open is ⇧⌘ and its first letter.** ⇧⌘C Changes, ⇧⌘H History,
  ⇧⌘F Files, ⇧⌘B a browser. That is the shape VS Code, Zed and the Claude
  app give theirs (⇧⌘E Explorer, ⇧⌘F Search or Files, ⇧⌘D Changes, ⇧⌘B
  Browser). A terminal is ⌘T, the one that differs, as it does in each of
  those. The keys these had until 2026-11-26 still work: ⌃⌘1, ⌃⌘2, ⌃⌘3 and
  ⇧⌘L.
- **Up and down for sessions, brackets for tabs.** ⌥⌘↑ / ⌥⌘↓ walk the sidebar,
  as Arc walks its; ⇧⌘[ / ⇧⌘] are previous and next tab, as in every Mac app.
- **A terminal is a terminal.** ⌘T, ⌘W, ⌘D, ⇧⌘D, ⌘K and ⌘] mean what they mean
  in iTerm, Ghostty and Warp. ⌘D and ⇧⌘D split where you are, to the right
  and down, and a split is zoomed and made equal with Ghostty's keys (⇧⌘↩,
  ⌃⌘=).
- **Arrows with ⌃ go by direction.** ⌃⌘ and an arrow moves the tab in front
  to the split on that side, ⌃⌥⌘ and an arrow moves the keyboard there.
- **A browser is a browser.** ⌘L, ⌘R, ⌘[ and ⌘] mean what they mean in Safari
  and Chrome.

⌘/ opens this list, and the Help menu's search field finds any command by name.

## Sessions

A session is a sidebar row with its own terminal, layout and agent tracking.
Sessions take the keys Codex and cmux give their chats and workspaces.

| Action | Shortcut | Same as |
|---|---|---|
| New session | ⌘N | Codex, Claude, cmux |
| New terminal (only while Settings names a command for new sessions) | ⌃⌘N | |
| New session at home | ⌥⌘N | |
| New terminal at home (on the same condition as New terminal) | ⌃⌥⌘N | |
| New worktree session | ⌥⇧⌘N | |
| Open folder | ⌘O | Codex, cmux, every Mac app |
| Close session | ⇧⌘W | iTerm, Ghostty, Warp, VS Code (close window) |
| Next / previous session | ⌥⌘↓ / ⌥⌘↑ | Arc (its sidebar's tabs) |
| Back / forward through the sessions you've been on | ⌃⌘[ / ⌃⌘] | Safari, Chrome (⌘[ / ⌘], with ⌃ added because those are the areas here) |
| Session 1 to 9 | ⌘1 to ⌘9 | Codex, cmux |
| Next waiting session | ⌥⇧⌘↓ (also ⌥⌘]) | Slack (⌥⇧↓, the next unread) |
| Go to a session or a file, or run any command | ⌘P | VS Code, Cursor, Zed (quick open) |
| Run a command (the palette, commands only) | ⇧⌘P | VS Code (command palette) |
| Find a prompt you typed to an agent, and type it in again | ⌘Y | Safari, Chrome (History) |
| Rename session | ⌥⌘R | Codex |
| Mark session as unread (come back to it) | ⇧⌘U | ChatGPT |
| Pin / unpin session (a Pinned section at the top) | ⌥⌘P | ChatGPT |

⌘R still renames while no browser is showing, as it always did.

In the sidebar, ⌘-click adds or removes a session and ⇧-click selects a range,
as in the Finder; right-click the selection to pin, mark, colour or close
them all. Esc goes back to one. View ▸ Sort Unread First puts the sessions
that want you at the top of each section.

⌘Y searches what you've typed to Claude Code, Codex and Pi, in any session
and any project (this one's first), and puts the one you pick in the
session's input without sending it. ⌃R stays the shell's own history
search, and the agent's.

## Windows

Each window has its own sidebar, and a session is in one window at a time.
⌘N is a session, so a window is ⇧⌘N, as in apps whose ⌘N makes something
smaller than a window.

| Action | Shortcut | Same as |
|---|---|---|
| New window (with a new session at home) | ⇧⌘N | VS Code, Zed, cmux |
| Close the window and its sessions (asks if something runs) | the window's close button | Terminal |
| Move a session to another window | drag its row onto the other sidebar | cmux, Arc, Warp (tabs) |
| Move a session to a new window | drag its row out of the window, or Window ▸ Move Session to New Window | Safari, Arc, Warp (tabs) |
| Put every session in this window | Window ▸ Merge All Windows | every Mac app with tabs |

A row's right-click menu has Move to New Window and Move to Window ▸ too.
A file or web page tab dragged onto another window's tab row moves there.
Hold any drag still over a window behind and it comes forward, after the
Mac's spring-loading delay (System Settings ▸ Accessibility ▸ Pointer
Control).
Before 2026-11-19, ⇧⌘N was New Worktree Session; that is ⌥⇧⌘N now.

## The layout

| Action | Shortcut | Same as |
|---|---|---|
| Show / hide the sidebar | ⌘B (also ⌥⌘S) | VS Code, Cursor, Zed, Codex, cmux |
| Open Changes and Files beside the terminal, or close them | ⌥⌘B | VS Code, Zed, Codex, cmux |
| Go to the terminal below (making one if there is none), and back | ⌘J, ⌃` | VS Code, Zed, Codex |
| Focus the next / previous split | ⌘] / ⌘[ | iTerm, Ghostty, Warp (next / previous pane) |
| Focus the split to the left / right / above / below | ⌃⌥⌘← / ⌃⌥⌘→ / ⌃⌥⌘↑ / ⌃⌥⌘↓ | iTerm, Ghostty (⌥⌘ and an arrow, which are sessions and tabs here) |
| Zoom the split you're in, and show all of them again | ⇧⌘↩ | Ghostty, cmux |
| Make the splits equal | ⌃⌘= | Ghostty |
| Put every tab back where a session starts with it | View ▸ Reset Layout | |
| Full screen | ⌃⌘F | every Mac app |
| Show or hide Wortel, from any app | ⌃⌥⌘. | |

Everything beside the sidebar is made of splits: parts with a row of tabs
each. A session starts with one, its terminal. You make more with ⌘D and ⇧⌘D
(under Tabs), and two keys make one for you in a place of their own: ⌥⌘B at
the right edge, ⌘J under the terminal.

Every split's row is the same: its tabs, then "+". The session's own terminal
is a tab too, named after the session, with no close button.

**"+" in a row opens an empty tab in that split**, titled New Tab. ⌥⌘T is the
same thing as a key, in the split you're in (Tab ▸ New Tab). Its page
lists what the tab can become. Each has a key that opens the same thing
without asking, in its usual place (a terminal in the split you're in, the
other four in the split beside your work):

| On the page | Key that skips the page |
|---|---|
| Terminal | ⌘T |
| Browser | ⇧⌘B |
| Changes | ⇧⌘C |
| History | ⇧⌘H |
| Files | ⇧⌘F |

Click a row, or use ↑ and ↓ and Return, and that takes the tab's place. Esc
closes the empty tab. On the page a row's first letter alone picks it too: T
for Terminal, B for Browser, C for Changes, H for History, F for Files. They
are the letters of the keys in the table, without ⇧⌘, and nothing can be
typed on that page, so the letter is enough. Any other letter does nothing. So ⌥⌘T then C opens Changes in the
split you're in, and ⌥⌘T then B a browser. A closed empty tab is forgotten:
⇧⌘T never brings one back.

⌘T and ⌘D do not ask. They open a terminal at once, because what follows
them is typing, and on a page where a letter picks a row that typing would
pick rows. The "+", the split buttons and ⌥⌘T ask. Changes, History or Files that are open in another
split move to this one. A row keeps one empty tab at most: "+" again brings
it forward. It works the same in every split, since anything can be opened
anywhere.

At the right end of the titlebar are four buttons: Split Right, Split Down,
what the session is running, and **"…"** at the edge, which is the session
itself (rename, pin, close and the rest of what its sidebar row's menu has).
A split button makes a split beside or under the one you're in, with an
empty tab in it. ⌘D and ⇧⌘D make the same split with a terminal in it: a key
does not ask.

For a few hours on 2026-11-26 the "+" was a new terminal and Changes,
History, Files and a browser were buttons in that corner. Before that the
"+" was a menu. Both are gone.

**Nothing is hidden.** A split is on screen while it holds a tab and gone when
it holds none. Until 2026-11-26, ⌥⌘B and ⌘J hid the side column and the
bottom strip and brought them back with their tabs. They no longer do:

- **⌥⌘B** (View ▸ Show Changes and Files) opens Changes and Files in a split
  at the right edge, at the width you last gave it, with the one you used
  last in front, and puts the keyboard there. Press it again (Hide Changes
  and Files) and it closes Changes, History and Files in that split, and the
  keyboard goes back to your terminal. Closing them loses nothing. Anything
  else in that split stays, a terminal or a file for one, and so does the
  split. A pane you have dragged into another split is not opened twice: it
  stays where you put it.
- **⌘J** (View ▸ Terminal Below, also ⌃`) puts the keyboard in the terminal
  under your main one, and from there back in the main one. If there is none
  yet, it makes one. It never closes or hides it. To close it, close its
  tabs (⌘W).
- **To have the whole window for one split, zoom it** (⇧⌘↩). That is what
  hiding the others was for.

Changes and Files slide in when ⌥⌘B opens them, and so does the terminal
below when ⌘J makes it. Putting them away, a split you make or close, a zoom
and ⌃⌘= land in one cut.

⌘] and ⌘[ walk every split on screen in reading order, left to right and top
down (View ▸ Focus Next Split, Focus Previous Split). ⌃⌥⌘ and an arrow goes
by direction instead (View ▸ Focus Split).

A zoomed split is shown alone and the others are kept. Any split can be
zoomed. A double-click on the empty part of a split's row zooms it too,
unless the row is in the titlebar, where a double-click is the window's. A
button at the end of the row brings the others back. A zoom is not kept
through a relaunch.

The line between two splits drags, and a double-click on it makes all of them
equal. The split ⌥⌘B opens and the one ⌘J makes keep their size when the
others are made equal. A line stops where a split would get smaller than 160
by 100 points, so dragging it to the edge closes nothing.

**Reset Layout** (in the View menu) is the way back when the splits have got
away from you. Your terminal's split gets every terminal and file as tabs.
Changes, History, Files and browsers go into one split at the right edge, at
its usual size. Every other split is gone, and so is a zoom. Nothing is
closed: every terminal keeps running, as a tab. The tab you were looking at
stays in front. It has no key on purpose, because it cannot be undone. It
is in View, after Equalize Splits, and in the command palette (⇧⌘P, type
"reset"). It is never dimmed: with nothing to put back it does nothing.

Sizes are shares of the window. Make the window wider and every split gets
wider, Changes too. Before 2026-11-26 the side column kept its width and the
terminal took all of the change.

There is no menu command to move Changes to the other side any more (it was
⇧⌥⌘B). Drag its tab to the left edge of your terminal's split instead.

Splits were added on 2026-11-26. They are on `main` and not in a release
yet.

## Panes

| Action | Shortcut | Same as |
|---|---|---|
| Show Changes | ⇧⌘C (also ⌃⌘1) | the Claude app (⇧⌘D); GitHub Desktop, Tower, Fork (⌘1) |
| Show History | ⇧⌘H (also ⌃⌘2, ⌥⇧⌘G) | GitHub Desktop, Tower (⌘2) |
| Show Files | ⇧⌘F (also ⌃⌘3, ⇧⌘E, ⌥⌘E) | the Claude app (⇧⌘F); VS Code, Cursor, Zed, Codex (⇧⌘E) |
| Source control, on the pane you used last | ⌃⇧G (also ⌥⌘G) | VS Code, Cursor, Zed, Codex |
| Focus the list | ⌥⌘L | |
| The selected file in the preview tab, or close it (in Changes or Files) | Space | Finder (Quick Look) |

One rule, wherever the pane is. Not open, it opens in a split at the right
edge, beside your terminal. Open but behind another tab, or behind a zoomed
split, it comes forward. On screen, it closes: closing a pane loses nothing.
An empty tab's page offers the same panes, and puts the one you pick in that
split. (Until
2026-11-26 a pane that shared a row with your session's terminal went behind
the terminal with its tab kept, and one you had dragged into a split of its
own only ever came forward.)
While a file is in front, a click or ↑/↓ in Changes or Files shows the picked
file in the preview tab (italic title). A double-click on a file opens it
there too, and a double-click on the file it already shows keeps it as a tab.

## Tabs

These act on the tab row you're in: the split you last clicked or typed in,
picked a tab in, or moved to with ⌘] / ⌘[ or ⌃⌥⌘ and an arrow. ⌥⌘T, ⌘T, ⌘W
and ⇧⌘T act in whichever split you're in.

| Action | Shortcut | Same as |
|---|---|---|
| New tab here: an empty tab that asks what it should be | ⌥⌘T | |
| New terminal tab here | ⌘T | everyone (new tab); in a terminal, a new shell where you are |
| Split right: a new terminal in a split beside the one you're in | ⌘D | iTerm, Ghostty, Warp, cmux |
| Split down: the same, under it | ⇧⌘D | iTerm, Ghostty, Warp, cmux |
| New terminal below: one more tab in the split under the main terminal | ⌃⇧` | VS Code, Zed (new terminal) |
| New browser tab, in the split beside your work | ⇧⌘B (also ⇧⌘L) | the Claude app (⇧⌘B); cmux (⇧⌘L) |
| Close tab | ⌘W | everyone |
| Reopen closed tab | ⇧⌘T | Safari, Chrome, VS Code, Zed, iTerm, Ghostty, Warp, cmux |
| Next / previous tab | ⇧⌘] / ⇧⌘[ (also ⌃Tab / ⌃⇧Tab, ⌥⌘→ / ⌥⌘←) | Safari, Chrome, Finder, Xcode, Terminal, iTerm, Ghostty; VS Code, Zed |
| Tab 1 to 9 | ⌥⌘1 to ⌥⌘9 (9 is the last) | Xcode (inspector tabs) |
| Move the tab in front to the split on its left / right | ⌃⌘← / ⌃⌘→ | |
| Move it to the split below / above | ⌃⌘↓ / ⌃⌘↑ | |

⌘W closes what you're in. With your session's own terminal in front, that is the
session, the same as closing a tab in any other terminal ends its shell.

⌘D and ⇧⌘D put the new terminal in a split of its own, beside or under the
split you're in, whichever that is: ⌘D with Changes in front gives you a
terminal next to Changes. Where the split you're in is too small to be two,
the new one takes its room from the whole row instead, a little from each
(⌘D beside a narrow Changes still gives you a terminal next to it). Only
when the row has no room either do they beep and do nothing: a split is
never laid out under 160 by 100 points while there is room. A split is there only while it has tabs, so closing its
last tab closes the split and its neighbours take the room.

How to split:

- ⌘D and ⇧⌘D, also in the Tab menu: a new terminal in a split beside or under
  the one you're in.
- The two split buttons at the right end of the titlebar: the same split,
  with an empty tab in it that asks what goes there.
- A right-click on a tab, then Split Right or Split Down: that tab moves into
  a new split. The two items are there only when the tab is not the only one
  in its split.
- Let go of a tab, or a file out of Changes or Files, on the edge of a split.
- `wortel split`, from a script or an agent.
- Changes, History and Files make a split at the right edge when there is
  none, from their key.

The keys and the buttons beep the same way when there is no room. The
session's "…" has no split items: it is only about the session. The session's
own terminal stays in the main row and can't be split off.

That right-click menu no longer has Move to Main Area, Move to Side Column
and Move to Bottom Strip. There are no named places to move to, only splits.
A tab goes to another split by a drag, or by ⌃⌘ and an arrow.

A tab dragged onto the edge of a split makes a new split there, and onto its
middle moves into it (the split lights up). That is the rule for every split.
Before 2026-11-26 the sides of the main area stood for the side column and
its lower quarter for the strip. They no longer do. A split too small to be
two has no edges, only a middle. A file dragged out of Changes or Files lands
the same way, except over a terminal, which takes its path. The session's own
tab goes nowhere but its own row. (It used to trade sides with the side
column when dropped on it. To have Changes on the left, drag Changes there.)

⌃⌘ and an arrow moves the tab in front to the neighbouring split. Where there
is none, two directions still make one: toward the right edge, the tab goes
to a new split there (where ⌥⌘B opens Changes and Files), and down, to a new
one under the main terminal (where ⌘J makes its terminal), when there is no
such split yet. Your session's own terminal stays in its row: ⌃⌘ and an arrow
does nothing with it in front.

Before 2026-11-26, ⌘D was a new terminal in the side column and ⇧⌘D one in the
bottom strip. ⌘D from Changes does the first now, and ⌃⇧` is the second.

## In a terminal

| Action | Shortcut | Same as |
|---|---|---|
| Clear | ⌘K | every terminal |
| Previous / next prompt | ⌘↑ / ⌘↓ | Ghostty, Terminal, VS Code |
| Top / bottom of the scrollback | ⌘Home / ⌘End | every terminal |
| Bigger / smaller / actual size | ⌘+ / ⌘- / ⌘0 | everyone |
| Copy / paste | ⌘C / ⌘V | everyone |
| Select all | ⇧⌘A | |
| Clear the line you're typing | ⌘A | |
| Undo in the line you're typing | ⌘Z | |
| Start / end of the line, delete to either | ⌘← / ⌘→, ⌘⌫ / ⌘⌦ | every Mac text field |
| Word left / right, delete a word | ⌥← / ⌥→, ⌥⌫ / ⌥⌦ | every Mac text field |

## In a browser

| Action | Shortcut | Same as |
|---|---|---|
| Go to the address field | ⌘L | Safari, Chrome, Codex, cmux |
| Reload | ⌘R | Safari, Chrome, Codex, cmux |
| Reload, ignoring the cache | ⇧⌘R | Chrome, Codex, cmux |
| Back / forward | ⌘[ / ⌘] | Safari, Chrome, cmux |
| Zoom in / out / actual size | ⌘+ / ⌘- / ⌘0 | Safari, Chrome |
| Web Inspector | ⌥⌘I | Safari, Chrome |
| Find in the page | ⌘F | everyone |
| Next / previous match | ⌘G / ⇧⌘G (also Return) | everyone |
| Look for what is selected | ⌘E | Safari, every Mac app with a find |
| A page from a file: its source, and back | ⌥⌘U | Safari, Chrome (View Source) |

⌘L, ⌘R, ⇧⌘R and ⌘F reach the browser in front from anywhere, the terminal
included: change something, ⌘R, look. With no browser showing they are left to
the terminal (and ⌘R renames the session).

⌥⌘U is for a page shown from an `.html` file on this Mac (`wortel open
report.html`, or a ⌘-clicked path): the file's text takes the page's place in
the same tab, and the page stays loaded behind it. The header's Page · Source
does the same. ⌘F then searches whichever is showing. On any other page the
item is disabled.

⌘E needs the keyboard in the page, since it reads the page's selection. It
also puts the text on the Mac's find pasteboard, so ⌘G in another app looks
for the same thing. After ⌘E, ⌘G works without opening the bar first. The bar
says "Not found" and gives no count of matches: WebKit's public find does not
report one.

Back, forward and zoom need the keyboard in the page. When the page has no
history in that direction, ⌘[ and ⌘] move between areas as they do everywhere
else, so the keyboard is never stuck in a page.

## In a file

| Action | Shortcut | Same as |
|---|---|---|
| Find in the file tab in front | ⌘F | everyone |
| Next / previous match | ⌘G / ⇧⌘G (also Return) | everyone |
| Open a file or server in the other place, this once | ⌥-click | |

With a file and a page both showing, ⌘F takes the one in the area you're in.
With neither showing, ⌘F is left to the terminal.

A file opens beside your terminal's tab, and a browser in the split beside
your work, where Changes, History and Files open. Every time: Wortel no
longer remembers where you last moved one (it did until 2026-11-26, and the
released app still does). To have one somewhere else, open it there with
that split's "+" or with ⌥⌘T and its letter, or move it. ⌥-click opens it in
the other place, this once: out of the main row if it's there or would go
there, into the main row otherwise.

## Deliberately different

- **⌘A clears the line you're typing** and Select All is ⇧⌘A, where every other
  terminal selects the whole scrollback on ⌘A. In a text field, a page or a
  preview, ⌘A is Select All as usual.
- **⌘1 to ⌘9 are sessions, not tabs.** Sessions are what you switch between all
  day, which is also how Codex and cmux spend those keys. So the git apps' ⌘1
  and ⌘2 for Changes and History are not used: those are ⇧⌘C and ⇧⌘H (and
  still ⌃⌘1 and ⌃⌘2, what they were).
- **⇧⌘F is Files, not find.** Where an editor searches the project on ⇧⌘F,
  Wortel shows the file tree, by its first letter like the other things you
  open. ⌘P finds a file by name.
- **⌘, is Settings**, as in every Mac app: a short window of switches. Keys
  are not among them; `wortel.conf` decides those. ⌘P finds any session, file
  or command, ⇧⌘P commands only, and so does the Help menu's search field.
- **⌥⌘ and an arrow are sessions and tabs, not splits.** iTerm and Ghostty
  move between splits with them. Here that is ⌃⌥⌘ and an arrow, because ⌥⌘
  was taken and ⌃⌘ and an arrow moves a tab.

## Deliberately not used

- **Control with a number** (the editors' "tab N"): in a terminal ⌃2 is NUL, ⌃3
  is Escape, ⌃6 is vim's alternate file and ⌃8 is Delete.
- **⌥⌘H**: the Mac's Hide Others.
