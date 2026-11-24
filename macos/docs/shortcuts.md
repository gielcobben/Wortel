# Keyboard shortcuts

Wortel's shortcuts follow the apps people already have in their fingers, so the
layout works the way you'd guess from day one. Where apps disagree, the choice
goes to what most of them share, and nearly every shortcut is Command-based.
The few Control keys are the ones the editors all use (⌃Tab, ⌃`, ⌃⇧G), and
⌃⌘ with a number for the panes, where ⌘ alone is taken by the sessions.
Control and Option with a letter always stay with the shell.

Three rules cover most of it:

- **The layout is an editor's.** ⌘B, ⌥⌘B and ⌘J show and hide the three areas,
  as in VS Code, Cursor, Zed and Codex. The three panes are numbered as git
  apps number theirs: ⌃⌘1 Changes, ⌃⌘2 History, ⌃⌘3 Files.
- **Up and down for sessions, brackets for tabs.** ⌥⌘↑ / ⌥⌘↓ walk the sidebar,
  as Arc walks its; ⇧⌘[ / ⇧⌘] are previous and next tab, as in every Mac app.
- **A terminal is a terminal.** ⌘T, ⌘W, ⌘D, ⇧⌘D, ⌘K and ⌘] mean what they mean
  in iTerm, Ghostty and Warp.
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
| Go to a session, or run any command | ⌘P | VS Code, Cursor, Zed (quick open) |
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
| Show / hide the side column | ⌥⌘B | VS Code, Zed, Codex, cmux |
| Show / hide the bottom strip | ⌘J, ⌃` | VS Code, Zed, Codex |
| Move the side column to the other side | ⇧⌥⌘B | |
| Focus the next / previous area | ⌘] / ⌘[ | iTerm, Ghostty, Warp (next / previous pane) |
| Full screen | ⌃⌘F | every Mac app |
| Show or hide Wortel, from any app | ⌃⌥⌘. | |

## Panes

| Action | Shortcut | Same as |
|---|---|---|
| Show Changes | ⌃⌘1 | GitHub Desktop, Tower, Fork (⌘1) |
| Show History | ⌃⌘2 (also ⌥⇧⌘G) | GitHub Desktop, Tower (⌘2) |
| Show Files | ⌃⌘3 (also ⇧⌘E, ⌥⌘E) | VS Code, Cursor, Zed, Codex (⇧⌘E) |
| Source control, on the pane you used last | ⌃⇧G (also ⌥⌘G) | VS Code, Cursor, Zed, Codex |
| Focus the list | ⌥⌘L | |

Each opens its pane, brings it forward, or closes it when it's already in front.

## Tabs

These act on the tab row you're in: the area you last clicked or typed in,
picked a tab in, or moved to with ⌘] / ⌘[.

| Action | Shortcut | Same as |
|---|---|---|
| New terminal tab here | ⌘T | everyone (new tab); in a terminal, a new shell where you are |
| New terminal in the side column | ⌘D | iTerm, Ghostty, Warp, cmux, Terminal (split right) |
| New terminal in the bottom strip | ⇧⌘D, ⌃⇧` | iTerm, Ghostty, Warp, cmux (split down); VS Code, Zed |
| New browser tab here | ⇧⌘L | cmux |
| Close tab | ⌘W | everyone |
| Reopen closed tab | ⇧⌘T | Safari, Chrome, VS Code, Zed, iTerm, Ghostty, Warp, cmux |
| Next / previous tab | ⇧⌘] / ⇧⌘[ (also ⌃Tab / ⌃⇧Tab, ⌥⌘→ / ⌥⌘←) | Safari, Chrome, Finder, Xcode, Terminal, iTerm, Ghostty; VS Code, Zed |
| Tab 1 to 9 | ⌥⌘1 to ⌥⌘9 (9 is the last) | Xcode (inspector tabs) |
| Move tab left / right | ⌃⌘← / ⌃⌘→ | |
| Move tab down to the bottom strip / up to the main area | ⌃⌘↓ / ⌃⌘↑ | |

⌘W closes what you're in. With your session's own terminal in front, that is the
session, the same as closing a tab in any other terminal ends its shell.

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

⌘L, ⌘R and ⇧⌘R reach the browser in front from anywhere, the terminal included:
change something, ⌘R, look. With no browser showing they are left to the
terminal (and ⌘R renames the session).

Back, forward and zoom need the keyboard in the page. When the page has no
history in that direction, ⌘[ and ⌘] move between areas as they do everywhere
else, so the keyboard is never stuck in a page.

## In a file

| Action | Shortcut | Same as |
|---|---|---|
| Find in the file tab in front | ⌘F | everyone |
| Next / previous match | ⌘G / ⇧⌘G (also Return) | everyone |
| Open a file or server in the other place, this once | ⌥-click | |

With no file tab showing, ⌘F is left to the terminal.

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
  are not among them; `wortel.conf` decides those. ⌘P finds any session or
  command, ⇧⌘P commands only, and so does the Help menu's search field.

## Deliberately not used

- **Control with a number** (the editors' "tab N"): in a terminal ⌃2 is NUL, ⌃3
  is Escape, ⌃6 is vim's alternate file and ⌃8 is Delete.
- **⌥⌘H**: the Mac's Hide Others.
