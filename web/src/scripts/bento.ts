// The bento's script: it puts the real app into the tiles.
//
// Nothing on the poster is drawn by hand. Three things are arranged here:
//   parts     a tile that shows a piece of a pane (the diff, the rendered
//             Markdown) gets a clone of that named part, out of the panes the
//             component renders into a <template>;
//   browser   a window with no sidebar, its bar as the canvas draws one, and
//             the site itself in its tab, light or dark with the page;
//   terminal  the window in the middle is a Pi session at work, with no
//             sidebar, so its bar gains what the canvas gives such a window.
//             Pi is shown only here: the stages show Claude Code and Codex,
//             whose screens at work were captured, and Pi's could not be;
//   rows      the worktree tile shows three rows of the sidebar: one folder,
//             filled with clones of the canvas's own worktree row;
//   splits    a window in three splits: a session's shell, the dev server's
//             under it, and a new tab beside both.
// Everything else is still, or moves in CSS.
import { Terminal, named, pi, piScreen, wholeRows } from './app';

export function initBento() {
  const scope = document.querySelector<HTMLElement>('#more');
  const poster = scope?.querySelector<HTMLElement>('[data-bento]');
  if (!scope || !poster) return;
  parts(scope, poster);
  terminal(scope, poster);
  browser(scope, poster);
  splits(scope, poster);
  rows(poster);
}

function parts(scope: HTMLElement, poster: HTMLElement) {
  const src = scope.querySelector<HTMLTemplateElement>('template[data-src]')?.content;
  if (!src) return;
  poster.querySelectorAll<HTMLElement>('[data-part]').forEach((holder) => {
    const part = src.querySelector<HTMLElement>(`[data-name="${holder.dataset.part}"]`);
    if (part) holder.append(part.cloneNode(true));
  });
}

function browser(scope: HTMLElement, poster: HTMLElement) {
  const win = poster.querySelector<HTMLElement>('[data-win="browser"]');
  const lead = scope.querySelector<HTMLTemplateElement>('template[data-tpl="lead"]')?.content;
  if (!win || !lead) return;
  win.dataset.solo = '';
  win.querySelector('header[data-name="Main bar"]')!.prepend(lead.cloneNode(true));
  const img = named(win, 'Web page') as HTMLImageElement | null;
  if (!img) return;
  // The page follows the page around it, as everything in the windows does.
  const picture = document.createElement('picture');
  const dark = document.createElement('source');
  dark.srcset = '/img/browser-dark.jpg';
  dark.media = '(prefers-color-scheme: dark)';
  img.replaceWith(picture);
  picture.className = 'flex min-h-0 flex-1';
  img.src = '/img/browser-light.jpg';
  img.alt = 'The wortel.sh homepage';
  img.width = 1440; img.height = 900;
  picture.append(dark, img);
}

function terminal(scope: HTMLElement, poster: HTMLElement) {
  const win = poster.querySelector<HTMLElement>('[data-win="hero"]');
  const lead = scope.querySelector<HTMLTemplateElement>('template[data-tpl="lead"]')?.content;
  if (!win || !lead) return;
  win.dataset.solo = '';
  win.querySelector('header[data-name="Main bar"]')!.prepend(lead.cloneNode(true));
  named(win, 'Title')!.textContent = 'Tidy the appcast feed';
  const run = piScreen('Trim the appcast feed to the last five');
  run.add(pi.say('I’ll read the feed, then cut the old entries.'));
  run.add(pi.tool('read', 'updates/appcast.xml'));
  run.working(true);
  new Terminal(named(win, 'Terminal')!).swap(run.nodes);
  wholeRows(win);
}

// A plain session in the repository's folder, named for it, as a session with
// no agent is: the canvas's own new shell (its "Terminal pane") shown in the
// session's terminal. The canvas draws the shell under it zoomed, so its Show
// All Splits is put away here.
function splits(scope: HTMLElement, poster: HTMLElement) {
  const win = poster.querySelector<HTMLElement>('[data-win="splits"]');
  const lead = scope.querySelector<HTMLTemplateElement>('template[data-tpl="lead"]')?.content;
  const shell = scope.querySelector<HTMLTemplateElement>('template[data-src]')?.content.querySelector<HTMLElement>('[data-name="Terminal pane"] [data-name="Terminal"]');
  if (!win || !lead || !shell) return;
  const bar = win.querySelector<HTMLElement>('header[data-name="Main bar"]')!;
  bar.prepend(lead.cloneNode(true));
  named(bar, 'Title')!.textContent = 'wortel';
  named(bar.parentElement!, 'Terminal')!.replaceChildren(...Array.from(shell.children).map((el) => el.cloneNode(true)));
  const unzoom = named(win, 'Show All Splits');
  if (unzoom) unzoom.hidden = true;
  wholeRows(win);
}

function rows(poster: HTMLElement) {
  const card = poster.querySelector<HTMLElement>('[data-rows]');
  const nav = card && named(card, 'Sessions');
  if (!nav) return;
  const head = named(nav, 'Section wortel')!;
  const mould = named(nav, 'Sparkle appcast cleanup')!;
  const working = named(nav, 'Working')!.parentElement!.cloneNode(true) as HTMLElement;
  const pill = named(nav, 'Pill')!;

  const row = (name: string, branch: string, status: 'working' | 'chart-1' | 'chart-2') => {
    const r = mould.cloneNode(true) as HTMLElement;
    r.dataset.name = name;
    r.children[0].textContent = name;
    r.children[1].lastElementChild!.textContent = branch;
    const dot = r.querySelector<HTMLElement>('[data-name="Status"]')!;
    if (status === 'working') dot.replaceWith(working.cloneNode(true));
    else { dot.firstElementChild!.classList.remove('bg-chart-1', 'bg-chart-2'); dot.firstElementChild!.classList.add(`bg-${status}`); }
    return r;
  };
  const list = [
    row('Sparkle appcast cleanup', 'appcast-cleanup', 'working'),
    row('Keeper holds the terminal', 'keeper-terminal', 'chart-1'),
    row('Sort By in the sidebar', 'section-sort', 'working'),
  ];
  head.style.height = '30px';
  nav.replaceChildren(head, ...list);
  list[0].prepend(pill);
}
