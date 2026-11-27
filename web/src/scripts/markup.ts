// The mark-up scene: a page is pointed at in the browser split, a sentence is
// written around the marks, Return copies it, and it is pasted into the
// agent in the terminal split. Cause in one split, effect in the other, and
// before and after in the same pixels: the page is as it was once the note
// is copied.
//
// Every state is a layer of the canvas's own (MarkUpPage, NotePasted),
// shown or hidden: the lit button, the hover outline, the two marks, the
// note bar and the words and chips in it, the checkmark the button shows for
// 1.4 s after a copy (MarkupButton.swift: justCopied). What this adds is
// where the marks are when the split is not the 537 the page was captured
// at, the pointer's moves, and the typing.
//
// components/films/MarkupFilm.astro is the window it plays in.
import { gsap } from 'gsap';
import { Pointer, Sidebar, Terminal, foldable, named, pressKeys, reduced, schemePictures, wholeRows } from './app';
import { film } from './film';

const HERO = 'Landing page hero';
/** The width the page was captured at, and the canvas's marks drawn for. */
const PAGE = 537;
/** A character, typed. */
const TYPE = 0.055;
/** From a key going down to the app answering. */
const BEAT = 0.5;
const REPLY = "I'll make the link use the accent colour and give the paragraph more room above it.";

export function initMarkup() {
  const v = document.querySelector<HTMLElement>('[data-film="markup"]');
  const win = v?.querySelector<HTMLElement>('[data-mwin]');
  if (!v || !win) return;
  const box = win.parentElement!;
  const termSplit = win.querySelector<HTMLElement>('[data-split="terminal"]')!;
  const webSplit = win.querySelector<HTMLElement>('[data-split="browser"]')!;
  const keys = (k: string) => v.querySelector<HTMLElement>(`[data-keys="${k}"]`)!;
  const keyMark = keys('markup'), keyCopy = keys('copy'), keyPaste = keys('paste'), keySend = keys('send'), said = keys('copied');

  // ---- the window -------------------------------------------------------------
  // The session building the landing page, selected (its tab and transcript
  // are the canvas's own).
  const sb = new Sidebar(named(win, 'Sidebar')!);
  sb.show(['Section web', HERO, 'Changelog typography', 'Pricing FAQ copy', 'Section Sessions', 'Quicker panes', 'Marketing screenshots']);
  sb.select(HERO);
  foldable(win, v.querySelector<HTMLTemplateElement>('template[data-tpl="lead"]')?.content);

  // ---- the page and what is drawn over it ---------------------------------------
  const page = named(webSplit, 'Page')!;
  schemePictures(page);
  const button = named(webSplit, 'Mark Up')!;
  const lit = named(button, 'Lit')!, copied = named(button, 'Copied')!, pencil = named(button, 'pencil.tip.crop.circle')!;
  const outline = named(page, 'Hover outline')!;
  const mark1 = named(page, 'Mark 1')!, mark2 = named(page, 'Mark 2')!;
  const badge2 = named(mark2, 'Badge')!;
  const bar = named(page, 'Note bar')!;
  const placeholder = named(bar, 'Placeholder')!;
  const note = named(bar, 'Note')!;
  const caret = named(note, 'Caret')!;
  const chips = [named(note, 'Chip 1')!, named(note, 'Chip 2')!];
  const words = [1, 2, 3, 4].map((i) => named(note, `Words ${i}`)!);
  const SAID = words.map((w) => w.textContent || '');

  // The canvas places the marks in the page's points at 537. A narrower split
  // shows the same page smaller (MarkupFilm.astro), so they are placed at its
  // scale; at 537 that is where the canvas has them.
  type Box = { l: number; t: number; w: number; h: number };
  const drawn = new Map<HTMLElement, Box>([outline, mark1, mark2].map((el) => {
    const cs = getComputedStyle(el);
    return [el, { l: parseFloat(cs.left), t: parseFloat(cs.top), w: parseFloat(cs.width), h: parseFloat(cs.height) }] as const;
  }));
  // With the sidebar hidden from the start (MarkupFilm.astro, bare) the
  // browser is the larger split, and from 640 wide it shows the page as it
  // was captured at a wide split, 1074 points (public/img/page-wide-*.webp).
  // That is another layout of the same page, so the same two things are
  // somewhere else in it: the paragraph and the button, measured on the site
  // at that width (2026-11-27) and given the room the canvas gives them (8
  // around the paragraph, 2 around the button, 1 for the hover outline).
  // Retake the picture and these go with it.
  const WIDE = 1074;
  const wider = new Map<HTMLElement, Box>([
    [outline, { l: 31, t: 383, w: 204, h: 42 }],
    [mark1, { l: 30, t: 382, w: 206, h: 44 }],
    [mark2, { l: 24, t: 288, w: 576, h: 72 }],
  ]);
  // There the narrow picture is a retake too. The canvas's was taken before
  // the hero's stage had arrived, so under the buttons it shows an empty box
  // where the window on the lake is. The retake is this site at the same 537
  // with the hero held (public/img/page-narrow-*.webp): the same layout to
  // the point, so the canvas's marks are where they were.
  const dark = matchMedia('(prefers-color-scheme: dark)');
  const wides = !win.hasAttribute('data-bare') ? [] : Array.from(page.querySelectorAll<HTMLImageElement>(':scope > img')).map((narrow) => {
    const retake = `/img/page-narrow-${narrow.classList.contains('dark:block') ? 'dark' : 'light'}.webp`;
    // schemePictures keeps the address of the one not in use in data-src.
    if (narrow.dataset.src) narrow.dataset.src = retake; else narrow.src = retake;
    const img = narrow.cloneNode(false) as HTMLImageElement;
    img.removeAttribute('src');
    delete img.dataset.src;
    img.dataset.wide = img.classList.contains('dark:block') ? 'dark' : 'light';
    narrow.after(img);
    return img;
  });
  const wide = () => wides.length > 0 && page.clientWidth >= 640;
  const shapes = () => (wide() ? wider : drawn);
  const scale = () => (page.clientWidth || PAGE) / (wide() ? WIDE : PAGE);
  // Of the wide picture's two, only the one the colour scheme shows is fetched.
  const picture = () => {
    page.toggleAttribute('data-wide', wide());
    if (wide()) wides.forEach((img) => { if (!img.src && (img.dataset.wide === 'dark') === dark.matches) img.src = `/img/page-wide-${img.dataset.wide}.webp`; });
  };
  dark.addEventListener('change', picture);
  const drag = { p: 1 };
  const place = () => {
    picture();
    const s = scale();
    for (const [el, r] of shapes()) {
      const p = el === mark2 ? drag.p : 1;
      Object.assign(el.style, { left: `${r.l * s}px`, top: `${r.t * s}px`, width: `${r.w * s * p}px`, height: `${r.h * s * p}px` });
    }
  };
  new ResizeObserver(place).observe(page);
  place();

  // ---- the note -----------------------------------------------------------------
  // The canvas lays the note out as a row that wraps: words, then a chip,
  // then words. A line break a text view would make is a break here, put in
  // where the finished sentence wraps, so a word being typed never jumps from
  // the end of one line to the start of the next.
  const breaks: HTMLElement[] = [];
  const unbreak = () => breaks.splice(0).forEach((b) => b.remove());
  const breakBefore = (el: HTMLElement) => {
    const b = document.createElement('div');
    b.style.cssText = 'flex-basis:100%;height:0';
    el.before(b);
    breaks.push(b);
  };
  const setNote = (marks: number, typed: string[]) => {
    unbreak();
    chips.forEach((c, i) => (c.hidden = i >= marks));
    words.forEach((w, i) => { w.textContent = typed[i] || ''; w.hidden = !typed[i]; });
    note.append(caret);
    placeholder.hidden = marks > 0 || typed.some(Boolean);
  };
  /** The finished sentence at this width: what each part says, and which of
   *  them start a line. "needs" and "more" are two layers with no space
   *  between them, since the canvas wraps the line there: where the two
   *  meet on one line, the second brings the space. */
  const plan = () => {
    setNote(2, SAID);
    const text = [...SAID];
    const top = (el: HTMLElement) => el.offsetTop;
    let force = false;
    if (top(words[3]) === top(words[2])) {
      words[3].textContent = ` ${SAID[3]}`;
      if (top(words[3]) === top(words[2])) text[3] = ` ${SAID[3]}`;
      else { words[3].textContent = SAID[3]; force = true; }
    }
    const order = [words[0], chips[0], words[1], chips[1], words[2], words[3]];
    const starts = words.map((w, k) => {
      const at = order.indexOf(w);
      return k === 3 && force ? true : at > 0 && top(w) > top(order[at - 1]);
    });
    // A part that starts a line does not start it with a space.
    starts.forEach((s, k) => { if (s) text[k] = text[k].trimStart(); });
    return { text, starts, force };
  };
  /** The sentence as it is once written. */
  const written = () => {
    const { text, force } = plan();
    setNote(2, text);
    if (force) breakBefore(words[3]);
  };

  // The bar is pinned to the bottom of the page, so a line more grows it
  // upwards. While it grows its contents hold to its bottom edge.
  let moving = false;
  const grow = (fn: () => void) => {
    const from = bar.offsetHeight;
    fn();
    const to = bar.offsetHeight;
    if (!moving || from === to) return;
    bar.style.justifyContent = 'flex-end';
    gsap.fromTo(bar, { height: from }, { height: to, duration: 0.2, ease: 'power2.out', clearProps: 'height', onComplete: () => { bar.style.justifyContent = ''; } });
  };

  // ---- the terminal -------------------------------------------------------------
  const term = new Terminal(named(termSplit, 'Terminal')!);
  const home = term.lines();
  const glyph = term.prompt.firstElementChild!;
  const PASTED = term.prompt.textContent!.replace(glyph.textContent || '', '').trim();
  const prompt = (text: string) => {
    while (glyph.nextSibling) glyph.nextSibling.remove();
    if (text) term.prompt.append(text);
  };
  let working = false;
  const busy = (on: boolean) => { if (working !== on) sb.status(HERO, on ? 'working' : 'none'); working = on; };
  /** Lines printed while the agent's status line is up go above it. */
  const above = (el: HTMLElement) => {
    const status = term.root.querySelector(':scope > [data-name="Status"]');
    if (status) status.before(el);
    return el;
  };
  const resetTerm = () => { term.idle(); term.swap(home); prompt(''); busy(false); };
  const pasted = () => {
    resetTerm();
    term.print('You', PASTED);
    term.gap();
    term.print('Claude', REPLY);
    term.status('Thinking…', '3s');
    busy(true);
  };

  // ---- on a phone, one split at a time --------------------------------------------
  // The browser while the page is pointed at, the terminal once the note is
  // pasted. The window is two splits wide there (MarkupFilm.astro) and pans.
  // The stage's 16px gutter would show the end of the split out of view
  // (its last column, the divider, the stubs of the prompt's rules): once
  // the pan has arrived, the window is cut at the edge of the split in view.
  // The cut sides only; the other three keep the window's shadow.
  const phone = matchMedia('(max-width: 760px)');
  let onTerm = false;
  const cutAt = () => !phone.matches ? ''
    : onTerm ? `inset(-64px ${webSplit.offsetWidth + 1}px -64px -64px)`
    : `inset(-64px -64px -64px ${termSplit.offsetWidth + 1}px)`;
  const pan = (toTerm: boolean, animate: boolean) => {
    const moving = onTerm !== toTerm && animate && !reduced();
    onTerm = toTerm;
    if (moving) win.style.clipPath = '';
    gsap.to(win, {
      x: phone.matches && !toTerm ? -(termSplit.offsetWidth + 1) : 0,
      duration: moving ? 0.6 : 0, ease: 'power3.inOut', overwrite: 'auto',
      onComplete: () => { win.style.clipPath = cutAt(); },
    });
  };
  phone.addEventListener('change', () => pan(onTerm, false));
  let seen = box.clientWidth;
  new ResizeObserver(() => { if (box.clientWidth !== seen) { seen = box.clientWidth; pan(onTerm, false); } }).observe(box);

  // ---- hands --------------------------------------------------------------------
  // Keys pressed in a split go where they cover nothing that matters.
  // Over the page: on the hero's photo, between the buttons and the note
  // bar. Over the terminal, which its transcript fills to the prompt: just
  // under the prompt, over the box's lower rule and the mode line.
  const overPage = (k: HTMLElement) => {
    const b = box.getBoundingClientRect(), p = page.getBoundingClientRect(), s = scale();
    const h = k.offsetHeight || 56;
    // The buttons end 10 over where the keys may start, and the photo
    // starts 36 under that.
    const link = shapes().get(mark1)!;
    const below = p.top - b.top + (link.t + link.h + 10) * s, photo = below + 36 * s;
    const above = bar.getBoundingClientRect().top - b.top + 8;
    k.style.left = `${p.left - b.left + p.width / 2}px`;
    k.style.top = `${Math.round(Math.max(below, Math.min((photo + above) / 2, above) - h / 2))}px`;
  };
  const overTerm = (k: HTMLElement) => {
    const b = box.getBoundingClientRect(), r = termSplit.getBoundingClientRect(), q = term.prompt.getBoundingClientRect();
    k.style.left = `${r.left - b.left + r.width / 2}px`;
    k.style.top = `${Math.round(q.bottom - b.top + 2)}px`;
  };
  const press = (k: HTMLElement, place: (k: HTMLElement) => void, hold = 1.1) => { place(k); pressKeys(gsap.timeline(), k, 0, hold); };
  const pointer = new Pointer(box);
  const hand = pointer.el;
  let handOut = false;
  /** Where a point of the page (in the canvas's points) is in the stage now. */
  const on = (x: number, y: number) => {
    const b = box.getBoundingClientRect(), r = page.getBoundingClientRect(), s = scale();
    return { x: r.left - b.left + x * s, y: r.top - b.top + y * s };
  };
  const travel = (to: { x: number; y: number }, seconds: number, ease = 'power3.inOut') => {
    if (!handOut) { gsap.set(hand, { x: to.x + 120, y: to.y + 90, opacity: 0, scale: 1 }); handOut = true; }
    gsap.to(hand, { opacity: 1, duration: 0.15 });
    gsap.to(hand, { x: to.x, y: to.y, duration: seconds, ease });
  };
  const down = (on: boolean) => gsap.to(hand, { scale: on ? 0.86 : 1, duration: 0.08, transformOrigin: '10% 6%' });
  const away = () => { pointer.hide(); handOut = false; };

  // ---- whole states ---------------------------------------------------------------
  type State = 'clean' | 'pointed' | 'written' | 'pasted';
  const ALL = [hand, bar, mark1, mark2, badge2, outline, drag, keyMark, keyCopy, keyPaste, keySend, said];
  /** Stop whatever a chapter left moving. */
  const cut = () => {
    moving = false;
    gsap.killTweensOf(ALL);
    for (const k of [keyMark, keyCopy, keyPaste, keySend, said]) {
      gsap.set(k, { opacity: 0 });
      const caps = Array.from(k.querySelectorAll('kbd'));
      if (caps.length) { gsap.killTweensOf(caps); gsap.set(caps, { y: 0 }); }
    }
    away();
  };
  /** Put the window in a state at once. */
  const show = (st: State) => {
    const marking = st === 'pointed' || st === 'written';
    lit.hidden = !marking;
    copied.hidden = true;
    pencil.hidden = false;
    outline.hidden = true;
    gsap.set([mark1, mark2, badge2, bar], { clearProps: 'opacity,visibility,transform,height' });
    bar.style.justifyContent = '';
    mark1.hidden = mark2.hidden = !marking;
    drag.p = 1;
    place();
    gsap.set(bar, { autoAlpha: marking ? 1 : 0 });
    if (st === 'written') written(); else setNote(marking ? 2 : 0, []);
    if (st === 'pasted') pasted(); else resetTerm();
  };

  const f = film(v, (f) => {
    const at = (fn: () => void, s: number) => f.later(fn, s);

    /** Point: Mark Up turns on, a click picks the link, a drag boxes the paragraph. */
    const point = () => {
      show('clean');
      setNote(0, []);
      pan(false, true);
      at(() => press(keyMark, overPage), 0);
      at(() => {
        lit.hidden = false;
        placeholder.hidden = false;
        gsap.fromTo(bar, { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: 0.35, ease: 'expo.out', clearProps: 'transform' });
      }, 0.4);
      // Over the link, its outline follows the pointer; a click marks it.
      at(() => { const r = shapes().get(mark1)!; travel(on(r.l + r.w / 2, r.t + r.h / 2), 0.7); }, 0.7);
      at(() => { outline.hidden = false; }, 1.25);
      at(() => {
        down(true);
        outline.hidden = true;
        mark1.hidden = false;
        gsap.fromTo(mark1, { opacity: 0 }, { opacity: 1, duration: 0.15, ease: 'power2.out' });
        grow(() => setNote(1, []));
      }, 1.8);
      at(() => down(false), 1.88);
      // A drag around the paragraph draws a box with it.
      at(() => { const r = shapes().get(mark2)!; travel(on(r.l, r.t), 0.6); }, 2.4);
      at(() => {
        down(true);
        drag.p = 0.02;
        badge2.style.visibility = 'hidden';
        mark2.hidden = false;
        place();
        gsap.to(drag, { p: 1, duration: 0.9, ease: 'power2.inOut', onUpdate: place });
        const r = shapes().get(mark2)!, end = on(r.l + r.w, r.t + r.h);
        gsap.to(hand, { x: end.x, y: end.y, duration: 0.9, ease: 'power2.inOut' });
      }, 3.1);
      at(() => {
        down(false);
        badge2.style.visibility = '';
        gsap.fromTo(badge2, { opacity: 0 }, { opacity: 1, duration: 0.15 });
        grow(() => setNote(2, []));
      }, 4.0);
      at(away, 4.5);
    };

    /** Say it: the sentence types itself around the chips. */
    const say = () => {
      show('pointed');
      pan(false, true);
      const { text, starts } = plan();
      setNote(2, []);
      let t = 0.4;
      text.forEach((part, k) => {
        [...part].forEach((_, i) => at(() => grow(() => {
          if (!i) {
            if (starts[k]) breakBefore(words[k]);
            words[k].hidden = false;
            words[k].after(caret);
          }
          words[k].textContent = part.slice(0, i + 1);
        }), t + i * TYPE));
        t += part.length * TYPE + 0.2;
      });
    };

    /** Copy: Return copies the note and turns mark-up off. */
    const copy = () => {
      show('written');
      pan(false, true);
      at(() => press(keyCopy, overPage, 0.6), 0.3);
      at(() => {
        // The marks, the bar and the lit fill go at once; the button says it copied.
        gsap.to([mark1, mark2, bar], { autoAlpha: 0, duration: 0.15, ease: 'power2.out' });
        lit.hidden = true;
        pencil.hidden = true;
        copied.hidden = false;
      }, 0.3 + BEAT);
      at(() => { overPage(said); gsap.fromTo(said, { opacity: 0, y: 8, scale: 0.96 }, { opacity: 1, y: 0, scale: 1, duration: 0.25, ease: 'power2.out' }); }, 0.3 + BEAT + 0.15);
      at(() => {
        copied.hidden = true;
        pencil.hidden = false;
        gsap.to(said, { opacity: 0, y: -4, duration: 0.2, ease: 'power2.out' });
      }, 0.3 + BEAT + 1.4);
    };

    /** Paste: ⌘V in the agent's prompt, Return, and it answers. */
    const paste = () => {
      show('clean');
      pan(true, true);
      const t = phone.matches ? 0.8 : 0.3;
      at(() => press(keyPaste, overTerm), t);
      at(() => prompt(PASTED), t + BEAT);
      at(() => press(keySend, overTerm), t + 1.3);
      const sent = t + 1.3 + BEAT;
      at(() => {
        prompt('');
        term.print('You', PASTED);
        term.gap();
        term.status('Thinking…', '0s');
        busy(true);
      }, sent);
      // Its clock runs, a second at a time, as Claude Code's does.
      for (let s = 1; s <= 4; s++) at(() => { const c = term.root.querySelector(':scope > [data-name="Status"] > :last-child'); if (c) c.textContent = `(${s}s)`; }, sent + s);
      // Its first words, streamed in as it prints them.
      at(() => {
        const line = above(term.print('Claude', ''));
        const out = document.createTextNode('');
        line.append(out);
        const parts = REPLY.split(/(?<= )/);
        parts.forEach((_, k) => at(() => { out.textContent = parts.slice(0, k + 1).join(''); term.fit(); }, k * 0.035));
      }, sent + 0.9);
    };

    const chapter = (hold: number, end: State, play: () => void, toTerm = false) => ({
      hold,
      enter: (animate: boolean) => {
        cut();
        if (!animate || reduced()) { show(end); pan(toTerm, false); return; }
        moving = true;
        play();
      },
    });
    return [
      // Each holds about 1.5 s after its last beat.
      chapter(5.5, 'pointed', point),
      chapter(5.5, 'written', say),
      chapter(3.7, 'clean', copy),
      chapter(5.4, 'pasted', paste, true),
    ];
  }, 1);
  void f;

  wholeRows(win);
}
