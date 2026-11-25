# Browser plan

A plan, not a record of what the app does. Decided 2026-11-25 in a question
round with the owner, after a survey of what other tools ship. When a phase
lands, its behaviour moves to `architecture/` and `docs/decisions.md`, and its
section here is deleted. When all are done, so is this file.

## What the browser tab is for

The page being built, and the odd signed-in site beside it. In practice: the
servers a session is running, and an HTML page an agent wrote to show
something. It is not a second browser. You sign in inside Wortel's tab and
stay signed in (the default data store, as today).

That purpose decides what is left out, for good unless it changes:

- No bundled Chromium. WKWebView only.
- No import of cookies, history or passwords from other browsers.
- No profiles, bookmarks, device emulation, focus mode or visual CSS editing.
- No view of network requests. WebKit has no public interface for it, and the
  private one can break with any macOS update.
- Passkeys need an entitlement Apple grants on request
  (`com.apple.developer.web-browser.public-key-credential`). Asking for it is
  the owner's call. Nothing is built around it.

## Decisions

| Question | Answer |
| --- | --- |
| Interface for agents | The `wortel` command (`wortel browser …`), not MCP. `docs/product.md`: the command is the whole interface. |
| Which tab an agent drives | One tab of its own per session, made the first time it opens a page, and marked. The person can use it too. Tabs the person opened are never navigated by an agent. An agent never reaches another session's tabs. |
| What you see | The agent's tab comes in front in the column once, when it is made, if the column is open. It never takes the keyboard and never opens a closed column. Later commands move nothing. |
| Out of sight | It works in a session nobody is looking at. The page is kept drawn off screen while the agent uses it, and let go after it has sat unused and unseen for a while (it reloads when shown). Cost follows use, not the number of sessions. |
| Logins | Local addresses just work. The first time an agent wants to use a real site where the person is signed in, the session raises attention and the tab asks: use the sign-in for this site, or go on signed out. Remembered per site. |
| Other questions to the person | None. The agent already has a shell, so asking before JavaScript, downloads, uploads or a new site adds no safety. |
| First version of the commands | A small core: `open`, `reload`, `back`, `snapshot`, `click`, `fill`, `type`, `press`, `wait`, `eval`, `console` (with page errors), `screenshot`. Names follow agent-browser, which agents already know. A command is added when a real session shows it missing. |
| Pointing at a page | Mark-up: pick elements and draw on the page, write one note around the marks, paste it into the agent's prompt. See "Mark-up" below. |

Smaller choices made while planning, open to change in a phase's own plan:

- A snapshot is a short outline of the page with a reference per element
  (`@e3`), made by a script in a private `WKContentWorld`. A reference to an
  element that is gone fails, loudly.
- Input is real mouse and key events sent to the web view, so a page sees
  what it sees from a person. A JavaScript `click()` is not a fallback.
- Local means `localhost`, `*.localhost`, loopback addresses and `file:`.
- An agent's download goes where the agent names. (A person's is saved to
  `~/Downloads`, since phase 1.) Nothing downloaded is opened.
- A screenshot is written to a file and the command prints the path.
- While the tab is showing, the element an agent acts on is ringed briefly.
- The `wortel` skill gets a section. It tells an agent to prefer `snapshot`
  to `screenshot` and to check a page when it matters, not after every edit:
  the complaint about every other tool's browser is that agents check too
  much and each check takes seconds.

## Mark-up

Decided in a second round the same day, after the owner showed a tool that
does it.

| Question | Answer |
| --- | --- |
| What you point with | Both: pick an element, and draw freehand. |
| Switching between them | No tools. Moving the pointer outlines the element under it, a click picks it, a drag draws. A stroke becomes a region from its outline. |
| Where the words go | One note bar over the page. Each pick or stroke drops a chip in the mark's colour where the cursor is, and one message is written around the chips. Marks can be removed and the note edited before anything reaches the agent. Drawn with the system's materials and controls. |
| Return in the bar | Pastes the note into the agent's prompt as one paste and moves the keyboard to the terminal. A second Return, the person's own, sends it. A copy button puts the same text on the clipboard. |
| What the agent gets | In the prompt: the sentence, each chip as a short reference (what it is, its text, its selector), the page's address, and two paths. One is a screenshot with the marks on it. The other is a details file: per mark its position, size, key styles (font, colours, spacing, border) and HTML, and for a region the elements inside it. |

The note bar is a text field of Wortel's own, next to "no AI chat box of its
own" in `docs/product.md`. It is on the right side of that line because it
talks to nobody: it prepares text for the agent's own prompt, and the person
sends it there. That argument goes into `docs/decisions.md` with the phase.

Smaller choices, open to change in the phase's plan:

- The marks are drawn by a native view over the web view, not by the page.
- While mark-up is on, clicks don't reach the page and scrolling does. Marks
  are tied to the page and scroll with it.
- It works in any browser tab, the person's or the agent's, and the note goes
  to that tab's session.
- A mark's colour is given, from the system's colours, and its chip matches.
- A header button and a shortcut turn it on, Esc turns it off. A note not yet
  sent is kept while the page stays where it is.
- Sending clears the marks.
- With no agent running in the session, Return copies instead of pasting
  into a shell.
- The source file of an element is the agent's to find, from the text and
  selector. Only a React development build names its component.
- Render the bar and the marks off screen and look at them before a build is
  shown.

## Phases

Each is one branch in its own worktree, done in order because all three
touch `Wortel/Browser/BrowserTabs.swift`. Each ends with `./scripts/check.sh`,
a test copy (the `test-copy` skill), a review, and the owner's hand check.

### 1. Basics and HTML pages (landed 2026-11-25)

Find in page, downloads that save, and `.html` files as pages. What it does
is in `architecture/workspace-tabs.md` and `../../docs/decisions.md`. One
check is still owed, by hand: whether 1Password fills a sign-in form in the
tab.

### 2. Mark-up

The mode, picking and drawing, the note bar, the paste, the two files. It
needs nothing from phase 3 and carries no open technical question, which is
why it comes first.

### Spike, beside phases 1 and 2 (one day, thrown away)

Phase 3 rests on three things nobody has measured here. On a Vite dev server,
a sign-in form and a rich text editor:

- Does a web view kept off screen take real clicks and keys, and give a
  screenshot? In what kind of window, at what cost in memory and energy?
- Does the snapshot script give a usable outline, and how many tokens?
- How does "use the sign-in for this site" work under one web view: a
  separate data store for the agent's tab with that site's cookies copied in,
  or one store and a gate on the commands?

The spike's numbers go into phase 3's plan with their date.

### 3. `wortel browser`

The agent's tab, the twelve commands, the out-of-sight rule, the one login
question, the skill section, `docs/wortel-command.md`.

## What other tools ship (read 2026-11-25)

From each product's own docs, changelog or repository on that date.

- Standard now: a browser pane, opening a detected local server, and an agent
  that can click, type, take a screenshot and read the console.
- Added by most in 2026: picking an element and sending it to the agent.
- Where they differ: logins. VS Code gives an agent a private session and has
  the person share a signed-in tab on purpose. Others give agents a separate
  session without the person's logins.
- Zed has no built-in browser. Its agents reach a page through MCP only.
- cmux, the closest app in build (Swift, WKWebView), has an agent command set
  ported from agent-browser, later a Playwright-shaped REPL, imports from
  other browsers, profiles, a design mode, and has started shipping Chromium.
- The cost people report is time: each screenshot adds seconds.

Next to look at, not yet researched: commenting on a diff and sending it to
the agent, and remote work over SSH.
