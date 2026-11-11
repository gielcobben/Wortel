// A film with chapters.
//
// A stage (components/Stage.astro) has a row of chapter tabs and a caption per
// chapter. A scene hands film() one function per chapter that puts the window
// in that chapter's state. Chapters play by themselves while the stage is on
// screen, each for its `hold`; pressing a tab (or the arrow keys on the row)
// goes there and stops the autoplay, so the reader is never fought for control.
// Reduced motion: no autoplay, and the scene opens on its most telling chapter.
import { reduced } from './app';

export interface Scene {
  /** Put the window in this chapter's state. `animate` is false on first paint. */
  enter(animate: boolean): void;
  /** Seconds this chapter holds while playing by itself. */
  hold: number;
}

export interface Film {
  /** Run something later in this chapter; dropped if the chapter changes first. */
  later(fn: () => void, seconds: number): void;
  go(i: number, byHand?: boolean): void;
}

export function film(root: HTMLElement, make: (f: Film) => Scene[], still = 0): Film {
  const tabs = Array.from(root.querySelectorAll<HTMLButtonElement>('[data-chapter]'));
  const caps = Array.from(root.querySelectorAll<HTMLElement>('[data-caption]'));
  let current = -1, auto = !reduced(), onScreen = false;
  let advance = 0;
  const pending = new Set<number>();

  const f: Film = {
    later(fn, seconds) {
      const id = window.setTimeout(() => { pending.delete(id); fn(); }, seconds * 1000);
      pending.add(id);
    },
    go(i, byHand = false) {
      if (byHand) { auto = false; root.classList.remove('auto'); }
      clearTimeout(advance);
      pending.forEach(clearTimeout); pending.clear();
      const first = current < 0;
      current = (i + scenes.length) % scenes.length;
      tabs.forEach((t, k) => { t.setAttribute('aria-selected', String(k === current)); t.tabIndex = k === current ? 0 : -1; });
      caps.forEach((c, k) => c.classList.toggle('on', k === current));
      root.style.setProperty('--hold', `${scenes[current].hold}s`);
      scenes[current].enter(!first);
      if (byHand) tabs[current]?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
      schedule();
    },
  };
  const scenes = make(f);

  function schedule() {
    clearTimeout(advance);
    if (!auto || !onScreen) return;
    // Restart the tab's progress fill from zero.
    root.classList.remove('auto'); void root.offsetWidth; root.classList.add('auto');
    advance = window.setTimeout(() => f.go(current + 1), scenes[current].hold * 1000);
  }

  tabs.forEach((t, i) => {
    t.addEventListener('click', () => f.go(i, true));
    t.addEventListener('keydown', (e) => {
      const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (!d) return;
      e.preventDefault();
      f.go(current + d, true);
      tabs[current].focus();
    });
  });

  f.go(reduced() ? still : 0);
  new IntersectionObserver(([e]) => {
    onScreen = e.isIntersecting;
    if (onScreen) { if (auto) f.go(current); } else { clearTimeout(advance); root.classList.remove('auto'); }
  }, { threshold: 0.45 }).observe(root);
  return f;
}
