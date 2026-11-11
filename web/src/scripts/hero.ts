// The landing: the copy settles, the window comes up, and then a small job
// happens in it from the first keystroke: you type what you want, the agent
// reads, edits and builds, and the Changes pane fills in as files change.
//
// Built the way the product films are: one GSAP timeline, every beat at a named
// time, so the whole sequence can be retimed in one place. ?t=<seconds> seeks
// it and holds (for screenshots); reduced motion skips straight to the end.
import { gsap } from 'gsap';
import { Terminal, fitTerminal, named, reduced, wholeRows } from './app';

const q = (root: ParentNode, sel: string) => Array.from(root.querySelectorAll<HTMLElement>(sel));

export function playHero() {
  const hero = document.querySelector<HTMLElement>('[data-hero]');
  if (!hero) return;
  const win = hero.querySelector<HTMLElement>('[data-win]')!;
  const term = named(win, 'Terminal')!;
  const changes = named(win, 'Change list');

  // ---- the cast -------------------------------------------------------------
  const lines = Array.from(term.children) as HTMLElement[];
  const firstRule = lines.findIndex((l) => l.dataset.name === 'Rule');
  const youAt = lines.findIndex((l) => l.dataset.name === 'You');
  const you = lines[youAt];
  const body = lines.slice(youAt + 1, firstRule);
  const prompt = named(term, 'Prompt')!;
  const ask = (you.textContent || '').replace(/^❯/, '');

  // A new session: Claude Code's header at the top, the prompt box pinned to
  // the bottom (styles/app.css), and the suggestion it shows before you type.
  const t = new Terminal(term);
  prompt.classList.remove('h-[19px]');
  prompt.classList.add('min-h-[19px]', 'whitespace-pre-wrap', 'pl-[17px]', 'pr-1', '[overflow-wrap:anywhere]');
  const typed = document.createElement('span');
  const caret = document.createElement('span');
  caret.style.cssText = 'display:inline-block;width:8.5px;height:17px;vertical-align:-3px;background:var(--primary)';
  const hint = document.createElement('span');
  hint.className = 'text-[#666666] dark:text-[#999999]';
  hint.textContent = 'Try "edit <filepath> to..."';
  prompt.append(typed, caret, hint);
  // Before you type, it suggests a start; while the agent works the box is
  // empty; when the turn ends it suggests a next step, as Claude Code does.
  const type = (text: string, suggest = '') => {
    typed.textContent = text;
    hint.textContent = suggest;
    hint.hidden = text.length > 0 || !suggest;
  };
  const FIRST = 'Try "edit <filepath> to..."', NEXT = 'commit this';

  // The line Claude's own turn ends with stays hidden until the turn ends.
  const worked = body.find((l) => l.dataset.name === 'Worked');

  const rows = changes ? q(changes, '[data-name$=".swift"], [data-name$=".md"]') : [];
  const header = changes?.querySelector('span');
  const diff = named(win, 'Diff');
  const sidebarDots = q(win, '[data-name="Working"] > div');

  const live = () => tl.isActive() && !frozen;
  const show = (el?: Element | null) => {
    if (!el) return;
    el.removeAttribute('hidden');
    if (live()) gsap.fromTo(el, { opacity: 0 }, { opacity: 1, duration: 0.22, ease: 'power1.out', clearProps: 'opacity' });
  };
  const hide = (el?: Element | null) => el?.setAttribute('hidden', '');
  // Only whole rows: as lines arrive, the oldest leave the top a row at a time.
  const fit = () => fitTerminal(term);

  // Which change row a tool line brings in.
  const rowFor = (line: HTMLElement) => {
    const t = line.textContent || '';
    if (!/Update\(|Write\(/.test(t)) return null;
    return rows.find((r) => t.includes(r.dataset.name!)) || null;
  };

  // ---- the timeline ---------------------------------------------------------
  let frozen = false;
  const tl = gsap.timeline({ paused: true, defaults: { ease: 'expo.out' } });
  const at = { copy: 0, window: 0.25, type: 1.5 };

  tl.fromTo(q(hero, '[data-fade]'), { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 1.1, stagger: 0.08 }, at.copy);
  tl.fromTo(win, { opacity: 0, y: 40 }, { opacity: 1, y: 0, duration: 1.5, clearProps: 'transform,opacity' }, at.window);

  // Time 0: an idle session. Seeking backwards restores it.
  tl.call(() => {
    hide(you); body.forEach(hide); t.idle(); rows.forEach(hide);
    type('', FIRST);
    if (header) header.textContent = 'Changes (0)';
    if (diff) diff.style.opacity = '0';
    fit();
  }, [], 0);

  // You type.
  const per = 0.019;
  for (let i = 1; i <= ask.length; i++) tl.call(() => type(ask.slice(0, i), FIRST), [], at.type + i * per);
  let beat = at.type + ask.length * per + 0.5;
  // Return: it becomes your message, and the agent starts.
  tl.call(() => { type(''); show(you); t.status('Shaving the open and close curves…', 'thinking'); fit(); }, [], beat);

  let count = 0;
  for (const line of body) {
    if (line.dataset.name === 'Worked') continue;
    const name = line.dataset.name;
    beat += !name ? 0 : name === 'Result' ? 0.32 : name === 'Claude' ? 0.9 : 0.55;
    const row = name === 'Tool' ? rowFor(line) : null;
    tl.call(() => {
      show(line); fit();
      if (!row) return;
      show(row);
      count = rows.filter((r) => !r.hasAttribute('hidden')).length;
      if (header) header.textContent = `Changes (${count})`;
      if (diff && row === rows[0]) gsap.to(diff, { opacity: 1, duration: 0.5 });
    }, [], beat);
  }
  beat += 0.6;
  tl.call(() => { t.idle(); show(worked); type('', NEXT); fit(); }, [], beat);

  // The other sessions keep working in the sidebar: three dots, in turn.
  if (sidebarDots.length && !reduced()) {
    gsap.to(sidebarDots, { opacity: 0.25, duration: 0.5, ease: 'sine.inOut', stagger: { each: 0.18, repeat: -1, yoyo: true } });
  }

  wholeRows(win);

  // ---- play, or hold a frame ------------------------------------------------
  const params = new URLSearchParams(location.search);
  if (params.has('t')) { frozen = true; tl.seek(Number(params.get('t')), false); fit(); return; }
  if (reduced()) { frozen = true; tl.progress(1); fit(); return; }
  tl.play();
}
