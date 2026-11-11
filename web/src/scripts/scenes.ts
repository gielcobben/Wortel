// The scenes on the homepage's stages below the panes. Each is a film with
// chapters (film.ts): a chapter is a function that puts a real window (app.ts)
// in that chapter's state, from wherever it was, so chapters can be played in
// order or jumped between. The windows answer to the pointer as well; a click
// in one pauses its film. Nothing is tied to scroll.
import { gsap } from 'gsap';
import { Pointer, Sidebar, Terminal, named, pressKeys, reduced, sessionScreen, wholeRows, type Status } from './app';
import { film } from './film';

const fadeIn = (el: Element) => gsap.fromTo(el, { opacity: 0 }, { opacity: 1, duration: 0.28, ease: 'power1.out', clearProps: 'opacity' });
const tap = (keys: HTMLElement) => pressKeys(gsap.timeline(), keys, 0, 1.1);
const BEAT = 0.5; // from a key going down to the app reacting
const REACH = 0.75; // the pointer's travel to what it presses

// ---- agents: a session stops for you, and one key takes you to it ----------
for (const v of document.querySelectorAll<HTMLElement>('[data-film="agents"]')) {
  const sb = new Sidebar(named(v, 'Sidebar')!);
  const term = new Terminal(named(v, 'Terminal')!);
  const title = named(v, 'Title')!;
  const note = v.querySelector<HTMLElement>('[data-note]')!;
  const jump = v.querySelector<HTMLElement>('[data-keys="jump"]')!;
  const enter = v.querySelector<HTMLElement>('[data-keys="enter"]')!;
  const HOME = 'Quicker panes', HERO = 'Landing page hero';

  // The session you are in. Its last stretch is what "at work" plays back.
  const home = term.lines();
  const tail = home.slice(home.findIndex((l) => (l.textContent || '').includes('SidebarOutlineView.swift')) - 0);
  const worked = home.find((l) => l.dataset.name === 'Worked')!;
  let busy: HTMLElement | null = null;
  const settle = () => { if (busy) term.idle(); busy = null; tail.forEach((l) => (l.hidden = false)); };

  // The session that wants you, and its question.
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
  const screens = new Map<string, HTMLElement[]>([[HOME, home], [HERO, asking]]);
  const screen = (name: string) => screens.get(name) || screens.set(name, sessionScreen(term, name)).get(name)!;

  // Where the scene is, so a chapter only changes what differs.
  let at = { session: HOME, screen: home as HTMLElement[], status: '' as Status | '', note: false };
  const show = (session: string, status: Status, withNote: boolean, animate: boolean) => {
    const lines = screen(session);
    settle();
    if (at.session !== session) { sb.select(session, animate); title.textContent = session; }
    if (at.screen !== lines || lines === asking) { term.idle(); term.swap(lines); if (animate && at.screen !== lines) fadeIn(term.root); }
    if (at.status !== status) sb.status(HERO, status);
    if (at.note !== withNote || !animate) {
      gsap.to(note, withNote
        ? { autoAlpha: 1, x: 0, duration: animate ? 0.6 : 0, ease: 'expo.out', overwrite: true }
        : { autoAlpha: 0, x: 48, duration: animate ? 0.35 : 0, ease: 'power2.in', overwrite: true });
    }
    at = { session, screen: lines, status, note: withNote };
  };

  const f = film(v, (f) => {
    // The answer: the build runs, comes back, and the dot is gone.
    const answer = (yes: boolean) => {
      question.forEach((q) => q.remove());
      if (!yes) {
        fadeIn(term.print('Claude', 'Understood. I will leave the build to you.'));
        sb.status(HERO, 'none'); at.status = 'none';
        return;
      }
      const result = term.print('Result', 'Running…');
      term.status('Running the build…', '2s');
      sb.status(HERO, 'working'); at.status = 'working';
      f.later(() => {
        term.idle();
        result.lastElementChild!.textContent = 'built in 2.14s';
        term.gap();
        fadeIn(term.print('Claude', 'Built. The hero paints in 0.8s, down from 2.1s.'));
        term.gap();
        term.print('Worked', 'Worked for 48s');
        sb.status(HERO, 'none'); at.status = 'none';
      }, 2);
    };
    // The choices in the prompt can be pressed.
    question.slice(2).forEach((q, i) => {
      q.dataset.press = '';
      q.addEventListener('click', () => { f.pause(); f.mark(3); answer(i < 2); });
    });

    return [
      {
        hold: 5,
        enter: (a) => {
          show(HOME, 'working', false, a);
          if (!a) return;
          // Play the session's last stretch back: lines arrive, a status turns.
          tail.forEach((l) => (l.hidden = true));
          busy = term.status('Checking the build…', '9s · thinking');
          term.fit();
          const beats = tail.filter((l) => l.dataset.name && l !== worked);
          beats.forEach((l, i) => f.later(() => {
            l.hidden = false;
            // The empty row above a block arrives with it.
            const gap = l.previousElementSibling as HTMLElement | null;
            if (gap && !gap.dataset.name) gap.hidden = false;
            term.fit();
          }, 0.7 + i * 0.55));
          f.later(settle, 0.7 + beats.length * 0.55 + 0.4);
        },
      },
      { hold: 3.8, enter: (a) => show(HOME, 'attention', true, a) },
      {
        hold: 4.4,
        enter: (a) => {
          if (!a) { show(HERO, 'attention', false, false); return; }
          show(HOME, 'attention', true, a);
          tap(jump);
          f.later(() => show(HERO, 'attention', false, true), BEAT);
        },
      },
      {
        hold: 6,
        enter: (a) => {
          show(HERO, 'attention', false, a);
          if (a) tap(enter);
          f.later(() => answer(true), a ? BEAT : 0);
        },
      },
    ];
  }, 1);

  // ---- your hands ------------------------------------------------------------
  // The notification takes you there, the way a click on one does.
  note.addEventListener('click', () => { f.pause(); f.mark(2); show(HERO, 'attention', false, true); });
  sb.clickable((name) => {
    f.pause();
    if (name === HERO && at.status === 'attention') f.mark(2);
    show(name, at.status || 'working', false, true);
  });
  wholeRows(v);
}

// ---- worktrees: pick a session, and the window is that worktree -------------
for (const v of document.querySelectorAll<HTMLElement>('[data-film="worktrees"]')) {
  const sb = new Sidebar(named(v, 'Sidebar')!);
  const term = new Terminal(named(v, 'Terminal')!);
  const title = named(v, 'Title')!;
  const col = named(v, 'Changes pane')!;
  const branch = named(col, 'Branch')!.querySelector('span')!;
  const header = named(col, 'Changes header')!.querySelector('span')!;
  const rows = Array.from(named(col, 'Change list')!.querySelectorAll<HTMLElement>('[data-name$=".swift"], [data-name$=".md"]'));
  const diff = named(col, 'Diff')!;
  // The shell's prompt names the directory and the branch; a long one wraps, as it would.
  const prompt = named(v, 'Strip terminal')!.querySelectorAll('p')[1];
  prompt.classList.remove('h-[19px]', 'whitespace-pre');
  prompt.classList.add('min-h-[19px]', 'whitespace-pre-wrap', '[overflow-wrap:anywhere]');
  const shell = prompt.querySelectorAll('span');
  const cols = { changes: v.querySelector<HTMLElement>('[data-col="changes"]')!, history: v.querySelector<HTMLElement>('[data-col="history"]')! };
  const pointer = new Pointer(v.querySelector<HTMLElement>('.set')!);

  type File = [mark: 'M' | '?', name: string, path: string];
  type Tree = { dir: string; branch: string; files: File[]; diff: boolean; screen: HTMLElement[] };
  const read = (r: HTMLElement): File => [r.children[0].textContent as 'M' | '?', r.children[1].textContent!, r.children[2].textContent!];
  const ORDER = ['Quicker panes', 'Icon grid survey and fixes', 'Sparkle appcast cleanup'];
  const TREES = new Map<string, Tree>([
    [ORDER[0], { dir: 'wortel', branch: 'main', files: rows.map(read), diff: true, screen: term.lines() }],
    [ORDER[1], {
      dir: 'codebase-survey-and-fixes', branch: 'codebase-survey-and-fixes', diff: false,
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
      }, '/…/wortel/codebase-survey-and-fixes'),
    }],
    [ORDER[2], {
      dir: 'appcast-cleanup', branch: 'appcast-cleanup', diff: false,
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
      }, '/…/wortel/appcast-cleanup'),
    }],
  ]);
  // A session that is not on a branch of its own works in the repository itself.
  const tree = (name: string) => TREES.get(name)
    || TREES.set(name, { dir: 'wortel', branch: 'main', files: [], diff: false, screen: sessionScreen(term, name) }).get(name)!;

  let on = ORDER[0], column: 'changes' | 'history' = 'changes';
  const session = (name: string, animate: boolean) => {
    if (on === name) return;
    on = name;
    const s = tree(name);
    sb.select(name, animate);
    title.textContent = name;
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
    gsap.fromTo(cols[which], { autoAlpha: 0, y: 6 }, { autoAlpha: 1, y: 0, duration: 0.32 * d, delay: 0.16 * d, ease: 'power2.out', clearProps: 'transform' });
    column = which;
  };

  const f = film(v, (f) => [
    ...ORDER.map((name) => ({
      hold: 4,
      enter: (a: boolean) => {
        showColumn('changes', a);
        if (!a || on === name) { session(name, a); pointer.hide(); return; }
        // The film picks the session the way you would: with the pointer.
        pointer.click(sb.row(name), REACH);
        f.later(() => session(name, true), REACH);
        f.later(() => pointer.hide(), REACH + 1.2);
      },
    })),
    { hold: 4.6, enter: (a: boolean) => { pointer.hide(); session(ORDER[0], a); showColumn('history', a); } },
  ], 1);

  // ---- your hands ------------------------------------------------------------
  sb.clickable((name) => {
    f.pause(); pointer.hide();
    const i = ORDER.indexOf(name);
    if (i >= 0) f.mark(i);
    showColumn('changes', true);
    session(name, true);
  });
  // History carries a Changes tab: it goes back.
  const back = named(cols.history, 'Changes tab');
  if (back) { back.dataset.press = ''; back.addEventListener('click', () => { f.pause(); f.mark(ORDER.indexOf(on) >= 0 ? ORDER.indexOf(on) : 0); showColumn('changes', true); }); }
  wholeRows(v);
}

// ---- survival: quit, and the work goes on -----------------------------------
for (const v of document.querySelectorAll<HTMLElement>('[data-film="survival"]')) {
  const frame = v.querySelector<HTMLElement>('[data-frame]')!;
  const ghost = v.querySelector<HTMLElement>('[data-ghost]')!;
  const dock = v.querySelector<HTMLElement>('[data-dock]')!;
  const icon = v.querySelector<HTMLElement>('[data-icon]')!;
  const running = v.querySelector<HTMLElement>('[data-running]')!;
  const keys = v.querySelector<HTMLElement>('[data-keys="quit"]')!;
  const sb = new Sidebar(named(v, 'Sidebar')!);
  const term = new Terminal(named(v, 'Terminal')!);
  const pointer = new Pointer(v.querySelector<HTMLElement>('.set')!);
  wholeRows(v);
  sb.pulse();
  // The agent's last lines are what the window misses while it is closed.
  const missed = term.lines().slice(-9);
  const miss = (hidden: boolean) => { missed.forEach((l) => l.toggleAttribute('hidden', hidden)); term.fit(); };

  // The sessions keep time whether or not there is a window to show it.
  const clocks = Array.from(v.querySelectorAll<HTMLElement>('[data-clock]'));
  const fmt = (s: number) => `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`;
  if (!reduced()) setInterval(() => clocks.forEach((c) => { const s = Number(c.dataset.clock) + 1; c.dataset.clock = String(s); c.textContent = fmt(s); }), 1000);

  let open = true;
  const win = (to: boolean, animate: boolean) => {
    open = to;
    gsap.to(frame, to
      ? { scale: 1, autoAlpha: 1, duration: animate ? 0.7 : 0, ease: 'expo.out', overwrite: true }
      : { scale: 0.08, autoAlpha: 0, duration: animate ? 0.55 : 0, ease: 'power2.in', overwrite: true });
    gsap.to(running, { opacity: to ? 1 : 0, duration: animate ? 0.2 : 0, delay: animate && !to ? 0.5 : 0, overwrite: true });
  };
  const away = (shown: boolean, animate: boolean) => gsap.to(ghost, { opacity: shown ? 1 : 0, duration: animate ? 0.4 : 0, delay: animate && shown ? 0.35 : 0, overwrite: true });
  const bounce = () => gsap.fromTo(icon, { y: 0 }, { y: -20, duration: 0.18, ease: 'power2.out', yoyo: true, repeat: 1 });
  const reopen = () => { away(false, true); miss(false); win(true, true); };

  const f = film(v, (f) => [
    { hold: 3, enter: (a) => { pointer.hide(); miss(true); away(false, a); win(true, a); } },
    {
      hold: 2.8,
      enter: (a) => {
        pointer.hide(); miss(true); away(false, a); win(true, a);
        if (!a) return;
        tap(keys);
        f.later(() => win(false, true), BEAT);
      },
    },
    { hold: 4, enter: (a) => { pointer.hide(); win(false, a); away(true, a); } },
    {
      hold: 5.4,
      enter: (a) => {
        if (!a) { miss(false); away(false, false); win(true, false); return; }
        win(false, false); away(true, false);
        // The film reopens it the way you would: a click on the Dock icon.
        pointer.click(dock, REACH);
        f.later(() => { bounce(); f.later(reopen, 0.4); f.later(() => pointer.hide(), 1.4); }, REACH);
      },
    },
  ], 2);

  // ---- your hands: the Dock icon quits and reopens ---------------------------
  dock.addEventListener('click', () => {
    f.pause(); pointer.hide();
    if (open) { f.mark(2); miss(true); win(false, true); away(true, true); }
    else { f.mark(3); bounce(); gsap.delayedCall(0.4, reopen); }
  });
}
