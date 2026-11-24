// The scenes on the homepage's stages beside the panes. Each is a film with
// chapters (film.ts): a chapter is a function that puts a real window (app.ts)
// in that chapter's state, from wherever it was, so chapters can be played in
// order or jumped between. The windows answer to the pointer as well; a click
// in one pauses its film. Nothing is tied to scroll.
import { gsap } from 'gsap';
import { Sidebar, Terminal, codex, codexFresh, codexScreen, named, pressKeys, reduced, sessionScreen, wholeRows, type Status } from './app';
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
  // Five sessions in a flat list, and their dots: here the dots are the point.
  sb.show(['Section Sessions', HOME, 'Marketing screenshots', HERO, 'Changelog typography', 'Pricing FAQ copy']);

  // The other sessions live too: while you watch one, the rest keep moving.
  // `before` is how "at work" opens, `after` how it ends (and how every later
  // chapter finds them); a row only changes, and its dot only pops, when its
  // status does.
  const MARKETING = 'Marketing screenshots', CHANGELOG = 'Changelog typography', PRICING = 'Pricing FAQ copy';
  const before: Record<string, Status> = { [MARKETING]: 'working', [CHANGELOG]: 'none', [PRICING]: 'done' };
  const after: Record<string, Status> = { [MARKETING]: 'done', [CHANGELOG]: 'working', [PRICING]: 'done' };
  const now: Record<string, Status> = { [MARKETING]: 'working', [CHANGELOG]: 'none', [PRICING]: 'none' };
  const set = (name: string, status: Status) => { if (now[name] !== status) { sb.status(name, status); now[name] = status; } };
  const all = (states: Record<string, Status>) => Object.entries(states).forEach(([n, st]) => set(n, st));
  all(before);
  // A background agent that finishes gets a notification of its own: the
  // start of its answer, under the session's name.
  const doneNote = note.cloneNode(true) as HTMLElement;
  doneNote.setAttribute('aria-label', `Notification: ${MARKETING}. Six of nine done. Go to that session.`);
  doneNote.querySelector('b')!.textContent = MARKETING;
  doneNote.querySelector('.msg')!.textContent = 'Six of nine done. The three with the browser pane need the new site first.';
  note.after(doneNote);
  const banner = (el: HTMLElement, on: boolean, animate: boolean) => on
    ? gsap.fromTo(el, { autoAlpha: 0, x: 72, scale: 0.96 }, { autoAlpha: 1, x: 0, scale: 1, duration: animate ? 0.7 : 0, ease: 'back.out(1.25)', overwrite: true })
    : gsap.to(el, { autoAlpha: 0, x: 48, duration: animate ? 0.25 : 0, ease: 'power2.out', overwrite: true });

  // This section's agent is Claude Code (the page's sections take turns).
  // The session you are in: its last stretch is what "at work" plays back.
  const home = term.lines();
  // The whole turn, from the agent's first words: "at work" streams all of it.
  const tail = home.slice(home.findIndex((l) => l.dataset.name === 'Claude'));
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

  // Switching into a session that was waiting on you, the app flashes a ring
  // in its colour over the terminal, to orient the eye, and the dot clears
  // (ContentView.AttentionFlashOverlay: 0.12s in to 85%, 0.7s out).
  const pane = named(v, 'Terminal pane')!;
  pane.style.position = 'relative';
  const ring = document.createElement('div');
  ring.className = 'pointer-events-none absolute inset-[1.5px] z-10 rounded-[8px] border-[2.5px] border-chart-1 opacity-0';
  pane.append(ring);
  const flash = () => {
    gsap.killTweensOf(ring);
    if (reduced()) { gsap.fromTo(ring, { opacity: 0.85 }, { opacity: 0, duration: 0.5, delay: 0.4, ease: 'power1.in' }); return; }
    gsap.timeline()
      .fromTo(ring, { opacity: 0 }, { opacity: 0.85, duration: 0.12, ease: 'power1.out' })
      .to(ring, { opacity: 0, duration: 0.7, ease: 'power1.in' });
  };

  // Where the scene is, so a chapter only changes what differs.
  let at = { session: HOME, screen: home as HTMLElement[], status: '' as Status | '', note: false };
  const show = (session: string, status: Status, withNote: boolean, animate: boolean) => {
    const lines = screen(session);
    settle();
    // Arriving where you were wanted: the ring, and the dot clears.
    const arriving = session === HERO && at.session !== HERO && at.status === 'attention';
    if (arriving) { status = 'none'; if (animate) flash(); }
    // A session switch is instant, as in the app: no fade, no slide.
    if (at.session !== session) { sb.select(session); title.textContent = session; }
    if (at.screen !== lines || lines === asking) { term.idle(); term.swap(lines); }
    if (at.status !== status) sb.status(HERO, status);
    if (at.note !== withNote || !animate) banner(note, withNote, animate);
    at = { session, screen: lines, status, note: withNote };
  };

  const f = film(v, (f) => {
    /** Stream a line's words in after its glyph, as an agent prints them. */
    const stream = (line: HTMLElement, at: number, each = 0.035) => {
      const glyph = line.firstElementChild;
      const rest = Array.from(line.childNodes).filter((n) => n !== glyph);
      const text = rest.map((n) => n.textContent).join('');
      rest.forEach((n) => n.remove());
      const out = document.createTextNode('');
      line.append(out);
      const words = text.split(/(?<= )/);
      words.forEach((_, k) => f.later(() => { out.textContent = words.slice(0, k + 1).join(''); term.fit(); }, at + k * each));
      return at + words.length * each;
    };
    /** A tool call: its dot blinks grey while it runs, then turns green. */
    const run = (line: HTMLElement, at: number, takes: number) => {
      const dot = line.firstElementChild as HTMLElement | null;
      if (!dot) return;
      f.later(() => {
        dot.style.color = '#999999';
        gsap.fromTo(dot, { opacity: 1 }, { opacity: 0.2, duration: 0.18, yoyo: true, repeat: Math.max(1, Math.round(takes / 0.18) - 1) });
      }, at);
      f.later(() => { gsap.killTweensOf(dot); gsap.set(dot, { opacity: 1 }); dot.style.color = ''; }, at + takes);
    };
    // What the status line says it is doing, by the tool it is in.
    const VERB: Record<string, string> = { Read: 'Reading', Search: 'Searching', Update: 'Editing', Write: 'Writing', Bash: 'Building' };

    // The answer: the build runs, comes back, and the dot is gone.
    const answer = (yes: boolean) => {
      question.forEach((q) => q.remove());
      if (!yes) {
        fadeIn(term.print('Claude', 'Understood. I will leave the build to you.'));
        sb.status(HERO, 'none'); at.status = 'none';
        return;
      }
      // The build runs under the tool line: its output arrives a line at a
      // time while the dot blinks, then the answer streams in.
      const bash = Array.from(term.root.querySelectorAll<HTMLElement>(':scope > [data-name="Tool"]')).pop();
      if (bash) run(bash, 0, 2);
      const result = term.print('Result', 'vite v6.3 building for production…');
      const busy = term.status('Building…', '1s');
      sb.status(HERO, 'working'); at.status = 'working';
      const out = result.lastElementChild!;
      f.later(() => { out.textContent = '✓ 142 modules transformed.'; }, 0.7);
      f.later(() => { out.textContent = 'dist/assets/hero-2400.avif  184 kB'; busy.lastElementChild!.textContent = '(2s)'; }, 1.3);
      f.later(() => {
        term.idle();
        out.textContent = '✓ built in 2.14s';
        term.gap();
        const said = term.print('Claude', 'Built. The hero paints in 0.8s, down from 2.1s.');
        const end = stream(said, 0.05);
        f.later(() => {
          term.gap();
          term.print('Worked', 'Worked for 48s');
          sb.status(HERO, 'none'); at.status = 'none';
        }, end + 0.2);
      }, 2);
    };
    // The choices in the prompt can be pressed.
    question.slice(2).forEach((q, i) => {
      q.dataset.press = '';
      q.addEventListener('click', () => { f.pause(); f.mark(3); answer(i < 2); });
    });

    return [
      {
        hold: 9,
        enter: (a) => {
          show(HOME, 'working', false, a);
          banner(doneNote, false, a);
          if (!a) { all(after); return; }
          all(before);
          // Play the session's last stretch back as it happened: its words
          // stream in, each tool's dot blinks while it runs and its result
          // follows, the status line says what it is doing, and its clock runs.
          const texts = new Map(tail.map((l) => [l, l.innerHTML] as const));
          tail.forEach((l) => (l.hidden = true));
          busy = term.status('Thinking…', '9s');
          const said = busy.children[1] as HTMLElement, clock = busy.lastElementChild!;
          for (let s = 1; s <= 7; s++) f.later(() => { clock.textContent = `(${9 + s}s)`; }, s);
          term.fit();
          let t = 0.4;
          const reveal = (l: HTMLElement, when: number) => f.later(() => {
            l.hidden = false;
            // The empty row above a block arrives with it.
            const gap = l.previousElementSibling as HTMLElement | null;
            if (gap && !gap.dataset.name) gap.hidden = false;
            term.fit();
          }, when);
          for (const l of tail.filter((l) => l.dataset.name && l !== worked)) {
            l.innerHTML = texts.get(l)!;
            if (l.dataset.name === 'Claude') {
              reveal(l, t);
              t = stream(l, t + 0.05, 0.03) + 0.25;
            } else if (l.dataset.name === 'Tool') {
              const verb = VERB[l.children[1]?.textContent || ''];
              if (verb) f.later(() => { said.textContent = `${verb}…`; }, t);
              reveal(l, t);
              run(l, t, 0.45);
              t += 0.5;
            } else {
              reveal(l, t);
              t += 0.2;
            }
          }
          f.later(settle, t + 0.3);
          // Meanwhile, in the sidebar: one picks up work, one finishes and
          // says so, and the one that was done is read.
          f.later(() => set(CHANGELOG, 'working'), 1.4);
          f.later(() => { set(MARKETING, 'done'); banner(doneNote, true, true); }, 3.2);
          f.later(() => banner(doneNote, false, true), 6.2);
        },
      },
      { hold: 3.8, enter: (a) => { all(after); banner(doneNote, false, a); show(HOME, 'attention', true, a); } },
      {
        hold: 4.4,
        enter: (a) => {
          all(after); banner(doneNote, false, a);
          if (!a) { show(HERO, 'attention', false, false); return; }
          show(HOME, 'attention', true, a);
          tap(jump);
          f.later(() => show(HERO, 'attention', false, true), BEAT);
        },
      },
      {
        hold: 6,
        enter: (a) => {
          all(after); banner(doneNote, false, a);
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
  doneNote.addEventListener('click', () => { f.pause(); banner(doneNote, false, true); set(MARKETING, 'none'); show(MARKETING, at.status || 'working', false, true); });
  const pick = (name: string) => {
    f.pause();
    if (name === HERO && at.status === 'attention') f.mark(2);
    show(name, at.status || 'working', false, true);
  };
  sb.clickable(pick);
  sb.navigable(pick);
  wholeRows(v);
}

// ---- start: a shell first, and an agent when you want one -------------------
for (const v of document.querySelectorAll<HTMLElement>('[data-film="start"]')) {
  const sb = new Sidebar(named(v, 'Sidebar')!);
  const root = named(v, 'Terminal')!;
  const title = named(v, 'Title')!;
  const keys = v.querySelector<HTMLElement>('[data-keys="new"]')!;
  const HOME = sb.selected;
  // The plainest sidebar on the page: a flat list of sessions, nothing else.
  sb.show(['Section Sessions', HOME, 'Landing page hero', 'Changelog typography', 'Pricing FAQ copy', 'Open Graph image refresh']);

  // The plain shell's two kinds of line, as the canvas draws them.
  const strip = v.querySelector<HTMLTemplateElement>('template[data-tpl="shell"]')!.content.querySelector('[data-name="Strip terminal"]')!;
  const [plainMould, promptMould] = Array.from(strip.children) as HTMLElement[];
  const out = (text: string) => { const p = plainMould.cloneNode(true) as HTMLElement; p.textContent = text; return p; };
  const prompt = (cmd = '') => {
    const p = promptMould.cloneNode(true) as HTMLElement;
    const cursor = p.lastElementChild as HTMLElement;
    const typed = document.createElement('span');
    // The canvas draws the prompt with no space after it: the command brings one.
    typed.textContent = cmd && ` ${cmd}`;
    cursor.before(typed);
    return { p, typed, cursor };
  };
  const done = (cmd: string) => { const l = prompt(cmd); l.cursor.remove(); return l.p; };

  // The agent here is Codex: the page's sections take turns, Claude Code,
  // Codex, Pi, and this is the second. Its screens are the captured ones
  // (app.ts): just started, which can be typed into, and at work.
  let fresh: ReturnType<typeof codexFresh> | null = null;
  let run: ReturnType<typeof codexScreen> | null = null;
  const show = (nodes: HTMLElement[]) => { root.dataset.agent = 'codex'; root.style.justifyContent = 'flex-start'; root.replaceChildren(...nodes); };
  const shell = (lines: HTMLElement[]) => { delete root.dataset.agent; root.style.justifyContent = 'flex-start'; root.replaceChildren(...lines); };
  /** The agent takes the screen: Codex, just started. */
  const agent = () => { run = null; fresh = codexFresh(); show(fresh.nodes); };
  /** What is typed in its input box. */
  const ask = (text: string) => fresh?.type(text);
  /** Send what was asked: it goes up under the header and Codex sets to work. */
  const send = (text: string) => { fresh = null; run = codexScreen(text); show(run.nodes); run.working(0); };

  const LOGIN = 'Last login: Fri Nov 20 09:41:12 on ttys004';
  // A test run, as a runner prints one: a tick per test, then the count. The
  // greens and the grey are the terminal's own (GitHub Light and Dark).
  const GREEN = 'text-[#116329] dark:text-[#3fb950]', DIM = 'text-[#666666] dark:text-[#999999]';
  const rich = (parts: [string, string?][]) => {
    const p = out('');
    for (const [text, cls] of parts) {
      const span = document.createElement('span');
      if (cls) span.className = cls;
      span.textContent = text;
      p.append(span);
    }
    return p;
  };
  const TICKS: [string, string][] = [
    ['a session switches on mouse-down', '3ms'],
    ['sessions come back after a quit', '12ms'],
    ['a worktree opens on its branch', '8ms'],
    ['the scrollback is kept while closed', '21ms'],
    ['light and dark follow the system', '2ms'],
    ['a reminder rings once', '4ms'],
  ];
  const tick = ([name, ms]: [string, string]) => rich([[' ✓ ', GREEN], [name], [`  ${ms}`, DIM]]);
  const summary = () => [out(''), rich([[' Tests  ', DIM], ['212 passed', `${GREEN} font-bold`], [' (212)', DIM]]), rich([[' Time   ', DIM], ['4.1s']]), out('')];
  /** The shell after a test run: every tick printed, a prompt waiting. */
  const worked = () => {
    const last = prompt();
    shell([out(LOGIN), done('npm test'), out(''), ...TICKS.map(tick), ...summary(), last.p]);
    return last;
  };

  const AGENT = 'codex';
  const REQUEST = 'Make the sidebar rows a touch taller';
  // What Codex does with it, a block at a time.
  const WORK = [
    () => [codex.say('I’ll measure the rows first. Their height lives in SidebarOutlineView.swift.')],
    () => codex.explored(['macos/Wortel/UI/SidebarOutlineView.swift', 'macos/Wortel/UI/Chrome.swift']),
    () => codex.edited('macos/Wortel/UI/Chrome.swift', 2, 2),
  ];
  /** The first session after its request: the agent reading and editing. */
  const busy = () => {
    send(REQUEST);
    WORK.forEach((block) => run!.add(block()));
    run!.working(14);
    sb.status(HOME, 'working');
  };
  // The sessions ⌘N opens, one a press. Each arrives at the top of the list
  // named for its folder, with the agent's name already typed at its prompt;
  // given a task, it takes the task's name and its row says it is at work.
  const FOLDER = 'wortel';
  // The agent names a session from its first prompt (Claude Code titles
  // itself), so each task is what was asked, and the name it came back with.
  const TASKS: [name: string, asked: string][] = [
    ['Fix the login redirect', 'The login redirect loops on Safari, fix it'],
    ['Add a changelog page', 'Add a changelog page to the site'],
    ['Tidy the appcast feed', 'Trim the appcast feed to the last five'],
  ];
  const opened: HTMLElement[] = [];
  /** A new session: its row, selected, and its shell, with the agent
   *  Settings names already typed into it. */
  const open = (task: string) => {
    const row = named(sb.nav, 'Pricing FAQ copy')!.cloneNode(true) as HTMLElement;
    row.dataset.name = task;
    row.hidden = false;
    row.querySelector('span')!.textContent = FOLDER;
    row.querySelector('[data-name="Status"]')?.remove();
    named(sb.nav, 'Section Sessions')!.after(row);
    opened.push(row);
    sb.select(task);
    title.textContent = FOLDER;
    shell([out(LOGIN), prompt(AGENT).p]);
  };
  /** Given its task: the session takes the name, and its row the dots. */
  const work = (task: string) => {
    named(sb.nav, task)!.querySelector('span')!.textContent = task;
    if (sb.selected === task) title.textContent = task;
    sb.status(task, 'working');
  };
  const close = () => {
    sb.select(HOME);
    title.textContent = HOME;
    opened.splice(0).forEach((r) => r.remove());
    sb.status(HOME, 'none');
  };

  // Settings, and the one field in it that this is about. The field shows
  // its placeholder until something is typed, as the app's does.
  const prefs = v.querySelector<HTMLElement>('[data-settings]')!;
  const field = named(prefs, 'Placeholder')!;
  const PLACEHOLDER = field.textContent || 'Command';
  const command = (text: string) => {
    field.textContent = text || PLACEHOLDER;
    field.classList.toggle('text-muted-foreground', !text);
    field.classList.toggle('text-foreground', !!text);
  };
  let prefsOpen = false;
  const settings = (open: boolean, animate: boolean) => {
    if (open === prefsOpen && animate) return;
    prefsOpen = open;
    gsap.to(prefs, open
      ? { autoAlpha: 1, y: 0, scale: 1, duration: animate ? 0.35 : 0, ease: 'expo.out', overwrite: true, clearProps: 'transform' }
      : { autoAlpha: 0, y: 8, scale: 0.98, duration: animate ? 0.2 : 0, ease: 'power2.out', overwrite: true });
  };
  gsap.set(prefs, { y: 8, scale: 0.98 });

  film(v, (f) => {
    const type = (into: () => HTMLElement, text: string, at: number) => {
      [...text].forEach((_, i) => f.later(() => { into().textContent = ` ${text.slice(0, i + 1)}`; }, at + i * 0.04));
      return at + text.length * 0.04;
    };
    return [
      {
        hold: 4.2,
        enter: (a) => {
          close(); settings(false, a);
          if (!a) { worked(); return; }
          // One command, and the shell answers at once: the ticks run down.
          const line = prompt();
          shell([out(LOGIN), line.p]);
          const t = type(() => line.typed, 'npm test', 0.3) + 0.2;
          f.later(() => { line.cursor.remove(); root.append(out('')); }, t);
          TICKS.forEach((k, i) => f.later(() => root.append(tick(k)), t + 0.15 + i * 0.11));
          f.later(() => root.append(...summary(), prompt().p), t + 0.3 + TICKS.length * 0.11);
        },
      },
      {
        hold: 6.6,
        enter: (a) => {
          close(); settings(false, a);
          if (!a) { busy(); return; }
          // The agent is typed like anything else, and takes the screen. Then
          // it is asked for something, and sets to work.
          const line = worked();
          let t = type(() => line.typed, AGENT, 0.5);
          f.later(agent, t + 0.35);
          t += 0.9;
          [...REQUEST].forEach((_, i) => f.later(() => ask(REQUEST.slice(0, i + 1)), t + i * 0.03));
          t += REQUEST.length * 0.03 + 0.3;
          f.later(() => { send(REQUEST); sb.status(HOME, 'working'); }, t);
          WORK.forEach((block, i) => f.later(() => { run?.add(block()); run?.working(1 + i * 2); }, t + 0.8 + i * 0.8));
        },
      },
      {
        hold: 3.6,
        enter: (a) => {
          // Settings opens over the session, with the agent still at work
          // under it, and the agent's name is typed into the one field.
          close(); busy();
          command(a ? '' : AGENT);
          settings(true, a);
          if (!a) return;
          [...AGENT].forEach((_, i) => f.later(() => command(AGENT.slice(0, i + 1)), 0.8 + i * 0.07));
        },
      },
      {
        hold: 9,
        enter: (a) => {
          command(AGENT);
          settings(false, a);
          close();
          // The first session's agent is still at work.
          sb.status(HOME, 'working');
          const named_ = (name: string, asked: string) => () => {
            send(asked);
            work(name);
          };
          if (!a) {
            TASKS.forEach(([name]) => open(name));
            TASKS.forEach(([name]) => work(name));
            agent(); named_(...TASKS[TASKS.length - 1])();
            return;
          }
          busy();
          // A press, a session with the agent Settings names already running,
          // a request, and the session takes the name the agent gives it.
          // Three times.
          TASKS.forEach(([name, asked], i) => {
            const at = 0.3 + i * 2.5;
            f.later(() => tap(keys), at);
            f.later(() => open(name), at + BEAT);
            f.later(agent, at + BEAT + 0.35);
            const from = at + BEAT + 0.7;
            [...asked].forEach((_, k) => f.later(() => ask(asked.slice(0, k + 1)), from + k * 0.022));
            f.later(named_(name, asked), from + asked.length * 0.022 + 0.25);
          });
        },
      },
    ];
  }, 0);
  wholeRows(v);
}
