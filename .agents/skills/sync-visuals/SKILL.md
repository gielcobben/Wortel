---
name: sync-visuals
description: Bring the design canvas (the Opmaak file) and the app windows on wortel.sh up to date with the app as it is on main. Finds what changed in the app since the canvas last showed it, captures the real app from a throwaway copy, updates the canvas, regenerates the site's windows and checks the site's words. Use when asked whether the canvas, the design file or the website still match the app, after a batch of visible changes, before making marketing images, or when the release skill reports many commits since the last sync.
---

# Bring the canvas and the site up to date with the app

This is a maintainer-only tool: it needs the private `opmaak` CLI and the
design canvas, and contributors don't need it. The site's windows it produces,
`web/src/app/gen/`, are committed, so the site builds without it.

The picture of the app flows one way, and each step has its own tool:

| From, to | How | How to tell it is behind |
| --- | --- | --- |
| The app, to the canvas | By hand. This skill | `web/scripts/opmaak/drift.sh` |
| The canvas, to the site's windows | `web/scripts/opmaak/regen.sh` | `regen.sh --check` |
| The app, to the site's words | By hand, in `web/src/data/site.ts` | Step 5 |

So when the site shows an app that no longer exists, the canvas is nearly
always where it went wrong. Fix it there. Never in `web/src/app/gen/`.

This is hours of work, not minutes, which is why it is not a step of every
release (`docs/decisions.md`, Website). Do it for a batch of changes.

Read `DESIGN.md` first, and load the `opmaak` skill (or run `opmaak guide`)
before the first command that changes the canvas.

## 1. What is behind

```sh
web/scripts/opmaak/drift.sh             # the app's commits since the last sync
(cd web && scripts/opmaak/regen.sh --check)   # does the site match the canvas
```

Sort every commit in both lists into one of three:

- **Changes something the canvas draws.** Name the frame.
- **Adds something the canvas does not draw.** A new window, pane or state.
- **Nothing to see.** Most of the second list, and fixes to behaviour.

Read the commit when the subject does not settle it, and read the diff of every
file under `UI/`, `Settings/` and `Preview/` whatever the subject says: on
2026-11-19 a new button in every file header came in a commit called "Links: a
⌘-clicked path opens in Wortel at its line". Then say the plan before
starting: what you will redraw, what you will add, and what you are leaving
out and why. A new frame is a decision about what the site and the marketing
images need, so ask when it is not obvious.

What the canvas holds (2026-11-27), all on its first page:

- A cover, the **Tokens** sheets and the **Components** sheets, light and dark.
- **Panes**, each by itself in a slot (`Pane · Sidebar · Dark`, and so on):
  sidebar, terminal (wide, beside a column, in a split, with a note pasted),
  changes, history, files, a file in the column and in the main area, code,
  browser, bottom strip, command palette, the window's corner (`Window
  controls`), the New Tab page, and mark-up (on Markdown, and on a page).
  Light and dark twins carry the same markup.
- **Window skeletons** with empty slots.
- **States**, whole windows, each four times: light and dark, on black and on
  a wallpaper. The twelve from before the splits, and since 2026-11-27: New
  Tab, Splits, Zoomed split, Mark-up, Mark-up on a page, and the browser's
  find bar, downloads list and a page from a file.
- **Mark-up · Parts**, light and dark: its button, chips, tools and marks.
- **Shots** for marketing, and `Foggy Lake`, whose window is the site's hero.
- **Other windows**, in a row at y 17100: Settings (General, and Updates as a
  released build has it) and a preview window, each light and dark.

Every frame was redrawn for the splits on 2026-11-27 from the app's code
(revision 1468 to about 1915), not from captures: Screen Recording kept being
lost to app swaps that night. Compare against captures before moving the
marker. The section header colour is plain classes
(`text-black/[0.38] dark:text-white/[0.45]`), because the canvas refuses a
custom token.

Not drawn yet: the reminder picker, menus, sheets and hover cards. The one
popover drawn is the downloads list, and its corner, arrow and shadow are
assumed.
Keep this paragraph true.

**A sidebar is one flat list** of section headers and rows. The gap between
sections is written as the header's height: 30 at the top or after a folded
section, 44 after an open one. A change to order or spacing is a rewrite of
each `nav "Sessions"` with `opmaak set`, which keeps every node's id when the
markup carries them (`opmaak tree --ids`). There were 53 on 2026-11-19, and the
site's `fitSidebar` works the same rule out again after it cuts rows.

## 2. See the app as it is now

Never work from memory of the app, and never from the person's own window.
Build main (`run-build`, step 1; if packages do not resolve, the header of
`scripts/check.sh` says what to pass), then make a throwaway copy the way the
`test-copy` skill does, with three differences: its own bundle id and folder,
so it shares nothing with another agent's test, and the window size set before
launch. The canvas's window is 1310 by 815.

```sh
SRC=<the built Wortel.app>                 # run-build, step 3 prints it
COPY="$HOME/.wsv/WortelShots.app"; DATA="$HOME/.wsv/data"
ID=com.gielcobben.Wortel.shots
mkdir -p "$DATA" && cp -Rc "$SRC" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$COPY/Contents/Info.plist"
codesign --force --deep --sign - "$COPY"
# x y w h of the window, then the screen it was on, less the menu bar and Dock
screen=$(swift -e 'import AppKit; let f = NSScreen.main!.visibleFrame; print(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))')
defaults write $ID "NSWindow Frame main" "100 80 1310 815 $screen "
open -g -n --env WORTEL_DATA_DIR="$DATA" --env DO_NOT_TRACK=1 "$COPY"
```

The copy's pid is in `$DATA/instance.lock`. Everything below addresses the copy
by that pid, never by name: the person's app is called Wortel too. Shell
variables do not survive from one command to the next, so each block starts
with `pid=$(cat "$HOME/.wsv/data/instance.lock")`.

**Fill it** with its own command, `WORTEL_DATA_DIR="$DATA"` on every call
(`test-copy` says why). Sessions go in a scratch clone with made-up edits,
never in the person's checkout. `wortel new --name folder/leaf` makes a folder,
`--branch` a worktree, `notify` and `mark` the dots. Use the names the canvas
already uses, so a capture and a frame can be laid over each other.

The first launch prunes the folder order and folded folders, and the CLI
makes folders newest first. To match the canvas, quit the copy (Wortel ▸ Quit
through its menu, below), then write both and launch it again:

```sh
# the canvas's sidebar folders, top to bottom, then the ones it shows folded
defaults write $ID WortelFolderOrder -array <folder> <folder> …
defaults write $ID WortelCollapsedFolders -array <folder> …
defaults write $ID "NSSplitView Subview Frames window-split" -array \
  "0, 0, 234, 815, NO, NO" "235, 0, 1459, 815, NO, NO"
```

The last line gives the sidebar the canvas's 234pt. The window's split view
has two panes since 2026-11-26 (the sidebar, and everything beside it), saved
as `window-split`. The side column is a split inside the second pane, not a
pane, so nothing here hides it: use View ▸ Hide Changes and Files through
the menu, below (the item is Show Changes and Files while they are closed,
and since 2026-11-26 it closes those panes; nothing is hidden with its tabs
kept). This line was written from the code (`MainSplitViewController`) and
has not been tried yet. A build from before that date has three panes, saved
as `main-split`, and takes a third frame that hides the column:
`"1310, 0, 384, 815, YES, YES"` after `"235, 0, 1075, 815, NO, NO"`.

**Open panes and windows through its menus.** This does not bring the copy
forward or take the keyboard:

```sh
menu() { osascript -e "tell application \"System Events\" to tell (first process \
  whose unix id is $pid) to click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1"; }
menu View "Show Files"
menu Wortel "Settings…"
```

A button that is in no menu (a file header's Open in New Window, which is how
a preview window is made without dragging) is a SwiftUI button that
AppleScript cannot see. Press it through the accessibility API instead, by its
help text; never with a click at a point, which moves the person's pointer:

```sh
cat > /tmp/axpress.swift <<'EOF'
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!, want = CommandLine.arguments[2]
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func walk(_ e: AXUIElement, _ d: Int) -> Bool {
  if d > 40 { return false }
  let texts = [kAXHelpAttribute, kAXDescriptionAttribute, kAXTitleAttribute].compactMap { attr(e, $0) as? String }
  if attr(e, kAXRoleAttribute) as? String == "AXButton", texts.contains(want) {
    AXUIElementPerformAction(e, kAXPressAction as CFString); return true }
  for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if walk(c, d + 1) { return true } }
  return false
}
print(walk(AXUIElementCreateApplication(pid), 0) ? "pressed" : "not found")
EOF
swift /tmp/axpress.swift $pid "Open in New Window"
```

A Debug build's Updates tab says "Nothing to set in this build". The rows a
released build shows are in `SettingsView.swift` (`UpdatesRows`); draw those.

**Light and dark** without changing the Mac (a Debug build only). The object is
`dark`, `light` or `system`:

```sh
osascript -l JavaScript -e "ObjC.import('Foundation');
  \$.NSDistributedNotificationCenter.defaultCenter
   .postNotificationNameObjectUserInfoDeliverImmediately(
     'sh.wortel.test.appearance.$pid', 'dark', \$(), true)"
```

**Capture a window by its id.** Each window of the copy has one: the main
window, Settings, a preview window.

```sh
WPID=$pid swift - <<'EOF'
import CoreGraphics
import Foundation
let want = Int(ProcessInfo.processInfo.environment["WPID"] ?? "") ?? -1
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in all where (w[kCGWindowOwnerPID as String] as? Int) == want && (w[kCGWindowLayer as String] as? Int) == 0 {
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  print(w[kCGWindowNumber as String] ?? "?", "\(b["Width"] ?? "?")x\(b["Height"] ?? "?")", w[kCGWindowName as String] ?? "")
}
EOF
screencapture -x -o -l <id> raw.png
magick raw.png -profile "/System/Library/ColorSync/Profiles/sRGB Profile.icc" shot.png
```

The capture is 2x and Display P3. Convert before sampling a colour, or every
saturated value lands wrong. `-o` leaves the shadow out.

All of the above was run on 2026-11-19 against a build of main: a 1310 by 815
window gave 2620 by 1630 pixels in both themes, and the menus opened the Files
pane and the Settings window while another app stayed in front.

What it cannot show:

- **A window in the background draws as inactive**: grey traffic lights, and
  a switch that is on draws grey instead of blue. The canvas draws the window
  in front. Don't bring the copy forward to get it.
- **Glyphs the canvas does not have yet**: render the SF Symbol at the point
  size and weight the code names, white, at 2x, and upload it. Drawn into a
  rect of `NSImage.size` after `withSymbolConfiguration`, that gives the same
  boxes the canvas's existing glyphs have (21 by 16 for `macwindow.badge.plus`
  at 13pt, checked 2026-11-19).
- **Menus and popovers** only exist while the pointer holds them open. Nobody
  has captured one this way yet. Take their sizes from the code.
- **A locked screen** gives no surfaces and an empty capture.
- Screen Recording or Accessibility refused though it shows as granted:
  `macos/docs/debugging.md`.

Put the copy away as `test-copy` says (its keeper outlives it), then
`defaults delete $ID`.

## 3. Change the canvas

The working canvas is the one named in `web/README.md`. `opmaak open` it once.

- **Numbers come from the code first.** A value with a name in `Chrome.swift`
  is copied from there. Pixels are for what the system draws: materials, label
  colours, the padding inside a system control.
- **Work outward.** A token, then the component on the Components sheets, then
  the pane, then every state that holds that pane. States are copies, not
  links: `opmaak find` lists them, and `opmaak edit` takes several nodes at
  once. `Foggy Lake` and the shots are copies too.
- **Light and dark twins keep the same markup.** Colour differs through tokens
  and `dark:` classes only. The site draws one markup in both schemes, so a
  twin that differs is a difference the site cannot show. `regen.sh` reports it.
- **Layer names are an interface.** The site's scripts find rows, dots and
  buttons by them. Don't rename a layer. `regen.sh` reports a name that went
  missing.
- **What the owner changed stays.** `opmaak log` says who changed what.
- **Compare, don't judge by eye.** A state is 1510 wide with the window inset
  100, so at 2x the window is the crop below:

  ```sh
  opmaak render "Terminal · Dark" --scale 2 --out canvas.png
  magick canvas.png -crop 2620x1630+200+200 +repage canvas-win.png
  magick compare -metric AE -fuzz 4% shot.png canvas-win.png diff.png
  ```

  With no tab open on the canvas the server draws it, with its own fonts and
  without some glyphs. Boxes are right, text is not. For type and glyphs, have
  the canvas open in a tab, or compare boxes only.

Measured once already, so don't measure again (the rest is in `DESIGN.md`):

- Ghostty snaps the SF Mono 14 cell to 17 device pixels, so a cell is 8.5 by
  19pt and terminal text takes `tracking-[-0.155px]`. Glyphs from a fallback
  font (⎿ ● ❯) get a cell of their own, and rows of `─` are 1px lines.
- A system label carries 2pt of padding each side. Tab titles start at 36, not
  34.
- A span directly inside a div does not take the div's font size on the
  canvas. Put the size on the span. Nested spans are refused.
- Terminal text is written as logical lines that wrap, not as rows, so a
  window can be resized. Rows stay on the grid from the top.
- Glyphs are SF Symbols rendered to white 2x PNGs and used as masks over a
  token, so one image serves both themes.

End the turn on the canvas with `opmaak done --summary "…"`, and say in it
what you did not check.

`DESIGN.md` also names a public copy of the canvas. It is not a mirror: it was
duplicated from the working canvas on 2026-11-11, sorted onto canvases of its
own, and edited separately since (a newer site screenshot in the Browser pane,
a DMG window, lake frames). On 2026-11-19 the maintainer chose the working
canvas as the one this skill keeps current. Don't touch the public copy
unasked.

**Before a large change, ask for a backup.** The studio's web UI duplicates a
whole document; the `opmaak` command cannot. The maintainer does it there.

## 4. Regenerate the site

```sh
cd web
scripts/opmaak/regen.sh          # writes src/app/gen, fetches new images
npm run dev                      # then look, in light and dark
../scripts/check.sh web
```

Read every `note` line it prints. A new pane needs a row in the script's table
and a component that imports the file. Then look at each film on the homepage
the way `web/AGENTS.md` says to: both themes, a phone width, zoomed in. The
site adds a few things on top of the canvas (the Claude Code header, whole
rows only, its own window edge). `web/README.md`, "1:1 with the canvas", lists
them, and a regenerated window has to survive each one.

## 5. The words

For everything in step 1 that someone would look up: is it on wortel.sh/docs,
and is what the homepage says still true? `web/src/data/site.ts` holds the
command table, the shortcuts table, `DOCS_SECTIONS` and the FAQ. Leave out what
has not shipped: the site describes the released app, and the release skill
adds the rest at release time. If a value in `Chrome.swift` changed, its row in
`DESIGN.md` changes too.

## 6. Move the marker

`web/scripts/opmaak/synced` names the commit the canvas now shows. Set `app` to
the commit you built in step 2, `canvas` to the revision `opmaak log` ends on,
and `date` to today. Move it only when every commit in step 1 is drawn or left
out on purpose, and list what was left out in the commit body. If you stopped
halfway, leave the marker where it is and say so.

One commit for the site: the regenerated files, new images, the marker and any
doc that changed. `Canvas: the sidebar and Settings as they are in 2026.47.3`.
Deploying the site is a separate thing, and asked for each time.
