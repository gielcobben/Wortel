# Brand

The name, the mark, and what Wortel looks like, in the app and on the site.
Read this before making anything a person will see. The design system itself,
with its numbers, is `DESIGN.md` at the root. For how it sounds, see `voice.md`.

## The name

**Wortel is Dutch for root.** The root of a plant, the part below the surface
that holds everything up. And the root shell, where the real work happens.
`wortel.sh` reads as "root shell".

- It is not "carrot", although the word means that too. No carrots, no orange,
  no vegetables, no mascot. Where an old asset leans that way it is a leftover.
- The app is **Wortel**. The command is `wortel`, lowercase, in code type.
- The name follows a house habit: one short Dutch word that means two things.
  Keep that in mind if something here ever needs naming.
- A rename to another name was built on a branch in July 2026 and parked. On
  `main` it is Wortel. Don't move that along.

## The mark

The mark is the app icon: a near-black tile, a white lowercase **w**, and a
blue block cursor beside it.

- The source is `macos/Wortel/AppIcon.icon`, an Icon Composer file. It is the
  only source.
- **Never redraw it, restyle it or approximate it.** Every icon on the site is
  exported from that file (`web/README.md` has the `ictool` commands). An icon
  drawn for the site was rejected on sight.
- The cursor's blue is the brand's one accent colour, everywhere.

## The look, in one line

Quiet, native and exact. It should look like it came with the Mac.

The taste it answers to is Apple's own pro-app pages and the restraint of sites
like linear.app, polar.sh and cursor.com: one idea per screen, real product,
nothing decorative.

## The app

The app has no look of its own to invent. It looks like macOS, and the terminal
looks like Ghostty.

- **Type:** SF Mono Medium, 14pt, in the terminal. The system font everywhere
  else.
- **Colour:** GitHub Light Default and GitHub Dark Default, following the
  system's appearance, live. Nothing else is themed.
- **Cursor:** a block that does not blink.
- **Chrome:** one behind-window material under everything; only the pages (the
  terminal, the column) are opaque. The titlebar is Wortel's own flat band, so
  toolbar items don't sit on glass capsules. Selection in the sidebar is a
  neutral pill, since the sidebar never holds the keyboard.
- **Motion:** a session switch is instant. Panes snap when a switch changes
  them. Terminals don't resize during an animation.
- **Signals:** a dot, a spinner, a ring. Colour means something or isn't there.

All of it is fixed in `macos/Resources/wortel.conf` and the code. "Decided
once" is the brand as much as the palette is.

## The site

**A foggy lake at first light.** Warm fog whites for the page, ink for type,
sampled from the photograph the windows stand on. At night, the same lake in
the dark. The header of `web/src/styles/site.css` is the design system, and it
is short. Read it before adding anything.

The palette, the type scale and every measurement are in `DESIGN.md`. In short:

- **Colour:** fog whites, ink, and one accent, the cursor's blue.
- **Type:** the system's own. SF Pro for text and display, SF Mono for code. No
  web fonts.
- **Layout:** one container. Headings and visuals start at the left edge, and
  what there is to read about a heading starts beside it: at the middle of the
  page on the homepage, and after a narrow column of names on a page of text.
  Nothing is centred.
- **Grid:** every margin, padding, gap and fixed height is a multiple of 8.
  Hairlines, radii, font sizes and measured widths are exempt.
- **Headings are two-tone, light and short:** the claim in ink, its other half
  in grey on the line under it. Size and tone carry the hierarchy, not weight.
- **Every section opens the same way:** a hairline, the heading at the left, a
  short paragraph at the right. Then what it shows.
- **Photos:** four, all misty water and hills, chosen by colour to sit with the
  lake (`web/README.md`, Photos). Neighbouring sections never share one.
- **Motion:** arrives softly, answers quickly, never hijacks the scroll. The
  rules are in `web/README.md`, Motion and interaction.

### The app on the site is the app

Every window on the site is the real interface, built from the design canvas as
live HTML at the app's own sizes.

- **1:1, never scaled.** A shorter window is fine. A zoomed one is not.
- **Never a screenshot** where a window can stand, and never half a row.
- **It follows the page:** a light window on the light page, dark at night.
- **Details are judged at pixel level.** Traffic lights are true circles. A
  window has one hairline, snapped to the device pixel. Before calling a visual
  done, zoom in on the corners, the lights, the tab labels and the last row.

## Never

- Gradients, glows, blur as decoration, glass for its own sake.
- A dark, centred, "AI product" page. It was built once and rejected whole.
- Illustration, mascots, emoji, stock imagery of people.
- A second accent colour.
- Invented numbers, invented testimonials, invented icons.
- Anything that scales, crops or fakes the app.

## Before you ship something visible

1. Is it on the grid, and on the left edge or the reading column?
2. Is the only colour the accent, and does it mean something?
3. Is every app visual the real one, at 1:1, in both light and dark?
4. Did you look at it zoomed in?
5. Would it look at home on a Mac?
