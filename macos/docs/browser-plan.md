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
| HTML files | `wortel open x.html` and a ⌘-clicked `.html` path show the page in a browser tab, reloading when the file changes. One click goes from the page to its source and one click back. |
| Pointing at a page | Mark-up: pick elements and draw on the page, write one note around the marks, paste it into the agent's prompt. See "Mark-up" below. |

Smaller choices made while planning, open to change in a phase's own plan:

- A snapshot is a short outline of the page with a reference per element
  (`@e3`), made by a script in a private `WKContentWorld`. A reference to an
  element that is gone fails, loudly.
- Input is real mouse and key events sent to the web view, so a page sees
  what it sees from a person. A JavaScript `click()` is not a fallback.
- Local means `localhost`, `*.localhost`, loopback addresses and `file:`.
- A download saves to `~/Downloads`, as Safari's does. An agent's download
  goes where the agent names. Nothing downloaded is opened.
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

### 1. Basics and HTML pages

- Find in page: ⌘F, ⌘G, ⇧⌘G, ⌘E, Safari's keys.
- Downloads save instead of going to another browser.
- An `.html` file opens as a page, with the step to its source and back.
- Check, don't assume: does 1Password fill a sign-in form in the tab (its
  system-wide autofill), and does a sign-in survive a relaunch.

### 2. Mark-up

The mode, picking and drawing, the note bar, the paste, the two files. It
needs nothing from phase 3 and carries no open technical question, which is
why it comes first.

### Spike (measured 2026-11-25, harness thrown away)

Phase 3 rested on three things nobody had measured here. They are measured
now, on a Vite dev server, a sign-in form and a rich text editor. The short
answers:

1. **Out of sight works.** A web view in a window that is never shown takes
   real clicks and keys and gives a screenshot, for about 1 mW or less while
   idle. What it does not do is draw: no animation frames, no finished
   transitions. Showing the same window fully clear turns drawing on in 35 ms.
2. **The outline is usable and small.** 100 to 300 tokens on the three test
   pages, 3,500 to 4,500 on two large real ones, 39,000 on one long reference
   page (750 when cut to the window). Click, fill and type by reference worked
   on all three. A `<select>`, a date field and hover did not.
3. **A store of its own for the agent's tab.** Copying one site's cookies into
   it signs the same web view in, in under a millisecond. One shared store
   cannot offer "go on signed out" at all.

#### How it was measured

A standalone AppKit app with one `WKWebView`, outside the Wortel targets,
driven over stdin. macOS 27.0.1 (26A434), an Apple M5 laptop with 16 GB, on
mains power, one 1512×982 display at 2×, web view 1024×768. Public API only:
where only a private one would do is said in place. Events were handed to the
harness's own views. Nothing was posted to the system.

Three limits on what follows:

- **The harness was never the frontmost app.** That is the harder case, the
  person in another app while an agent works. Wortel frontmost with the page in
  its key window was not measured.
- **Nothing was looked at.** No screenshot of the screen was taken, so "out of
  sight" is what the window server reports, not what an eye saw.
- **Energy is the CPU's.** It is what `proc_pid_rusage` bills to the harness
  and its three WebKit processes over 30 seconds. The GPU and the window server
  are not in it: the window server sat near 39% of a core for other reasons the
  whole time and could not be told apart. One run per number, so read sizes,
  not decimals. Memory is the four processes' footprint added up.

#### 1. A web view out of sight

Every arrangement took input and gave a screenshot. They differ in whether the
page draws, and that is the whole cost.

| The window | Page draws | Idle, still page | Idle, moving page | In use | Memory, idle and in use |
| --- | --- | ---: | ---: | ---: | ---: |
| Shown, for comparison | yes | 0.05 mW | 24 mW | 24 mW | 61 and 134 MB |
| On screen, fully clear | yes | 0.06 mW | 22 mW | 22 mW | 61 and 137 MB |
| Below the desktop | yes | 0.06 mW | 19 mW | 17 mW | 61 and 132 MB |
| Shown, the web view under another view | yes | 0.05 mW | 24 mW | 25 mW | 61 and 140 MB |
| Two points of it left on screen | yes | 0.09 mW | 23 mW | 23 mW | 61 and 137 MB |
| Never ordered in | no | 0.03 mW | 1.3 mW | 19 mW | 61 and 120 MB |
| Wholly past the screen's edge | no | 0.03 mW | 0.1 mW | 16 mW | 61 and 123 MB |
| Covered by another window | no | 0.05 mW | 0.9 mW | 19 mW | 62 and 133 MB |
| Shown, the web view hidden | no | 0.03 mW | 0.2 mW | 23 mW | 62 and 118 MB |
| In no window at all | no | 0.02 mW | 0.0 mW | 20 mW | 41 and 53 MB |

The still page is the sign-in form. The moving one runs a spinner and a
canvas on every frame. "In use" is, once a second: two clicks, three keys, an
outline and a screenshot. A page that draws reports itself visible and runs
60 frames a second. One that does not reports hidden and runs none.

Read down the columns. A still page costs nothing measurable anywhere. A
moving page costs 19 to 24 mW and up to a fifth of one core wherever it
draws, the same as when it is shown, and about 1 mW or less where it does
not. Use costs about 20 mW either way. The 61 MB is the whole harness with
one tab: 23 MB the app's own, 24 MB the page's process, 10 MB the GPU process
and 5 MB networking. The GPU process grows to about 57 MB while screenshots
are being taken or a moving page is drawn, and gives it back.

What was found:

- **Input goes straight to the view.** `mouseDown(with:)`, `mouseUp(with:)`,
  `keyDown(with:)` and `keyUp(with:)` on the web view, with `NSEvent`s made for
  its window. The page gets mouseover, mousedown, mouseup and click, then
  keydown, keypress, beforeinput, input and keyup, all `isTrusted`, with the
  right coordinates, `key` and `code`. Through `NSWindow.sendEvent` a key
  arrives, but a mouse-down in a window that is not key is dropped.
- **Text** goes in with `insertText(_:)`: beforeinput and input, no key
  events, any character, 5,000 characters in 4 ms. The plain `NSResponder`
  method is enough. `WKWebView` also answers to `NSTextInputClient` at run
  time, but its public header does not declare that.
- **A screenshot** (`takeSnapshot`) comes back in 1.4 to 5 ms at 2048×1536
  and shows the page as it is after the last click, drawn or not. Writing the
  PNG is the slow part: 17 to 23 ms, about 70 KB. `createPDF` works too.
- **A hidden page still runs, it only stops drawing.** A one-off 300 ms timer
  fired at 302 ms, `fetch`, `MessageChannel` and `IntersectionObserver` ran,
  and a Vite hot reload landed in 109 ms with the component's state kept. But
  `requestAnimationFrame` never ran and a CSS transition never ended, until
  the window was shown 4.9 s later. Repeating timers drop to once a second. A
  screenshot does not push a frame through.
- **Drawn without being seen** is a window that is on screen and fully clear
  (`alphaValue` 0, ignoring the mouse), one below the desktop, a web view under
  another view, or a window with two points left on screen. A window wholly
  past the edge counts as hidden. (Ordered in at a position off screen, macOS
  moved it back on. Setting the position after ordering it in stuck.)
- **Switching is cheap.** Never shown to shown clear: the page said visible
  after 35 ms and ran 60 frames in the next second. Ordered out again: hidden
  after 18 ms. Moving the live web view to another window took 8 ms and kept
  the document.
- **A click takes the keyboard.** With another view as first responder in the
  same window (the terminal's place), one click on a field made the web view
  first responder. Handing the keyboard back in the same turn did not hold:
  0.4 s later the web view had it again. A window that refuses in
  `makeFirstResponder(_:)` does hold, and clicks, keys and text still reach
  the page: sign-in and the editor both worked that way. The price is that the
  page gets `focusin` but no `focus` or `blur`, so the form's check on leaving
  a field never ran. In a window of its own the web view is first responder
  and `focus` and `blur` fire.
- **Keys queue, text and commands do not.** Sent back to back, five keys,
  some text, move-to-start and one more key gave `gentXa text` for
  `Xagent text`. With one script round trip after each step the order held,
  and 180 keys took 166 ms.
- **`document.hasFocus()` is false** in a window that is not key. Overriding
  `isKeyWindow` and posting the became-key notification makes it true. None of
  the test pages needed it.

Not measured: another Space, a full-screen app in front, a locked screen, a
sleeping display. All of them are expected to end drawing, so a command must
never wait on a frame without a time limit.

Private API that would help, found by asking whether the method exists and
not called: `_setWindowOcclusionDetectionEnabled:` (keep drawing while
covered), `_simulateMouseMove:` (hover), `_webProcessIdentifier` (which
process is this tab's).

**Recommendation.** Keep an agent's page that is out of sight in a window of
its own that is never shown, and send input to the view, not the window. While
a command runs and for a few seconds after, order that window in fully clear
so the page draws. Order it out when the agent goes quiet: that is the
difference between 22 mW and 1 mW for a page that moves. Let the web view go
after long disuse, as planned: what an idle one holds is memory (24 MB for
its own process), not energy. When the tab is showing in the column and the
person is typing in the terminal, the window must refuse the web view the
keyboard until the person clicks in the page. Before phase 3 is built, check
the clear window by eye and on a second Space.

#### 2. The outline

A script of about 300 lines, installed at document start in a private
`WKContentWorld` and called with `callAsyncJavaScript`. It gives each element
a role, a name, its state, and a reference when it can be acted on. The
references live in a map in that world, where the page cannot reach them, and
an element keeps its reference from one outline to the next. The sign-in form,
whole, in the compact shape:

```
- banner:
  - link "Acme" [ref=e1]
- main:
  - heading "Sign in to Acme" [level=1]
  - form:
    - textbox "Email" [ref=e2] [required]
    - textbox "Password" [ref=e3] [required]
    - checkbox "Remember me" [ref=e4]
    - paragraph:
      - button "Sign in" [ref=e5] [disabled]
      - link "Forgot password?" [ref=e6]
  - paragraph: New here? [Create an account](e7)
```

Tokens, counted on the machine with `o200k_base` as a stand-in. Claude's own
count will differ.

| Page | Full | Compact | Compact, window only | Controls only | Its HTML |
| --- | ---: | ---: | ---: | ---: | ---: |
| Vite's React starter | 216 | 186 | 149 | 97 | 2,716 |
| Sign-in form | 144 | 135 | 135 | 97 | 527 |
| ProseMirror basic example | 292 | 282 | 282 | 238 | 6,041 |
| Lexical playground | 936 | 880 | 841 | 746 | 4,770 |
| vite.dev/guide | 3,898 | 3,489 | 804 | 1,674 | 36,918 |
| A GitHub repository page | 4,501 | 3,746 | 1,602 | 2,873 | 123,421 |
| MDN's page on `<input>` | 38,976 | 35,400 | 749 | 17,440 | 59,069 |

The script takes 1 to 15 ms, and 20 to 54 ms on the MDN page (3,691
elements). Compact lifts a lone link or button out of its list item and
writes text with plain links on one line, which saves 3 to 17%. Adding link
addresses costs up to 90% more (the GitHub page goes from 3,746 to 7,079).

By reference, all in a window that was never shown:

- **Vite.** Click the counter, twice with the same reference across a
  re-render. Fill a controlled React input (the Add button came alive, so
  React saw it). Type with keys and submit with Enter. A checkbox. Fill again
  replaces, fill with nothing clears.
- **Sign-in.** Fill both fields, tick the box, click Sign in, and once more
  with Enter. The form's check on leaving a field ran. The outline shows a
  password as `•••`.
- **ProseMirror.** Click one paragraph by reference and type at its end. Enter
  for a new paragraph. Accents, a tick and Chinese as text. ⌘B as a key makes
  bold. A double click selects a word and the toolbar's button, by reference,
  makes it bold. Open the menu's dropdown, pick an item. Fill replaces the
  document and ⌘Z brings it back. The editor saw 137 events, all trusted. The
  Lexical playground took fill, keys, Enter and its Bold button the same way.
- **Frames and shadow roots.** Open shadow roots and same-origin frames are in
  the outline and take clicks and fills. A frame from another origin works
  through public API too: the script in the frame announces itself with a
  script message, the message carries the `WKFrameInfo`, the outline is made
  inside the frame, and the click lands at the frame's place plus the
  element's.
- **Loud failures.** A reference to an element that is gone says so. A button
  under an overlay says what covers it. A button 2,000 points down is
  scrolled to and clicked.

What failed:

- **`<select>`.** A click opens a native menu, from a window that is not on
  screen, and the menu runs its own event loop until something is chosen. With
  the select focused, a typed letter picks an option with trusted events.
  Arrow keys and Space open the menu again. It needs a `select` command that
  sets the value in script, the one place a trusted event is given up.
- **`<input type="date">`.** The keys arrive and the value stays empty, hidden
  or drawn. Setting the value in script works.
- **Hover.** `mouseMoved(with:)` alone gives no mousemove, no mouseover and no
  `:hover`, in every arrangement. Hover only moves on a mouse-down. A menu
  that opens on hover cannot be opened. This and the date field are the two
  results most likely to differ with the app in front, which was not tried.
- **⌘A and the Edit menu's other keys.** The page gets the keydown, so a
  shortcut the page handles itself works. One the Edit menu turns into a
  command does nothing: ⌘A selected nothing. `doCommand(by:)` with
  `selectAll:` does it. Copy and paste were not tried: they go through the
  person's clipboard, which is a reason to leave them out.
- **Closed shadow roots** are not in the outline. On macOS 27 a world made
  with `allowAccessingClosedShadowRoots` sees them, tried and working. Wortel
  targets 14.
- **Two bugs of the first version**, both fixed in the spike. Content slotted
  into a shadow root was dropped (the MDN page came out at 529 tokens), until
  the walk followed `assignedNodes` and stopped treating `display: contents`
  as hidden. And compact folded a disabled button into a line of text and lost
  "disabled": a control keeps its own line.
- **`alert()`, a file input and a link that opens a new window** reach the
  delegate and show nothing. Phase 3 has to answer each.

**Recommendation.** Build it this way. `snapshot` prints the compact outline
without addresses. Past about 4,000 tokens it prints the window's part and
says how many elements are above and below, with a flag for the whole page
and one for controls only. Mask passwords. Wait one round trip after every
key. Add `select` to the first commands, set dates in script, and leave hover
out until a session needs it.

#### 3. The sign-in

Tried with a real cookie login on a local HTTPS server. The session cookie was
`__Host-sid` (Secure, HttpOnly, SameSite=Lax, 30 days), beside a
SameSite=Strict session cookie and a plain one. The person's tab used the
default store. The agent's tab used a store of its own
(`WKWebsiteDataStore(forIdentifier:)`).

A store of its own, with the site's cookies copied in:

- **It signs the same web view in.** Before the copy the server got no
  cookies from the agent's tab. After it, a reload was signed in. The web view
  was not remade.
- **The copy is small and exact.** `getAllCookies`, keep the site's,
  `setCookie` each: 3 cookies, 0.15 ms to read and 0.43 ms to write. Secure,
  HttpOnly, SameSite, expiry and the `__Host-` name all arrived intact. With
  3,000 other cookies in the jar the read took 22 to 24 ms, and macOS 27's
  `getCookies(for:)` 0.1 ms.
- **Only that site.** A second site the person was signed in to stayed signed
  out in the agent's tab.
- **It can be taken back.** Deleting the site's cookies from the agent's store
  signed it out. The person signing out (the server dropping the session)
  signed the agent's tab out too.
- **It costs nothing extra.** A tab in its own store adds one web process of
  about 24 MB, the same as a tab in the shared store, and no second network
  process.
- **"This site" has a public answer.** `WKWebsiteDataRecord.displayName` gave
  `example.co.uk` for cookies on `app.` and `accounts.example.co.uk`.
- **It lasts as long as the cookies do.** After a relaunch the agent's store
  still had the 30-day cookies and was signed in. The session-only cookie was
  gone, as it would be from any store.

What the copy does not do:

- **Only cookies.** A page that keeps its sign-in in `localStorage` or
  IndexedDB was signed out in the agent's tab after the copy. The macOS 26
  `fetchData(of:)` and `restoreData(_:)` take `localStorage` only (the other
  13 types, cookies among them, are refused on 27.0.1) and move the whole
  store, not one site.
- **Two copies of one session can part.** On a server that swaps the session
  id on use, one request from the agent's tab signed the person's tab out. The
  cookie observer fires on every change, so copying back is possible. It was
  not built.

One store and a gate:

- **Everything carries.** A second web view on the person's store was signed
  in at once, with nothing copied and nothing to keep in step. It is the same
  store, so `localStorage` comes too (not tried separately).
- **"Go on signed out" cannot be kept.** A load with
  `httpShouldHandleCookies` off reached the server without cookies, and the
  first `fetch()` from that page sent them all.
- **A web view cannot change store.** `configuration` hands back a copy:
  setting `websiteDataStore` on it changed nothing, and the next page was
  still signed in. So "signed out" needs a second web view in another store
  anyway, and the gate becomes the only thing between an agent and every site
  the person is signed in to.

Either way it is a seat belt. The store's cookies are a plain file in the
home folder, and `strings` on it printed the HttpOnly session id. An agent
has a shell. The question stops an agent using a sign-in by accident, not one
that means to.

**Recommendation.** A store of its own: one persistent store shared by every
agent's tab. On yes, copy that site's cookies in (by registrable domain) and
reload. On no, do nothing. Keep an allowed site in step with the cookie
observer, in both directions, so a server that swaps session ids does not
sign the person out. When a site still shows signed out after yes, say that
its sign-in is not in cookies and that signing in inside the agent's tab
works: the person can use that tab too.

#### What this changes above

- "The page is kept drawn off screen while the agent uses it" holds, as a
  clear window that is ordered in while the agent works.
- "A JavaScript `click()` is not a fallback" holds for clicks. A `<select>`
  and a date field are set in script, and say so.
- "It never takes the keyboard" needs the window to refuse the web view, and
  costs the page its `focus` and `blur` events while it does.
- `select` joins the first commands. Hover does not exist yet.

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
