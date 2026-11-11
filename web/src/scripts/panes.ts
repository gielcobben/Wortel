// The panes section: a window you arrange.
//
// The window has four places and a state per place: what it holds, or hidden.
// set() moves one place to a new state the way the app does it: a pane swaps
// out and in, a hidden place folds to nothing and its neighbours take the
// room. The choices under the window call set(); until someone presses one, a
// short storyboard presses them itself so the window is never still.
import { gsap } from 'gsap';
import { reduced } from './app';

type Place = 'sidebar' | 'main' | 'side' | 'strip';

export function initPanes() {
  const root = document.querySelector<HTMLElement>('[data-panes]');
  const win = root?.querySelector<HTMLElement>('[data-pwin]');
  if (!root || !win) return;

  const slot = (k: string) => win.querySelector<HTMLElement>(`[data-slot="${k}"]`)!;
  const pane = (k: string) => win.querySelector<HTMLElement>(`[data-pane="${k}"]`)!;
  const div = (k: string) => win.querySelector<HTMLElement>(`[data-div="${k}"]`)!;
  const bars = Array.from(win.querySelectorAll<HTMLElement>('[data-slot="main"] header'));

  const state: Record<Place, string> = { sidebar: 'sidebar', main: 'terminal', side: 'changes', strip: 'strip' };
  const size = { sidebar: slot('sidebar').offsetWidth || 234, side: slot('side').offsetWidth || 360, strip: slot('strip').offsetHeight || 176 };
  const FOLD = { duration: 0.55, ease: 'power3.inOut' };

  // ---- one place, one change ------------------------------------------------
  function set(place: Place, value: string, instant = false) {
    const from = state[place];
    if (from === value) return;
    state[place] = value;
    const d = instant ? 0 : 1;

    // Fold or unfold the place itself.
    if (place !== 'main' && (value === 'hidden' || from === 'hidden')) {
      const open = value !== 'hidden';
      const s = slot(place);
      if (place === 'strip') gsap.to(s, { height: open ? size.strip : 0, ...FOLD, duration: FOLD.duration * d });
      else {
        gsap.to(s, { width: open ? size[place] : 0, ...FOLD, duration: FOLD.duration * d });
        gsap.to(div(place), { autoAlpha: open ? 1 : 0, duration: 0.2 * d, delay: open ? 0 : 0.3 * d });
      }
      // With no sidebar, the main bar makes room for the traffic lights.
      if (place === 'sidebar') gsap.to(bars, { paddingLeft: open ? '' : 84, ...FOLD, duration: FOLD.duration * d, clearProps: open ? 'paddingLeft' : '' });
    }

    // Swap what the place holds: the old pane out, then the new one in.
    const a = from !== 'hidden' ? pane(from) : null;
    const b = value !== 'hidden' ? pane(value) : null;
    if (a && b && a !== b) {
      gsap.to(a, { autoAlpha: 0, duration: 0.14 * d, ease: 'power1.in' });
      gsap.fromTo(b, { autoAlpha: 0, y: 6 }, { autoAlpha: 1, y: 0, duration: 0.3 * d, delay: 0.14 * d, ease: 'power2.out' });
    }

    // The choices under the window follow.
    const fact = root!.querySelector<HTMLElement>(`[data-place="${place}"]`)!;
    fact.querySelectorAll<HTMLButtonElement>('[data-set]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.set === value)));
    if (!instant && place !== 'main' && (value === 'hidden' || from === 'hidden')) {
      const key = fact.querySelector('kbd');
      key?.classList.add('down');
      setTimeout(() => key?.classList.remove('down'), 160);
    }
    pan(place);
  }

  // ---- on a phone, the window pans to the place that changed ----------------
  const phone = matchMedia('(max-width: 760px)');
  function pan(place: Place) {
    if (!phone.matches) { gsap.set(win!, { x: 0 }); return; }
    const box = win!.parentElement!;
    const r = slot(place === 'strip' ? 'main' : place).getBoundingClientRect(), w = win!.getBoundingClientRect();
    const centre = r.left - w.left + Math.max(r.width, 120) / 2;
    const x = Math.min(0, Math.max(box.clientWidth - win!.offsetWidth, box.clientWidth / 2 - centre));
    gsap.to(win!, { x, duration: 0.6, ease: 'power3.inOut', overwrite: 'auto' });
  }

  // ---- your hands -------------------------------------------------------------
  let auto = !reduced();
  let timer = 0;
  root.querySelectorAll<HTMLButtonElement>('[data-set]').forEach((b) => b.addEventListener('click', () => {
    auto = false; clearTimeout(timer);
    set(b.closest<HTMLElement>('[data-place]')!.dataset.place as Place, b.dataset.set!);
  }));

  // ---- its own: a storyboard of presses, while nobody has touched it --------
  // [seconds to wait, place, value]
  const STORY: [number, Place, string][] = [
    [2.2, 'side', 'history'],
    [2.2, 'side', 'files'],
    [2.0, 'main', 'file'],
    [2.2, 'main', 'browser'],
    [2.2, 'strip', 'hidden'],
    [1.0, 'side', 'hidden'],
    [1.0, 'sidebar', 'hidden'],
    [0.9, 'main', 'terminal'],
    [3.2, 'sidebar', 'sidebar'],
    [0.5, 'side', 'changes'],
    [0.5, 'strip', 'strip'],
  ];
  let i = 0;
  const next = () => {
    if (!auto) return;
    const [wait, place, value] = STORY[i % STORY.length];
    timer = window.setTimeout(() => { if (!auto) return; set(place, value); i++; next(); }, wait * 1000);
  };
  new IntersectionObserver(([e]) => {
    clearTimeout(timer);
    if (e.isIntersecting && auto) next();
  }, { threshold: 0.4 }).observe(win);

  // ?panes=quiet holds the folded window, for screenshots.
  if (new URLSearchParams(location.search).get('panes') === 'quiet') {
    auto = false;
    (['strip', 'side', 'sidebar'] as Place[]).forEach((p) => set(p, 'hidden', true));
  }
}
