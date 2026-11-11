// The panes scene: one window, moved between arrangements.
//
// The window has four places and a state per place: what it holds, or hidden.
// set() moves one place the way the app does it: a pane swaps out and in, a
// hidden place folds to nothing and its neighbours take the room. A chapter
// is just a target state for all four; arrange() walks there a place at a
// time, so going from any chapter to any other is the same code.
import { gsap } from 'gsap';
import { film } from './film';

type Place = 'sidebar' | 'main' | 'side' | 'strip';
type Layout = Record<Place, string>;

const CHAPTERS: Layout[] = [
  { sidebar: 'sidebar', main: 'terminal', side: 'changes', strip: 'strip' }, // everything
  { sidebar: 'sidebar', main: 'terminal', side: 'history', strip: 'hidden' }, // reviewing
  { sidebar: 'sidebar', main: 'browser', side: 'hidden', strip: 'strip' }, // previewing
  { sidebar: 'sidebar', main: 'file', side: 'files', strip: 'hidden' }, // reading
  { sidebar: 'hidden', main: 'terminal', side: 'hidden', strip: 'hidden' }, // quiet
];

export function initPanes() {
  const root = document.querySelector<HTMLElement>('[data-film="panes"]');
  const win = root?.querySelector<HTMLElement>('[data-pwin]');
  if (!root || !win) return;

  const slot = (k: string) => win.querySelector<HTMLElement>(`[data-slot="${k}"]`)!;
  const pane = (k: string) => win.querySelector<HTMLElement>(`[data-pane="${k}"]`)!;
  const div = (k: string) => win.querySelector<HTMLElement>(`[data-div="${k}"]`)!;
  const bars = Array.from(win.querySelectorAll<HTMLElement>('[data-slot="main"] header'));
  const pads = bars.map((b) => parseFloat(getComputedStyle(b).paddingLeft) || 0);

  const state: Layout = { ...CHAPTERS[0] };
  const size = { sidebar: slot('sidebar').offsetWidth || 234, side: slot('side').offsetWidth || 336, strip: slot('strip').offsetHeight || 168 };
  const FOLD = { duration: 0.6, ease: 'power3.inOut' };

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
      // With no sidebar, the main bar makes room for the traffic lights.
      if (place === 'sidebar') bars.forEach((b, i) => gsap.to(b, { paddingLeft: open ? pads[i] : 84, ...FOLD, duration: FOLD.duration * d, delay }));
    }

    // Swap what the place holds: the old pane out, then the new one in.
    const a = from !== 'hidden' ? pane(from) : null;
    const b = value !== 'hidden' ? pane(value) : null;
    if (a && b && a !== b) {
      gsap.to(a, { autoAlpha: 0, duration: 0.16 * d, delay, ease: 'power1.in' });
      gsap.fromTo(b, { autoAlpha: 0, y: 6 }, { autoAlpha: 1, y: 0, duration: 0.32 * d, delay: delay + 0.16 * d, ease: 'power2.out' });
    } else if (b && !a) {
      // Unfolding onto a pane that was not the one left there.
      (Array.from(slot(place).querySelectorAll<HTMLElement>('[data-pane]'))).forEach((p) => gsap.set(p, { autoAlpha: p === b ? 1 : 0, y: 0 }));
    }
  }

  // ---- a whole arrangement, a place at a time -------------------------------
  const ORDER: Place[] = ['main', 'side', 'strip', 'sidebar'];
  function arrange(to: Layout, animate: boolean) {
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
    const x = -Math.max(0, win!.offsetWidth - box.clientWidth) * focus;
    gsap.to(win!, { x, duration: 0.6, ease: 'power3.inOut', overwrite: 'auto' });
  }

  film(root, () => CHAPTERS.map((layout, i) => ({
    hold: i === 0 ? 3.6 : 4.4,
    enter: (animate) => arrange(layout, animate),
  })));
}
