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

const unfit = (root: Element) => root.querySelectorAll<HTMLElement>('[data-fit]').forEach((el) => { el.style.display = ''; delete el.dataset.fit; });
const drop = (el: HTMLElement) => { el.style.display = 'none'; el.dataset.fit = ''; };
const shown = (el: Element) => !(el as HTMLElement).hidden && (el as HTMLElement).style.display !== 'none';

/** Hide the oldest rows of a terminal until what is left fits whole. */
export function fitTerminal(root: HTMLElement) {
  unfit(root);
  const rows = (Array.from(root.children) as HTMLElement[]).filter(shown);
  const end = rows.findIndex((r) => r.dataset.name === 'Rule');
  const body = rows.slice(0, end < 0 ? rows.length : end);
  // A terminal is filled from the bottom, so what does not fit is cut at the
  // top, where scrollHeight cannot see it: measure the rows themselves.
  const cs = getComputedStyle(root);
  const room = root.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom);
  let used = rows.reduce((h, r) => h + (r.dataset.name === 'Rest' ? 0 : r.offsetHeight), 0);
  let i = 0;
  while (i < body.length && used > room + 0.5) { used -= body[i].offsetHeight; drop(body[i++]); }
  if (!i) return;
  // Having cut, do not open on an empty row, or on a result whose tool line went.
  while (i < body.length && (!body[i].textContent?.trim() || body[i].dataset.name === 'Result')) drop(body[i++]);
}

/** Hide the last rows of a sidebar until the list fits, and no folder is left without its rows. */
export function fitSidebar(nav: HTMLElement) {
  unfit(nav);
  const rows = (Array.from(nav.children) as HTMLElement[]).filter(shown);
  let i = rows.length - 1;
  while (i > 0 && nav.scrollHeight > nav.clientHeight) drop(rows[i--]);
  // A folder header whose first row was just cut goes with it.
  while (i > 0 && i < rows.length - 1 && rows[i].dataset.name?.startsWith('Section ') && 'fit' in rows[i + 1].dataset && !rows[i + 1].dataset.name?.startsWith('Section ')) drop(rows[i--]);
}

/** Keep every terminal and sidebar inside `root` to whole rows, now and as it resizes. */
export function wholeRows(root: ParentNode) {
  const terms = Array.from(root.querySelectorAll<HTMLElement>('[data-name="Terminal"], [data-name="Strip terminal"]'));
  const navs = Array.from(root.querySelectorAll<HTMLElement>('[data-name="Sessions"]'));
  const run = () => { terms.forEach(fitTerminal); navs.forEach(fitSidebar); };
  run();
  const ro = new ResizeObserver(run);
  [...terms, ...navs].forEach((el) => ro.observe(el));
  document.fonts?.ready.then(run);
}

// ---- the sidebar ----------------------------------------------------------

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

  row(name: string) { return named(this.nav, name)!; }

  /** The session rows, top to bottom (not the folder headers). */
  rows() {
    return (Array.from(this.nav.children) as HTMLElement[]).filter((r) => r.dataset.name && !r.dataset.name.startsWith('Section '));
  }

  /** Move the selection to a row, the way a click does. */
  select(name: string, animate = true) {
    const to = this.row(name);
    if (!to || name === this.selected) return;
    const from = this.pill.getBoundingClientRect();
    to.prepend(this.pill);
    this.selected = name;
    if (!animate || !from.height) return;
    const now = this.pill.getBoundingClientRect();
    gsap.fromTo(this.pill, { y: from.top - now.top, height: from.height }, { y: 0, height: now.height, duration: 0.3, ease: 'power3.out', clearProps: 'transform,height' });
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
      gsap.fromTo(dot, { scale: 0 }, { scale: 1, duration: 0.4, ease: 'back.out(3)' });
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
    gsap.set(dots, { opacity: 1 });
    if (dots.length && !reduced()) {
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
  }

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
    nodes.forEach((n) => this.root.insertBefore(n, this.anchor));
    this.fit();
  }

  /** Build a screen without showing it: run `fn`, take what it printed. */
  compose(fn: () => void) {
    const keep = this.lines();
    this.clear();
    fn();
    const made = this.lines();
    this.swap(keep);
    return made;
  }

  /** Print a line. `tool` is the bold verb of a tool line: Read, Bash, Update. */
  print(kind: Kind, text: string, tool?: string) {
    const p = this.moulds.get(kind)!.cloneNode(true) as HTMLElement;
    p.hidden = false; p.style.display = ''; delete p.dataset.fit;
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

  /** A status line while the agent works: the turning glyph and what it is doing. */
  status(text: string) {
    const p = this.print('Worked', text);
    p.dataset.name = 'Status';
    p.firstElementChild!.classList.add('spin');
    return p;
  }
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

// ---- hands ------------------------------------------------------------------

/** Press a cluster of keycaps: it appears, the keys dip, it leaves. */
export function pressKeys(tl: gsap.core.Timeline, keys: HTMLElement, at: number, hold = 0.9) {
  tl.fromTo(keys, { opacity: 0, y: 8, scale: 0.96 }, { opacity: 1, y: 0, scale: 1, duration: 0.25, ease: 'power2.out' }, at);
  tl.to(keys.querySelectorAll('kbd'), { y: 2, duration: 0.08, yoyo: true, repeat: 1 }, at + 0.4);
  tl.to(keys, { opacity: 0, y: -4, duration: 0.25, ease: 'power2.in' }, at + hold);
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

  /** Travel to `target` and press it. Resolves in `seconds`: act then. */
  click(target: Element, seconds = 0.7) {
    const b = this.box.getBoundingClientRect(), t = target.getBoundingClientRect();
    const x = t.left - b.left + Math.min(t.width / 2, 120), y = t.top - b.top + t.height / 2;
    if (!this.shownAt) {
      gsap.set(this.el, { x: x + 120, y: y + 90, opacity: 0 });
      this.shownAt = true;
    }
    gsap.killTweensOf(this.el);
    const tl = gsap.timeline();
    tl.to(this.el, { opacity: 1, duration: 0.15 }, 0);
    tl.to(this.el, { x, y, duration: seconds, ease: 'power3.inOut' }, 0);
    tl.to(this.el, { scale: 0.86, duration: 0.08, yoyo: true, repeat: 1, transformOrigin: '10% 6%' }, seconds);
    return tl;
  }

  hide() { gsap.to(this.el, { opacity: 0, duration: 0.3, overwrite: 'auto' }); this.shownAt = false; }
}
