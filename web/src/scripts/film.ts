// A film with chapters.
//
// A stage (components/Stage.astro) has a bar: chapter tabs, a caption per
// chapter, play/pause. A scene hands film() one function per chapter that puts
// the window in that chapter's state. Chapters play by themselves while the
// stage is on screen, each for its `hold`. Pressing a tab, the arrow keys on
// the row, or anything in the window itself goes there and pauses, so the
// reader is never fought for control; play resumes from where they are.
// Reduced motion: paused from the start, on the scene's most telling chapter.
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
  /** The reader did something in the window: stop playing. */
  pause(): void;
  /** The window is in a state no chapter describes: say the stage's own line. */
  own(): void;
  /** Mark a chapter as the one on screen without entering it. */
  mark(i: number): void;
  readonly current: number;
  readonly playing: boolean;
}

export function film(root: HTMLElement, make: (f: Film) => Scene[], still = 0): Film {
  const tabs = Array.from(root.querySelectorAll<HTMLButtonElement>('[data-chapter]'));
  const caps = Array.from(root.querySelectorAll<HTMLElement>('[data-caption]'));
  const row = root.querySelector<HTMLElement>('.chapters');
  const thumb = root.querySelector<HTMLElement>('.thumb');
  const play = root.querySelector<HTMLButtonElement>('[data-play]');
  let current = -1, auto = !reduced(), onScreen = false;
  let advance = 0;
  const pending = new Set<number>();

  const setAuto = (on: boolean) => {
    auto = on;
    if (!on) { clearTimeout(advance); root.classList.remove('auto'); }
    play?.setAttribute('aria-pressed', String(!on));
    play?.setAttribute('aria-label', on ? 'Pause' : 'Play');
  };

  // The thumb sits under the current tab.
  const place = () => {
    const t = tabs[current];
    if (!row || !t || root.classList.contains('own')) return;
    row.style.setProperty('--tx', `${t.offsetLeft}px`);
    row.style.setProperty('--tw', `${t.offsetWidth}px`);
  };
  const say = (key: string) => caps.forEach((c) => c.classList.toggle('on', c.dataset.caption === key));
  const select = (i: number) => {
    current = i;
    root.classList.remove('own');
    tabs.forEach((t, k) => { t.setAttribute('aria-selected', String(k === i)); t.tabIndex = k === i ? 0 : -1; });
    say(String(i));
    place();
  };

  const f: Film = {
    get current() { return current; },
    get playing() { return auto; },
    later(fn, seconds) {
      const id = window.setTimeout(() => { pending.delete(id); fn(); }, seconds * 1000);
      pending.add(id);
    },
    pause() { setAuto(false); },
    own() {
      setAuto(false);
      root.classList.add('own');
      tabs.forEach((t) => t.setAttribute('aria-selected', 'false'));
      say('own');
    },
    mark(i) { select(i); },
    go(i, byHand = false) {
      if (byHand) setAuto(false);
      clearTimeout(advance);
      pending.forEach(clearTimeout); pending.clear();
      const first = current < 0;
      select((i + scenes.length) % scenes.length);
      root.style.setProperty('--hold', `${scenes[current].hold}s`);
      scenes[current].enter(!first);
      if (byHand && row) {
        const t = tabs[current];
        row.scrollTo({ left: t.offsetLeft - (row.clientWidth - t.offsetWidth) / 2, behavior: 'smooth' });
      }
      schedule();
    },
  };
  const scenes = make(f);

  function schedule() {
    clearTimeout(advance);
    root.classList.remove('auto');
    if (!auto || !onScreen) return;
    // Restart the thumb's fill from zero.
    void root.offsetWidth; root.classList.add('auto');
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
  play?.addEventListener('click', () => {
    if (auto) { setAuto(false); return; }
    setAuto(true);
    // From an arrangement of the reader's own, pick the film back up at the start.
    if (root.classList.contains('own')) f.go(0); else schedule();
  });

  if (reduced()) setAuto(false);
  f.go(reduced() ? still : 0);
  // The first placement has nothing to slide from.
  requestAnimationFrame(() => { place(); requestAnimationFrame(() => thumb?.classList.remove('still')); });
  window.addEventListener('resize', place);
  document.fonts?.ready.then(place);

  new IntersectionObserver(([e]) => {
    onScreen = e.isIntersecting;
    if (onScreen) schedule(); else { clearTimeout(advance); root.classList.remove('auto'); }
  }, { threshold: 0.45 }).observe(root);
  return f;
}
