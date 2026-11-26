# Keyboard shortcuts

Wortel's shortcuts follow the apps people already have in their fingers, so the
layout works the way you'd guess from day one. Where apps disagree, the choice
goes to what most of them share, and nearly every shortcut is Command-based.
The few Control keys are the ones the editors all use (⌃Tab, ⌃`, ⌃⇧G), and
⌃⌘ with a number for the panes, where ⌘ alone is taken by the sessions.
Control and Option with a letter always stay with the shell.

A few rules cover most of it:

- **The layout is an editor's.** ⌘B, ⌥⌘B and ⌘J show and hide the three areas,
  as in VS Code, Cursor, Zed and Codex. The three panes are numbered as git
  apps number theirs: ⌃⌘1 Changes, ⌃⌘2 History, ⌃⌘3 Files.
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
| Show / hide the side column, with its tabs kept | ⌥⌘B | VS Code, Zed, Codex, cmux |
| Show / hide the bottom strip, with its tabs kept | ⌘J, ⌃` | VS Code, Zed, Codex |
| Move the side column to the other side | ⇧⌥⌘B | |
| Focus the next / previous split | ⌘] / ⌘[ | iTerm, Ghostty, Warp (next / previous pane) |
| Focus the split to the left / right / above / below | ⌃⌥⌘← / ⌃⌥⌘→ / ⌃⌥⌘↑ / ⌃⌥⌘↓ | iTerm, Ghostty (⌥⌘ and an arrow, which are sessions and tabs here) |
| Zoom the split you're in, and show all of them again | ⇧⌘↩ | Ghostty, cmux |
| Make the splits equal | ⌃⌘= | Ghostty |
| Full screen | ⌃⌘F | every Mac app |
| Show or hide Wortel, from any app | ⌃⌥⌘. | |

Everything beside the sidebar is made of splits: parts with a row of tabs
each. The side column and the bottom strip are two of them. Wortel opens
those for you, the side column at the outer edge and the strip under the
terminal, each at the size you last gave it. Any other split you make
yourself (⌘D and ⇧⌘D, under Tabs).

⌥⌘B and ⌘J put the side column and the strip away and bring them back with
the same tabs and the same share of the window. A split you made has no such key: it is
there while it has tabs. The two slide open and shut on those keys, as they
always have. A split you make or close, a zoom and ⌃⌘= land in one cut.

⌘] and ⌘[ walk every split on screen in reading order, left to right and top
down, the side column and the strip where they sit. ⌃⌥⌘ and an arrow goes by
direction instead (View ▸ Focus Area).

A zoomed split is shown alone and the others are kept. The side column and
the strip can be zoomed like any other. A double-click on the empty part of a
split's row zooms it too, unless the row is in the titlebar, where a
double-click is the window's. A button at the end of the row brings the
others back. A zoom is not kept through a relaunch.

The line between two splits drags, and a double-click on it makes all of them
equal. The side column and the strip keep their size when the others are made
equal. A line stops where a split would get smaller than 160 by 100 points,
so dragging it to the edge closes nothing: ⌥⌘B and ⌘J do that.

Sizes are shares of the window. Make the window wider and every split gets
wider, the side column too. Before 2026-11-26 the side column kept its width
and the terminal took all of the change.

Splits were added on 2026-11-26 and are not in a release yet.

## Panes

| Action | Shortcut | Same as |
|---|---|---|
| Show Changes | ⌃⌘1 | GitHub Desktop, Tower, Fork (⌘1) |
| Show History | ⌃⌘2 (also ⌥⇧⌘G) | GitHub Desktop, Tower (⌘2) |
| Show Files | ⌃⌘3 (also ⇧⌘E, ⌥⌘E) | VS Code, Cursor, Zed, Codex (⇧⌘E) |
| Source control, on the pane you used last | ⌃⇧G (also ⌥⌘G) | VS Code, Cursor, Zed, Codex |
| Focus the list | ⌥⌘L | |
| The selected file in the preview tab, or close it (in Changes or Files) | Space | Finder (Quick Look) |

Each opens its pane, brings it forward, or closes it when it's already in front.
A pane that is in a split you made only comes forward: there is nothing to put it away to.
While a file is in front, a click or ↑/↓ in Changes or Files shows the picked
file in the preview tab (italic title). A double-click on a file opens it
there too, and a double-click on the file it already shows keeps it as a tab.

## Tabs

These act on the tab row you're in: the split you last clicked or typed in,
picked a tab in, or moved to with ⌘] / ⌘[ or ⌃⌥⌘ and an arrow. The side
column and the strip are splits like the others, so ⌘T, ⌘W, ⇧⌘T and ⇧⌘L act
in whichever one you're in.

| Action | Shortcut | Same as |
|---|---|---|
| New terminal tab here | ⌘T | everyone (new tab); in a terminal, a new shell where you are |
| Split right: a new terminal in a split beside the one you're in | ⌘D | iTerm, Ghostty, Warp, cmux |
| Split down: the same, under it | ⇧⌘D | iTerm, Ghostty, Warp, cmux |
| New terminal in the bottom strip | ⌃⇧` | VS Code, Zed (new terminal) |
| New terminal in the side column | Tab ▸ New Terminal in Side Column | |
| New browser tab here | ⇧⌘L | cmux |
| Close tab | ⌘W | everyone |
| Reopen closed tab | ⇧⌘T | Safari, Chrome, VS Code, Zed, iTerm, Ghostty, Warp, cmux |
| Next / previous tab | ⇧⌘] / ⇧⌘[ (also ⌃Tab / ⌃⇧Tab, ⌥⌘→ / ⌥⌘←) | Safari, Chrome, Finder, Xcode, Terminal, iTerm, Ghostty; VS Code, Zed |
| Tab 1 to 9 | ⌥⌘1 to ⌥⌘9 (9 is the last) | Xcode (inspector tabs) |
| Move the tab in front to the split on its left / right | ⌃⌘← / ⌃⌘→ | |
| Move it to the split below / above | ⌃⌘↓ / ⌃⌘↑ | |

⌘W closes what you're in. With your session's own terminal in front, that is the
session, the same as closing a tab in any other terminal ends its shell.

⌘D and ⇧⌘D put the new terminal in a split of its own, beside or under the
split you're in. From the side column that is a split beside the side column
(⌘D with Changes in front gives you a terminal next to Changes), and from the
strip one beside the strip. Where the split you're in is too small to be two
they beep and do nothing: a split is never laid out under 160 by 100 points
while there is room. A split is there only while it has tabs, so closing its
last tab closes the split and its neighbours take the room.

Split Right and Split Down are also in a tab's right-click menu, where they
move that tab into a new split, and in every row's "+" and the session's "…",
where they open a new terminal. They beep the same way when there is no room.
The session's own terminal stays in the main row and can't be split off.

A tab dragged onto the edge of a split makes a new split there, and onto its
middle moves into it (the split lights up). That is the rule for every split, the
side column and the strip included. Before 2026-11-26 the sides of the main
area stood for the side column and its lower quarter for the strip. They no
longer do: to put a tab in the side column, drop it on the side column, or on
its row. While the side column is hidden, a tab's right-click menu (Move to
Side Column) or ⌃⌘ and an arrow puts it there. A split too small to be two has no edges, only a middle. A file
dragged out of Changes or Files lands the same way (an edge says "Open to the Right" and so on), except over a terminal, which takes its path. The session's own
tab goes nowhere but its own row. Dropped on the side column, it trades
sides with it.

⌃⌘ and an arrow moves the tab in front to the neighbouring split. Where there
is none, two directions still open something: toward the side the side
column is on, the tab goes to the side column, and down it goes to the strip,
when that one is hidden or not there yet. The session's own terminal sent
toward the column swaps sides with it.

Before 2026-11-26, ⌘D was a new terminal in the side column and ⇧⌘D one in the
bottom strip. Both are still in the Tab menu, the strip's on ⌃⇧`.

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

A file opens in the main area and a browser in the column until you drag one
somewhere else (between rows, or onto a row from a list or a preview window);
after that, that kind opens where you last put one, per session. ⌥-click opens
it in the other place: out of the main area if it's there or would go there,
into the main area otherwise.

## Deliberately different

- **⌘A clears the line you're typing** and Select All is ⇧⌘A, where every other
  terminal selects the whole scrollback on ⌘A. In a text field, a page or a
  preview, ⌘A is Select All as usual.
- **⌘1 to ⌘9 are sessions, not tabs.** Sessions are what you switch between all
  day, which is also how Codex and cmux spend those keys. So the git apps' ⌘1
  and ⌘2 for Changes and History are ⌃⌘1 and ⌃⌘2 here.
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
