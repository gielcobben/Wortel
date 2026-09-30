# Keyboard shortcuts

Wortel's shortcuts follow the apps people already have in their fingers, so the
layout works the way you'd guess from day one. Where apps disagree, the choice
goes to what most of them share, and nearly every shortcut is Command-based.
The few Control keys are the ones the editors all use (⌃Tab, ⌃`, ⌃⇧G).
Control and Option with a letter always stay with the shell.

Three rules cover most of it:

- **The layout is an editor's.** ⌘B, ⌥⌘B and ⌘J show and hide the three areas,
  ⇧⌘E is files and ⌃⇧G is source control, as in VS Code, Cursor, Zed and Codex.
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
| New session at home | ⌥⌘N | |
| New folder | ⇧⌘N | Finder |
| Open folder | ⌘O | Codex, cmux, every Mac app |
| Close session | ⇧⌘W | iTerm, Ghostty, Warp, VS Code (close window) |
| Next / previous session | ⇧⌘] / ⇧⌘[, ⌥⌘↓ / ⌥⌘↑ | Codex, Claude |
| Session 1 to 9 | ⌘1 to ⌘9 | Codex, cmux |
| Next waiting session | ⌥⌘] | |
| Go to a session, or run any command | ⌘P | VS Code, Cursor, Zed (quick open) |
| Run a command (the palette, commands only) | ⇧⌘P | VS Code (command palette) |
| Rename session | ⌥⌘R | Codex |
| Mark session as unread (come back to it) | ⇧⌘U | ChatGPT |
| Pin / unpin session (a Pinned section at the top) | ⌥⌘P | ChatGPT |

⌘R still renames while no browser is showing, as it always did.

## The layout

| Action | Shortcut | Same as |
|---|---|---|
| Show / hide the sidebar | ⌘B (also ⌥⌘S) | VS Code, Cursor, Zed, Codex, cmux |
| Show / hide the side column | ⌥⌘B | VS Code, Zed, Codex, cmux |
| Show / hide the bottom strip | ⌘J, ⌃` | VS Code, Zed, Codex |
| Move the side column to the other side | ⇧⌥⌘B | |
| Focus the next / previous area | ⌘] / ⌘[ | iTerm, Ghostty, Warp (next / previous pane) |
| Full screen | ⌃⌘F | every Mac app |

## Panes

| Action | Shortcut | Same as |
|---|---|---|
| Show Files | ⇧⌘E (also ⌥⌘E) | VS Code, Cursor, Zed, Codex |
| Show Changes (or History, if that's where you were) | ⌃⇧G (also ⌥⌘G) | VS Code, Cursor, Zed, Codex |
| Show History | ⇧⌥⌘G | |
| Focus the list | ⌥⌘L | |

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
| Next / previous tab | ⌃Tab / ⌃⇧Tab, ⌥⌘→ / ⌥⌘← | Safari, Terminal, Ghostty, Codex; VS Code, Zed, Chrome |
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
| Open a file or server in the main area, this once | ⌥-click | |

With no file tab showing, ⌘F is left to the terminal.

Files and browsers open in the column until you move one somewhere else; after
that, that kind opens where you last moved one, per session.

## Deliberately different

- **⌘A clears the line you're typing** and Select All is ⇧⌘A, where every other
  terminal selects the whole scrollback on ⌘A. In a text field, a page or a
  preview, ⌘A is Select All as usual.
- **⌘1 to ⌘9 are sessions, not tabs.** Sessions are what you switch between all
  day, which is also how Codex and cmux spend those keys.
- **No command palette (⇧⌘P) and no settings (⌘,).** Wortel has neither. The
  Help menu's search field finds any command.

## Deliberately not used

- **Control with a number** (the editors' "tab N"): in a terminal ⌃2 is NUL, ⌃3
  is Escape, ⌃6 is vim's alternate file and ⌃8 is Delete.
- **⌥⌘H**: the Mac's Hide Others.
