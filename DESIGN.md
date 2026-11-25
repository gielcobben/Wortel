---
name: Wortel
description: A native macOS terminal for working next to coding agents. A fixed frame per window, glass chrome, opaque pages, almost no colour.
sources:
  app: macos/Wortel/UI/Chrome.swift
  terminal: macos/Resources/wortel.conf
  canvas: https://opmaak.dev/c/x7olxfuo7j
  site: web/src/styles/site.css
colors:
  light:
    page: "#ffffff"
    raised: "#ffffff"
    text: "rgb(0 0 0 / 0.7)"
    text-secondary: "rgb(0 0 0 / 0.5)"
    text-tertiary: "rgb(0 0 0 / 0.275)"
    glyph: "rgb(0 0 0 / 0.55)"
    glyph-disabled: "rgb(0 0 0 / 0.14)"
    list-wash: "rgb(255 255 255 / 0.35)"
    selected-on-glass: "rgb(0 0 0 / 0.08)"
    selected-on-page: "rgb(0 0 0 / 0.07)"
    hover: "rgb(0 0 0 / 0.05)"
    strip-band: "rgb(0 0 0 / 0.03)"
    hairline: "rgb(0 0 0 / 0.07)"
    hairline-strong: "rgb(0 0 0 / 0.10)"
    accent: "#0070f5"
    needs-you: "#ff9500"
    turn-done: "#00c7be"
    added: "#34c759"
    failed: "#ff3b30"
    finished: "#007aff"
  dark:
    page: "#1f1f1f"
    raised: "#2e2e2e"
    text: "rgb(255 255 255 / 0.9)"
    text-secondary: "rgb(255 255 255 / 0.55)"
    text-tertiary: "rgb(255 255 255 / 0.35)"
    glyph: "rgb(255 255 255 / 0.66)"
    glyph-disabled: "rgb(255 255 255 / 0.18)"
    list-wash: "rgb(255 255 255 / 0.02)"
    selected-on-glass: "rgb(255 255 255 / 0.08)"
    selected-on-page: "rgb(255 255 255 / 0.11)"
    hover: "rgb(255 255 255 / 0.07)"
    strip-band: "rgb(255 255 255 / 0.04)"
    hairline: "rgb(255 255 255 / 0.08)"
    hairline-strong: "rgb(255 255 255 / 0.12)"
    accent: "#007aff"
    needs-you: "#ff9f0a"
    turn-done: "#63e6e2"
    added: "#30d158"
    failed: "#ff453a"
    finished: "#0a84ff"
typography:
  ui: "-apple-system, SF Pro Text, 13pt"
  terminal: "SF Mono Medium, 14pt, cells 8.5 by 19pt"
  diff: "SF Mono, 12pt"
rounded:
  control: 8
  palette: 16
  window: 18
motion:
  opening: 0.26s
  closing: 0.18s
  tabs: 0.18s
  curve: "cubic-bezier(0.23, 1, 0.32, 1)"
---

# Wortel design

How Wortel is designed, and the numbers it is built from. Read this before
changing anything in `macos/Wortel/UI/`, adding a control anywhere in the app,
or touching how the app is drawn on the site. `docs/brand.md` covers the name
and the mark, `docs/voice.md` the words.

## Where the truth is

| For | The source |
| --- | --- |
| The app's colours, metrics and motion | `macos/Wortel/UI/Chrome.swift`. Every value below that has a `Chrome.` or `Motion.` name lives there. |
| The terminal's look | `macos/Resources/wortel.conf` |
| The app, drawn element by element | The design canvas. Its public copy is https://opmaak.dev/c/x7olxfuo7j: tokens and components, each pane by itself, twelve whole-window states in light and dark, and the same on wallpapers. Measured against the real app and checked pixel by pixel. The site's windows are generated from the working copy named in `web/README.md`. |
| The site | The header of `web/src/styles/site.css` |
| The app's tokens on the site | `web/src/styles/app.css`, scoped to `.wapp` |

When they disagree, the code is right for the app, and the canvas and the site
follow it. A change to a value in `Chrome.swift` is a change to make on the
canvas too, or the site will show an app that no longer exists.

Nothing keeps the canvas current by itself: it is drawn by hand from the app.
`web/scripts/opmaak/synced` names the commit it last showed,
`web/scripts/opmaak/drift.sh` lists what the app has gained since, and the
`sync-visuals` skill is how it is brought level again.

## The idea

Wortel has a handful of settings, and it is not a small app. It holds
sessions, tabs in three places, a git client, a file tree, previews, a browser,
a process list and a command line of its own. The design problem is fitting all
of that into something that still reads as a terminal, with next to no
preferences to lean on.
These are the ideas that do it.

**A fixed frame, in every window.** There are four places and only four:
sessions on the left, the terminal in the middle, the repository beside it, a
second shell underneath. Tabs live inside those places. There is no grid of
splits to arrange, so there is no layout to configure and none to get wrong.
A second window (⇧⌘N) is the same frame again, with a sidebar of its own
sessions: windows are how work is set apart, never how a layout is built.

**Glass for the frame, pages for the work.** The whole window sits on one
behind-window material, so the desktop tints it. The titlebar band and the
sidebar let that through. The terminal and the side column are opaque pages
laid on top. You can tell chrome from content without a single border doing
the telling.

**Almost no colour.** The interface is black or white at different opacities.
Colour appears only where it means a state: an agent that needs you, a changed
file, a branch lane, a diff. The attention dots are the only colour in the
sidebar, which is why they work.

**One set of numbers.** Every control in every row is 28pt high with 8pt
corners and a 14pt glyph. A tab and the button beside it are the same height,
the same roundness, the same glyph weight. The difference between a row that
looks designed and one that looks assembled is mostly that nothing in it is two
points off anything else.

**Hover sits a step under selection.** A row under the pointer never reads as
chosen: hover is 4% on the glass and selection is 8%.

**Absent, not greyed.** Chrome that has nothing to say is not drawn. The side
column appears with its first tab and goes with its last. The menu bar item
exists only while something waits. A status sits beside the thing it describes.

**Power is in the keys, not in a window of switches.** Everything is a menu
command with a shortcut, ⌘P finds any of them by name (it reads the menus, so
it cannot drift), and the `wortel` command reaches the same things from a
script. Where another app would add a setting, Wortel picks the answer. Where
the answer truly differs per person, it is a checkmark in a menu if it is
flipped while working, and a row in Settings (⌘,) if it is decided once.

**Borrowed on purpose.** Each interaction comes from an app the user already
knows, so there is nothing to learn. Selection and tag colours from Finder.
Chrome, tab metrics and the motion curve from the ChatGPT desktop app. Open
Quickly from Xcode for ⌘P. The graph from Fork. Markdown metrics from GitHub.
`macos/docs/shortcuts.md` lists where every shortcut comes from.

**Native behaviour kept, only the look changed.** System selection, drag,
accessibility and text editing stay the system's. Web habits stay out: no
pointing-hand cursor over rows, no card fading into a corner.

**Nothing moves unless something happened.** Switching sessions is instant.
Opening takes a little longer than closing, because putting something away
should not make you watch it go.

## Colour

Every colour is one of these. The left column is the name on the canvas and in
`app.css`; the second is what it is in the code or in macOS.

### Surfaces and lines

| Token | In the app | Light | Dark | For |
| --- | --- | --- | --- | --- |
| `background` | `Chrome.content` | `#ffffff` | `#1f1f1f` | The pages: the terminal, the side column |
| `card` | `Chrome.raised` | `#ffffff` | `#2e2e2e` | The tab in front, on a page. Lifted in dark, where the page's own colour would vanish into it |
| `sidebar` | the window's vibrancy | grey 245 at 90% | `oklch(0.269 0 0)` at 85% | The glass behind everything. In the app it is a system material; these are the canvas's stand-ins |
| `sidebar-primary` | `Chrome.sidebar` | white 35% | white 2% | The session list's wash over the glass |
| `sidebar-accent` | `Chrome.raisedOnBand`, `pillAlpha` | black 8% | white 8% | A selection on the glass: the session pill, the tab in front of a titlebar row |
| `secondary` | `Chrome.selectedFill` | black 7% | white 11% | A selected row on a page, a glyph button that is on |
| `accent` | `Chrome.hoverFill` | black 5% | white 7% | Hover on a control |
| `muted` | `Chrome.stripBand` | black 3% | white 4% | The bottom strip's tab row. (The palette's footer is the label colour at 3%.) |
| `border` | `Chrome.hairline` | black 7% | white 8% | Hairlines |
| `input` | `Chrome.hairlineStrong` | black 10% | white 12% | Toolbar dividers, tab edges, field outlines |
| `popover` | the `.popover` material | 226 at 90% | 37 at 80% | The command palette |

On the glass, a tab in front is translucent, never opaque. An opaque tab there
read as a hole in the glass.

In the sidebar: hover 4%, selected 8%, also-selected (the rest of a multiple
selection) 6%, all of the label colour.

### Text and glyphs

| Token | macOS | Light | Dark | For |
| --- | --- | --- | --- | --- |
| `foreground` | `labelColor` | black 70% | white 90% | Text |
| `muted-foreground` | `secondaryLabelColor` | black 50% | white 55% | Quieter text, glyphs on a page |
| `sidebar-section-foreground` | `Chrome.sectionHeader` | black 38% | white 45% | Section headers in the sidebar |
| `sidebar-primary-foreground` | `tertiaryLabelColor` | black 27.5% | white 35% | Branch lines, line numbers |
| `sidebar-accent-foreground` | secondary glyph | black 55% | white 66% | Toolbar and row glyphs on the glass |
| `sidebar-ring` | disabled glyph | black 14% | white 18% | Back and Forward with nowhere to go |

Glyphs are SF Symbols tinted with a token, so they follow the appearance.

### Colour that means something

| Token | macOS | Light | Dark | Means |
| --- | --- | --- | --- | --- |
| `primary` | `controlAccentColor` | `#0070f5` | `#007aff` | The accent: the selected row in ⌘P, checkboxes, the caret, focus |
| `chart-1` | `systemOrange` | `#ff9500` | `#ff9f0a` | Needs you. Modified. The main lane |
| `chart-2` | `systemMint` | `#00c7be` | `#63e6e2` | Turn done |
| `chart-3` | `systemGreen` | `#34c759` | `#30d158` | Added. A server that is serving |
| `chart-4` | `systemRed` | `#ff3b30` | `#ff453a` | Failed. Deleted |
| `chart-5` | `systemBlue` | `#007aff` | `#0a84ff` | Finished. The second lane. Hunk headers |

These are the system's colours, not ours, so they change with the system's
settings where macOS lets them.

**Not tokens, on purpose:** the terminal's colours and syntax colours come from
the terminal theme (GitHub Light Default and GitHub Dark Default), never from
the app.

## Type

- **Interface:** the system font. Titles and rows 13pt regular. Folder headers
  are the same 13pt in a grey of their own (`Chrome.sectionHeader`), not
  smaller and not bold. Between the tertiary, too faint on the glass (2.2:1
  in dark, 1.9:1 in light), and the secondary, too close to the rows (4.5:1,
  3.9:1). It measures 3.2:1 and 2.6:1, chosen by eye.
- **Terminal:** SF Mono Medium 14pt on cells of 8.5 by 19pt, padding 5 by 2, a
  block cursor that does not blink. Regular weight at 14 with taller cells was
  tried; Medium stayed.
- **Diffs in the side column:** SF Mono 12pt, rows 18pt. A preview is for
  reading, so it starts at 13pt and ⌘+ and ⌘- take it from 9 to 24.
- **Rendered Markdown:** GitHub's metrics. Body 16 on 24, a 602pt measure,
  headings 32, 24, 20, 16, 14, 13.6 semibold, inline code at 85%.
- **Weight is used sparingly.** Bold marks the tool an agent called and the
  scope before the colon in a commit subject. Little else.

## Metrics

### Window

| | |
| --- | --- |
| Titlebar row | 40pt, measured from the system at launch (`Chrome.titlebarHeight`) |
| Room for the traffic lights | 78pt (`Chrome.trafficLightInset`) |
| Any control in a row | 28 by 28pt, corners 8pt (`controlSize`, `controlRadius`) |
| Any glyph in a row | 14pt regular; 13pt in menus |
| Sidebar | 234pt on the canvas; drags between 180 and 400 |
| Side column | 384pt on the canvas; at least 260, and it may grow until the terminal has 320 |
| Window corners | 18pt |

Each pane draws its own 40pt row of one flat band, with hairlines between
panes. The titlebar is Wortel's own because macOS 26 and later put every
toolbar item on a glass capsule, and there is no switch for that.

### Sidebar

| | |
| --- | --- |
| Row | 30pt. With a line under the name (a worktree's branch, a reminder's time), 44pt |
| Section header | 30pt |
| Between sections | 14pt under an open section's last row, part of that row. None under a folded section, so folded folders stack like rows |
| Selection pill | 8pt corners |
| Status | Centred in the last 34pt of the row. The dot and the close button share that slot, so nothing shifts on hover |
| Session colour | A 3pt bar inside the pill's leading edge, in Finder's tag colours |
| Bottom edge | The list ends level with the tops of the + and ⓘ. While rows go on below, it fades out over the last 20pt, as an overflowing tab row does |

A row is one line. Two things add a second, small and grey, under the name: a
worktree's branch, with a small branch glyph, and a reminder's time
("Tomorrow at 09:00"), with a small clock. A row with both has them on the
one line, the time first and written short ("Tue 09:00"). A line too long for
the row slides on hover, as the name does.

### Tabs

One tab shape for every row: 10, a 16pt glyph, 8, the title, 4, a 20pt close
button, 4. Sized to its title, between 130 and 240pt, 4pt apart. When a row
overflows it scrolls under 20pt faded edges, with "+" pinned after the last
tab.

### Side column

| | |
| --- | --- |
| Repository header | 34pt |
| Change row, file row | 22pt |
| File tree indent | 8, then 12 per level, a 16pt disclosure |
| Diff row | 18pt, tinted across the full width |
| Ignored files | Shown at 40%, never hidden |

### Command palette (⌘P)

560pt wide, 16pt corners, a 56pt field, 44pt rows with eight showing, a 32pt
footer with the keys. The selected row is the accent with white text.

## States

**A session, in the sidebar**

| What you see | Means |
| --- | --- |
| Three small dots in a soft wave | Working |
| Orange dot, breathing | Needs input |
| Red dot, breathing | Failed |
| Mint dot, breathing | The agent's turn is done |
| Blue dot, steady | Finished: a long command or a job ended |
| Hollow ring | Unread: you have not been there since |
| Small orange triangle | No status: the agent is a version too old to say what it is doing. The sidebar's bar has the same triangle, and its popover says which version it needs |
| Number in place of the status | ⌘ is held: ⌘1 to ⌘9 |

A louder state is never replaced by a quieter one, and a collapsed folder shows
the loudest thing inside it after its chevron: a dot, or the three dots when
nothing in it is louder than working. Sound only when a state gets louder.

**A control**

Rest, hover (`hoverFill`), on (`selectedFill`, held while its menu is open),
disabled (the glyph at 14% or 18%). A destructive control is grey until
hovered, and red then.

**Focus**

The list selection is the accent only while its list has the keyboard, and
grey otherwise, as in Finder. Moving between areas with ⌘] blinks a short
outline around the one that now has the keyboard.

## Motion

| | |
| --- | --- |
| A pane opening | 0.26s (`Motion.opening`) |
| A pane closing | 0.18s (`Motion.closing`) |
| Tabs | 0.18s (`Motion.tabs`) |
| The curve | `cubic-bezier(0.23, 1, 0.32, 1)`: most of the distance early, a long gentle settle |

- Switching sessions is instant. A switch that changes whether a pane is
  showing snaps; it never animates.
- A terminal does not resize during an animation. It resizes once, when the
  pane lands.
- A control that is there in both states moves; it is never hidden in one
  place and shown in another. The sidebar toggle stays by the traffic lights
  and Back and Forward ride the sidebar's edge.
- The sidebar never re-sorts under the pointer.
- A long name scrolls after resting a second, slowly, with faded edges.
- Reduce Motion stills the dots and the wave. The flash around a session that
  starts wanting you still fades out, without its fade in.

## Which surface for what

- **A popover belongs to a control. A sheet belongs to the window.** A notice
  hangs off the control it is about and uses a switch, not two buttons. A sheet
  is for a decision that stops the window: a new worktree, cleaning up.
- **A menu for commands.** Every command is in the menu bar; that is what ⌘P
  lists. The Session menu comes before Edit. There is no File menu.
- **Settings is one of Wortel's own windows.** Its titlebar row on
  the glass holding its two tabs, drawn as every tab is, and the rows on a
  page: 13pt
  names, a 12pt grey line under each saying what it does, rows that belong
  together in a box (a faint band, 10pt corners), small switches, a 28pt
  field with 8pt corners for what is typed.
  The whole of a row's text is the switch's to click. A row that can do
  nothing on this build is absent. The system's preferences window was
  built and used first (`macos/docs/architecture/settings.md` has why it
  went).
- **The same menu everywhere** for the same thing. A session's menu is one
  menu, in one order, wherever it opens.
- **A tooltip says what the eye cannot see, and nothing cleverer:** a name
  that was cut off, a glyph button's name and shortcut, a folder's directory,
  what a waiting session wants and for how long.
- **A notification is the news itself:** the start of the agent's answer. One
  per question. None for the session you are looking at.
- **An empty state is a few centred lines**, with a small grey glyph at most.
  Never an illustration.

Wording rules for all of these are in `docs/voice.md`.

## The site

The site is the same hand in a different material: quiet, left-aligned, and
built around the real app.

### What is there

A fog-white page. A wordmark and four links, and one black pill that says
Download. Then the name in two tones on two lines, "Meet Wortel" in ink and
"A terminal for your agents." in grey, one short paragraph, one pill, and a
few words of small print beside it.

Under it, a stage: a rounded frame holding a photograph of mist over water,
and standing on it, the app. Not a picture of the app. The window is live
markup at the app's own sizes, and its sessions select, its tabs switch and
its sidebar folds.

Every section after that opens with the same row, 160px below the last. A
hairline across the page. Under it, at the left, a light heading in two short
lines: the claim in ink, its other half in grey. At the right, starting at the
middle of the page, one short paragraph and a link with a small arrow. The
words stay as they are while the film below plays.

Then a stage at full width, with a glass pill of chapter names and a round
pause button floating over the window. The chapters play by themselves until
you press something.

After three stages comes a poster of thirteen tiles, each one piece of the real
app with a label of a few words. Then the questions, which open in place: they
sit in the right column, and their heading stays beside them while they scroll.
The page ends on the icon on the lake with "Put down roots." The footer says
"Wortel is Dutch for root."

Inner pages open with one large line and one grey sentence, then the same
rows in a wider measure: a smaller heading in a narrow column on the left (on
the changelog, the version with its date in grey under it), the text in the
wide column beside it, a hairline between rows.

At night the page is near-black, the photographs are the same places in the
dark, and the app is its dark self. On a phone the window is not scaled down.
It is a small window instead: as wide as the stage, its sidebar folded the way
the app folds it, the terminal wrapped to that width. A film about two parts
of the window keeps both in a wider window, and the stage shows one at a time.

### The numbers

| Token | Light | Dark | For |
| --- | --- | --- | --- |
| `--fog-0` | `#fbfaf7` | `#0e0e0c` | The page |
| `--fog-1`, `--fog-2`, `--fog-3` | `#f3f2ed` `#e9e7e0` `#dedbd2` | `#151512` `#1d1d19` `#272722` | Raised band, tile |
| `--ink` | `#1b1b17` | `#ecebe6` | Text, and the primary button |
| `--ink-2`, `--ink-3` | `#6b6960` `#77746a` | `#9e9b90` `#8a877c` | Secondary, tertiary |
| `--tone` | `#9c998e` | `#6c6a61` | The grey half of a heading. Large type only |
| `--line`, `--line-2` | ink at 10%, 16% | ink at 9%, 15% | Hairlines |
| `--accent` | `#0070f5` | `#4a9bff` | The cursor's blue. The only accent |

| Style | Size / line | Tracking |
| --- | --- | --- |
| Display | 56 / 64, weight 500. 48 / 56 under 1000px, 36 / 44 under 640px | -0.012em |
| Heading | 28 / 36, weight 400. 24 / 32 under 640px | -0.02em |
| Lead | 19 / 28 | -0.01em |
| Copy | 17 / 28. The paragraph beside a section's heading | |
| Body | 15 / 24 | |
| Label | 13 / 16 | |

- **Fonts:** the system's. SF Pro for text and display, SF Mono for code.
- **Weights:** light. 500 for a page's one large line, 400 for a heading, 500
  for small headings and labels that need it. 600 only for bold inside prose.
- **Container:** 1200px with 32px gutters, twelve columns with 32px between.
  Headings and visuals start at the left edge. Reading starts at column 7 on
  the homepage and at column 4 on a page of text.
- **Grid:** every margin, padding, gap and fixed height is a multiple of 8.
  The insides of the pills below are the exception.
- **Sections:** 160px above each (112 under 900px). Each opens with a hairline,
  then 48px, then the row: its name in columns 1 to 5, the reading column in
  7 to 12, on one baseline. What it shows follows 48px under the row. On an
  inner page the row's name is 20 / 28 in columns 1 to 3 and the text has
  columns 4 to 11.
- **Stage:** 20px corners (16 on a phone), a 1px inset line. The window inside
  has 18px corners, one 0.5px hairline as a real border, and one soft shadow.
  On a phone (760px and under) the stage's padding is 16px and the window is
  512px high at most.
- **Under a finger:** a control takes taps from at least 40px each way. One
  drawn smaller (a 32px button, a chapter tab, a link with an arrow) keeps its
  size and has a larger area around it.
- **Buttons:** pills, 40px high, 20px side padding. The primary is ink on fog.
  A press scales to 0.97. Small ones are 32px.
- **Chapter tabs:** a pill of 32px pills; the lit one slides. Play is a 40px
  circle.
- **Traffic lights:** drawn in CSS as true 14pt circles, `#f35f55`, `#fcbf00`,
  `#37c000`.

Motion on the site has its own rules in `web/README.md` (Motion and
interaction): three curves, no ease-in, answers under 300ms, nothing tied to
scroll but the photographs' small drift.

## Tried, and taken out

Look here before proposing one of these again. Most of the reasons are in
`docs/decisions.md`; for the selection colour and the tabs on the glass they
are in the comments in `SidebarOutlineView.swift` and `Chrome.swift`.

- A second line on sidebar rows (the path, then the running agent).
- A "Needs You" section at the top of the sidebar, and an Archived fold.
- An accent-coloured selection in the sidebar. It is grey: the sidebar never
  holds the keyboard.
- A custom card for "new tab". A native menu does it.
- Opaque tabs on the glass.
- Two toolbar glyphs for one running state.
- A sparkle after an update.
- On the site: a dark centred page, a drawn icon, scroll snapping, a pinned
  scrolling explainer, a row of steps under the window, a raster screenshot, a
  window wider than the app really is, a heading whose grey half changed with
  the chapter, a two-tone heading run on as one long line, numbered sections
  and a margin index in mono, grey photographs with film grain.

## Do, and don't

**Do**

- Use a token. If a colour or a size is not in `Chrome.swift`, ask why you need
  it before adding it.
- Make a new control 28pt high with 8pt corners and a 14pt glyph.
- Put a control beside what it controls.
- Use the system's component and keep its behaviour.
- Check light and dark, and on a wallpaper: the glass takes its colour.
- Look at it zoomed in before calling it done.

**Don't**

- Add a colour that does not mean a state.
- Add a border where a surface change already says it.
- Animate a session switch, or resize a terminal mid-animation.
- Grey out chrome that has nothing to say. Leave it out.
- Add a setting where an answer would do. Decide first; a row in Settings is
  for what truly differs per person.
- Scale, crop or redraw the app anywhere it is shown.
