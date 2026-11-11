// The films in the homepage's shots below the panes. Each is one looping GSAP
// timeline acting on a real window (see app.ts): it starts when its shot comes
// on screen and pauses when it leaves. Beats are at named times, so a scene is
// retimed in one place. Nothing is tied to scroll.
import { gsap } from 'gsap';
import { Sidebar, Terminal, named, pressKeys, reduced, whileVisible } from './app';

const fadeIn = (el: Element) => gsap.fromTo(el, { opacity: 0 }, { opacity: 1, duration: 0.28, ease: 'power1.out', clearProps: 'opacity' });

// ---- agents: a session stops for you, and one key takes you to it ----------
for (const v of document.querySelectorAll<HTMLElement>('[data-agents]')) {
  const sb = new Sidebar(named(v, 'Sidebar')!);
  const term = new Terminal(named(v, 'Terminal')!);
  const title = named(v, 'Title')!;
  const note = v.querySelector<HTMLElement>('[data-note]')!;
  const jump = v.querySelector<HTMLElement>('[data-keys="jump"]')!;
  const enter = v.querySelector<HTMLElement>('[data-keys="enter"]')!;
  const HOME = 'Quicker panes', HERO = 'Landing page hero';

  // The two screens: the session you are in, and the one that wants you.
  const home = term.lines();
  let question: HTMLElement[] = [];
  const asking = term.compose(() => {
    term.print('You', 'Make the landing page hero load faster.');
    term.gap();
    term.print('Claude', 'The photo was the slow part. I resized it and inlined the critical CSS. I want to run the build and check the numbers.');
    term.gap();
    term.print('Tool', '(npm run build)', 'Bash');
    question = [
      term.gap(),
      term.plain('Do you want to proceed?'),
      term.plain('❯ 1. Yes', true),
      term.plain('  2. Yes, and don’t ask again for npm run build'),
      term.plain('  3. No, and tell Claude what to do differently'),
    ];
  });
  let result: HTMLElement | null = null;

  const reset = () => {
    sb.select(HOME, false); title.textContent = HOME; term.swap(home);
    sb.status(HERO, 'working');
    gsap.set(note, { opacity: 0, x: 40 });
  };
  reset();
  if (reduced()) { sb.status(HERO, 'attention'); gsap.set(note, { opacity: 1, x: 0 }); continue; }

  whileVisible(v, () => {
    const tl = gsap.timeline({ repeat: -1 });
    const at = { stop: 1.6, note: 2.0, jump: 3.8, arrive: 4.25, enter: 6.4, answer: 6.85, done: 9.0, back: 11.6, end: 12.4 };
    tl.call(reset, [], 0);
    // It stops and waits: the dot turns, and a notification finds you.
    tl.call(() => sb.status(HERO, 'attention'), [], at.stop);
    tl.to(note, { opacity: 1, x: 0, duration: 0.6, ease: 'expo.out' }, at.note);
    // One shortcut, and you are in that session, looking at its question.
    pressKeys(tl, jump, at.jump);
    tl.call(() => { sb.select(HERO); title.textContent = HERO; term.swap(asking); fadeIn(term.root); }, [], at.arrive);
    tl.to(note, { opacity: 0, x: 40, duration: 0.4, ease: 'power2.in' }, at.arrive + 0.2);
    // Yes.
    pressKeys(tl, enter, at.enter);
    tl.call(() => {
      question.forEach((q) => q.remove());
      result = term.print('Result', 'Running…');
      sb.status(HERO, 'working');
    }, [], at.answer);
    tl.call(() => {
      if (result) result.lastElementChild!.textContent = 'built in 2.14s';
      term.gap();
      fadeIn(term.print('Claude', 'Built. The hero paints in 0.8s, down from 2.1s.'));
      term.gap();
      term.print('Worked', 'Worked for 48s');
      sb.status(HERO, 'none');
    }, [], at.done);
    // Back to what you were doing.
    tl.call(() => { sb.select(HOME); title.textContent = HOME; term.swap(home); fadeIn(term.root); }, [], at.back);
    tl.set({}, {}, at.end);
    return tl;
  });
}

// ---- worktrees: pick a session, and the window is that branch ---------------
for (const v of document.querySelectorAll<HTMLElement>('[data-worktrees]')) {
  const sb = new Sidebar(named(v, 'Sidebar')!);
  const term = new Terminal(named(v, 'Terminal')!);
  const title = named(v, 'Title')!;
  const col = named(v, 'Changes pane')!;
  const branch = named(col, 'Branch')!.querySelector('span')!;
  const header = named(col, 'Changes header')!.querySelector('span')!;
  const list = named(col, 'Change list')!;
  const rows = Array.from(list.querySelectorAll<HTMLElement>('[data-name$=".swift"], [data-name$=".md"]'));
  const diff = named(col, 'Diff')!;
  const shell = named(v, 'Strip terminal')!.querySelectorAll('p')[1].querySelectorAll('span');

  type File = [mark: 'M' | '?', name: string, path: string];
  const read = (r: HTMLElement): File => [r.children[0].textContent as 'M' | '?', r.children[1].textContent!, r.children[2].textContent!];
  const SESSIONS: { row: string; dir: string; branch: string; files: File[]; screen: HTMLElement[]; diff: boolean }[] = [
    { row: 'Quicker panes', dir: 'wortel', branch: 'main', files: rows.map(read), screen: term.lines(), diff: true },
    {
      row: 'Icon grid survey and fixes', dir: 'codebase-survey-and-fixes', branch: 'codebase-survey-and-fixes', diff: false,
      files: [['M', 'IconGrid.swift', 'ikoon/Views'], ['M', 'GridMetrics.swift', 'ikoon/Model'], ['?', 'survey.md', 'docs']],
      screen: term.compose(() => {
        term.print('You', 'Survey the icon grid and fix what is off.');
        term.gap();
        term.print('Claude', 'Three icons sit half a point low, and the metrics are computed in two places. Fixing both.');
        term.gap();
        term.print('Tool', '(ikoon/Views/IconGrid.swift)', 'Update');
        term.print('Result', 'Updated with 12 additions and 9 removals');
        term.gap();
        term.print('Tool', '(docs/survey.md)', 'Write');
        term.print('Result', 'Wrote 41 lines');
        term.gap();
      }),
    },
    {
      row: 'Sparkle appcast cleanup', dir: 'appcast-cleanup', branch: 'appcast-cleanup', diff: false,
      files: [['M', 'appcast.xml', 'updates/public'], ['M', 'release.sh', 'macos/scripts']],
      screen: term.compose(() => {
        term.print('You', 'Clean up the Sparkle appcast and the script that writes it.');
        term.gap();
        term.print('Claude', 'The feed carries eleven entries nobody can update from any more. Trimming it to the last five.');
        term.gap();
        term.print('Tool', '(updates/public/appcast.xml)', 'Update');
        term.print('Result', 'Updated with 4 additions and 86 removals');
        term.gap();
        term.print('Tool', '(macos/scripts/release.sh --dry-run)', 'Bash');
        term.print('Result', 'The feed is valid. Nothing published.');
        term.gap();
      }),
    },
  ];

  const go = (i: number, animate = true) => {
    const s = SESSIONS[i];
    sb.select(s.row, animate);
    title.textContent = s.row;
    term.swap(s.screen);
    shell[1].textContent = `${s.dir} `;
    shell[3].textContent = s.branch;
    branch.textContent = s.branch;
    header.textContent = `Changes (${s.files.length})`;
    rows.forEach((r, k) => {
      const f = s.files[k];
      r.toggleAttribute('hidden', !f);
      if (!f) return;
      r.children[0].textContent = f[0];
      r.children[0].classList.toggle('text-chart-1', f[0] === 'M');
      r.children[0].classList.toggle('text-chart-3', f[0] === '?');
      r.children[1].textContent = f[1];
      r.children[2].textContent = f[2];
    });
    rows[0].classList.toggle('bg-secondary', s.diff);
    diff.style.visibility = s.diff ? '' : 'hidden';
    if (animate) [term.root, col.querySelector('[data-name="Page"]')!, shell[1].parentElement!].forEach(fadeIn);
  };
  go(0, false);
  if (reduced()) continue;

  whileVisible(v, () => {
    const tl = gsap.timeline({ repeat: -1 });
    const HOLD = 3.4;
    SESSIONS.forEach((_, i) => tl.call(() => go(i), [], i === 0 ? 0.01 : i * HOLD));
    tl.set({}, {}, SESSIONS.length * HOLD);
    return tl;
  });
}

// ---- survival: quit, and the work goes on -----------------------------------
for (const v of document.querySelectorAll<HTMLElement>('[data-survival]')) {
  const frame = v.querySelector<HTMLElement>('[data-frame]')!;
  const ghost = v.querySelector<HTMLElement>('[data-ghost]')!;
  const icon = v.querySelector<HTMLElement>('[data-icon]')!;
  const running = v.querySelector<HTMLElement>('[data-running]')!;
  const keys = v.querySelector<HTMLElement>('[data-keys="quit"]')!;
  const sb = new Sidebar(named(v, 'Sidebar')!);
  const term = new Terminal(named(v, 'Terminal')!);
  sb.pulse();
  // The agent's last lines are what the window misses while it is closed.
  const missed = term.lines().slice(-9);

  // The sessions keep time whether or not there is a window to show it.
  const clocks = Array.from(v.querySelectorAll<HTMLElement>('[data-clock]'));
  const fmt = (s: number) => `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`;
  if (reduced()) continue;
  setInterval(() => clocks.forEach((c) => { const s = Number(c.dataset.clock) + 1; c.dataset.clock = String(s); c.textContent = fmt(s); }), 1000);

  whileVisible(v, () => {
    const tl = gsap.timeline({ repeat: -1 });
    const at = { quit: 1.2, gone: 1.65, away: 2.3, launch: 5.4, back: 5.75, end: 9.4 };
    tl.call(() => missed.forEach((l) => l.setAttribute('hidden', '')), [], 0);
    tl.set(frame, { opacity: 1, scale: 1 }, 0).set(ghost, { opacity: 0 }, 0).set(running, { opacity: 1 }, 0);
    // ⌘Q: the window goes down into the Dock.
    pressKeys(tl, keys, at.quit);
    tl.to(frame, { scale: 0.08, opacity: 0, duration: 0.55, ease: 'power2.in' }, at.gone);
    tl.to(running, { opacity: 0, duration: 0.2 }, at.gone + 0.5);
    // No window. The sessions are still there, still counting.
    tl.to(ghost, { opacity: 1, duration: 0.4 }, at.away);
    // A click on the icon: it bounces, and the window is back with what it missed.
    tl.to(icon, { y: -20, duration: 0.18, ease: 'power2.out', yoyo: true, repeat: 1 }, at.launch);
    tl.to(running, { opacity: 1, duration: 0.2 }, at.back);
    tl.to(ghost, { opacity: 0, duration: 0.25 }, at.back);
    tl.call(() => missed.forEach((l) => l.removeAttribute('hidden')), [], at.back);
    tl.to(frame, { scale: 1, opacity: 1, duration: 0.7, ease: 'expo.out' }, at.back);
    tl.set({}, {}, at.end);
    return tl;
  });
}
