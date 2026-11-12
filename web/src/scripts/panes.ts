// The panes scene: one window, moved between arrangements, by the film or by
// the visitor's own hands on the window's controls.
//
// The window has four places and a state per place: what it holds, or hidden.
// set() moves one place the way the app does it: a pane swaps out and in, a
// hidden place folds to nothing and its neighbours take the room, and the main
// bar gains the buttons the canvas gives it when a neighbour is gone. A chapter
// is a target state for all four plus the session; arrange() walks there a
// place at a time, so going from any chapter to any other is the same code.
import { gsap } from 'gsap';
import { Sidebar, Terminal, named, sessionScreen, wholeRows } from './app';
import { film } from './film';

type Place = 'sidebar' | 'main' | 'side' | 'strip';
type Layout = Record<Place, string> & { session: string };

const HOME = 'Quicker panes', WEB = 'Landing page hero';
const CHAPTERS: Layout[] = [
  { session: HOME, sidebar: 'sidebar', main: 'terminal', side: 'changes', strip: 'strip' }, // everything
  { session: HOME, sidebar: 'sidebar', main: 'terminal', side: 'history', strip: 'hidden' }, // reviewing
  { session: WEB, sidebar: 'sidebar', main: 'browser', side: 'hidden', strip: 'strip' }, // previewing
  { session: HOME, sidebar: 'sidebar', main: 'file', side: 'files', strip: 'hidden' }, // reading
  { session: HOME, sidebar: 'hidden', main: 'terminal', side: 'hidden', strip: 'hidden' }, // quiet
];

export function initPanes() {
  const root = document.querySelector<HTMLElement>('[data-film="panes"]');
  const win = root?.querySelector<HTMLElement>('[data-pwin]');
  if (!root || !win) return;

  const slot = (k: string) => win.querySelector<HTMLElement>(`[data-slot="${k}"]`)!;
  const pane = (k: string) => win.querySelector<HTMLElement>(`[data-pane="${k}"]`)!;
  const div = (k: string) => win.querySelector<HTMLElement>(`[data-div="${k}"]`)!;
  const tpl = (k: string) => root.querySelector<HTMLTemplateElement>(`template[data-tpl="${k}"]`)!;
  const bars = Array.from(win.querySelectorAll<HTMLElement>('[data-slot="main"] header'));

  const sb = new Sidebar(named(win, 'Sidebar')!);
  const term = new Terminal(named(pane('terminal'), 'Terminal')!);
  const title = named(pane('terminal'), 'Title')!;
  const screens = new Map<string, HTMLElement[]>([[HOME, term.lines()]]);

  const state: Layout = { ...CHAPTERS[0] };
  const size = { sidebar: 234, side: 384, strip: slot('strip').offsetHeight || 200 };
  const FOLD = { duration: 0.5, ease: 'power3.inOut' };
  // The buttons the main bar gains with no sidebar: Show Sidebar, Back, Forward.
  const LEAD = 28 + 8 + 60 + 8;

  // ---- the main bar's extra buttons ------------------------------------------
  const trail = (on: boolean) => bars.forEach((h) => {
    const has = named(h, 'Show Side Column');
    if (on && !has) named(h, 'Trailing')?.append(tpl('trail').content.cloneNode(true));
    if (!on && has) { has.previousElementSibling?.remove(); has.remove(); }
    press();
  });
  const lead = (on: boolean, d: number, delay: number) => bars.forEach((h) => {
    gsap.killTweensOf(h, 'paddingLeft');
    const rest = parseFloat(h.dataset.pad ||= getComputedStyle(h).paddingLeft);
    if (on) {
      // Make the room while the sidebar folds, then put the buttons in it.
      gsap.to(h, { paddingLeft: 78 + LEAD, ...FOLD, duration: FOLD.duration * d, delay, onComplete: () => {
        if (!h.querySelector('[data-lead]')) h.prepend(tpl('lead').content.cloneNode(true));
        gsap.set(h, { paddingLeft: 78 });
        if (d) gsap.fromTo(h.querySelector('[data-lead]')!.children, { opacity: 0 }, { opacity: 1, duration: 0.2 });
        press();
      } });
    } else {
      if (h.querySelector('[data-lead]')) { h.querySelector('[data-lead]')!.remove(); gsap.set(h, { paddingLeft: 78 + LEAD }); }
      gsap.to(h, { paddingLeft: rest, ...FOLD, duration: FOLD.duration * d, delay, clearProps: 'paddingLeft' });
    }
  });

  // ---- one place, one change ------------------------------------------------
  function set(place: Place, value: string, d = 1, delay = 0) {
    const from = state[place];
    if (from === value) return;
    state[place] = value;

    // Fold or unfold the place itself.
    if (place !== 'main' && (value === 'hidden' || from === 'hidden')) {
      const open = value !== 'hidden';
      const s = slot(place);
      if (place === 'strip') gsap.to(s, { height: open ? size.strip : 0, ...FOLD, duration: FOLD.duration * d, delay });
      else {
        gsap.to(s, { width: open ? size[place] : 0, ...FOLD, duration: FOLD.duration * d, delay });
        gsap.to(div(place), { autoAlpha: open ? 1 : 0, duration: 0.2 * d, delay: delay + (open ? 0 : 0.35 * d) });
      }
      if (place === 'sidebar') lead(!open, d, delay);
      if (place === 'side') gsap.delayedCall(delay + (open ? 0 : 0.3 * d), () => trail(!open));
    }

    // Swap what the place holds: the old pane out, then the new one in.
    const a = from !== 'hidden' ? pane(from) : null;
    const b = value !== 'hidden' ? pane(value) : null;
    if (a && b && a !== b) {
      // The app swaps at once; a short fade in only says what changed.
      gsap.set(a, { autoAlpha: 0, delay });
      gsap.fromTo(b, { autoAlpha: 0 }, { autoAlpha: 1, duration: 0.2 * d, delay, ease: 'power2.out', clearProps: 'transform' });
    } else if (b && !a) {
      // Unfolding onto a pane that was not the one left there.
      Array.from(slot(place).querySelectorAll<HTMLElement>('[data-pane]')).forEach((p) => gsap.set(p, { autoAlpha: p === b ? 1 : 0, clearProps: 'transform' }));
    }
  }

  function session(name: string, animate: boolean) {
    if (state.session === name) return;
    state.session = name;
    sb.select(name, animate);
    title.textContent = name;
    if (!screens.has(name)) screens.set(name, sessionScreen(term, name));
    term.swap(screens.get(name)!);
    if (animate && state.main === 'terminal') gsap.fromTo(term.root, { opacity: 0 }, { opacity: 1, duration: 0.28, clearProps: 'opacity' });
  }

  // ---- a whole arrangement, a place at a time -------------------------------
  const ORDER: Place[] = ['main', 'side', 'strip', 'sidebar'];
  function arrange(to: Layout, animate: boolean) {
    session(to.session, animate);
    let k = 0;
    for (const place of ORDER) {
      if (state[place] === to[place]) continue;
      set(place, to[place], animate ? 1 : 0, animate ? k * 0.14 : 0);
      k++;
    }
    pan(to);
  }

  // ---- on a phone, the window pans to the place the chapter is about --------
  const phone = matchMedia('(max-width: 760px)');
  function pan(to: Layout) {
    if (!phone.matches) { gsap.set(win!, { x: 0 }); return; }
    const box = win!.parentElement!;
    const focus = to.side !== 'hidden' && to.side !== 'changes' ? 1 : to.main !== 'terminal' ? 0.5 : 0;
    gsap.to(win!, { x: -Math.max(0, win!.offsetWidth - box.clientWidth + 16) * focus, duration: 0.6, ease: 'power3.inOut', overwrite: 'auto' });
  }

  // ---- the film ----------------------------------------------------------------
  const f = film(root, () => CHAPTERS.map((layout, i) => ({
    hold: i === 0 ? 3.6 : 4.4,
    enter: (animate) => arrange(layout, animate),
  })));

  // ---- your hands on the window ---------------------------------------------
  // What each named control does to the state. The names are the canvas's.
  const PRESS: Record<string, () => void> = {
    'Hide Sidebar': () => set('sidebar', 'hidden'),
    'Show Sidebar': () => set('sidebar', 'sidebar'),
    'Hide Side Column': () => set('side', 'hidden'),
    'Show Side Column': () => set('side', 'changes'),
    'Hide Bottom Strip': () => set('strip', 'hidden'),
    'Changes tab': () => set('side', 'changes'),
    'History tab': () => set('side', 'history'),
    'Files tab': () => set('side', 'files'),
    'Quicker panes tab': () => { session(HOME, true); set('main', 'terminal'); },
    'Landing page hero tab': () => { session(WEB, true); set('main', 'terminal'); },
  };
  function press() {
    for (const name of Object.keys(PRESS)) win!.querySelectorAll<HTMLElement>(`[data-name="${name}"]`).forEach((el) => (el.dataset.press = ''));
  }
  const settle = () => {
    f.pause();
    const i = CHAPTERS.findIndex((c) => (Object.keys(c) as (keyof Layout)[]).every((k) => c[k] === state[k]));
    if (i >= 0) f.mark(i); else f.own();
  };
  win.addEventListener('click', (e) => {
    const hit = (e.target as HTMLElement).closest<HTMLElement>('[data-press]');
    if (!hit || !win.contains(hit)) return;
    PRESS[hit.dataset.name!]?.();
    settle();
  });
  sb.clickable((name) => { session(name, true); set('main', 'terminal'); settle(); });

  // The canvas drew the file and browser bars with no column beside them.
  trail(false);
  press();
  wholeRows(win);
}
