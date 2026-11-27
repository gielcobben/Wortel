// The surfaces scene on /mark-up: the same thing done to three previews, one
// after another in the same tab's place. Mark Up turns on, the marks are
// drawn, and the sentence is written around them: over rendered Markdown,
// over a file's source, over its diff.
//
// The rendered plan is a canvas frame as drawn (MarkUp). The other two are
// put together here from frames the canvas has, since it has none of mark-up
// over source or over a diff: the source tab (Code), the diff of the same
// file (out of the Changes pane, in the component's template), and the
// plan's own marks, note bar, Mark Up button and mode switch, cloned and
// placed over the lines. A mark keeps the colour and the tool the canvas
// drew it with: the first mark of a note is a red box, the second an orange
// arrow.
//
// components/markup/Surfaces.astro is the window it plays in.
import { gsap } from 'gsap';
import { Pointer, Sidebar, foldable, named, pressKeys, reduced, wholeRows } from './app';
import { film } from './film';
import { planMarks } from './plan';

const SESSION = 'Quicker panes';
/** A character, typed, and from a key going down to the app answering. */
const TYPE = 0.04, BEAT = 0.5;
/** The pointer's travel to where a mark starts, and the stroke itself. */
const TRAVEL = 0.55, DRAW = 0.65;

type Kind = 'box' | 'arrow' | 'highlight';
type Mark = { el: HTMLElement; kind: Kind };
type Surface = {
  pane: HTMLElement;
  /** The Mark Up button in the preview's header: lit while marking. */
  button: HTMLElement;
  bar: HTMLElement;
  marks: Mark[];
  chips: HTMLElement[];
  /** The note's words, in the order they are typed: before the first chip, then after each. */
  words: HTMLElement[];
  said: string[];
  caret: HTMLElement;
};

export function initSurfaces() {
  const root = document.querySelector<HTMLElement>('[data-film="surfaces"]');
  const win = root?.querySelector<HTMLElement>('[data-swin]');
  if (!root || !win) return;
  const box = win.parentElement!;
  const keys = root.querySelector<HTMLElement>('[data-keys="markup"]')!;
  const pane = (k: string) => win.querySelector<HTMLElement>(`[data-pane="${k}"]`)!;
  const src = root.querySelector<HTMLTemplateElement>('template[data-src]')!.content;

  // ---- the window ---------------------------------------------------------------
  const sb = new Sidebar(named(win, 'Sidebar')!);
  sb.show(['Section web', 'Landing page hero', 'Changelog typography', 'Section Sessions', SESSION, 'Marketing screenshots']);
  sb.select(SESSION);
  const lead = root.querySelector<HTMLTemplateElement>('template[data-tpl="lead"]')?.content;
  foldable(win, lead);
  // Each preview brings its own row: the other two gain the same buttons.
  for (const k of ['source', 'diff']) {
    const buttons = (lead?.cloneNode(true) as DocumentFragment | undefined)?.firstElementChild as HTMLElement | null;
    if (!buttons) continue;
    buttons.dataset.narrowOnly = '';
    pane(k).querySelector('header[data-name="Main bar"]')!.prepend(buttons);
  }
  win.querySelectorAll<HTMLElement>('[data-name="Title"]').forEach((t) => (t.textContent = SESSION));

  // ---- the rendered plan: the canvas's own -----------------------------------------
  const plan = pane('rendered');
  const planNote = named(plan, 'Note')!;
  const rendered: Surface = {
    pane: plan,
    button: named(plan, 'Mark Up')!,
    bar: named(plan, 'Note bar')!,
    marks: (['box', 'arrow', 'highlight'] as const).map((kind, i) => ({ el: named(plan, `Mark ${i + 1}`)!, kind })),
    chips: [1, 2, 3].map((i) => named(planNote, `Chip ${i}`)!),
    words: Array.from(planNote.querySelectorAll<HTMLElement>(':scope > span')),
    said: [],
    caret: named(planNote, 'Caret')!,
  };
  rendered.said = rendered.words.map((w) => w.textContent || '');

  // ---- source and diff: put together from the canvas's parts ------------------------
  /** Give a source tab what a preview being marked up has, from the plan's frame. */
  const dress = (host: HTMLElement, mode: 'Source' | 'Diff', said: string[]): Surface => {
    const header = named(host, 'Preview header')!;
    // The mode switch: a changed file in a repository offers its diff and its
    // source, in that order (PreviewMode.swift, available).
    const modes = named(plan, 'Mode switch')!.cloneNode(true) as HTMLElement;
    const [first, second] = Array.from(modes.children) as HTMLElement[];
    first.textContent = 'Diff'; second.textContent = 'Source';
    if (mode === 'Diff') [first.className, second.className] = [second.className, first.className];
    named(header, 'Open in Editor')!.before(modes);
    const button = rendered.button.cloneNode(true) as HTMLElement;
    header.append(button);
    // The lines, in a box of their own that the marks and the note bar lie over.
    const lines = named(host, 'Source')!;
    const preview = document.createElement('div');
    preview.dataset.name = 'Preview';
    preview.className = 'relative flex min-h-0 flex-1 flex-col overflow-hidden';
    lines.before(preview);
    if (mode === 'Diff') { lines.remove(); preview.append(src.querySelector('[data-name="Diff"]')!.cloneNode(true)); } else preview.append(lines);
    const bar = rendered.bar.cloneNode(true) as HTMLElement;
    preview.append(bar);
    const note = named(bar, 'Note')!;
    const caret = named(note, 'Caret')!;
    const word = rendered.words[0], chips: HTMLElement[] = [], words: HTMLElement[] = [];
    note.replaceChildren();
    said.forEach((_, i) => {
      if (i) { const c = rendered.chips[i - 1].cloneNode(true) as HTMLElement; chips.push(c); note.append(c); }
      const w = word.cloneNode(false) as HTMLElement;
      words.push(w); note.append(w);
    });
    note.append(caret);
    const kinds: Kind[] = ['box', 'arrow'];
    const marks = chips.map((_, i) => {
      const el = rendered.marks[i].el.cloneNode(true) as HTMLElement;
      // Under the note bar, as the app has them.
      bar.before(el);
      return { el, kind: kinds[i] };
    });
    return { pane: host, button, bar, marks, chips, words, said, caret };
  };
  const source = dress(pane('source'), 'Source', ['Move ', ' out of ', '. It is the window’s number, not the chrome’s.']);
  const diff = dress(pane('diff'), 'Diff', ['', ' is barely quicker. Try 0.2 and 0.14.']);
  const all = [rendered, source, diff];

  // Where the marks go over the lines: measured, so they sit on the text
  // whatever the pane's width. A line's last child is its text.
  const text = (line: Element) => {
    const span = (line.lastElementChild ?? line) as HTMLElement, r = span.getBoundingClientRect();
    const s = span.textContent || '', lead = s.length - s.trimStart().length;
    return { left: r.left + (s.length ? (r.width / s.length) * lead : 0), right: r.right, top: line.getBoundingClientRect().top, bottom: line.getBoundingClientRect().bottom };
  };
  const rows = (s: Surface) => Array.from(s.pane.querySelectorAll<HTMLElement>('[data-name="Line"], [data-name="Diff line"], [data-name="Hunk"]'));
  /** A box around lines `from` to `to`, 6 points clear of their text. */
  const around = (s: Surface, m: Mark, from: number, to: number) => {
    const at = rows(s).slice(from, to + 1).map(text), o = m.el.parentElement!.getBoundingClientRect();
    if (!at.length || !o.width) return;
    const l = Math.min(...at.map((r) => r.left)) - 6, r = Math.max(...at.map((q) => q.right)) + 6;
    Object.assign(m.el.style, { left: `${l - o.left}px`, top: `${at[0].top - o.top - 3}px`, width: `${r - l}px`, height: `${at[at.length - 1].bottom - at[0].top + 6}px` });
  };
  /** The canvas's arrow, its tip just past the end of a line. */
  const pointAt = (s: Surface, m: Mark, line: number) => {
    const at = rows(s)[line] && text(rows(s)[line]), o = m.el.parentElement!.getBoundingClientRect();
    if (!at || !o.width) return;
    // The arrow's tip is 4.5 in and 37 down in its own box (the canvas's Ink).
    Object.assign(m.el.style, { left: `${at.right + 8 - 4.5 - o.left}px`, top: `${(at.top + at.bottom) / 2 - 37 - o.top}px` });
  };
  // The plan's marks are the canvas's while the plan is as wide as it was
  // drawn, and are put over the same things again where it is narrower
  // (scripts/plan.ts).
  const doc = named(plan, 'Markdown')!;
  const { column, place: placePlan } = planMarks(doc);
  /** Scroll a file's lines up until row `last` is clear of the note bar: in a
   *  window as short as a phone's the lines being marked would lie under it.
   *  The bar is allowed its tallest, a note of three lines. */
  const clear = (s: Surface, last: number) => {
    const lines = s.pane.querySelector<HTMLElement>('[data-name="Source"], [data-name="Diff"]'), row = rows(s)[last];
    if (!lines || !row || !lines.clientHeight) return;
    lines.scrollTop = 0;
    const under = row.getBoundingClientRect().bottom - (s.pane.getBoundingClientRect().bottom - 176);
    if (under > 0) lines.scrollTop = Math.ceil(under / row.offsetHeight) * row.offsetHeight;
  };
  const place = () => {
    placePlan();
    clear(source, 13);
    clear(diff, 19);
    // Chrome.swift: the titlebar's height with the comment over it (lines 11
    // to 14), and the enum it is in (line 10: the two lines before it are
    // short, so the arrow's tail lies over nothing).
    around(source, source.marks[0], 10, 13);
    pointAt(source, source.marks[1], 9);
    // Its diff: the two durations, before and after (the second hunk).
    around(diff, diff.marks[0], 16, 19);
  };

  // ---- one preview's state ----------------------------------------------------------
  const lit = (s: Surface, on: boolean) => s.button.classList.toggle('bg-secondary', on);
  const setNote = (s: Surface, marks: number, typed: string[]) => {
    s.chips.forEach((c, i) => (c.hidden = i >= marks));
    s.words.forEach((w, i) => { w.textContent = typed[i] || ''; w.hidden = !typed[i]; });
    s.caret.parentElement!.append(s.caret);
  };
  const ink = (m: Mark) => named(m.el, 'Ink')!, badge = (m: Mark) => named(m.el, 'Badge')!;
  /** A box being dragged out, and the size it has when it is whole again. */
  const strokes: gsap.core.Tween[] = [];
  const whole = (m: Mark) => { m.el.style.width = m.el.style.height = ''; };
  /** Put a preview in a state at once: untouched, or marked up with its note written. */
  const show = (s: Surface, done: boolean) => {
    lit(s, done);
    gsap.set(s.bar, { clearProps: 'transform,opacity,visibility' });
    gsap.set(s.bar, { autoAlpha: done ? 1 : 0 });
    for (const m of s.marks) {
      m.el.hidden = !done;
      gsap.set([m.el, ink(m), badge(m)], { clearProps: 'clipPath,opacity,scale,transformOrigin' });
      whole(m);
    }
    place();
    setNote(s, done ? s.chips.length : 0, done ? s.said : []);
  };
  let front = -1;
  /** Bring a preview to the front: tabs swap at once, with a short fade. */
  const bring = (i: number, animate: boolean) => {
    if (front === i) return;
    front = i;
    all.forEach((s, k) => (s.pane.hidden = k !== i));
    place();
    if (animate) gsap.fromTo(all[i].pane.querySelector('[data-name="File page"], [data-name="Code page"]'), { opacity: 0 }, { opacity: 1, duration: 0.2, ease: 'power2.out', clearProps: 'opacity' });
  };

  // ---- on a phone, code scrolls sideways to a mark drawn past its edge ----------------
  // A line of code does not wrap, so in a window as narrow as a phone's the
  // end of one can be out of sight. The lines are scrolled, as a code view
  // is, until the mark being drawn is in view, and back for the sentence.
  // The marks lie over the lines, not in them, so they are placed again as
  // the lines move.
  let scrolling: gsap.core.Tween | null = null;
  const scroller = (s: Surface) => s.pane.querySelector<HTMLElement>('[data-name="Source"], [data-name="Diff"]');
  // The plan is read from its foot, so in a short window its steps are above
  // what shows: the plan moves down to the mark being drawn there, as a
  // preview scrolled up would, and back.
  const look = (s: Surface, el: Element | null, animate: boolean) => {
    const lines = scroller(s);
    if (!lines) {
      let y = 0;
      if (el) {
        const top = el.getBoundingClientRect().top - (gsap.getProperty(column, 'y') as number);
        y = Math.max(0, Math.ceil(doc.getBoundingClientRect().top + 24 - top));
      }
      gsap.to(column, { y, duration: animate && !reduced() ? 0.45 : 0, ease: 'power3.inOut', overwrite: 'auto' });
      return;
    }
    let to = 0;
    if (el) {
      const r = el.getBoundingClientRect(), v = lines.getBoundingClientRect();
      const visible = Math.min(v.right, box.getBoundingClientRect().right);
      // As far as shows the mark's end, and no further than keeps its start in view.
      const want = Math.min(Math.max(0, r.right + 16 - visible), Math.max(0, r.left - 24 - v.left));
      to = Math.max(0, Math.min(lines.scrollWidth - lines.clientWidth, lines.scrollLeft + want));
    }
    const at = { v: lines.scrollLeft };
    scrolling?.kill();
    scrolling = gsap.to(at, { v: to, duration: animate && !reduced() && Math.abs(to - at.v) > 1 ? 0.45 : 0, ease: 'power3.inOut', onUpdate: () => { lines.scrollLeft = at.v; place(); } });
    if (Math.abs(to - at.v) <= 1) { lines.scrollLeft = to; place(); }
  };

  // ---- hands --------------------------------------------------------------------------
  const pointer = new Pointer(box);
  const hand = pointer.el;
  const spot = (el: Element, fx: number, fy: number) => {
    const b = box.getBoundingClientRect(), r = el.getBoundingClientRect();
    return { x: r.left - b.left + r.width * fx, y: r.top - b.top + r.height * fy };
  };
  /** Where each kind of stroke starts and ends, as shares of the mark's own box. */
  const STROKE: Record<Kind, [number, number, number, number]> = { box: [0, 0, 1, 1], arrow: [0.88, 0.3, 0.04, 0.84], highlight: [0, 0.5, 0.93, 0.5] };
  const over = () => {
    const b = box.getBoundingClientRect(), w = win.getBoundingClientRect();
    const p = all[front].pane.getBoundingClientRect();
    const left = Math.max(p.left, b.left), right = Math.min(p.right, b.right, w.right);
    Object.assign(keys.style, { left: `${(left + right) / 2 - b.left}px`, top: `${p.top - b.top + p.height * 0.42}px` });
  };

  const cut = () => {
    strokes.splice(0).forEach((t) => t.kill());
    gsap.killTweensOf([hand, keys, ...all.flatMap((s) => [s.bar, ...s.marks.flatMap((m) => [m.el, ink(m), badge(m)])])]);
    gsap.set(keys, { opacity: 0 });
    gsap.set(keys.querySelectorAll('kbd'), { y: 0 });
    pointer.hide();
  };

  const f = film(root, (f) => all.map((s, i) => {
    const at = (fn: () => void, t: number) => f.later(fn, t);
    // When each mark is drawn, then when the typing starts and ends.
    const starts = s.marks.map((_, k) => 1.4 + k * (TRAVEL + DRAW + 0.6));
    const typing = starts[starts.length - 1] + TRAVEL + DRAW + 0.5;
    const length = typing + s.said.join('').length * TYPE + s.said.length * 0.15;
    const play = () => {
      bring(i, true);
      show(s, false);
      look(s, null, false);
      at(() => { over(); pressKeys(gsap.timeline(), keys, 0, 0.9); }, 0.3);
      at(() => {
        lit(s, true);
        gsap.fromTo(s.bar, { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: 0.35, ease: 'expo.out', clearProps: 'transform' });
      }, 0.3 + BEAT);
      s.marks.forEach((m, k) => {
        const [x0, y0, x1, y1] = STROKE[m.kind];
        // The mark is laid out, unseen, so the lines can scroll to where it
        // will be before the pointer sets off for it.
        at(() => { m.el.hidden = false; gsap.set(m.el, { opacity: 0 }); look(s, m.el, true); }, starts[k] - 0.5);
        at(() => pointer.move(spot(m.el, x0, y0), TRAVEL), starts[k]);
        at(() => {
          // The stroke, and the mark's number as the button comes up. A box
          // is dragged out from its corner: a whole rectangle all the way,
          // its far corner under the pointer. (It was first uncovered from
          // behind a clip instead, which showed two of its sides growing and
          // the other two only as the stroke ended.) An arrow and a
          // highlight are uncovered along their length.
          gsap.set(m.el, { opacity: 1 });
          gsap.set(badge(m), { opacity: 0 });
          gsap.to(hand, { scale: 0.86, duration: 0.08, transformOrigin: '10% 6%' });
          const to = spot(m.el, x1, y1);
          gsap.to(hand, { x: to.x, y: to.y, duration: DRAW, ease: 'power2.inOut' });
          if (m.kind === 'box') {
            const w = m.el.offsetWidth, h = m.el.offsetHeight, grown = { p: 0.02 };
            const size = () => Object.assign(m.el.style, { width: `${w * grown.p}px`, height: `${h * grown.p}px` });
            size();
            strokes.push(gsap.to(grown, { p: 1, duration: DRAW, ease: 'power2.inOut', onUpdate: size, onComplete: () => { whole(m); place(); } }));
          } else {
            gsap.fromTo(ink(m), { clipPath: m.kind === 'arrow' ? 'inset(0% 0% 0% 100%)' : 'inset(0% 100% 0% 0%)' }, { clipPath: 'inset(0% 0% 0% 0%)', duration: DRAW, ease: 'power2.inOut', clearProps: 'clipPath' });
          }
        }, starts[k] + TRAVEL);
        at(() => {
          gsap.to(hand, { scale: 1, duration: 0.08 });
          gsap.fromTo(badge(m), { opacity: 0, scale: 0.6 }, { opacity: 1, scale: 1, duration: 0.2, ease: 'power2.out', clearProps: 'scale' });
          setNote(s, k + 1, []);
        }, starts[k] + TRAVEL + DRAW);
      });
      at(() => { pointer.hide(); look(s, null, true); }, typing - 0.3);
      let t = typing;
      s.said.forEach((part, k) => {
        [...part].forEach((_, c) => at(() => { s.words[k].hidden = false; s.words[k].textContent = part.slice(0, c + 1); s.words[k].after(s.caret); }, t + c * TYPE));
        t += part.length * TYPE + 0.15;
      });
    };
    return {
      hold: length + 1.5,
      enter: (animate: boolean) => {
        cut();
        if (!animate || reduced()) { bring(i, false); show(s, true); look(s, null, false); return; }
        play();
      },
    };
  }), 0);
  void f;

  new ResizeObserver(place).observe(win);
  wholeRows(win);
}
