// The landing: the copy settles, the window rises onto the lake, and then an
// agent does a small job in it.
//
// Built the way the product films are: one GSAP timeline, every beat at a named
// time, so the whole sequence can be retimed in one place. ?t=<seconds> seeks
// it and holds (for screenshots); reduced motion skips straight to the end.
import { gsap } from 'gsap';

const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
const q = <T extends Element = HTMLElement>(root: ParentNode, sel: string) => Array.from(root.querySelectorAll<T & HTMLElement>(sel));
const named = (root: ParentNode, name: string) => root.querySelector<HTMLElement>(`[data-name="${name}"]`);

export function playHero() {
  const hero = document.querySelector<HTMLElement>('[data-hero]');
  if (!hero) return;
  const win = hero.querySelector<HTMLElement>('[data-win]')!;
  const term = named(win, 'Terminal')!;
  const changes = named(win, 'Change list');

  // ---- the agent's job, as beats ------------------------------------------
  // Everything after the prompt you typed is hidden and comes back line by
  // line. The prompt box at the bottom stays: Claude Code always draws it.
  const lines = Array.from(term.children) as HTMLElement[];
  const firstRule = lines.findIndex((l) => l.dataset.name === 'Rule');
  const youAt = lines.findIndex((l) => l.dataset.name === 'You');
  const body = lines.slice(youAt + 1, firstRule);

  // A live status line while the agent works, swapped for "Worked for" at the end.
  const worked = body.find((l) => l.dataset.name === 'Worked');
  const status = worked ? (worked.cloneNode(true) as HTMLElement) : null;
  if (status) {
    status.dataset.name = 'Status';
    const label = status.querySelector('span:last-child')!;
    label.textContent = 'Shaving the open and close curves… (esc to interrupt)';
    status.querySelector('span')!.classList.add('spin');
    term.insertBefore(status, lines[firstRule]);
  }

  const rows = changes ? q(changes, '[data-name$=".swift"], [data-name$=".md"]') : [];
  const header = changes?.querySelector('span');
  const diff = named(win, 'Diff');

  const sidebarDots = q(win, '[data-name="Working"] > div');

  const show = (el: Element | null | undefined) => el && (el as HTMLElement).removeAttribute('hidden');
  const hide = (el: Element | null | undefined) => el && (el as HTMLElement).setAttribute('hidden', '');

  // Which change rows a tool line brings in.
  const rowFor = (line: HTMLElement) => {
    const t = line.textContent || '';
    if (!/^(●)?(Update|Write)\(/.test(t.trim().replace(/^●/, '')) && !/Update\(|Write\(/.test(t)) return null;
    return rows.find((r) => t.includes(r.dataset.name!)) || null;
  };

  // ---- build the timeline -------------------------------------------------
  const tl = gsap.timeline({ paused: true, defaults: { ease: 'expo.out' } });
  const at = { copy: 0, window: 0.35, agent: 1.6 };

  tl.fromTo(q(hero, '[data-fade]'), { opacity: 0, y: 16 }, { opacity: 1, y: 0, duration: 1.1, stagger: 0.08 }, at.copy);
  tl.fromTo(hero.querySelector('[data-shot]'), { opacity: 0 }, { opacity: 1, duration: 1.2, ease: 'power2.out' }, at.window);
  tl.fromTo(win, { opacity: 0, y: 64 }, { opacity: 1, y: 0, duration: 1.6, clearProps: 'transform,opacity' }, at.window + 0.2);

  // The agent. Hidden state is set at time 0 so seeking backwards restores it.
  tl.call(() => {
    body.forEach(hide);
    show(status);
    rows.forEach(hide);
    if (header) header.textContent = 'Changes (0)';
    if (diff) diff.style.opacity = '0';
  }, [], 0);

  let t = at.agent;
  let count = 0;
  for (const line of body) {
    if (line.dataset.name === 'Worked') continue;
    const isGap = !line.dataset.name;
    const name = line.dataset.name;
    const step = isGap ? 0 : name === 'Result' ? 0.35 : name === 'Claude' ? 0.9 : 0.55;
    t += step;
    const row = name === 'Tool' ? rowFor(line) : null;
    tl.call(() => {
      show(line);
      if (row) {
        show(row);
        count = rows.filter((r) => !r.hasAttribute('hidden')).length;
        if (header) header.textContent = `Changes (${count})`;
        if (diff && row === rows[0]) gsap.to(diff, { opacity: 1, duration: 0.4 });
      }
    }, [], t);
  }
  t += 0.6;
  tl.call(() => { hide(status); show(worked); }, [], t);

  // The other sessions keep working in the sidebar: three dots, in turn.
  if (sidebarDots.length) {
    gsap.to(sidebarDots, { opacity: 0.25, duration: 0.5, ease: 'sine.inOut', stagger: { each: 0.18, repeat: -1, yoyo: true } });
  }

  // ---- play, or hold a frame ----------------------------------------------
  const params = new URLSearchParams(location.search);
  if (params.has('t')) { tl.seek(Number(params.get('t'))); return; }
  if (reduced()) { tl.progress(1); return; }
  tl.play();
}
