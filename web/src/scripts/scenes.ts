// The scenes on the homepage's stages below the panes. Each is a film with
// chapters (film.ts): a chapter is a function that puts a real window (app.ts)
// in that chapter's state, from wherever it was, so chapters can be played in
// order or jumped between. Nothing is tied to scroll.
import { gsap } from 'gsap';
import { Sidebar, Terminal, named, pressKeys, reduced, type Status } from './app';
import { film } from './film';

const fadeIn = (el: Element) => gsap.fromTo(el, { opacity: 0 }, { opacity: 1, duration: 0.28, ease: 'power1.out', clearProps: 'opacity' });
const tap = (keys: HTMLElement) => pressKeys(gsap.timeline(), keys, 0, 1.1);
const BEAT = 0.5; // from a key going down to the app reacting

// ---- agents: a session stops for you, and one key takes you to it ----------
for (const v of document.querySelectorAll<HTMLElement>('[data-film="agents"]')) {
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

  // Where the scene is, so a chapter only changes what differs.
  let at = { session: '', screen: null as HTMLElement[] | null, status: '' as Status | '', note: false };
  const show = (session: string, screen: HTMLElement[], status: Status, withNote: boolean, animate: boolean) => {
    if (at.session !== session) { sb.select(session, animate); title.textContent = session; }
    if (at.screen !== screen || screen === asking) { term.swap(screen); if (animate && at.screen !== screen) fadeIn(term.root); }
    if (at.status !== status) sb.status(HERO, status);
    if (at.note !== withNote || !animate) {
      gsap.to(note, withNote
        ? { opacity: 1, x: 0, duration: animate ? 0.6 : 0, ease: 'expo.out' }
        : { opacity: 0, x: 40, duration: animate ? 0.4 : 0, ease: 'power2.in' });
    }
    at = { session, screen, status, note: withNote };
  };

  film(v, (f) => [
    { hold: 3.2, enter: (a) => show(HOME, home, 'working', false, a) },
    { hold: 3.8, enter: (a) => show(HOME, home, 'attention', true, a) },
    {
      hold: 4.4,
      enter: (a) => {
        show(HOME, home, 'attention', true, a);
        if (!a) { show(HERO, asking, 'attention', false, false); return; }
        tap(jump);
        f.later(() => show(HERO, asking, 'attention', false, true), BEAT);
      },
    },
    {
      hold: 6,
      enter: (a) => {
        show(HERO, asking, 'attention', false, a);
        if (a) tap(enter);
        f.later(() => {
          question.forEach((q) => q.remove());
          const result = term.print('Result', 'Running…');
          sb.status(HERO, 'working'); at.status = 'working';
          f.later(() => {
            result.lastElementChild!.textContent = 'built in 2.14s';
            term.gap();
            fadeIn(term.print('Claude', 'Built. The hero paints in 0.8s, down from 2.1s.'));
            term.gap();
            term.print('Worked', 'Worked for 48s');
            sb.status(HERO, 'none'); at.status = 'none';
          }, 2);
        }, a ? BEAT : 0);
      },
    },
  ], 1);
}

// ---- worktrees: pick a branch, and the window is that worktree --------------
for (const v of document.querySelectorAll<HTMLElement>('[data-film="worktrees"]')) {
  const sb = new Sidebar(named(v, 'Sidebar')!);
  const term = new Terminal(named(v, 'Terminal')!);
  const title = named(v, 'Title')!;
  const col = named(v, 'Changes pane')!;
  const branch = named(col, 'Branch')!.querySelector('span')!;
  const header = named(col, 'Changes header')!.querySelector('span')!;
  const rows = Array.from(named(col, 'Change list')!.querySelectorAll<HTMLElement>('[data-name$=".swift"], [data-name$=".md"]'));
  const diff = named(col, 'Diff')!;
  const shell = named(v, 'Strip terminal')!.querySelectorAll('p')[1].querySelectorAll('span');
  const cols = { changes: v.querySelector<HTMLElement>('[data-col="changes"]')!, history: v.querySelector<HTMLElement>('[data-col="history"]')! };

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

  let on = -1, column: 'changes' | 'history' = 'changes';
  const session = (i: number, animate: boolean) => {
    if (on === i) return;
    on = i;
    const s = SESSIONS[i];
    sb.select(s.row, animate);
    title.textContent = s.row;
    term.swap(s.screen);
    shell[1].textContent = `${s.dir} `;
    shell[3].textContent = s.branch;
    branch.textContent = s.branch;
    header.textContent = `Changes (${s.files.length})`;
    rows.forEach((r, k) => {
      const file = s.files[k];
      r.toggleAttribute('hidden', !file);
      if (!file) return;
      r.children[0].textContent = file[0];
      r.children[0].classList.toggle('text-chart-1', file[0] === 'M');
      r.children[0].classList.toggle('text-chart-3', file[0] === '?');
      r.children[1].textContent = file[1];
      r.children[2].textContent = file[2];
    });
    rows[0].classList.toggle('bg-secondary', s.diff);
    diff.style.visibility = s.diff ? '' : 'hidden';
    if (animate) [term.root, col.querySelector('[data-name="Page"]')!, shell[1].parentElement!].forEach(fadeIn);
  };
  const showColumn = (which: 'changes' | 'history', animate: boolean) => {
    if (column === which) return;
    const d = animate ? 1 : 0;
    gsap.to(cols[column], { autoAlpha: 0, duration: 0.16 * d, ease: 'power1.in' });
    gsap.fromTo(cols[which], { autoAlpha: 0, y: 6 }, { autoAlpha: 1, y: 0, duration: 0.32 * d, delay: 0.16 * d, ease: 'power2.out' });
    column = which;
  };

  film(v, () => [
    ...SESSIONS.map((_, i) => ({ hold: 3.8, enter: (a: boolean) => { showColumn('changes', a); session(i, a); } })),
    { hold: 4.6, enter: (a: boolean) => { session(0, a); showColumn('history', a); } },
  ], 1);
}

// ---- survival: quit, and the work goes on -----------------------------------
for (const v of document.querySelectorAll<HTMLElement>('[data-film="survival"]')) {
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
  const miss = (hidden: boolean) => missed.forEach((l) => l.toggleAttribute('hidden', hidden));

  // The sessions keep time whether or not there is a window to show it.
  const clocks = Array.from(v.querySelectorAll<HTMLElement>('[data-clock]'));
  const fmt = (s: number) => `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`;
  if (!reduced()) setInterval(() => clocks.forEach((c) => { const s = Number(c.dataset.clock) + 1; c.dataset.clock = String(s); c.textContent = fmt(s); }), 1000);

  const win = (open: boolean, animate: boolean) => {
    gsap.to(frame, open
      ? { scale: 1, opacity: 1, duration: animate ? 0.7 : 0, ease: 'expo.out', overwrite: true }
      : { scale: 0.08, opacity: 0, duration: animate ? 0.55 : 0, ease: 'power2.in', overwrite: true });
    gsap.to(running, { opacity: open ? 1 : 0, duration: animate ? 0.2 : 0, delay: animate && !open ? 0.5 : 0, overwrite: true });
  };
  const away = (shown: boolean, animate: boolean) => gsap.to(ghost, { opacity: shown ? 1 : 0, duration: animate ? 0.4 : 0, delay: animate && shown ? 0.35 : 0, overwrite: true });

  film(v, (f) => [
    { hold: 3, enter: (a) => { miss(true); away(false, a); win(true, a); } },
    {
      hold: 2.8,
      enter: (a) => {
        miss(true); away(false, a); win(true, a);
        if (!a) return;
        tap(keys);
        f.later(() => win(false, true), BEAT);
      },
    },
    { hold: 4, enter: (a) => { win(false, a); away(true, a); } },
    {
      hold: 5,
      enter: (a) => {
        if (!a) { miss(false); away(false, false); win(true, false); return; }
        win(false, false);
        gsap.to(icon, { y: -20, duration: 0.18, ease: 'power2.out', yoyo: true, repeat: 1 });
        f.later(() => { away(false, true); miss(false); win(true, true); }, 0.4);
      },
    },
  ], 2);
}
