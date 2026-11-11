// Motion for the homepage's sections below the panes.
//
// Two kinds: scrubbed (the statement lighting up, the branches growing), where
// scroll position is the playhead, and played (the terminals typing, the
// agents loop, the quit loop), which start when they come on screen and pause
// when they leave. Nothing locks the scroll.
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';

gsap.registerPlugin(ScrollTrigger);
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Run `play` when el enters the viewport; pause the returned timeline when it leaves. */
function whileVisible(el: Element, make: () => gsap.core.Timeline) {
  let tl: gsap.core.Timeline | null = null;
  ScrollTrigger.create({
    trigger: el,
    start: 'top 85%',
    end: 'bottom 15%',
    onToggle: (self) => {
      if (self.isActive) { tl ??= make(); tl.play(); } else tl?.pause();
    },
  });
}

// ---- the statement: words light up as it passes ---------------------------
for (const p of document.querySelectorAll<HTMLElement>('[data-lit]')) {
  const words = Array.from(p.querySelectorAll('span'));
  if (reduced) { words.forEach((w) => w.classList.add('lit')); continue; }
  ScrollTrigger.create({
    trigger: p,
    start: 'top 85%',
    end: 'bottom 45%',
    scrub: true,
    onUpdate: (self) => {
      const n = Math.round(self.progress * words.length);
      words.forEach((w, i) => w.classList.toggle('lit', i < n));
    },
  });
}

// ---- worktrees: the branches grow out of main ------------------------------
for (const g of document.querySelectorAll<SVGElement>('[data-graph]')) {
  const brs = Array.from(g.querySelectorAll<SVGGElement>('.br'));
  const tl = gsap.timeline({ defaults: { ease: 'none' } });
  brs.forEach((b, i) => {
    const line = b.querySelector('.line')!;
    const dots = b.querySelectorAll('.c');
    const tag = b.querySelector('.tag');
    const start = i * 0.18;
    tl.fromTo(line, { strokeDasharray: 1, strokeDashoffset: 1 }, { strokeDashoffset: 0, duration: 1 }, start);
    tl.fromTo(tag, { opacity: 0, y: 6 }, { opacity: 1, y: 0, duration: 0.2 }, start + 0.15);
    tl.fromTo(dots, { scale: 0, transformOrigin: '50% 50%' }, { scale: 1, duration: 0.08, stagger: 0.1 }, start + 0.25);
  });
  if (reduced) { tl.progress(1); continue; }
  ScrollTrigger.create({ trigger: g, start: 'top 85%', end: 'bottom 35%', scrub: 0.5, animation: tl });
}

// ---- terminals type when they come on screen -------------------------------
function typeTimeline(term: HTMLElement) {
  const lines = Array.from(term.querySelectorAll<HTMLElement>('.ln:not(.cur)'));
  const cur = term.querySelector<HTMLElement>('.ln.cur')!;
  lines.forEach((l) => (l.hidden = true));
  const tl = gsap.timeline({ paused: true });
  let t = 0.4;
  for (const l of lines) {
    t += Number(l.dataset.pause || 0);
    const cmd = l.dataset.cmd;
    if (cmd !== undefined) {
      const typed = l.querySelector<HTMLElement>('.typed')!;
      tl.call(() => { l.hidden = false; typed.textContent = ''; l.after(cur); cur.hidden = true; }, [], t);
      const per = Math.min(0.045, 1.4 / Math.max(cmd.length, 1));
      for (let i = 1; i <= cmd.length; i++) tl.call(() => { typed.textContent = cmd.slice(0, i); }, [], t + i * per);
      t += cmd.length * per + 0.35;
    } else {
      tl.call(() => { l.hidden = false; }, [], t);
      t += 0.12;
    }
  }
  tl.call(() => { term.querySelector('[data-screen]')!.appendChild(cur); cur.hidden = false; }, [], t + 0.1);
  return tl;
}
for (const term of document.querySelectorAll<HTMLElement>('[data-term]')) {
  if (term.closest('[data-survival]')) continue;
  if (reduced) continue;
  const tl = typeTimeline(term);
  ScrollTrigger.create({ trigger: term, start: 'top 75%', once: true, onEnter: () => tl.play(0) });
}

// ---- font size: the one setting ----------------------------------------------
for (const demo of document.querySelectorAll<HTMLElement>('[data-fontdemo]')) {
  const screen = demo.querySelector<HTMLElement>('[data-screen]')!;
  let size = 14;
  demo.querySelectorAll<HTMLButtonElement>('[data-font]').forEach((b) => b.addEventListener('click', () => {
    const d = Number(b.dataset.font);
    size = d === 0 ? 14 : Math.max(10, Math.min(22, size + d * 2));
    gsap.to(screen, { fontSize: size, lineHeight: `${Math.round(size * 1.36)}px`, duration: 0.25, ease: 'power2.out' });
  }));
}

// ---- survival: quit, and the work goes on ------------------------------------
for (const v of document.querySelectorAll<HTMLElement>('[data-survival]')) {
  const frame = v.querySelector<HTMLElement>('[data-frame]')!;
  const ghost = v.querySelector<HTMLElement>('[data-ghost]')!;
  const key = v.querySelector<HTMLElement>('[data-key]')!;
  const lines = Array.from(v.querySelectorAll<HTMLElement>('.ln:not(.cur)'));
  const cur = v.querySelector<HTMLElement>('.ln.cur')!;
  if (reduced) continue;
  whileVisible(v, () => {
    const tl = gsap.timeline({ repeat: -1, repeatDelay: 1.2 });
    tl.call(() => { lines.forEach((l, i) => (l.hidden = i > 0)); cur.hidden = false; }, [], 0);
    tl.set(frame, { opacity: 1, scale: 1, filter: 'blur(0px)' }, 0);
    tl.set(ghost, { opacity: 0 }, 0);
    // the agent works for a moment
    tl.call(() => { lines[1].hidden = false; }, [], 0.8);
    // ⌘Q
    tl.fromTo(key, { opacity: 0, y: 8 }, { opacity: 1, y: 0, duration: 0.3 }, 1.6);
    tl.to(key.querySelectorAll('kbd'), { y: 2, duration: 0.08, yoyo: true, repeat: 1 }, 2.1);
    tl.to(key, { opacity: 0, duration: 0.3 }, 2.6);
    tl.to(frame, { opacity: 0, scale: 0.94, filter: 'blur(6px)', duration: 0.5, ease: 'power2.in' }, 2.2);
    tl.to(ghost, { opacity: 1, duration: 0.4 }, 2.6);
    // meanwhile, out of sight, it keeps going
    lines.slice(2, 6).forEach((l, i) => tl.call(() => { l.hidden = false; }, [], 3.0 + i * 0.6));
    // reopen: everything it did is there
    tl.to(ghost, { opacity: 0, duration: 0.3 }, 5.8);
    tl.to(frame, { opacity: 1, scale: 1, filter: 'blur(0px)', duration: 0.7, ease: 'expo.out' }, 5.9);
    lines.slice(6).forEach((l, i) => tl.call(() => { l.hidden = false; }, [], 6.9 + i * 0.5));
    tl.set({}, {}, 9.5);
    return tl;
  });
}

// ---- agents: who needs you ---------------------------------------------------
for (const v of document.querySelectorAll<HTMLElement>('[data-agents]')) {
  const row = (n: string) => v.querySelector<HTMLElement>(`[data-name="${n}"]`);
  const hero = row('Landing page hero');
  const working = row('Marketing screenshots')?.querySelector<HTMLElement>('[data-name="Status"]');
  const note = v.querySelector<HTMLElement>('[data-note]')!;
  if (!hero || !working) continue;
  // Give "Landing page hero" a status slot of its own: dots, then an orange dot.
  hero.classList.add('relative');
  const status = working.cloneNode(true) as HTMLElement;
  const dots = status.querySelector<HTMLElement>('[data-name="Working"]')!;
  const orange = document.createElement('div');
  orange.className = 'size-[7px] rounded-full bg-chart-1';
  orange.style.cssText = 'position:absolute;inset:0;margin:auto;opacity:0';
  status.appendChild(orange);
  hero.appendChild(status);
  const allDots = v.querySelectorAll('[data-name="Working"] > div');
  gsap.to(allDots, { opacity: 0.2, duration: 0.5, ease: 'sine.inOut', stagger: { each: 0.18, repeat: -1, yoyo: true } });
  if (reduced) { gsap.set(dots, { opacity: 0 }); gsap.set(orange, { opacity: 1 }); gsap.set(note, { opacity: 1, x: 0 }); continue; }
  whileVisible(v, () => {
    const tl = gsap.timeline({ repeat: -1, repeatDelay: 0.8 });
    tl.set(dots, { opacity: 1 }, 0).set(orange, { opacity: 0, scale: 1 }, 0).set(note, { opacity: 0, x: 380 }, 0);
    tl.to(dots, { opacity: 0, duration: 0.2 }, 2.4);
    tl.fromTo(orange, { opacity: 0, scale: 0 }, { opacity: 1, scale: 1, duration: 0.4, ease: 'back.out(3)' }, 2.5);
    tl.to(note, { opacity: 1, x: 0, duration: 0.7, ease: 'expo.out' }, 2.8);
    tl.to(note, { opacity: 0, x: 380, duration: 0.5, ease: 'power2.in' }, 6.6);
    tl.set({}, {}, 7.4);
    return tl;
  });
}
