// The marks the canvas draws on its rendered plan ("Mark-up, a plan"), kept
// on what they mark at any width.
//
// The canvas places the three in the points of the plan as it drew it: a
// preview of 650 or more, its column 602 wide. In a narrower one the plan
// wraps, and a mark left where it was would lie over other words. So there
// each is put over the same thing again, found in the plan itself: the box
// around steps 2 and 3, the arrow's tip at the end of "Checks", the
// highlight on "without a stutter". At 650 and up the canvas's own places
// are left alone.
//
// /mark-up's second film (scripts/surfaces.ts) and its "A drag draws on
// anything" tile (components/markup/Tiles.astro) both show the plan narrower
// than it was drawn.
import { named } from './app';

/** Where some words are drawn inside `root`: on one line one box, over two the longer part. */
export function phrase(root: Element, words: string) {
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    const at = (n.textContent || '').indexOf(words);
    if (at < 0) continue;
    const range = document.createRange();
    range.setStart(n, at); range.setEnd(n, at + words.length);
    return Array.from(range.getClientRects()).sort((a, b) => b.width - a.width)[0] ?? null;
  }
  return null;
}

/**
 * The plan's three marks, in a rendered plan (`doc`, the canvas's "Markdown").
 * Returns the column they are placed against, and a function that places
 * them for the plan's width as it is now: call it when that changes.
 */
export function planMarks(doc: HTMLElement) {
  const [boxed, arrow, glow] = [1, 2, 3].map((i) => named(doc, `Mark ${i}`)!);
  const ink = named(glow, 'Ink')!;
  // Found once, while the marks are drawn: a hidden one has no offset parent.
  const column = (boxed.offsetParent ?? doc.firstElementChild) as HTMLElement;
  const place = () => {
    for (const el of [boxed, arrow, glow, ink]) for (const k of ['left', 'top', 'width', 'height'] as const) el.style[k] = '';
    if (!doc.clientWidth || doc.clientWidth >= 650) return;
    const o = column.getBoundingClientRect();
    const items = Array.from(doc.querySelectorAll<HTMLElement>('[data-name="Item"]')).slice(1, 3).map((el) => el.getBoundingClientRect());
    const heading = phrase(doc, 'Checks'), words = phrase(doc, 'without a stutter');
    if (items.length === 2) Object.assign(boxed.style, { left: `${items[0].left - o.left - 7.5}px`, top: `${items[0].top - o.top - 4.5}px`, width: `${Math.max(items[0].width, items[1].width) + 15}px`, height: `${items[1].bottom - items[0].top + 9}px` });
    // The arrow's tip is 4.5 in and 37 down in its own box (the canvas's Ink).
    if (heading) Object.assign(arrow.style, { left: `${heading.right + 12 - 4.5 - o.left}px`, top: `${(heading.top + heading.bottom) / 2 - 37 - o.top}px` });
    if (words) {
      Object.assign(glow.style, { left: `${words.left - o.left}px`, top: `${(words.top + words.bottom) / 2 - 10 - o.top}px`, width: `${words.width + 10}px` });
      ink.style.width = `${words.width}px`;
    }
  };
  return { column, marks: [boxed, arrow, glow], place };
}
