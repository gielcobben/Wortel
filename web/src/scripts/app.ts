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

/**
 * Hide the last rows of a sidebar until the list fits, and no folder is left
 * without its rows. The selected row and its section's header stay: the app
 * lists the sessions in no folder last, so the session a window is showing is
 * often at the end, and a window whose own session is cut reads as wrong.
 */
export function fitSidebar(nav: HTMLElement) {
  unfit(nav);
  const rows = (Array.from(nav.children) as HTMLElement[]).filter(shown);
  const head = (r: HTMLElement) => !!r.dataset.name?.startsWith('Section ');
  const keep = new Set<HTMLElement>();
  const sel = rows.findIndex((r) => r.querySelector(':scope > [data-name="Pill"]'));
  if (sel >= 0) {
    keep.add(rows[sel]);
    for (let k = sel; k >= 0; k--) if (head(rows[k])) { keep.add(rows[k]); break; }
  }
  for (let i = rows.length - 1; i > 0 && nav.scrollHeight > nav.clientHeight; i--) if (!keep.has(rows[i])) drop(rows[i]);
  // A folder header whose rows were all cut goes with them. A folded one had none to cut.
  rows.forEach((r, i) => {
    if (!head(r) || keep.has(r) || 'fit' in r.dataset) return;
    const mine: HTMLElement[] = [];
    for (let k = i + 1; k < rows.length && !head(rows[k]); k++) mine.push(rows[k]);
    if (mine.length && mine.every((m) => 'fit' in m.dataset)) drop(r);
  });
  // The 14pt between sections belongs to the last row of an open section, so
  // a header after a folded or cut one sits close (as in the app since
  // 82992ca). The canvas writes it as the header's height, fixed for the
  // order it drew; after cutting or folding, work it out again.
  let prev: HTMLElement | null = null;
  for (const r of Array.from(nav.children) as HTMLElement[]) {
    if (!shown(r)) continue;
    if (head(r)) r.style.height = `${prev && !head(prev) ? 44 : 30}px`;
    prev = r;
  }
}

/** Keep every terminal and sidebar inside `root` to whole rows, now and as it resizes. */
export function wholeRows(root: ParentNode) {
  const terms = Array.from(root.querySelectorAll<HTMLElement>('[data-name="Terminal"], [data-name="Strip terminal"]'));
  const navs = Array.from(root.querySelectorAll<HTMLElement>('[data-name="Sessions"]'));
  terms.forEach((t) => { if (t.dataset.name === 'Terminal') withHeader(t); });
  const run = () => { terms.forEach(fitTerminal); navs.forEach(fitSidebar); };
  run();
  const ro = new ResizeObserver(run);
  [...terms, ...navs].forEach((el) => ro.observe(el));
  document.fonts?.ready.then(run);
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
    p.className = 'h-[19px] whitespace-pre pl-[93.5px] ' + cls;
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
      gsap.fromTo(dot, { scale: 0.5, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.35, ease: 'back.out(1.7)', clearProps: 'transform,opacity' });
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
    const glyph = document.createElement('span');
    glyph.className = 'spin absolute top-0 left-[0px] text-[#d77757]';
    glyph.textContent = '✽';
    const said = document.createElement('span');
    said.className = 'text-[#d77757]';
    said.textContent = text + ' ';
    const meta = document.createElement('span');
    meta.className = 'text-[#666666] dark:text-[#999999]';
    meta.textContent = `(${detail})`;
    p.append(glyph, said, meta);
    this.root.insertBefore(p, this.anchor);
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
