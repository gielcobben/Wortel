# Keyboard shortcuts

Wortel's shortcuts follow the apps people already have in their fingers, so the
layout works the way you'd guess from day one. Where apps disagree, the choice
goes to what most of them share, and every shortcut is Command-based except the
three Control keys that all of those apps use for tabs and terminals. Control and
Option with a letter always stay with the shell.

## Sessions

A session is a sidebar row with its own terminal, layout and agent tracking.
Sessions keep the "next / previous tab" keys other terminals use, since that's
what people reach for to move between shells; ⌘T opens a tab in the session you're in.

| Action | Shortcut | Same as |
|---|---|---|
| New session | ⌘N | Safari, ChatGPT (new window, new chat) |
| Close session | ⇧⌘W | iTerm, Ghostty |
| Next / previous session | ⇧⌘] / ⇧⌘[, ⌥⌘↓ / ⌥⌘↑ | Safari, Terminal, iTerm, Ghostty |
| Session 1 to 9 | ⌘1 to ⌘9 | Safari, iTerm, Ghostty |
| Next waiting session | ⌥⌘] | |
| Rename session | ⌘R | |

## The layout

| Action | Shortcut | Same as |
|---|---|---|
| Show / hide the sidebar | ⌘B (also ⌥⌘S) | VS Code, Cursor, Zed, ChatGPT (⌥⌘S: Finder) |
| Show / hide the side column | ⌥⌘B | VS Code, Zed |
| Show / hide the bottom strip | ⌘J, ⌃` | VS Code, Zed, ChatGPT |
| Move the side column to the other side | ⇧⌥⌘B | |
| Focus the next / previous area | ⌘] / ⌘[ | iTerm, Ghostty, Warp (next / previous pane) |

## Tabs

These act on the tab row you're in: the area you last typed in, picked a tab
in, or moved to with ⌘] / ⌘[.

| Action | Shortcut | Same as |
|---|---|---|
| New terminal tab here | ⌘T | everyone (new tab); in a terminal, a new shell where you are |
| New terminal in the bottom strip | ⌃⇧` | VS Code, Zed |
| New browser tab here | ⇧⌘L | cmux |
| Go to the address field of the browser in front | ⌘L | Safari, Chrome |
| Close tab | ⌘W | everyone |
| Reopen closed tab | ⇧⌘T | Safari, VS Code, Zed, iTerm, Ghostty, ChatGPT |
| Next / previous tab | ⌃Tab / ⌃⇧Tab, ⌥⌘→ / ⌥⌘← | Safari, Terminal, Ghostty; VS Code, Zed, ChatGPT |
| Tab 1 to 9 | ⌥⌘1 to ⌥⌘9 (9 is the last) | Xcode (inspector tabs) |
| Move tab left / right | ⌃⌘← / ⌃⌘→ | VS Code (move editor to next group) |
| Move tab down to the bottom strip / up to the main area | ⌃⌘↓ / ⌃⌘↑ | |

⌘W closes what you're in. With your session's own terminal in front, that is the
session, the same as closing a tab in any other terminal ends its shell.
With no browser in front, ⌘L is left to the terminal.

## Files

| Action | Shortcut |
|---|---|
| Find in the file tab in front | ⌘F |

With no file tab showing, ⌘F is left to the terminal.

## Panes

| Action | Shortcut |
|---|---|
| Show Changes (or History, if that's where you were) | ⌥⌘G |
| Show History | ⇧⌥⌘G |
| Show Files | ⌥⌘E |
| Focus the list | ⌥⌘L |

## Deliberately not used

- **Control with a number** (the editors' "tab N"): in a terminal ⌃2 is NUL, ⌃3
  is Escape, ⌃6 is vim's alternate file and ⌃8 is Delete.
- **⌥⌘H**: the Mac's Hide Others.
- **⌃⌘F**: the Mac's full screen.
