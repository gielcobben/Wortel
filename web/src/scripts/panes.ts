// The splits scene: one window and one story, told a chapter at a time, by
// the film or by the visitor's own hands on the window's controls.
//
// The session is the agent building the landing page. ⇧⌘D splits its
// terminal down, and a dev server is started in the new shell under it. A
// ⌘-click on the address the server prints opens the page where a browser
// opens by itself, in a column at the outer edge, half the window, and its
// tab is dragged from there into the agent's split, where it joins the
// agent's tab. Then ⇧⌘↩ gives the page everything beside the sidebar, and
// ⇧⌘↩ again shows both splits. The window only ever goes forward: each
// chapter starts where the one before it ended. On /layouts a fourth
// chapter follows: ⌘B hides the sidebar.
//
// It moves the way the app does. A tab opened beside the terminal slides its
// column in; a split somebody makes, a tab dropped on an edge and a zoom land
// in one cut, with a short fade that only says what changed. Whichever row is
// the rightmost along the top keeps clear of the window's corner, the
// leftmost gains the sidebar's buttons when the sidebar is gone, and with
// three splits on screen the front tabs of the two you are not in go quiet.
import { gsap } from 'gsap';
import { Pointer, Sidebar, Terminal, fitTerminal, named, pressKeys, reduced, retaken, schemePictures, sessionScreen, wholeRows } from './app';
import { film, type Film } from './film';

/** The agent's split, the shell under it, the browser's column at the edge. */
type Split = 'main' | 'side' | 'web';
type Layout = {
  session: string;
  sidebar: 'sidebar' | 'hidden';
  /** Whether the terminal is split: the shell under it. */
  side: boolean;
  /** Where the browser is: nowhere, in the column at the outer edge, or a tab
   *  in the agent's split, in front of the agent's own. */
  web: 'none' | 'edge' | 'tab';
  /** The shell: new, or with the dev server running in it. */
  shell: 'idle' | 'dev';
  /** Whether the agent's split is zoomed. */
  zoom: boolean;
  /** Where the keyboard is. */
  focus: Split;
};

const HERO = 'Landing page hero';
// The terminal alone, where the story starts, and how each chapter ends.
const LONE: Layout = { session: HERO, sidebar: 'sidebar', side: false, web: 'none', shell: 'idle', zoom: false, focus: 'main' };
const TWO: Layout = { ...LONE, side: true, shell: 'dev', focus: 'side' };
const THREE: Layout = { ...TWO, web: 'tab', focus: 'main' };
const BACK: Layout = { ...THREE, focus: 'main' };
// The fourth chapter, on the page about layouts: the sidebar hidden.
const BARE: Layout = { ...BACK, sidebar: 'hidden' };
// What "Zoom" is about, for a visitor who gets no motion: the still.
const ZOOMED: Layout = { ...BACK, zoom: true };

// The film's pace: a key going down to the app reacting, the pointer's
// travel, a character typed, and how long a finished scene is held.
const BEAT = 0.5, TRAVEL = 0.7, KEY = 0.055, HELD = 1.5;
// The room a terminal keeps clear under its last line for the keys shown
// over it: five rows, which the 56 points of a key cluster sit in with air.
const ROOM = 95;

export function initPanes() {
  const root = document.querySelector<HTMLElement>('[data-film="panes"]');
  const win = root?.querySelector<HTMLElement>('[data-pwin]');
  if (!root || !win) return;

  const slot = (k: string) => win.querySelector<HTMLElement>(`[data-slot="${k}"]`)!;
  const pane = (k: string) => win.querySelector<HTMLElement>(`[data-pane="${k}"]`)!;
  const div = (k: string) => win.querySelector<HTMLElement>(`[data-div="${k}"]`)!;
  const tpl = (k: string) => root.querySelector<HTMLTemplateElement>(`template[data-tpl="${k}"]`)!;
  const keys = (k: string) => root.querySelector<HTMLElement>(`[data-keys="${k}"]`)!;
  const box = win.parentElement!;
  const mainBar = pane('terminal').querySelector<HTMLElement>('header')!;
  const devBar = pane('split').querySelector<HTMLElement>('header')!;
  const pageBar = pane('page').querySelector<HTMLElement>('header')!;
  /** The pane each split is drawn by: the agent's split shows the page once it holds it. */
  const of = (k: Split) => pane(k === 'main' ? (state.web === 'tab' ? 'page' : 'terminal') : k === 'side' ? 'split' : 'page');
  /** The agent's split's row: the top left one. */
  const head = () => (state.web === 'tab' ? pageBar : mainBar);

  // Show All Splits is the canvas's, drawn in the zoomed dev server split's
  // row. The app puts it in whichever row is zoomed, after the two split
  // buttons: here that is the agent's split, so it is cloned into the row of
  // each thing that can be in front there.
  const drawn = named(devBar, 'Show All Splits')!;
  const unzooms = [mainBar, pageBar].map((bar) => {
    const u = drawn.cloneNode(true) as HTMLElement;
    u.hidden = true;
    named(bar, 'Split buttons')!.append(u);
    return u;
  });
  drawn.hidden = true;

  // ---- the session ------------------------------------------------------------
  // The one building the landing page, in its folder, as the film after this
  // one has it (scripts/markup.ts): selected, its name on its own tab.
  const sb = new Sidebar(named(win, 'Sidebar')!);
  sb.show(['Section web', HERO, 'Changelog typography', 'Pricing FAQ copy', 'Section Sessions', 'Quicker panes', 'Marketing screenshots']);
  sb.select(HERO);
  const term = new Terminal(named(pane('terminal'), 'Terminal')!);
  const title = named(pane('terminal'), 'Title')!;
  title.textContent = HERO;
  // The canvas draws this terminal with a note pasted at its prompt, for the
  // mark-up film. Here nothing has been pasted yet.
  while (term.prompt.firstElementChild?.nextSibling) term.prompt.firstElementChild.nextSibling.remove();
  // Keys this film presses show over the terminal, in the room under the
  // agent's last line: the terminal keeps that much clear (app.ts, fitTerminal).
  term.root.dataset.reserve = String(ROOM);
  const screens = new Map<string, HTMLElement[]>([[HERO, term.lines()]]);

  // ---- the shell beside it -----------------------------------------------------
  // The canvas draws it as it stands with the dev server up. The film gets
  // there from a new shell: these are the canvas's own lines, shown as they
  // would have arrived, with the line a new shell opens on before them.
  const shell = (() => {
    const screen = named(pane('split'), 'Terminal')!;
    const tab = pane('split').querySelector<HTMLElement>('[data-name="Terminal tab"] > span')!;
    const lines = Array.from(screen.querySelectorAll<HTMLElement>(':scope > p'));
    // The prompt with `npm run dev` at it, the server's output, the two
    // requests it logs, and the cursor under them while it runs.
    const run = lines[0], cursor = lines[lines.length - 1];
    const docs = lines[lines.length - 2], served = lines[lines.length - 3];
    const out = lines.slice(1, -3);
    const RUN = run.lastChild!.textContent || '';
    run.lastChild!.remove();
    const typed = document.createElement('span');
    const caret = cursor.firstElementChild!.cloneNode(true) as HTMLElement;
    run.append(typed, caret);
    // The folder the prompt names: a shell is called by it until something runs.
    const FOLDER = (run.children[1].textContent || '').trim();
    // The same morning as the shell in "A terminal first" (scripts/scenes.ts).
    const login = out[1].cloneNode(false) as HTMLElement;
    login.textContent = 'Last login: Fri Nov 20 09:41:12 on ttys004';
    screen.prepend(login);
    const show = (els: HTMLElement[], on: boolean) => els.forEach((el) => (el.hidden = !on));
    // The canvas draws a prompt with no space after it: what is typed brings one.
    const say = (text: string) => { typed.textContent = text && ` ${text}`; };
    return {
      RUN, lines: out.length,
      /** The address the server prints, which can be ⌘-clicked. */
      link: out.map((l) => Array.from(l.querySelectorAll('span')).find((s) => s.textContent?.startsWith('http'))).find(Boolean) as HTMLElement,
      /** A new shell: its login line and a prompt. */
      idle() { tab.textContent = FOLDER; say(''); caret.hidden = false; show([...out, served, docs, cursor], false); },
      /** What is typed at the prompt so far. */
      type: say,
      /** Return on `npm run dev`: the tab is named for what runs in it. */
      started() { say(RUN); caret.hidden = true; tab.textContent = RUN; },
      /** The server's output, as far as its `n`th line; all of it leaves the cursor under it. */
      printed(n: number) { show(out.slice(0, n), true); if (n >= out.length) cursor.hidden = false; },
      /** The server logs the page it was asked for. */
      served(on: boolean) { served.hidden = !on; },
      /** The server up, as the canvas draws it. */
      dev() { this.started(); this.printed(out.length); show([docs], false); },
      /** Keep room clear under the last line, or stop: for the ⌘ shown over it. */
      roomy(on: boolean) { if (on) screen.dataset.reserve = String(ROOM); else delete screen.dataset.reserve; fitTerminal(screen); },
    };
  })();

  // ---- the browser -------------------------------------------------------------
  const tabOfPage = pane('page').querySelector<HTMLElement>('[data-name="Browser tab"]')!;
  // Of the page's two captures, light and dark, only the one in use is fetched.
  schemePictures(pane('page'));
  retaken(named(pane('page'), 'Page')!.querySelectorAll<HTMLImageElement>(':scope > img'));
  // Once the browser has the agent's split it is as wide as the window gives
  // it, and the page is the capture made at that width (PanesFilm.astro). Those
  // are fetched the first time they are shown, the scheme in use only.
  const dark = matchMedia('(prefers-color-scheme: dark)');
  const wide = Array.from(named(pane('page'), 'Page')!.querySelectorAll<HTMLImageElement>(':scope > img')).map((narrow) => {
    const img = narrow.cloneNode(false) as HTMLImageElement;
    const isDark = img.classList.contains('dark:block');
    img.removeAttribute('src');
    delete img.dataset.src;
    img.dataset.wide = isDark ? 'dark' : 'light';
    narrow.after(img);
    return img;
  });
  const loadWide = () => {
    if (!pane('page').hasAttribute('data-wide')) return;
    wide.forEach((img) => { if (!img.src && (img.dataset.wide === 'dark') === dark.matches) img.src = `/img/page-wide-${img.dataset.wide}.webp`; });
  };
  dark.addEventListener('change', loadWide);
  // The agent's own tab, behind the page's once the page joins its split:
  // a tab behind the front one, as the canvas draws one (no fill, the
  // quieter glyph and title, the room kept for its close button).
  const agentTab = (() => {
    const t = document.createElement('div');
    t.dataset.name = 'Agent tab';
    t.className = 'flex h-7 shrink-0 items-center rounded-lg pl-[10px] pr-1';
    const glyph = named(mainBar, 'Session tab')!.firstElementChild!.cloneNode(true) as HTMLElement;
    glyph.querySelectorAll('.bg-sidebar-foreground').forEach((g) => g.classList.replace('bg-sidebar-foreground', 'bg-sidebar-accent-foreground'));
    const label = document.createElement('span');
    label.className = 'ml-[10px] mr-[2px] min-w-0 truncate text-[13px] leading-4 text-sidebar-accent-foreground';
    label.textContent = HERO;
    const end = document.createElement('div');
    end.className = 'ml-1 flex';
    end.append(Object.assign(document.createElement('div'), { className: 'size-5' }));
    t.append(glyph, label, end);
    t.hidden = true;
    tabOfPage.before(t);
    return { t, label };
  })();

  // The film has a fourth chapter where its stage has a fourth tab
  // (films/PanesFilm.astro), unless the window is too narrow for a sidebar:
  // there it is folded already, and the tab is not shown.
  const ENDS = root.querySelectorAll('[data-chapter]').length > 3 && !matchMedia('(max-width: 1000px)').matches ? [TWO, THREE, BACK, BARE] : [TWO, THREE, BACK];
  const state: Layout = { ...LONE };
  const SIDEBAR = 234;
  // On a phone the stage shows one split's worth of this window at a time
  // (PanesFilm.astro). Between a phone and a wide screen (a tablet, a narrow
  // browser window) the window is whole but has no room for the sidebar and
  // three splits: there the sidebar is folded.
  const phone = matchMedia('(max-width: 760px)');
  const tight = matchMedia('(max-width: 1000px)');
  const fit = (to: Layout): Layout => (phone.matches || tight.matches ? { ...to, sidebar: 'hidden' } : to);
  const FOLD = { duration: 0.5, ease: 'power3.inOut' };
  // The buttons the leftmost row gains with no sidebar: Show Sidebar, Back, Forward.
  const LEAD = 28 + 8 + 60 + 8;
  // What the rightmost row along the top leaves free for the window's corner
  // (Running and "…", components/Window.astro): the app's trailing clearance.
  const END = 72;

  // How wide the column at the outer edge is. A tab opened there gets the
  // width that column opens at in the app, 440 and no more than half of the
  // area (MainArea.swift, sizeNewLeaves), and the agent's split and the shell
  // under it keep the rest.
  const COLUMN = 440;
  const sizes = () => {
    const area = win.offsetWidth - (state.sidebar === 'hidden' ? 0 : SIDEBAR + 1);
    return { edge: state.web === 'edge' ? Math.min(COLUMN, Math.floor(area / 2)) : 0 };
  };

  // ---- the leftmost row's extra buttons ----------------------------------------
  // The agent's split is always the leftmost along the top: its row is the
  // agent's, or the page's once the page is in front there.
  const led = () => head().querySelector<HTMLElement>(':scope > [data-lead]');
  /** Carry the buttons to the agent's split's row when what is in front there changes. */
  const seatLead = () => {
    const h = head(), other = h === mainBar ? pageBar : mainBar;
    const el = other.querySelector<HTMLElement>(':scope > [data-lead]');
    if (!el) return;
    h.prepend(el);
    gsap.killTweensOf([h, other], 'paddingLeft');
    gsap.set(h, { paddingLeft: 78 });
    gsap.set(other, { clearProps: 'paddingLeft' });
  };
  const lead = (on: boolean, d: number) => {
    const h = head();
    gsap.killTweensOf(h, 'paddingLeft');
    const rest = parseFloat(h.dataset.pad ||= getComputedStyle(h).paddingLeft);
    if (on) {
      // Make the room while the sidebar folds, then put the buttons in it.
      gsap.to(h, { paddingLeft: 78 + LEAD, ...FOLD, duration: FOLD.duration * d, onComplete: () => {
        if (!led()) h.prepend(tpl('lead').content.cloneNode(true));
        gsap.set(h, { paddingLeft: 78 });
        if (d) gsap.fromTo(led()!.children, { opacity: 0 }, { opacity: 1, duration: 0.2 });
        press();
      } });
    } else {
      if (led()) { led()!.remove(); gsap.set(h, { paddingLeft: 78 + LEAD }); }
      gsap.to(h, { paddingLeft: rest, ...FOLD, duration: FOLD.duration * d, clearProps: 'paddingLeft' });
    }
  };

  // ---- what follows from the state, in one cut ---------------------------------
  // Which splits are there and how wide, where the browser is, which row
  // clears the window's corner (data-end, styles/site.css), a zoom, and which
  // front tabs are quiet: with three splits on screen, the front tab of each
  // split you are not in keeps its fill and gives up its emphasis.
  const lay = () => {
    const z = state.zoom, tab = state.web === 'tab', edge = !z && state.web === 'edge', side = !z && state.side;
    gsap.killTweensOf([slot('edge'), mainBar, pageBar], 'width,paddingRight');
    gsap.set([mainBar, pageBar], { clearProps: 'paddingRight' });
    slot('side').hidden = div('side').hidden = !side;
    slot('edge').hidden = div('edge').hidden = !edge;
    if (state.web !== 'none') slot(tab ? 'main' : 'edge').append(pane('page'));
    pane('page').hidden = state.web === 'none';
    pane('terminal').hidden = tab;
    agentTab.t.hidden = !tab;
    pane('page').toggleAttribute('data-wide', tab && !phone.matches);
    loadWide();
    const w = sizes();
    slot('edge').style.setProperty('--edge', `${w.edge}px`);
    gsap.set(slot('edge'), phone.matches ? { clearProps: 'width' } : { width: w.edge });
    slot('main').toggleAttribute('data-end', !edge);
    slot('edge').toggleAttribute('data-end', true);
    slot('main').toggleAttribute('data-zoomed', z);
    unzooms.forEach((u) => (u.hidden = !z));
    seatLead();
    // The shell keeps room under its last line for the ⌘ shown over it.
    shell.roomy(true);
    const open: Split[] = z ? ['main'] : ['main', ...(state.side ? ['side' as const] : []), ...(edge ? ['web' as const] : [])];
    for (const p of ['terminal', 'split', 'page']) pane(p).removeAttribute('data-quiet');
    if (open.length > 2) for (const k of open) if (k !== state.focus) of(k).setAttribute('data-quiet', '');
    // On a phone: how many columns wide the window is.
    win.style.setProperty('--n', edge ? '2' : '1');
    press();
  };
  /** The short fade on what a cut brought. */
  const arrive = (...els: Element[]) => gsap.fromTo(els, { opacity: 0 }, { opacity: 1, duration: 0.2, ease: 'power2.out', clearProps: 'opacity' });
  /** Put the keyboard in a split. */
  const focus = (to: Split) => { state.focus = to; lay(); };

  // ---- what each cause does ------------------------------------------------------
  /** ⇧⌘D: the terminal is split down, a new shell under it, and the keyboard is in it. */
  function split() {
    state.side = true; state.shell = 'idle'; state.focus = 'side';
    shell.idle();
    lay();
    arrive(pane('split'));
    pan(true);
  }
  /** A ⌘-click on the server's address: the page opens where a browser opens
   *  by itself, in a column at the outer edge, which slides in. */
  function open() {
    state.web = 'edge'; state.focus = 'web';
    lay();
    shell.served(true);
    if (!phone.matches) {
      gsap.from(slot('edge'), { width: 0, ...FOLD });
      // The agent's row was the rightmost and no longer is: it gives the
      // corner's room back on the same curve.
      gsap.fromTo(mainBar, { paddingRight: END }, { paddingRight: parseFloat(getComputedStyle(mainBar).paddingRight), ...FOLD, clearProps: 'paddingRight' });
    }
    pan(true);
  }
  /** The browser's tab let go over the middle of the agent's split: it joins
   *  that split's tabs, in front, and its column at the edge is gone. */
  function drop() {
    state.web = 'tab'; state.focus = 'main';
    lay();
    arrive(pane('page'));
    pan(true);
  }
  /** Zoom the agent's split over everything beside the sidebar, or show all the splits again. */
  function zoom(on: boolean, fade = true) {
    if (state.zoom === on) return;
    state.zoom = on;
    if (on) state.focus = 'main';
    lay();
    pan(false);
    if (fade) arrive(...(on ? [of('main').firstElementChild!] : [slot('side'), of('main').firstElementChild!]));
  }
  function sidebar(to: Layout['sidebar'], d = 1) {
    if (state.sidebar === to) return;
    state.sidebar = to;
    const open = to !== 'hidden';
    gsap.to(slot('sidebar'), { width: open ? SIDEBAR : 0, ...FOLD, duration: FOLD.duration * d });
    gsap.to(div('sidebar'), { autoAlpha: open ? 1 : 0, duration: 0.2 * d, delay: open ? 0 : 0.35 * d });
    lead(!open, d);
    // The column at the edge keeps its share of what is beside the sidebar.
    if (!phone.matches) { const w = sizes(); gsap.to(slot('edge'), { width: w.edge, ...FOLD, duration: FOLD.duration * d }); }
  }

  function session(name: string) {
    if (state.session === name) return;
    state.session = name;
    // Instant, as in the app: no fade, no slide.
    sb.select(name);
    title.textContent = name;
    agentTab.label.textContent = name;
    if (!screens.has(name)) screens.set(name, sessionScreen(term, name));
    term.swap(screens.get(name)!);
  }

  // ---- a whole arrangement, in one cut ----------------------------------------
  let last = LONE;
  function arrange(layout: Layout) {
    last = layout;
    const to = fit(layout);
    session(to.session);
    sidebar(to.sidebar, 0);
    Object.assign(state, { side: to.side, web: to.web, zoom: to.zoom, focus: to.focus });
    dress(to);
    lay();
    pan(false);
  }
  /** What the shell shows in an arrangement. */
  function dress(to: Layout) {
    state.shell = to.shell;
    if (to.shell === 'dev') shell.dev(); else shell.idle();
    shell.served(to.shell === 'dev' && to.web !== 'none');
  }
  // Two arrangements are the same when the same splits hold the same things.
  // Where the keyboard is does not count.
  const same = (c: Layout) => {
    const to = fit(c);
    return (['session', 'sidebar', 'side', 'web', 'zoom'] as const).every((k) => to[k] === state[k]) && (!to.side || to.shell === state.shell);
  };

  // ---- on a phone, the window pans to the column that has the keyboard ---------
  // The stage shows one column of the window: the agent's split with the
  // shell under it, or the column at the edge while the browser is there.
  // What is off the stage is not drawn (data-view, PanesFilm.astro), so no strip
  // of it shows in the stage's own margin.
  function pan(animate: boolean) {
    if (!phone.matches) { gsap.set(win!, { x: 0 }); win!.removeAttribute('data-view'); return; }
    const view = !state.zoom && state.focus === 'web' && state.web === 'edge' ? 'edge' : 'main';
    const x = view === 'edge' ? -(box.clientWidth + 1) : 0;
    const moves = animate && !reduced() && Math.abs((gsap.getProperty(win!, 'x') as number) - x) > 0.5;
    if (moves) win!.removeAttribute('data-view');
    gsap.to(win!, { x, duration: moves ? 0.6 : 0, ease: 'power3.inOut', overwrite: 'auto', onComplete: () => win!.setAttribute('data-view', view) });
  }
  // Turned on its side, or a window dragged past the width: the same scene, laid out again.
  const again = () => { stop(); arrange(last); };
  phone.addEventListener('change', again);
  tight.addEventListener('change', again);
  // The pan is a distance in pixels of the stage's width, and the columns are
  // shares of the window's: a stage that changes width without crossing
  // either line is laid out again, in the same place.
  let seen = box.clientWidth;
  new ResizeObserver(() => { if (box.clientWidth !== seen) { seen = box.clientWidth; lay(); pan(false); } }).observe(box);

  // ---- your hands on the window ---------------------------------------------
  // What each named control does to the state. The names are the canvas's.
  const PRESS: Record<string, () => void> = {
    'Hide Sidebar': () => sidebar('hidden'),
    'Show Sidebar': () => sidebar('sidebar'),
    'Show All Splits': () => zoom(false),
  };
  // The same for a control that shares its name with others, found by where
  // it is: every tab's close button is "Close" (so is a traffic light). A
  // split is gone when its last tab closes. `when` says while it can be
  // pressed.
  const PRESS_AT: [where: string, act: () => void, when?: () => boolean][] = [
    ['[data-pane="split"] [data-name="Terminal tab"] [data-name="Close"]', () => { state.side = false; focus(state.focus === 'side' ? 'main' : state.focus); pan(true); }],
    ['[data-pane="page"] [data-name="Browser tab"] [data-name="Close"]', () => { const was = state.web; state.web = 'none'; focus(was === 'tab' || !state.side ? 'main' : 'side'); pan(true); }],
  ];
  function press() {
    for (const name of Object.keys(PRESS)) win!.querySelectorAll<HTMLElement>(`[data-name="${name}"]`).forEach((el) => (el.dataset.press = ''));
    for (const [where, , when] of PRESS_AT) win!.querySelectorAll<HTMLElement>(where).forEach((el) => el.toggleAttribute('data-press', !when || when()));
  }

  // ---- the film ----------------------------------------------------------------
  // The pointer, for what is done with the mouse, and what it carries while a
  // tab is dragged: the tab's own picture, as the app shows one, and where
  // the tab would land (styles/site.css, .landing).
  const pointer = new Pointer(box);
  const landing = document.createElement('div');
  landing.className = 'landing';
  landing.hidden = true;
  slot('main').append(landing);
  let carried: HTMLElement | null = null;
  let take = 0;
  const shown: gsap.core.Timeline[] = [];
  /** Stop a scene part way: the chapter changed, or the visitor took over. */
  const stop = () => {
    take++;
    pointer.hide();
    win.querySelectorAll('[data-lit]').forEach((el) => el.removeAttribute('data-lit'));
    shown.splice(0).forEach((tl) => tl.kill());
    gsap.set(root.querySelectorAll('[data-keys]'), { opacity: 0 });
    carried?.remove(); carried = null;
    landing.hidden = true;
    tabOfPage.style.opacity = '';
  };

  /**
   * The middle of the largest gap in what a split's terminal shows: under a
   * shell's last line, between an agent's last line and its prompt box. In
   * the stage's own points, and within the part of the split the stage shows.
   */
  function gap(split: Split) {
    const host = of(split), screen = host.querySelector<HTMLElement>('[data-name="Terminal"]');
    const b = box.getBoundingClientRect();
    // A page has no lines to keep clear of: the middle of what the split shows of it.
    if (!screen) {
      const r = (named(host, 'Page') ?? host).getBoundingClientRect();
      const left = Math.max(r.left, b.left), right = Math.min(r.right, b.right);
      return { x: (left + right) / 2 - b.left, y: (r.top + r.bottom) / 2 - b.top };
    }
    const r = screen.getBoundingClientRect();
    const cs = getComputedStyle(screen);
    const rows = (Array.from(screen.children) as HTMLElement[])
      .map((el) => ({ el, r: el.getBoundingClientRect() }))
      .filter(({ el, r: q }) => q.height > 0 && getComputedStyle(el).visibility !== 'hidden' && q.bottom > r.top && q.top < r.bottom)
      .sort((p, q) => p.r.top - q.r.top);
    let from = r.top + parseFloat(cs.paddingTop), best = { top: from, bottom: from };
    for (const edge of [...rows.map((p) => p.r), { top: r.bottom - parseFloat(cs.paddingBottom), bottom: r.bottom }]) {
      if (edge.top - from > best.bottom - best.top) best = { top: from, bottom: edge.top };
      from = Math.max(from, edge.bottom);
    }
    const left = Math.max(r.left, b.left), right = Math.min(r.right, b.right);
    return { x: (left + right) / 2 - b.left, y: (best.top + best.bottom) / 2 - b.top };
  }
  /** Keys show over the split that has the keyboard, in that gap: never over a line of text. */
  function over(name: string, split: Split) {
    const at = gap(split);
    Object.assign(keys(name).style, { left: `${at.x}px`, top: `${at.y}px` });
  }

  // One chapter's scene: where it starts, its beats (what happens, and when,
  // in seconds from the start), and when the last one has landed.
  type Scene = { start: Layout; beats: [at: number, act: () => void][]; length: number };
  function scene(i: number): Scene {
    const beats: Scene['beats'] = [];
    const step = (act: () => void, at: number) => { beats.push([at, act]); };
    /** Press keys over a split: they show and dip, the app answers a beat
     *  later, and they are gone as it does, so they never sit on what the
     *  answer put under them. */
    const chord = (name: string, on: Split, at: number, act: () => void) => {
      step(() => { over(name, on); const tl = gsap.timeline(); pressKeys(tl, keys(name), 0, 2); shown.push(tl); }, at);
      step(() => { act(); shown.splice(0).forEach((tl) => tl.kill()); gsap.to(keys(name), { opacity: 0, duration: 0.15, ease: 'power2.out' }); }, at + BEAT);
      return at + BEAT;
    };
    /** Type into something a character at a time. Returns when the last one lands. */
    const type = (into: (text: string) => void, text: string, at: number) => {
      [...text].forEach((_, k) => step(() => into(text.slice(0, k + 1)), at + k * KEY));
      return at + text.length * KEY;
    };

    if (i === 0) {
      // ⇧⌘D: the agent's terminal is split down, and in the new shell, which
      // opens in the session's folder, the dev server is started.
      let t = chord('split', 'main', 0.5, split);
      t = type((s) => shell.type(s), shell.RUN, t + 0.4);
      step(() => { shell.started(); state.shell = 'dev'; }, t + 0.15);
      // The output arrives in a run, as a dev server prints it.
      for (let n = 1; n <= shell.lines; n++) step(() => shell.printed(n), t + 0.25 + n * 0.05);
      step(() => { last = TWO; }, t + 0.3 + shell.lines * 0.05);
      return { start: LONE, beats, length: t + 0.3 + shell.lines * 0.05 };
    }
    if (i === 1) {
      // Drag a tab: ⌘ and a click on the address the server printed opens
      // the page in a column at the edge. Its tab is picked up and carried
      // over the middle of the agent's split, which lights all of it, and
      // let go there it joins that split's tabs.
      step(() => pointer.click(shell.link, TRAVEL), 0.3);
      chord('command', 'side', 0.3 + TRAVEL - BEAT, open);
      const grab = 0.3 + TRAVEL + 0.75, GRAB = 0.6, CARRY = 0.9;
      step(() => pointer.click(tabOfPage, GRAB), grab);
      const lift = grab + GRAB + 0.15;
      step(() => {
        // The tab's picture under the pointer, held where it was picked up,
        // and the tab itself dimmed in its row while it is out.
        const r = tabOfPage.getBoundingClientRect(), at = pointer.at(tabOfPage), b = box.getBoundingClientRect();
        carried = document.createElement('div');
        carried.className = 'wapp carried';
        carried.style.cssText = `left:${r.left - b.left - at.x}px;top:${r.top - b.top - at.y}px;width:${r.width}px`;
        carried.append(tabOfPage.cloneNode(true));
        pointer.el.prepend(carried);
        tabOfPage.style.opacity = '0.35';
        // To the middle of the agent's split. On a phone the stage follows
        // the tab there, so that is the middle of the stage's width.
        const s = slot('main').getBoundingClientRect();
        const to = { x: phone.matches ? box.clientWidth / 2 : s.left - b.left + s.width / 2, y: s.top - b.top + s.height / 2 };
        pointer.move(to, CARRY);
        if (phone.matches) { state.focus = 'main'; pan(true); }
      }, lift);
      step(() => { landing.removeAttribute('data-edge'); landing.hidden = false; }, lift + CARRY * 0.6);
      const let_go = lift + CARRY + 0.1;
      step(() => { carried?.remove(); carried = null; landing.hidden = true; tabOfPage.style.opacity = ''; drop(); last = THREE; }, let_go);
      step(() => pointer.hide(), let_go + 0.4);
      return { start: TWO, beats, length: let_go + 0.2 };
    }
    if (i === 3) {
      // Sidebar: ⌘B folds it away, and the leftmost row gains its buttons.
      const t = chord('sidebar', 'main', 0.5, () => { sidebar('hidden'); last = BARE; });
      return { start: BACK, beats, length: t + 0.6 };
    }
    // Zoom: the page has the keyboard where it was dropped, ⇧⌘↩ gives it
    // everything beside the sidebar, and ⇧⌘↩ again shows both splits.
    let t = chord('zoom', 'main', 0.5, () => zoom(true));
    t = chord('zoom', 'main', t + HELD, () => { zoom(false); last = BACK; });
    return { start: THREE, beats, length: t + 0.2 };
  }

  /** Play a chapter's scene once, from where it starts. */
  function play(i: number, f: Film) {
    const mine = take;
    const { start, beats } = scene(i);
    // The window is cut to the start unless it is there already: the scenes
    // follow on from one another, so only the first one cuts.
    if (same(start)) { dress(start); focus(start.focus); last = start; pan(true); } else arrange(start);
    for (const [at, act] of beats) f.later(() => { if (mine === take) act(); }, at);
  }

  const f = film(root, (f) => ENDS.map((layout, i) => ({
    // Every scene is held the same while after its last beat.
    hold: scene(i).length + HELD,
    enter: (animate) => {
      stop();
      // With no motion: how the chapter ends, and for "Zoom" the zoom itself.
      if (reduced()) arrange(i === 2 ? ZOOMED : layout);
      // Drawn before anyone is looking: where the story starts.
      else if (!animate) arrange(LONE);
      else play(i, f);
    },
  // With no motion the still is the busiest one: both splits, the page in front.
  })), 1);

  // Pressing something pauses the film, wherever it has got to.
  const settle = () => {
    stop();
    f.pause();
    const i = same(ZOOMED) ? 2 : same(LONE) ? 0 : ENDS.findIndex(same);
    if (i >= 0) f.mark(i); else f.own();
  };
  win.addEventListener('click', (e) => {
    const target = e.target as HTMLElement;
    const hit = target.closest<HTMLElement>('[data-press]');
    if (hit && win.contains(hit)) {
      const at = PRESS_AT.find(([where]) => hit.matches(where));
      (at ? at[1] : PRESS[hit.dataset.name!])?.();
      settle();
      return;
    }
    // A click anywhere else in a split puts the keyboard there.
    const into = (['main', 'side', 'web'] as const).find((k) => of(k).contains(target));
    if (into && into !== state.focus) { focus(into); settle(); }
  });
  const pick = (name: string) => { zoom(false); session(name); settle(); };
  sb.clickable(pick);
  sb.navigable(pick);

  shell.idle();
  press();
  wholeRows(win);
}
