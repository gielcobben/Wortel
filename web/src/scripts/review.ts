// The review scene: an agent has just said it is done, and what it did is
// looked at without leaving the window. ⇧⌘C opens Changes in a column beside
// the terminal, ⇧⌘H puts History in front there, ⇧⌘F Files, and a file
// picked in the tree opens with Space in a preview tab in front of the
// terminal. Each chapter starts where the one before ended; only the loop
// back to the first is a cut.
//
// Every state is the canvas's own panes, shown or hidden: the terminal and
// the plan in the session's split, and Changes, History and Files in the
// column, whose row of tabs the canvas draws a tab longer in each. It moves
// the way the app does (README, Motion): the column slides in, since it
// opens by itself beside the terminal; a tab brought to the front and a
// preview land in one cut, with a short fade that says what changed.
//
// components/films/ReviewFilm.astro is the window it plays in.
import { gsap } from 'gsap';
import { Pointer, Sidebar, foldable, named, pressKeys, reduced, wholeRows } from './app';
import { film } from './film';

const SESSION = 'Quicker panes';
type Side = 'none' | 'changes' | 'history' | 'files';
/** What the column shows, and whether the plan is previewed in front of the terminal. */
type State = { side: Side; file: boolean };
const START: State[] = [{ side: 'none', file: false }, { side: 'changes', file: false }, { side: 'history', file: false }, { side: 'files', file: false }];
const END: State[] = [{ side: 'changes', file: false }, { side: 'history', file: false }, { side: 'files', file: false }, { side: 'files', file: true }];
/** From a key going down to the app answering, and how long a finished chapter is held. */
const BEAT = 0.5, HELD = 2.4;
/** The room the terminal keeps clear above its prompt for the keys shown there. */
const ROOM = 95;

export function initReview() {
  const root = document.querySelector<HTMLElement>('[data-film="review"]');
  const win = root?.querySelector<HTMLElement>('[data-rwin]');
  if (!root || !win) return;
  const box = win.parentElement!;
  const pane = (k: string) => win.querySelector<HTMLElement>(`[data-pane="${k}"]`)!;
  const keys = (k: string) => root.querySelector<HTMLElement>(`[data-keys="${k}"]`)!;
  const main = win.querySelector<HTMLElement>('[data-slot="main"]')!;
  const side = win.querySelector<HTMLElement>('[data-slot="side"]')!;
  const rule = win.querySelector<HTMLElement>('[data-div="side"]')!;
  const mainBar = pane('terminal').querySelector<HTMLElement>('header')!;

  // ---- the window ---------------------------------------------------------------
  const sb = new Sidebar(named(win, 'Sidebar')!);
  sb.show(['Section web', 'Landing page hero', 'Changelog typography', 'Pricing FAQ copy', 'Section Sessions', SESSION, 'Marketing screenshots']);
  sb.select(SESSION);
  const lead = root.querySelector<HTMLTemplateElement>('template[data-tpl="lead"]')?.content;
  foldable(win, lead);
  // The preview brings its own row: it gains the same buttons the terminal's has.
  const buttons = (lead?.cloneNode(true) as DocumentFragment | undefined)?.firstElementChild as HTMLElement | null;
  if (buttons) { buttons.dataset.narrowOnly = ''; pane('file').querySelector('header[data-name="Main bar"]')!.prepend(buttons); }
  const term = named(pane('terminal'), 'Terminal')!;
  term.dataset.reserve = String(ROOM);
  // A file opened by picking it is a preview: its tab's title is in italics
  // until it is kept.
  pane('file').querySelector<HTMLElement>('[data-name="plan.md tab"] > span')?.classList.add('italic');

  // The tree's selection: the row the canvas draws chosen, and the plan.
  const tree = named(pane('files'), 'File tree')!;
  const drawn = named(tree, 'Chrome.swift')!, plan = named(tree, 'plan.md')!;
  const pick = (row: HTMLElement) => { for (const r of [drawn, plan]) r.classList.toggle('bg-secondary', r === row); };

  // ---- a whole state, at once -----------------------------------------------------
  const state: State = { side: 'none', file: false };
  const show = (to: State) => {
    Object.assign(state, to);
    const open = to.side !== 'none';
    gsap.killTweensOf([side, mainBar]);
    gsap.set([side, mainBar], { clearProps: 'width,paddingRight' });
    side.hidden = rule.hidden = !open;
    // The rightmost row along the top keeps clear of the window's corner.
    main.toggleAttribute('data-end', !open);
    for (const k of ['changes', 'history', 'files'] as const) pane(k).hidden = k !== (open ? to.side : 'changes');
    pane('file').hidden = !to.file;
    pane('terminal').hidden = to.file;
    pick(to.file ? plan : drawn);
    tree.scrollTop = 0;
    win.style.setProperty('--n', open ? '2' : '1');
  };
  const same = (to: State) => to.side === state.side && to.file === state.file;
  /** The short fade on what a cut brought. */
  const arrive = (el: Element) => gsap.fromTo(el, { opacity: 0 }, { opacity: 1, duration: 0.2, ease: 'power2.out', clearProps: 'opacity' });

  // ---- on a phone, one of the two at a time -----------------------------------------
  const phone = matchMedia('(max-width: 760px)');
  let view: 'main' | 'side' = 'main';
  const pan = (to: 'main' | 'side', animate: boolean) => {
    if (!phone.matches) { gsap.set(win, { x: 0 }); win.removeAttribute('data-view'); view = to; return; }
    const x = to === 'side' && state.side !== 'none' ? -(box.clientWidth + 1) : 0;
    const moves = animate && !reduced() && view !== to;
    view = to;
    if (moves) win.removeAttribute('data-view');
    gsap.to(win, { x, duration: moves ? 0.6 : 0, ease: 'power3.inOut', overwrite: 'auto', onComplete: () => win.setAttribute('data-view', x ? 'side' : 'main') });
  };

  // ---- hands ----------------------------------------------------------------------
  const pointer = new Pointer(box);
  /** Keys show over the terminal, in the room it keeps clear above its prompt.
   *  On a phone that is looking at the column, in the middle of what shows. */
  const over = (k: HTMLElement) => {
    const b = box.getBoundingClientRect();
    if (phone.matches && view === 'side') { Object.assign(k.style, { left: `${b.width / 2}px`, top: `${b.height * 0.55}px` }); return; }
    const t = main.getBoundingClientRect(), edge = named(term, 'Rule')!.getBoundingClientRect();
    const left = Math.max(t.left, b.left), right = Math.min(t.right, b.right);
    Object.assign(k.style, { left: `${(left + right) / 2 - b.left}px`, top: `${edge.top - b.top - ROOM / 2}px` });
  };
  const shown: gsap.core.Timeline[] = [];
  const cut = () => {
    shown.splice(0).forEach((tl) => tl.kill());
    gsap.set(root.querySelectorAll('[data-keys]'), { opacity: 0 });
    gsap.set(root.querySelectorAll('[data-keys] kbd'), { y: 0 });
    gsap.killTweensOf(tree);
    pointer.hide();
  };

  const f = film(root, (f) => {
    const at = (fn: () => void, t: number) => f.later(fn, t);
    /** Press keys: they show and dip, the app answers a beat later, and they are gone as it does. */
    const chord = (name: string, t: number, act: () => void) => {
      at(() => { over(keys(name)); const tl = gsap.timeline(); pressKeys(tl, keys(name), 0, 2); shown.push(tl); }, t);
      at(() => { act(); shown.splice(0).forEach((tl) => tl.kill()); gsap.to(keys(name), { opacity: 0, duration: 0.15, ease: 'power2.out' }); }, t + BEAT);
      return t + BEAT;
    };
    /** Bring one of the column's tabs to the front. */
    const front = (to: Exclude<Side, 'none'>) => { show({ side: to, file: false }); arrive(pane(to)); };

    const plays: (() => number)[] = [
      // Changes: ⇧⌘C, and the column slides in at the outer edge.
      () => chord('changes', 0.6, () => {
        show(END[0]);
        if (phone.matches) { pan('side', true); return; }
        const w = side.offsetWidth;
        gsap.fromTo(side, { width: 0 }, { width: w, duration: 0.5, ease: 'power3.inOut', clearProps: 'width' });
        // The terminal's row was the rightmost and no longer is: it gives
        // the corner's room back on the same curve.
        gsap.fromTo(mainBar, { paddingRight: 72 }, { paddingRight: parseFloat(getComputedStyle(mainBar).paddingRight), duration: 0.5, ease: 'power3.inOut', clearProps: 'paddingRight' });
      }) + 0.5,
      // History and Files: the tab is added to the column's row, in front.
      () => chord('history', 0.6, () => front('history')),
      () => chord('files', 0.6, () => front('files')),
      // Preview: the plan is picked in the tree, and Space opens it in front
      // of the terminal.
      () => {
        // In a window as short as a phone's the plan's row is below the fold.
        at(() => {
          const r = plan.getBoundingClientRect(), v = tree.getBoundingClientRect();
          if (r.bottom > v.bottom - 22) gsap.to(tree, { scrollTop: tree.scrollTop + r.bottom - v.bottom + 66, duration: 0.4, ease: 'power3.inOut' });
        }, 0.1);
        at(() => pointer.click(plan, 0.7), 0.6);
        at(() => pick(plan), 1.3);
        at(() => pointer.hide(), 1.7);
        if (phone.matches) at(() => pan('main', true), 1.8);
        return chord('space', phone.matches ? 2.5 : 1.9, () => {
          const scrolled = tree.scrollTop;
          show(END[3]);
          tree.scrollTop = scrolled;
          arrive(pane('file'));
        });
      },
    ];
    return plays.map((play, i) => ({
      // A chapter is held the same while after its last beat. Preview's last
      // beat lands 0.6 s later on a phone, where the film first pans back to
      // the tree, so its hold is read when the chapter starts.
      get hold() { return [1.6, 1.1, 1.1, phone.matches ? 3.0 : 2.4][i] + HELD; },
      enter: (animate: boolean) => {
        cut();
        // With no motion: how the chapter ends. Drawn before anyone is
        // looking: where the story starts.
        if (reduced()) { show(END[i]); pan(i === 3 ? 'main' : 'side', false); return; }
        if (!animate) { show(START[i]); pan('main', false); return; }
        if (!same(START[i])) show(START[i]);
        pan(i === 0 ? 'main' : 'side', i !== 0);
        play();
      },
    }));
  // With no motion the still is the fullest one: the tree, and the plan it opened.
  }, 3);
  void f;

  phone.addEventListener('change', () => pan(view, false));
  let seen = box.clientWidth;
  new ResizeObserver(() => { if (box.clientWidth !== seen) { seen = box.clientWidth; pan(view, false); } }).observe(box);

  wholeRows(win);
}
