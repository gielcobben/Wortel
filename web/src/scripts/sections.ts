// Motion inside the homepage's shots below the panes. Both are loops that
// start when their shot comes on screen and pause when it leaves. Nothing is
// tied to scroll.
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';

gsap.registerPlugin(ScrollTrigger);
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Build the timeline when el enters the viewport; pause it when it leaves. */
function whileVisible(el: Element, make: () => gsap.core.Timeline) {
  let tl: gsap.core.Timeline | null = null;
  ScrollTrigger.create({
    trigger: el,
    start: 'top 80%',
    end: 'bottom 20%',
    onToggle: (self) => {
      if (self.isActive) { tl ??= make(); tl.play(); } else tl?.pause();
    },
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

// ---- survival: quit, and the work goes on ------------------------------------
for (const v of document.querySelectorAll<HTMLElement>('[data-survival]')) {
  const frame = v.querySelector<HTMLElement>('[data-frame]')!;
  const ghost = v.querySelector<HTMLElement>('[data-ghost]')!;
  const key = v.querySelector<HTMLElement>('[data-key]')!;
  // The agent's last lines are what the window "missed" while it was closed.
  const term = v.querySelector<HTMLElement>('[data-name="Terminal"]');
  const lines = term ? (Array.from(term.children) as HTMLElement[]) : [];
  const rule = lines.findIndex((l) => l.dataset.name === 'Rule');
  const missed = rule > 0 ? lines.slice(Math.max(0, rule - 7), rule) : [];
  const allDots = v.querySelectorAll('[data-name="Working"] > div');
  gsap.to(allDots, { opacity: 0.2, duration: 0.5, ease: 'sine.inOut', stagger: { each: 0.18, repeat: -1, yoyo: true } });
  if (reduced) continue;
  whileVisible(v, () => {
    const tl = gsap.timeline({ repeat: -1, repeatDelay: 1 });
    tl.call(() => missed.forEach((l) => l.setAttribute('hidden', '')), [], 0);
    tl.set(frame, { opacity: 1, scale: 1, y: 0 }, 0).set(ghost, { opacity: 0 }, 0).set(key, { opacity: 0, y: 8 }, 0);
    // ⌘Q
    tl.to(key, { opacity: 1, y: 0, duration: 0.3 }, 1.4);
    tl.to(key.querySelectorAll('kbd'), { y: 2, duration: 0.08, yoyo: true, repeat: 1 }, 1.9);
    tl.to(frame, { opacity: 0, scale: 0.96, y: 16, duration: 0.45, ease: 'power2.in' }, 2.0);
    tl.to(key, { opacity: 0, duration: 0.3 }, 2.5);
    // closed: the lake, and the sessions still running
    tl.to(ghost, { opacity: 1, duration: 0.4 }, 2.6);
    tl.to(ghost, { opacity: 0, duration: 0.3 }, 5.4);
    // reopen: everything it did meanwhile is there
    tl.call(() => missed.forEach((l) => l.removeAttribute('hidden')), [], 5.5);
    tl.to(frame, { opacity: 1, scale: 1, y: 0, duration: 0.8, ease: 'expo.out' }, 5.6);
    tl.set({}, {}, 9.5);
    return tl;
  });
}
