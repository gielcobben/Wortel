// The panes section: one GSAP timeline, played a step at a time.
//
// The timeline is written like a film's storyboard: each step has a named start
// and a hold, so retiming a beat is one number. A step plays to the end of its
// hold; the steps advance by themselves while the section is on screen, and a
// click on one stops that and goes there. Scrolling is never involved.
//
// ?panes=<seconds> seeks the timeline and freezes it, for screenshots.
import { gsap } from 'gsap';

const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

export function initPanes() {
  const root = document.querySelector<HTMLElement>('[data-panes]');
  if (!root) return;
  const win = root.querySelector<HTMLElement>('[data-pwin]');
  if (!win) return;

  const slot = (k: string) => win.querySelector<HTMLElement>(`[data-slot="${k}"]`)!;
  const pane = (k: string) => win.querySelector<HTMLElement>(`[data-pane="${k}"]`)!;
  const ph = (k: string) => slot(k).querySelector<HTMLElement>('[data-ph]')!;
  const div = (k: string) => win.querySelector<HTMLElement>(`[data-div="${k}"]`)!;
  const mainBar = pane('terminal').querySelector<HTMLElement>('[data-name="Main bar"]');

  const caps = Array.from(root.querySelectorAll<HTMLElement>('[data-cap]'));
  const steps = Array.from(root.querySelectorAll<HTMLButtonElement>('[data-goto]'));

  // ---- storyboard ---------------------------------------------------------
  // [start of the step's motion, end of its hold]
  const S = {
    sidebar: [0.6, 2.4],
    main: [2.4, 4.2],
    side: [4.2, 7.4],
    strip: [7.4, 9.0],
    anywhere: [9.0, 11.0],
    quiet: [11.0, 13.2],
  } as const;
  const order = Object.keys(S) as (keyof typeof S)[];
  const IN = { duration: 0.8, ease: 'power3.out' };
  const SWAP = { duration: 0.5, ease: 'power2.inOut' };

  const all = ['sidebar', 'terminal', 'browser', 'strip', 'changes', 'history', 'files', 'file'];
  gsap.set(all.map(pane), { autoAlpha: 0 });

  const tl = gsap.timeline({ paused: true, defaults: { ease: 'power2.inOut' } });
  tl.set({}, {}, 0);

  // 01 sidebar
  tl.to(ph('sidebar'), { autoAlpha: 0, scale: 0.98, duration: 0.4 }, S.sidebar[0]);
  tl.fromTo(pane('sidebar'), { autoAlpha: 0, x: -24 }, { autoAlpha: 1, x: 0, ...IN }, S.sidebar[0] + 0.1);

  // 02 main
  tl.to(ph('main'), { autoAlpha: 0, scale: 0.98, duration: 0.4 }, S.main[0]);
  tl.fromTo(pane('terminal'), { autoAlpha: 0, y: 24 }, { autoAlpha: 1, y: 0, ...IN }, S.main[0] + 0.1);

  // 03 side column, then the column cycles through its three panes
  tl.to(ph('side'), { autoAlpha: 0, scale: 0.98, duration: 0.4 }, S.side[0]);
  tl.fromTo(pane('changes'), { autoAlpha: 0, x: 24 }, { autoAlpha: 1, x: 0, ...IN }, S.side[0] + 0.1);
  // One pane out, then the next in: never two dense layers at once.
  const OUT = { duration: 0.25, ease: 'power1.in' }, INN = { duration: 0.35, ease: 'power2.out' };
  tl.to(pane('changes'), { autoAlpha: 0, ...OUT }, S.side[0] + 1.3);
  tl.fromTo(pane('history'), { autoAlpha: 0, y: 8 }, { autoAlpha: 1, y: 0, ...INN }, S.side[0] + 1.55);
  tl.to(pane('history'), { autoAlpha: 0, ...OUT }, S.side[0] + 2.3);
  tl.fromTo(pane('files'), { autoAlpha: 0, y: 8 }, { autoAlpha: 1, y: 0, ...INN }, S.side[0] + 2.55);

  // 04 bottom strip
  tl.to(ph('strip'), { autoAlpha: 0, scale: 0.98, duration: 0.4 }, S.strip[0]);
  tl.fromTo(pane('strip'), { autoAlpha: 0, y: 32 }, { autoAlpha: 1, y: 0, ...IN }, S.strip[0] + 0.1);

  // 05 any tab, any place: a browser takes the main area, a plan the column
  tl.to(pane('terminal'), { autoAlpha: 0, duration: 0.25, ease: 'power1.in' }, S.anywhere[0]);
  tl.fromTo(pane('browser'), { autoAlpha: 0, y: 12 }, { autoAlpha: 1, y: 0, duration: 0.4, ease: 'power2.out' }, S.anywhere[0] + 0.25);
  tl.to(pane('files'), { autoAlpha: 0, duration: 0.25, ease: 'power1.in' }, S.anywhere[0] + 0.7);
  tl.fromTo(pane('file'), { autoAlpha: 0, y: 12 }, { autoAlpha: 1, y: 0, duration: 0.4, ease: 'power2.out' }, S.anywhere[0] + 0.95);

  // 06 quiet: everything folds away and the terminal has the window
  const q = S.quiet[0];
  tl.to(pane('browser'), { autoAlpha: 0, duration: 0.25, ease: 'power1.in' }, q);
  tl.to(pane('terminal'), { autoAlpha: 1, y: 0, duration: 0.4, ease: 'power2.out' }, q + 0.25);
  tl.to(slot('sidebar'), { width: 0, duration: 1, ease: 'power3.inOut' }, q + 0.3);
  tl.to(div('sidebar'), { autoAlpha: 0, duration: 0.3 }, q + 1.0);
  if (mainBar) tl.to(mainBar, { paddingLeft: 84, duration: 1, ease: 'power3.inOut' }, q + 0.3);
  tl.to(slot('side'), { width: 0, duration: 1, ease: 'power3.inOut' }, q + 0.5);
  tl.to(div('side'), { autoAlpha: 0, duration: 0.3 }, q + 1.2);
  tl.to(slot('strip'), { height: 0, duration: 1, ease: 'power3.inOut' }, q + 0.7);
  tl.set({}, {}, S.quiet[1]);

  // ---- on a phone, the stage pans to the place the step is about ----------
  const phone = matchMedia('(max-width: 700px)');
  const focus: Record<string, string | null> = { sidebar: 'sidebar', main: 'main', side: 'side', strip: 'strip', anywhere: 'side', quiet: null };
  const pan = (idx: number) => {
    if (!phone.matches) { gsap.set(win, { x: 0 }); return; }
    const box = win.parentElement!;
    const k = idx < 0 ? 'sidebar' : focus[order[idx]];
    let x = 0;
    if (k) {
      const el = slot(k);
      const r = el.getBoundingClientRect(), w = win.getBoundingClientRect();
      const centre = r.left - w.left + r.width / 2;
      x = Math.min(0, Math.max(box.clientWidth - win.offsetWidth, box.clientWidth / 2 - centre));
    }
    gsap.to(win, { x, duration: 0.7, ease: 'power3.inOut', overwrite: 'auto' });
  };

  // ---- captions follow the playhead ---------------------------------------
  let current = -2;
  const sync = (time: number) => {
    let idx = -1;
    order.forEach((k, i) => { if (time >= S[k][0] - 0.2) idx = i; });
    if (idx === current) return;
    current = idx;
    caps.forEach((c, i) => c.classList.toggle('on', i === Math.max(0, idx)));
    steps.forEach((s, i) => s.setAttribute('aria-selected', String(i === Math.max(0, idx))));
    pan(idx);
  };

  const params = new URLSearchParams(location.search);
  if (params.has('panes')) {
    const t = Number(params.get('panes'));
    tl.seek(t); sync(t);
    return;
  }

  sync(0);

  // Go to a step: play forward through the beats in between, or, going back,
  // jump to just before the step and play its own beat.
  let step = -1;
  const go = (i: number) => {
    step = i;
    const k = order[i];
    const end = S[k][1] - 0.2;
    if (end < tl.time()) tl.seek(S[k][0] - 0.05);
    tl.tweenTo(end, { duration: Math.min(2.4, Math.max(0.8, end - tl.time())), ease: 'none', onUpdate: () => sync(tl.time()) });
    sync(S[k][0]);
  };

  // While the section is on screen the steps advance by themselves; a click
  // anywhere in the row hands control to the reader for good.
  const HOLD = 5000;
  let timer = 0, auto = !reduced();
  const tick = () => {
    clearTimeout(timer);
    if (!auto) return;
    go((step + 1) % order.length);
    timer = window.setTimeout(tick, step === order.length - 1 ? HOLD + 1500 : HOLD);
  };
  new IntersectionObserver(([e]) => {
    if (e.isIntersecting) { if (auto && !timer) tick(); }
    else { clearTimeout(timer); timer = 0; }
  }, { threshold: 0.5 }).observe(win);

  steps.forEach((b, i) => b.addEventListener('click', () => { auto = false; clearTimeout(timer); go(i); }));
  if (reduced()) { tl.seek(S.side[1] - 0.2); sync(tl.time()); step = 2; }
}
