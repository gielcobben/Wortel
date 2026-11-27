// Tools for acting on the generated app windows (src/app/gen). The markup comes
// from the Opmaak canvas and keeps each layer's name as data-name, so a scene
// can find "the Landing page hero row" or "the Terminal" and do to it what the
// real app would: select it, give it a status, print a line. Everything here
// clones the canvas's own nodes, so nothing a scene adds is styled by hand.
import { gsap } from 'gsap';

export const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

export const named = (root: ParentNode, name: string) =>
  root.querySelector<HTMLElement>(`[data-name="${name}"]`);

// ---- whole rows only ------------------------------------------------------
// A terminal never shows half a row of text and a marketing window should not
// show half a sidebar row either. These hide what does not fit, and put it back
// when there is room. They mark what they hid, so they never undo a scene's
// own `hidden`.

const unfit = (root: Element) => {
  root.querySelectorAll<HTMLElement>('[data-fit]').forEach((el) => { el.style.display = ''; delete el.dataset.fit; });
  // A sidebar header's worked-out height (fitSidebar) goes back to the canvas's.
  root.querySelectorAll<HTMLElement>(':scope > [data-name^="Section "]').forEach((el) => { el.style.height = ''; });
};
const drop = (el: HTMLElement) => { el.style.display = 'none'; el.dataset.fit = ''; };
const shown = (el: Element) => !(el as HTMLElement).hidden && (el as HTMLElement).style.display !== 'none';

// A terminal makes room by scrolling, not by taking rows out. The rows that
// no longer fit stay where they are, unseen, and the box (which clips, and so
// can be scrolled by script) is scrolled past them to a row's edge. To the
// eye that is the same as removing them. To the browser it is not: rows taken
// out move every row under them, which Chrome counts as layout shift, and a
// film that prints a line a second ran the homepage's score on a phone to
// 0.108, over the 0.1 that counts as good. Scrolled, it counts nothing
// (measured 2026-11-24, both ways, in the same terminal).
const TUCKED = ['visibility', 'marginTop', 'marginBottom', 'minHeight'] as const;
const untuck = (root: HTMLElement) => {
  root.querySelectorAll<HTMLElement>('[data-fit]').forEach((el) => {
    for (const k of TUCKED) el.style[k] = '';
    el.style.display = '';
    delete el.dataset.fit;
  });
  if ('fitTop' in root.dataset) { root.style.justifyContent = ''; delete root.dataset.fitTop; }
  root.scrollTop = 0;
};
const mark = (el: HTMLElement) => { el.dataset.fit = ''; return el; };
const drawn = (el: HTMLElement) => shown(el) && el.getClientRects().length > 0;

/**
 * Put the oldest rows of a terminal out of sight until what is left fits whole.
 * A terminal that says so (data-reserve, in points) is scrolled a little
 * further, so that much stays clear under its last line: room for something a
 * scene shows over the terminal without covering a line of it.
 */
export function fitTerminal(root: HTMLElement) {
  untuck(root);
  const all = (Array.from(root.children) as HTMLElement[]).filter(drawn);
  // The spacer the canvas ends some terminals with: room, not a row.
  const rest = all.find((r) => r.dataset.name === 'Rest');
  const rows = all.filter((r) => r !== rest);
  // What is pinned to the bottom: Claude's prompt box, and the status line
  // over it while the agent works. Everything above is the transcript.
  let end = rows.findIndex((r) => r.dataset.name === 'Status');
  if (end < 0) end = rows.findIndex((r) => r.dataset.name === 'Rule');
  // With neither, the transcript ends at the spacer: what is under it
  // (another agent's input box and status lines) stays where it is.
  const upto = end >= 0 ? end : rest ? all.indexOf(rest) : rows.length;
  // A screen that keeps what the agent said in one box (data-rows: Codex's
  // and Pi's) gives up those rows one at a time, not the box at once: on a
  // narrow window that left the input box under an empty terminal.
  const body = rows.slice(0, upto)
    .flatMap((r) => ('rows' in r.dataset ? (Array.from(r.children) as HTMLElement[]).filter(drawn) : [r]));
  const pinned = end < 0 ? null : rows[end];
  const cs = getComputedStyle(root);
  const room = root.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom);
  const used = rows.reduce((h, r) => h + r.offsetHeight, 0);
  const fits = room - (Number(root.dataset.reserve) || 0);
  if (used <= fits + 0.5) return;

  const max = body.length;
  let i = 0, gone = 0;
  const tuck = () => { gone += body[i].offsetHeight; mark(body[i++]).style.visibility = 'hidden'; };
  while (i < max && used - gone > fits + 0.5) tuck();
  if (!i) return;
  // Having cut, do not open on an empty row, or on a result whose tool line went.
  while (i < max && (!body[i].textContent?.trim() || body[i].dataset.name === 'Result')) tuck();

  // The room left over once whole rows are gone. Where it goes is where the
  // terminal had it before: over the prompt box, under the last line of a
  // screen with no box, or at the top of one the canvas fills from the bottom.
  const spare = Math.max(0, room - (used - gone));
  const fromBottom = cs.justifyContent === 'flex-end' && !pinned && !rest;
  // A box filled from the bottom overflows upwards, where nothing can scroll.
  if (cs.justifyContent === 'flex-end') { root.style.justifyContent = 'flex-start'; root.dataset.fitTop = ''; }
  let to = gone;
  if (pinned) mark(pinned).style.marginTop = `${spare}px`;
  else if (rest) mark(rest).style.minHeight = `${spare}px`;
  else if (fromBottom) to = gone - spare;
  else if (body.length) {
    const last = mark(body[body.length - 1]);
    last.style.marginBottom = `${spare}px`;
    // Not every engine counts a last row's margin as something to scroll to.
    if (root.scrollHeight - root.clientHeight < to - 0.5) { last.style.marginBottom = ''; last.style.minHeight = `${last.offsetHeight + spare}px`; }
  }
  root.scrollTop = to;
}

/**
 * Hide the last rows of a sidebar until the list fits, and no folder is left
 * without its rows. The selected row and its section's header stay: the app
 * lists the sessions in no folder last, so the session a window is showing is
 * often at the end, and a window whose own session is cut reads as wrong.
 */
export function fitSidebar(nav: HTMLElement, also?: HTMLElement) {
  unfit(nav);
  const all = Array.from(nav.children) as HTMLElement[];
  const head = (r: HTMLElement) => !!r.dataset.name?.startsWith('Section ');
  // The 14pt between sections belongs to the last row of an open section, so
  // a header after a folded or cut one sits close (as in the app since
  // 82992ca). The canvas writes it as the header's height, fixed for the
  // order it drew, so it is worked out again for what is shown, before every
  // measurement: a fit measured with the old heights can still overflow.
  const gaps = () => {
    let prev: HTMLElement | null = null;
    for (const r of all) {
      if (!shown(r)) continue;
      if (head(r)) r.style.height = `${prev && !head(prev) ? 44 : 30}px`;
      prev = r;
    }
  };
  const rows = all.filter(shown);
  // The selected row, and a row a scene is about to point at or select.
  const keep = new Set<HTMLElement>();
  for (const at of [rows.findIndex((r) => r.querySelector(':scope > [data-name="Pill"]')), also ? rows.indexOf(also) : -1]) {
    if (at < 0) continue;
    keep.add(rows[at]);
    for (let k = at; k >= 0; k--) if (head(rows[k])) { keep.add(rows[k]); break; }
  }
  // A folder header whose rows were all cut goes with them, at once, so the
  // room it frees counts. A folded one had no rows to cut.
  const orphans = () => rows.forEach((r, i) => {
    if (!head(r) || keep.has(r) || 'fit' in r.dataset) return;
    const mine: HTMLElement[] = [];
    for (let k = i + 1; k < rows.length && !head(rows[k]); k++) mine.push(rows[k]);
    if (mine.length && mine.every((m) => 'fit' in m.dataset)) drop(r);
  });
  gaps();
  for (let i = rows.length - 1; i > 0 && nav.scrollHeight > nav.clientHeight; i--) {
    if (keep.has(rows[i]) || 'fit' in rows[i].dataset) continue;
    drop(rows[i]);
    orphans();
    gaps();
  }
}

// ---- a picture drawn twice ----------------------------------------------------
/**
 * A pane that carries a picture in both colour schemes holds two images, one
 * hidden by class (dark:hidden, and hidden dark:block). A hidden image is
 * still fetched once it is no longer lazy, so of each such pair only the one
 * the colour scheme shows keeps its address; the other gets it back when the
 * scheme changes. Call it before the stage nears (scripts/reveal.ts).
 */
export function schemePictures(root: ParentNode) {
  const dark = matchMedia('(prefers-color-scheme: dark)');
  const all = Array.from(root.querySelectorAll<HTMLImageElement>('img')).filter((img) => /(^|\s)dark:(hidden|block)(\s|$)/.test(img.className));
  const pick = () => all.forEach((img) => {
    const mine = img.classList.contains('dark:block') === dark.matches;
    if (!mine && img.getAttribute('src')) { img.dataset.src = img.getAttribute('src')!; img.removeAttribute('src'); }
    if (mine && img.dataset.src) { img.src = img.dataset.src; delete img.dataset.src; }
  });
  pick();
  dark.addEventListener('change', pick);
}

/**
 * The page a browser split shows is the canvas's picture of this site at 537
 * points. It was taken before the hero's stage had arrived, so under the
 * buttons it shows an empty box where the window on the lake is. These are a
 * retake, this site at the same width with the hero held
 * (public/img/page-narrow-*.webp, README): the same layout to the point, so
 * whatever the canvas drew over the page is where it was. Call it after
 * schemePictures, which keeps the address of the picture not in use in
 * data-src.
 */
export function retaken(imgs: Iterable<HTMLImageElement>) {
  for (const img of imgs) {
    const src = `/img/page-narrow-${img.classList.contains('dark:block') ? 'dark' : 'light'}.webp`;
    if (img.dataset.src) img.dataset.src = src; else img.src = src;
  }
}

// ---- a split's row of tabs --------------------------------------------------
// What the app works out from a row's width, worked out here the same way, so
// a pane drawn at one width on the canvas is right at another.
//
// The split buttons: shown while the row has 240 points of its own, which is
// its width less what stands before and after it (SplitPane.swift,
// roomForSplitButtons). Under that they go, and the tabs have the row.
//
// Tabs that do not fit, in the app's three steps (SideTabStrip.swift, plan):
// the tabs behind the one in front give up the room kept for their close
// button (data-short); then every tab gives way together, its title cut with
// an ellipsis, down to 130 points or its own width if that is less
// (data-short="squeeze", each tab's floor in --floor); and when they are all
// at their floors the row scrolls to the tab in front, its other end under a
// 20 point fade, with the "+" still after the last tab (data-over). A row
// whose front tab is its last is scrolled to its end. One whose front tab is
// its first stays where it is and fades at the far end (data-over="end"),
// though the "+" is then out of sight, where the app would pin it: only the
// hero's row at a tablet's width gets there. The styles are in site.css.
const SPLIT_ROOM = 240;
const BACK_AND_FORWARD = 60 + 8;
const TAB_FLOOR = 130;
function fitBar(bar: HTMLElement) {
  const tabs = bar.querySelector<HTMLElement>(':scope > [data-name="Tabs"]');
  // A row that is not drawn (a pane in a template, a hidden window) has no width to go by.
  if (!tabs || !bar.offsetWidth) return;
  const pair = bar.querySelector<HTMLElement>(':scope > [data-name="Split buttons"]');
  if (pair) {
    const gap = parseFloat(getComputedStyle(bar).columnGap) || 0;
    let room = tabs.offsetWidth + (pair.offsetWidth ? pair.offsetWidth + gap : 0);
    // On a phone Back and Forward are left out of a folded window's row
    // (site.css). The app has them, so its row is that much shorter.
    const arrows = bar.querySelector<HTMLElement>('[data-lead] [data-name="Back and Forward"]');
    if (arrows && !arrows.offsetWidth) room -= BACK_AND_FORWARD;
    const hides = room < SPLIT_ROOM;
    // A zoomed split's row has Show All Splits after the two, and keeps it
    // when they go (SplitPane.swift, fitSplitButtons).
    const unzoom = pair.querySelector<HTMLElement>(':scope > [data-name="Show All Splits"]');
    const keeps = !!unzoom && !unzoom.hidden;
    for (const b of Array.from(pair.children) as HTMLElement[]) if (b !== unzoom) b.hidden = keeps && hides;
    pair.hidden = hides && !keeps;
  }
  const kids = (Array.from(tabs.children) as HTMLElement[]).filter((k) => k.dataset.name && k.offsetWidth);
  const first = kids[0], last = kids[kids.length - 1];
  // Measured to the fraction: a whole-pixel sum can call a row that fits too long.
  const over = () => !!first && last.getBoundingClientRect().right - first.getBoundingClientRect().left > tabs.getBoundingClientRect().width + 0.5;
  delete tabs.dataset.short; delete tabs.dataset.over;
  if (!over()) return;
  tabs.dataset.short = '';
  if (!over()) return;
  const named = kids.filter((k) => k.dataset.name!.endsWith(' tab'));
  // To the fraction of a point: a floor rounded down cuts a title that fits.
  // A tab alone in its row has nothing to scroll past, so it has no floor
  // and its title is cut as far as the row needs (a phone's window is
  // narrower than the app's can be made).
  const alone = named.length === 1;
  named.forEach((k) => k.style.setProperty('--floor', alone ? '0px' : `${Math.min(parseFloat(getComputedStyle(k).width) || k.offsetWidth, TAB_FLOOR)}px`));
  tabs.dataset.short = 'squeeze';
  // The tab in front is the one with a fill: the titlebar's, or a band row's.
  const front = named.find((k) => k.classList.contains('bg-sidebar-accent') || k.classList.contains('bg-card'));
  if (!over() || !front) return;
  if (front === named[named.length - 1]) tabs.dataset.over = '';
  else if (front === named[0]) tabs.dataset.over = 'end';
}

/** Keep every split's row in `root` to what fits it, now and as it resizes. */
export function fitBars(root: ParentNode) {
  const ro = new ResizeObserver((entries) => entries.forEach((e) => fitBar((e.target as HTMLElement).parentElement!)));
  // A row's tabs take whatever the row has left, so their box changes with
  // the row's width, its insets, and anything put in beside them. What does
  // not change it is a tab's own title, which a scene rewrites when the
  // session changes: that is watched for apart. Fitting writes attributes
  // and styles only, which neither of the two watches.
  root.querySelectorAll<HTMLElement>('header > [data-name="Tabs"]').forEach((t) => {
    ro.observe(t);
    new MutationObserver(() => fitBar(t.parentElement!)).observe(t, { childList: true, subtree: true, characterData: true });
  });
}

/** Keep every terminal and sidebar inside `root` to whole rows, now and as it resizes. A row of tabs is kept to what fits it too (fitBars). */
export function wholeRows(root: ParentNode) {
  fitBars(root);
  const terms = Array.from(root.querySelectorAll<HTMLElement>('[data-name="Terminal"], [data-name="Strip terminal"]'));
  const navs = Array.from(root.querySelectorAll<HTMLElement>('[data-name="Sessions"]'));
  terms.forEach((t) => { if (t.dataset.name === 'Terminal') withHeader(t); });
  const run = () => { terms.forEach(fitTerminal); navs.forEach((n) => fitSidebar(n)); };
  run();
  const ro = new ResizeObserver(run);
  [...terms, ...navs].forEach((el) => ro.observe(el));
  // A terminal fits itself again whenever what it holds changes, before the
  // next paint. A scene that shows a line it had hidden, or prints without
  // asking for a fit, used to get away with it because the box was filled
  // from the bottom; scrolled, a stale fit would push the prompt box out of
  // sight. Fitting only writes styles and its own marks, which this does not
  // watch, so it cannot set itself off.
  // A spinner turning its glyph is not a change of rows: the glyphs are one
  // cell wide, and fitting on each turn ran a layout 12 times a second for
  // as long as the page was open.
  const turning = (n: Node) => !!(n instanceof Element ? n : n.parentElement)?.closest('[data-pi-spin], [data-claude-spin]');
  for (const t of terms) {
    new MutationObserver((changes) => { if (changes.some((c) => !turning(c.target))) fitTerminal(t); })
      .observe(t, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['hidden'] });
  }
  document.fonts?.ready.then(run);
}

// ---- a window on a phone ----------------------------------------------------
/**
 * On a phone a window is as wide as the stage and its sidebar is folded
 * (styles/site.css). Folded, the app moves the traffic lights to the window
 * and gives the main bar Show Sidebar, Back and Forward: this puts both in,
 * marked so only a phone shows them. The lights are the sidebar's own, and
 * the buttons the canvas's (components/Lead.astro, in the stage's template).
 * The window says it folds in its markup (data-narrow), so the sidebar is gone
 * from the first paint and nothing moves when this runs.
 */
export function foldable(win: HTMLElement, lead?: DocumentFragment | null) {
  const lights = win.querySelector<HTMLElement>('[data-name="Traffic lights"]');
  const bar = win.querySelector<HTMLElement>('header[data-name="Main bar"]');
  if (!lights || !bar || !lead) return;
  const mine = lights.cloneNode(true) as HTMLElement;
  mine.dataset.narrowOnly = '';
  mine.style.zIndex = '5';
  win.append(mine);
  const buttons = (lead.cloneNode(true) as DocumentFragment).firstElementChild as HTMLElement;
  buttons.dataset.narrowOnly = '';
  bar.prepend(buttons);
}

// ---- the start of a Claude Code session ------------------------------------
// What a session opens with, as Claude Code 2.1 draws it in a 60-column
// terminal (captured from a real session in a pty): the mascot in block
// characters, the version, the model and the folder, then two empty rows.
// The mascot is the captured cells drawn as shapes, one 8.5 by 19 point cell
// each, so its blocks meet the way a terminal's do instead of leaving the
// gaps a font's block glyphs leave between lines.

const MASCOT = '<svg width="76.5" height="57" viewBox="0 0 76.5 57" aria-hidden="true"><path fill="#000" d="M17 0h8.5v19h-8.5zM25.5 0h8.5v19h-8.5zM34 0h8.5v19h-8.5zM42.5 0h8.5v19h-8.5zM51 0h8.5v19h-8.5zM59.5 0h8.5v19h-8.5zM17 19h8.5v19h-8.5zM25.5 19h8.5v19h-8.5zM34 19h8.5v19h-8.5zM42.5 19h8.5v19h-8.5zM51 19h8.5v19h-8.5z"/><path fill="#d77757" d="M12.75 0h4.25v9.5h-4.25zM12.75 9.5h4.25v9.5h-4.25zM17 0h4.25v9.5h-4.25zM21.25 0h4.25v9.5h-4.25zM17 9.5h4.25v9.5h-4.25zM25.5 0h4.25v9.5h-4.25zM29.75 0h4.25v9.5h-4.25zM25.5 9.5h4.25v9.5h-4.25zM29.75 9.5h4.25v9.5h-4.25zM34 0h4.25v9.5h-4.25zM38.25 0h4.25v9.5h-4.25zM34 9.5h4.25v9.5h-4.25zM38.25 9.5h4.25v9.5h-4.25zM42.5 0h4.25v9.5h-4.25zM46.75 0h4.25v9.5h-4.25zM42.5 9.5h4.25v9.5h-4.25zM46.75 9.5h4.25v9.5h-4.25zM51 0h4.25v9.5h-4.25zM55.25 0h4.25v9.5h-4.25zM51 9.5h4.25v9.5h-4.25zM59.5 0h4.25v9.5h-4.25zM63.75 0h4.25v9.5h-4.25zM59.5 9.5h4.25v9.5h-4.25zM63.75 9.5h4.25v9.5h-4.25zM4.25 19h4.25v9.5h-4.25zM8.5 19h4.25v9.5h-4.25zM12.75 19h4.25v9.5h-4.25zM12.75 28.5h4.25v9.5h-4.25zM17 19h4.25v9.5h-4.25zM21.25 19h4.25v9.5h-4.25zM17 28.5h4.25v9.5h-4.25zM21.25 28.5h4.25v9.5h-4.25zM25.5 19h4.25v9.5h-4.25zM29.75 19h4.25v9.5h-4.25zM25.5 28.5h4.25v9.5h-4.25zM29.75 28.5h4.25v9.5h-4.25zM34 19h4.25v9.5h-4.25zM38.25 19h4.25v9.5h-4.25zM34 28.5h4.25v9.5h-4.25zM38.25 28.5h4.25v9.5h-4.25zM42.5 19h4.25v9.5h-4.25zM46.75 19h4.25v9.5h-4.25zM42.5 28.5h4.25v9.5h-4.25zM46.75 28.5h4.25v9.5h-4.25zM51 19h4.25v9.5h-4.25zM55.25 19h4.25v9.5h-4.25zM51 28.5h4.25v9.5h-4.25zM55.25 28.5h4.25v9.5h-4.25zM59.5 19h4.25v9.5h-4.25zM63.75 19h4.25v9.5h-4.25zM59.5 28.5h4.25v9.5h-4.25zM63.75 28.5h4.25v9.5h-4.25zM68 19h4.25v9.5h-4.25zM72.25 19h4.25v9.5h-4.25zM12.75 38h4.25v9.5h-4.25zM21.25 38h4.25v9.5h-4.25zM55.25 38h4.25v9.5h-4.25zM63.75 38h4.25v9.5h-4.25z"/></svg>';

/** The header a Claude Code session starts with. `path` is the folder, as Claude shortens it. */
export function claudeHeader(path = '~/Developer/wortel') {
  const head = document.createElement('div');
  head.dataset.name = 'Header';
  head.className = 'relative shrink-0 pt-[19px] pb-[38px]';
  head.innerHTML = MASCOT;
  (head.firstElementChild as SVGElement).setAttribute('style', 'position:absolute;left:0;top:19px');
  const row = (text: string, cls: string) => {
    const p = document.createElement('p');
    // It wraps in a window narrower than its longest line (a phone's).
    p.className = 'min-h-[19px] whitespace-pre-wrap [overflow-wrap:anywhere] pl-[93.5px] ' + cls;
    p.textContent = text;
    return p;
  };
  const first = row('', '');
  const name = document.createElement('span');
  name.className = 'font-bold';
  name.textContent = 'Claude Code';
  const ver = document.createElement('span');
  ver.className = 'text-[#666666] dark:text-[#999999]';
  ver.textContent = ' v2.1.322';
  first.append(name, ver);
  head.append(first,
    row('Opus 5.5 with high effort', 'text-[#666666] dark:text-[#999999]'),
    row(path, 'text-[#666666] dark:text-[#999999]'));
  return head;
}

/** Give a Claude terminal its header, once. */
export function withHeader(root: HTMLElement, path?: string) {
  if (root.querySelector(':scope > [data-name="Header"]') || !root.querySelector(':scope > [data-name="Prompt"]')) return;
  root.prepend(claudeHeader(path));
}

// ---- the sidebar ----------------------------------------------------------

/**
 * Show only part of a sidebar. The canvas draws a full one (six folders,
 * fifteen sessions), which is a power user's window: a window on the page
 * shows as much of it as its own story needs, and the page lets it grow from
 * a short flat list to folders and branches as it goes down.
 *
 * `layout` is what is shown, top to bottom: session names, and 'Section x'
 * for a header. Everything else is hidden. The rows are the canvas's own,
 * moved, so a session can be listed under another header than it was drawn.
 */
export function showSidebar(nav: HTMLElement, layout: string[]) {
  const keep = layout.map((name) => named(nav, name)).filter((r): r is HTMLElement => !!r);
  for (const el of Array.from(nav.children) as HTMLElement[]) el.hidden = !keep.includes(el);
  nav.append(...keep);
  fitSidebar(nav);
}

export type Status = 'working' | 'attention' | 'done' | 'none';

export class Sidebar {
  root: HTMLElement;
  nav: HTMLElement;
  private pill: HTMLElement;
  private working: HTMLElement;
  private attention: HTMLElement;
  selected: string;

  constructor(root: HTMLElement) {
    this.root = root;
    this.nav = named(root, 'Sessions')!;
    this.pill = named(root, 'Pill')!;
    this.selected = this.pill.parentElement!.dataset.name!;
    // The canvas has one of each status; they are the moulds for the rest.
    this.working = named(root, 'Working')!.parentElement!.cloneNode(true) as HTMLElement;
    this.attention = named(root, 'Attention')!.parentElement!.cloneNode(true) as HTMLElement;
  }

  /**
   * A session's row. One that fitSidebar cut is put back first (something else
   * goes instead), since a scene asks for a row to point at it or select it.
   */
  row(name: string) {
    const row = named(this.nav, name)!;
    if (row && 'fit' in row.dataset) fitSidebar(this.nav, row);
    return row;
  }

  /** Show only part of the sidebar (showSidebar). Before clickable(). */
  show(layout: string[]) { showSidebar(this.nav, layout); }

  /** The session rows, top to bottom (not the folder headers). */
  rows() {
    return (Array.from(this.nav.children) as HTMLElement[]).filter((r) => r.dataset.name && !r.dataset.name.startsWith('Section '));
  }

  /**
   * Move the selection to a row, the way a click does: at once, as the app
   * switches on the press. The session left goes on the Back list.
   */
  select(name: string) {
    const to = this.row(name);
    if (!to || name === this.selected) return;
    if (!this.walking) { this.back.push(this.selected); this.ahead = []; }
    to.prepend(this.pill);
    this.selected = name;
    this.arrows();
  }

  // ---- Back and Forward: the sessions you were on -----------------------------
  private back: string[] = [];
  private ahead: string[] = [];
  private walking = false;
  private go?: (name: string) => void;

  /** Make Back and Forward work. `go` switches the scene to a session. */
  navigable(go: (name: string) => void) {
    this.go = go;
    named(this.root, 'Back')?.addEventListener('click', () => this.walk(this.back, this.ahead));
    named(this.root, 'Forward')?.addEventListener('click', () => this.walk(this.ahead, this.back));
    this.arrows();
  }

  private walk(from: string[], to: string[]) {
    const name = from.pop();
    if (!name || !this.go) return;
    to.push(this.selected);
    this.walking = true;
    try { this.go(name); } finally { this.walking = false; }
    this.arrows();
  }

  /** A button with nowhere to go is drawn dimmed and does not press. */
  private arrows() {
    if (!this.go) return;
    for (const [name, list] of [['Back', this.back], ['Forward', this.ahead]] as const) {
      const button = named(this.root, name);
      const glyph = named(this.root, `${name} glyph`);
      if (!button || !glyph) continue;
      button.toggleAttribute('data-press', list.length > 0);
      glyph.classList.toggle('bg-sidebar-accent-foreground', list.length > 0);
      glyph.classList.toggle('bg-sidebar-ring', !list.length);
    }
  }

  /** Give a row a status the way the app marks one. */
  status(name: string, status: Status) {
    const row = this.row(name);
    row.querySelector('[data-name="Status"]')?.remove();
    if (status === 'none') { this.pulse(); return; }
    const el = (status === 'working' ? this.working : this.attention).cloneNode(true) as HTMLElement;
    if (status !== 'working') {
      const dot = el.firstElementChild as HTMLElement;
      dot.classList.remove('bg-chart-1', 'bg-chart-2');
      dot.classList.add(status === 'attention' ? 'bg-chart-1' : 'bg-chart-2');
      gsap.fromTo(dot, { scale: 0.5, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.35, ease: 'back.out(1.7)', clearProps: 'transform,opacity' });
      requestAnimationFrame(() => ping(dot));
    }
    row.classList.remove('pr-3'); row.classList.add('pr-[34px]');
    row.appendChild(el);
    this.pulse();
  }

  private pulseTween?: gsap.core.Tween;
  /** Working dots breathe, in turn. Re-run after statuses change. */
  pulse() {
    this.pulseTween?.kill();
    const dots = this.root.querySelectorAll('[data-name="Working"] > div');
    // No session at work: nothing to set, and GSAP warns about an empty target.
    if (!dots.length) return;
    gsap.set(dots, { opacity: 1 });
    if (!reduced()) {
      this.pulseTween = gsap.to(dots, { opacity: 0.2, duration: 0.5, ease: 'sine.inOut', stagger: { each: 0.18, repeat: -1, yoyo: true } });
    }
  }

  /** Make it answer to the pointer: rows select, folder headers fold. */
  clickable(onSelect: (name: string) => void) {
    for (const row of this.rows()) {
      row.dataset.row = '';
      row.addEventListener('click', () => onSelect(row.dataset.name!));
    }
    const all = Array.from(this.nav.children) as HTMLElement[];
    all.forEach((head, i) => {
      if (!head.dataset.name?.startsWith('Section ')) return;
      const mine: HTMLElement[] = [];
      for (let k = i + 1; k < all.length && !all[k].dataset.name?.startsWith('Section '); k++) mine.push(all[k]);
      if (!mine.length) return; // already folded on the canvas
      const hit = head.firstElementChild as HTMLElement;
      const chevron = named(head, 'Chevron');
      hit.dataset.fold = '';
      hit.addEventListener('click', () => {
        const folded = head.toggleAttribute('data-folded');
        mine.forEach((r) => (r.hidden = folded));
        if (chevron) gsap.to(chevron, { rotate: folded ? -90 : 0, duration: 0.2, ease: 'power2.out' });
        fitSidebar(this.nav);
      });
    });
  }
}

// ---- the terminal ---------------------------------------------------------

type Kind = 'You' | 'Claude' | 'Tool' | 'Result' | 'Worked';

export class Terminal {
  root: HTMLElement;
  private moulds = new Map<string, HTMLElement>();
  private anchor: Element;
  prompt: HTMLElement;

  constructor(root: HTMLElement) {
    this.root = root;
    for (const k of ['You', 'Claude', 'Tool', 'Result', 'Worked']) {
      const m = named(root, k);
      if (m) this.moulds.set(k, m.cloneNode(true) as HTMLElement);
    }
    // Lines are printed above the rule that opens the prompt box.
    this.anchor = named(root, 'Rule')!;
    this.prompt = named(root, 'Prompt')!;
    this.mode = named(root, 'Mode');
    withHeader(root);
  }

  mode: HTMLElement | null;

  /** The agent's lines, in order: everything above the prompt box. */
  lines() {
    const all = Array.from(this.root.children) as HTMLElement[];
    return all.slice(0, all.indexOf(this.anchor as HTMLElement));
  }

  fit() { fitTerminal(this.root); }

  clear() { this.lines().forEach((l) => l.remove()); }

  /** Replace what is on screen with another session's lines. */
  swap(nodes: HTMLElement[]) {
    this.clear();
    // Another agent's screen brings its own input box (codexScreen, piScreen):
    // Claude's is hidden while it is up (styles/app.css).
    const other = nodes.find((n) => n.dataset.agent)?.dataset.agent;
    if (other) this.root.dataset.agent = other; else delete this.root.dataset.agent;
    nodes.forEach((n) => this.root.insertBefore(n, this.anchor));
    this.fit();
  }

  /** Build a session's screen without showing it: its header, then what `fn` prints. */
  compose(fn: () => void, path?: string) {
    const keep = this.lines();
    this.clear();
    this.root.insertBefore(claudeHeader(path), this.anchor);
    fn();
    const made = this.lines();
    this.swap(keep);
    return made;
  }

  /** Print a line. `tool` is the bold verb of a tool line: Read, Bash, Update. */
  print(kind: Kind, text: string, tool?: string) {
    const p = this.moulds.get(kind)!.cloneNode(true) as HTMLElement;
    p.hidden = false; p.style.display = ''; delete p.dataset.fit;
    for (const k of TUCKED) p.style[k] = '';
    // Keep the glyph (the first span), replace what follows it.
    const glyph = p.firstElementChild!;
    while (glyph.nextSibling) glyph.nextSibling.remove();
    if (kind === 'Tool' && tool) {
      const verb = (this.moulds.get('Tool')!.children[1] as HTMLElement).cloneNode(false) as HTMLElement;
      verb.textContent = tool;
      p.append(verb, text);
    } else if (kind === 'Result' || kind === 'Worked') {
      const span = (this.moulds.get(kind)!.children[1] as HTMLElement).cloneNode(false) as HTMLElement;
      span.textContent = text;
      p.append(span);
    } else {
      p.append(text);
    }
    this.root.insertBefore(p, this.anchor);
    this.fit();
    return p;
  }

  /** An empty row between blocks, as the agent leaves one. */
  gap() {
    const d = document.createElement('div');
    d.className = 'h-[19px] shrink-0';
    this.root.insertBefore(d, this.anchor);
    return d;
  }

  /** A line with no glyph, the way a prompt's choices are printed. */
  plain(text: string, chosen = false) {
    const p = this.print('Claude', text);
    p.firstElementChild!.remove();
    if (chosen) p.style.color = 'var(--primary)';
    return p;
  }

  /** The status line while the agent works: just above the prompt box, the way
   *  Claude Code draws it, with "esc to interrupt" added to the mode line.
   *  Removing the returned line (or calling idle()) puts both back. */
  status(text: string, detail = 'thinking') {
    this.idle();
    const p = document.createElement('p');
    p.dataset.name = 'Status';
    p.className = 'relative shrink-0 whitespace-pre-wrap pl-[17px] pr-1 [overflow-wrap:anywhere]';
    p.innerHTML = '';
    // Its glyph steps through Claude Code's spinner, and the words shimmer.
    const glyph = document.createElement('span');
    glyph.className = 'claude-spin absolute top-0 left-[0px] text-[#d77757]';
    glyph.dataset.claudeSpin = '';
    glyph.textContent = '✽';
    const said = document.createElement('span');
    said.className = 'glimmer text-[#d77757]';
    said.textContent = text;
    const space = document.createTextNode(' ');
    const meta = document.createElement('span');
    meta.className = 'text-[#666666] dark:text-[#999999]';
    meta.textContent = `(${detail})`;
    p.append(glyph, said, space, meta);
    this.root.insertBefore(p, this.anchor);
    claudeSpin();
    if (this.mode && !this.mode.querySelector('[data-esc]')) {
      const esc = document.createElement('span');
      esc.dataset.esc = '';
      esc.className = 'text-[#666666] dark:text-[#999999]';
      esc.textContent = ' · esc to interrupt';
      this.mode.append(esc);
    }
    this.fit();
    return p;
  }

  /** The agent stopped: no status line, no "esc to interrupt". */
  idle() {
    this.root.querySelector(':scope > [data-name="Status"]')?.remove();
    this.mode?.querySelector('[data-esc]')?.remove();
  }
}

// Claude Code's spinner: the glyph steps out through these and back, as its
// own does. One timer for every spinner on the page, only while one is drawn.
const CLAUDE = ['·', '✢', '✳', '✶', '✻', '✽', '✻', '✶', '✳', '✢'];
let claudeTimer = 0;
function claudeSpin() {
  if (claudeTimer || reduced()) return;
  let k = 0;
  claudeTimer = window.setInterval(() => {
    const all = document.querySelectorAll<HTMLElement>('[data-claude-spin]');
    if (!all.length) { clearInterval(claudeTimer); claudeTimer = 0; return; }
    k = (k + 1) % CLAUDE.length;
    all.forEach((el) => { if (el.offsetParent) el.textContent = CLAUDE[k]; });
  }, 120);
}

/** An expanding ring from a status dot that just appeared: here is news. */
export function ping(dot: Element | null) {
  if (!dot || reduced()) return;
  const r = dot.getBoundingClientRect();
  if (!r.width) return;
  const ring = document.createElement('span');
  const color = getComputedStyle(dot).backgroundColor;
  ring.style.cssText = `position:absolute;inset:0;border-radius:50%;box-shadow:0 0 0 1.5px ${color};pointer-events:none`;
  (dot as HTMLElement).style.position = 'relative';
  dot.append(ring);
  gsap.fromTo(ring, { scale: 1, opacity: 0.9 }, { scale: 3.2, opacity: 0, duration: 0.9, ease: 'power2.out', onComplete: () => ring.remove() });
}

// ---- what each session on the canvas is doing -----------------------------
// The sidebar's sessions are the canvas's. Clicking one has to show something,
// so each has a request and where its agent has got to.

const SESSIONS: Record<string, [you: string, agent: string]> = {
  'Compass app icon for iOS 27': ['Redraw the Compass icon for the iOS 27 grid.', 'The needle sat a pixel off the new keyline. I moved it and exported all four sizes.'],
  'Icon grid survey and fixes': ['Survey the icon grid and fix what is off.', 'Three icons sit half a point low, and the metrics are computed in two places. Fixing both.'],
  'Sparkle appcast cleanup': ['Clean up the Sparkle appcast and the script that writes it.', 'The feed carries eleven entries nobody can update from any more. Trimming it to the last five.'],
  'Marketing screenshots': ['Retake the marketing screenshots in light and dark.', 'Six of nine done. The three with the browser pane need the new site first.'],
  'Landing page hero': ['Make the landing page hero load faster.', 'The photo was the slow part. I resized it and inlined the critical CSS.'],
  'Changelog typography': ['Tighten the changelog’s type.', 'Headings are on the 8px grid now, and long version numbers no longer wrap.'],
  'Pricing FAQ copy': ['Draft the pricing questions for the FAQ.', 'It is free, so there are two questions. Both are answered in a sentence.'],
  'Open Graph image refresh': ['Regenerate the Open Graph image from the new homepage.', 'Rendered at 1200 by 630 and checked in the three previewers that matter.'],
  'Agent tab computer cards': ['Lay out the computer cards on the Agent tab.', 'Two columns down to one below 640 points. The cards keep their ratio.'],
  'Compass app icon': ['Export the Compass icon for the Mac.', 'Layered file is in place. The Dock render matches the design at every size.'],
};

/** The screen of a session that has no scene of its own. */
export function sessionScreen(term: Terminal, name: string) {
  const [you, agent] = SESSIONS[name] || ['Pick this up where we left it.', 'On it.'];
  return term.compose(() => {
    term.print('You', you);
    term.gap();
    term.print('Claude', agent);
    term.gap();
  });
}

// ---- Codex and Pi, as they draw themselves ------------------------------------
// Captured from codex-cli 0.170.0 and pi 0.82.1 in a 100-column pty, a light
// terminal and a dark one (Codex doing a small real job; Pi's requests were
// refused by its provider, so its working line and dark colours are read off
// its own source and theme): what is drawn here is those screens, line for
// line and colour for colour. Only the folder and the requests are ours.
// A screen is a list of rows to hand to Terminal.swap; its first row says
// whose it is, so Claude's own input box is hidden while it is up.

type Part = [text: string, cls?: string];
/** A terminal row. A band runs the full width of the terminal, past its padding. */
export function termRow(parts: Part[], band = '') {
  const p = document.createElement('p');
  p.className = 'min-h-[19px] shrink-0 whitespace-pre-wrap [overflow-wrap:anywhere]' + (band ? ` -ml-[5px] -mr-[7.5px] pl-[5px] ${band}` : '');
  for (const [text, cls] of parts) {
    const span = document.createElement('span');
    if (cls) span.className = cls;
    span.textContent = text;
    p.append(span);
  }
  return p;
}
const blank = (band = '') => termRow([['']], band);
// The room between what an agent said and its input box. Named as the
// canvas names a terminal's spacer, so a fit gives it the room left over.
const spring = () => { const d = document.createElement('div'); d.className = 'flex-1'; d.dataset.name = 'Rest'; return d; };

const CX = {
  blue: 'text-[#1c64c8] dark:text-[#63a8f8]', file: 'text-[#40a02b] dark:text-[#a6e3a1]',
  dim: 'text-[#747679] dark:text-[#8f959b]', key: 'font-bold text-[#404348] dark:text-[#e6edf3]',
  model: 'text-[#a06c24] dark:text-[#f6e2b7]', path: 'text-[#3e862f] dark:text-[#abdfa7]',
  shimmer: 'text-[#8f9193] dark:text-[#797f85]', hint: 'text-[#666666] dark:text-[#999999]',
  add: 'text-[#00cd00]', del: 'text-[#cd0000]', ran: 'font-bold text-[#00cd00]',
  asked: 'bg-[#f9f9f9] dark:bg-[#33373c]', composer: 'bg-[#f4f4f4] dark:bg-[#2a2d32]',
};
/** Codex's lines, as it prints them. */
export const codex = {
  /** A sentence of its own. File names in it are drawn as Codex draws them. */
  say: (text: string) => termRow([['• '], ...text.split(/(\S+\.(?:swift|md|ts|json|yml))/).map((t, i): Part => [t, i % 2 ? CX.file : undefined])]),
  explored: (reads: string[]) => [
    termRow([['• '], ['Explored', 'font-bold']]),
    ...reads.map((f, i) => termRow([[i ? '    ' : '  └ '], ['Read', CX.blue], [` ${f}`]])),
    termRow([['    + Show details']]),
  ],
  edited: (file: string, add: number, del: number) => [
    termRow([['• '], ['Edited', 'font-bold'], [` ${file} (`], [`+${add}`, CX.add], [' '], [`-${del}`, CX.del], [')']]),
    termRow([['    + Show details']]),
  ],
  ran: (command: string, output: string) => [
    termRow([['•', CX.ran], [' '], ['Ran', 'font-bold'], [` ${command}`]]),
    termRow([[`  └ ${output}`]]),
  ],
  working: (seconds: number) => termRow([['•', 'font-bold'], [' '], ['Working', CX.shimmer], [` (${seconds}s • `], ['esc', CX.key], [' to interrupt)']]),
  worked: (took: string) => termRow([[`  Worked for ${took} • 9:41 AM`]]),
  blank,
};

const codexHeader = (path: string, first: HTMLElement) => [
  first,
  termRow([['  >_ ', CX.blue], ['OpenAI Codex', 'font-bold'], [' (v0.170.0)']]),
  termRow([[`     ${path}`]]),
];
const codexFoot = (path: string, field: HTMLElement) => [
  blank(CX.composer), field, blank(CX.composer), blank(),
  termRow([['  GPT-6-Luna default', CX.model], [' · ', CX.dim], [path, CX.path]]),
  termRow([['  ←', CX.key], [' for agents · ', CX.dim], ['?', CX.key], [' for shortcuts', CX.dim]]),
];

/** Codex just started: what it suggests, and its input box, which `type` fills. */
export function codexFresh(path = '~/Developer/wortel') {
  const typed = document.createElement('span');
  const hint = document.createElement('span');
  hint.className = CX.hint; hint.textContent = 'Ask Codex to do anything';
  const field = termRow([['›', 'font-bold'], [' ']], CX.composer);
  field.append(typed, hint);
  const top = termRow([['']]);
  top.dataset.agent = 'codex';
  const nodes = [
    ...codexHeader(path, top),
    blank(),
    termRow([['  To get started, describe a task or try one of these commands:']]),
    blank(),
    termRow([['  /init - create an AGENTS.md file with instructions for Codex']]),
    termRow([['  /status - show current session configuration']]),
    termRow([['  /permissions - choose what Codex is allowed to do']]),
    termRow([['  /model - choose what model and reasoning effort to use']]),
    termRow([['  /review - review any changes and find issues']]),
    spring(),
    ...codexFoot(path, field),
  ];
  return { nodes, type: (text: string) => { typed.textContent = text; hint.hidden = !!text; } };
}

/** A Codex session after a request: its header, the request, then `log`. */
export function codexScreen(asked: string, log: HTMLElement[] = [], path = '~/Developer/wortel') {
  const hint = document.createElement('span');
  hint.className = CX.hint; hint.textContent = 'Ask Codex to do anything';
  const field = termRow([['›', 'font-bold'], [' ']], CX.composer);
  field.append(hint);
  const top = termRow([['']]);
  top.dataset.agent = 'codex';
  const body = document.createElement('div');
  body.className = 'flex shrink-0 flex-col';
  body.dataset.rows = '';
  body.append(...log.flatMap((r, i) => (i && r.textContent?.startsWith('•') ? [blank(), r] : [r])));
  const nodes = [
    ...codexHeader(path, top),
    blank(), blank(),
    blank(CX.asked), termRow([['›', 'font-bold'], [` ${asked}`]], CX.asked), blank(CX.asked),
    blank(),
    body,
    spring(),
    ...codexFoot(path, field),
  ];
  // While it works: its working line under what it said. One empty row
  // separates blocks; the request already has one under it.
  let busy: HTMLElement[] = [];
  const said = () => body.childElementCount - busy.length > 0;
  const working = (seconds: number | null) => {
    busy.forEach((r) => r.remove());
    busy = seconds === null ? [] : [...(said() ? [blank()] : []), codex.working(seconds)];
    body.append(...busy);
  };
  /** Add a block to what it said, under the last, above its working line. */
  const add = (rows: HTMLElement[]) => {
    const at = busy[0] ?? null;
    [...(said() ? [blank()] : []), ...rows].forEach((r) => body.insertBefore(r, at));
    // The working line now has something above it: give it its empty row.
    if (busy.length === 1) { const gap = blank(); body.insertBefore(gap, busy[0]); busy.unshift(gap); }
  };
  return { nodes, body, working, add };
}

const PI = {
  accent: 'text-[#5a8080] dark:text-[#8abeb7]', dim: 'text-[#767676] dark:text-[#666666]',
  muted: 'text-[#6c6c6c] dark:text-[#808080]', rule: 'bg-[#5a8080] dark:bg-[#81a2be]',
  asked: 'bg-[#e8e8e8] dark:bg-[#343541]', tool: 'bg-[#e8f0e8] dark:bg-[#283228]',
  out: 'text-[#6c6c6c] dark:text-[#808080]',
};
/** Pi's lines, as it prints them (its components, read off its source). */
export const pi = {
  /** What it says: plain text, one column in. */
  say: (text: string) => [termRow([[` ${text}`]])],
  /** What you sent it: a box on the message colour. */
  you: (text: string) => [blank(PI.asked), termRow([[` ${text}`]], PI.asked), blank(PI.asked)],
  /** A finished tool: a box on the tool colour, its name bold, then its argument. */
  tool: (name: string, arg: string, output: string[] = []) => [
    blank(PI.tool),
    termRow([[' '], [name, 'font-bold'], [' '], [arg, name === 'read' || name === 'edit' ? PI.accent : 'font-bold']], PI.tool),
    ...output.map((o) => termRow([[` ${o}`, PI.out]], PI.tool)),
    blank(PI.tool),
  ],
};
// Pi's spinner turns every 80 ms, through the braille frames its loader uses.
const FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
let spinning = 0;
const spin = () => {
  if (spinning || reduced()) return;
  let k = 0;
  spinning = window.setInterval(() => {
    const all = document.querySelectorAll<HTMLElement>('[data-pi-spin]');
    if (!all.length) return;
    k = (k + 1) % FRAMES.length;
    all.forEach((el) => { if (el.offsetParent) el.textContent = FRAMES[k]; });
  }, 80);
};

/** A Pi session after a request: its header, the request, `log`, and while
 *  it works its spinner. */
export function piScreen(asked: string, log: HTMLElement[] = [], path = '~/Developer/wortel') {
  // A terminal draws box characters as one solid line; a browser's font
  // leaves gaps between them, so the rule is drawn as Claude's is.
  const rule = () => {
    const r = document.createElement('div');
    r.className = 'flex h-[19px] shrink-0 items-center';
    const l = document.createElement('div');
    l.className = `h-px w-full ${PI.rule}`;
    r.append(l);
    return r;
  };
  const top = termRow([['']]);
  top.dataset.agent = 'pi';
  const body = document.createElement('div');
  body.className = 'flex shrink-0 flex-col';
  body.dataset.rows = '';
  // Its editor, between the two rules: what you type goes here.
  const typed = document.createElement('span');
  const field = termRow([[' ']]);
  field.append(typed);
  const nodes = [
    top,
    termRow([[' '], ['pi', `font-bold ${PI.accent}`], [' v0.82.1', PI.dim]]),
    termRow([[' '], ['escape', PI.dim], [' interrupt · ', PI.muted], ['ctrl+c/ctrl+d', PI.dim], [' clear/exit · ', PI.muted], ['/', PI.dim], [' commands · ', PI.muted], ['!', PI.dim], [' bash · ', PI.muted], ['ctrl+o', PI.dim], [' more', PI.muted]]),
    termRow([[' Press ctrl+o to show full startup help and loaded resources.', PI.dim]]),
    blank(),
    termRow([[' Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.', PI.dim]]),
    blank(),
    blank(PI.asked), termRow([[` ${asked}`]], PI.asked), blank(PI.asked),
    body,
    spring(),
    rule(), field, rule(),
    termRow([[` ${path}`, PI.dim]]),
    termRow([[' $0.000 (sub) 0.0%/1.0M (auto)', PI.dim]]),
  ];
  // While it works: its loader, an empty row and the spinner line.
  let busy: HTMLElement[] = [];
  const working = (on: boolean) => {
    busy.forEach((r) => r.remove());
    if (!on) { busy = []; return; }
    const line = termRow([[' '], ['⠋', PI.accent], [' Working...', PI.muted]]);
    (line.children[1] as HTMLElement).dataset.piSpin = '';
    busy = [blank(), line];
    body.append(...busy);
    spin();
  };
  /** Add a component under the last, with the one empty row Pi leaves. */
  const add = (rows: HTMLElement[]) => {
    const at = busy[0] ?? null;
    [blank(), ...rows].forEach((r) => body.insertBefore(r, at));
  };
  log.forEach((r) => body.append(r));
  working(true);
  const type = (text: string) => { typed.textContent = text; };
  return { nodes, body, working, add, type };
}

// ---- hands ------------------------------------------------------------------

/** Press a cluster of keycaps: it appears, the keys dip, it leaves. */
export function pressKeys(tl: gsap.core.Timeline, keys: HTMLElement, at: number, hold = 0.9) {
  tl.fromTo(keys, { opacity: 0, y: 8, scale: 0.96 }, { opacity: 1, y: 0, scale: 1, duration: 0.25, ease: 'power2.out' }, at);
  tl.to(keys.querySelectorAll('kbd'), { y: 2, duration: 0.08, yoyo: true, repeat: 1 }, at + 0.4);
  tl.to(keys, { opacity: 0, y: -4, duration: 0.2, ease: 'power2.out' }, at + hold);
}

/** The pointer a film uses when the thing it shows is done with the mouse. */
export class Pointer {
  el: HTMLElement;
  private box: HTMLElement;
  private shownAt = false;

  constructor(box: HTMLElement) {
    this.box = box;
    this.el = document.createElement('div');
    this.el.className = 'pointer';
    this.el.setAttribute('aria-hidden', 'true');
    this.el.innerHTML = '<svg width="20" height="26" viewBox="0 0 20 26"><path d="M2 1.6v19l4.9-4.4 3.3 7.9 3.1-1.3-3.3-7.8 6.6-.4z" fill="#000" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>';
    box.appendChild(this.el);
  }

  /** Where the pointer points at something: its middle, or 120 in when it is wide. In the box's own points. */
  at(target: Element) {
    const b = this.box.getBoundingClientRect(), t = target.getBoundingClientRect();
    return { x: t.left - b.left + Math.min(t.width / 2, 120), y: t.top - b.top + t.height / 2 };
  }

  /** Travel to `to` (a thing, or a point of the box) without pressing. */
  move(to: Element | { x: number; y: number }, seconds = 0.7) {
    const { x, y } = to instanceof Element ? this.at(to) : to;
    if (!this.shownAt) {
      gsap.set(this.el, { x: x + 120, y: y + 90, opacity: 0 });
      this.shownAt = true;
    }
    gsap.killTweensOf(this.el);
    const tl = gsap.timeline();
    tl.to(this.el, { opacity: 1, duration: 0.15 }, 0);
    tl.to(this.el, { x, y, duration: seconds, ease: 'power3.inOut' }, 0);
    return tl;
  }

  /** Travel to `target` and press it. Resolves in `seconds`: act then. */
  click(target: Element | { x: number; y: number }, seconds = 0.7) {
    return this.move(target, seconds)
      .to(this.el, { scale: 0.86, duration: 0.08, yoyo: true, repeat: 1, transformOrigin: '10% 6%' }, seconds);
  }

  hide() { gsap.to(this.el, { opacity: 0, duration: 0.3, overwrite: 'auto' }); this.shownAt = false; }
}
