// ==========================================================================
// Wortel app demo: content, transcribed 1:1 from the reference screenshots
// (web/public/refs/*.png). Line breaks are hard-coded to match the reference
// exactly; the components render rows verbatim rather than re-wrapping.
// ==========================================================================

// ---- sidebar (from the light/dark-sidebar refs) ---------------------------
export const groups = [
  {
    name: 'Wortel',
    sessions: [
      { name: 'Web', active: true },
    ],
  },
  {
    name: 'Pontueel',
    sessions: [
      { name: 'Launch' },
      { name: 'Dashboard', dot: true },
      { name: 'SEO', spinner: true },
    ],
  },
];

// The same sidebar after the worktree beat, which is the ONE thing that beat
// has to show: two `wortel new --branch` calls, two more rows. A view asks for
// it with `agents: true` (see views.js) and every view after that one keeps it,
// because sessions do not disappear when you scroll past the paragraph.
//
// The rows are branch names WITHOUT a slash on purpose. A worktree session is
// named for its branch, and the sidebar splits a name on its LAST slash into
// folder plus leaf (SessionName.swift), so a session on `feature/x` inside the
// Wortel folder would file itself under a *new* "Wortel/feature" group. True to
// the app, and a distraction here, so the story uses branches that are one
// component. They are real branches of this repository.
export const agentGroups = [
  {
    name: 'Wortel',
    sessions: [
      { name: 'Web', active: true },
      { name: 'preview-window', spinner: true },
      { name: 'worktree-git', spinner: true },
    ],
  },
  groups[1],
];


// ---- the story -------------------------------------------------------------
// ONE session, told in beats. Scrolling the page does not swap the terminal's
// contents, it CONTINUES them: each section appends its beat to the same
// transcript, older output rides up and off the top the way scrollback does,
// and only the newly arrived lines animate in. Scroll back and it rewinds.
//
// IT HAS TO AGREE WITH THE PANEL BESIDE IT. The git panel below is transcribed
// 1:1 from the reference screenshots and cannot move, so the terminal is
// written to match it, not the other way round:
//
//   · `git log --oneline -3` prints the first three rows of the History pane,
//     same shas, same subjects.
//   · The work is what the Changes pane shows: on branch web-app-demo, the
//     Svelte demo being wired into Astro. That is exactly the diff the pane
//     has open (the @astrojs/svelte import and `integrations: [svelte()]`),
//     which is why the install touches package.json and package-lock.json and
//     why src/demo/tokens.css is untracked.
//   · The agent's summary names those four files, in the pane's order, and
//     "Four files changed" is the pane's own "Changes (4)".
//   · The Changes pane only opens at the git section, which is the beat right
//     after the agent finishes making them. Before that the hero shows History,
//     which is what beat 0 is reading.
//
// So: change one of these and change the other.
//
// Rows: { g: gutter glyph, cls: colour class, t: text with inline markup }.
// Markup: **bold**, *italic*, [text](#) renders in the link colour. Blank t is
// an empty line. `block: true` is the agent's user-message card. A beat may
// declare `cwd`, which moves the titlebar the way a real `cd` does.
//
// Text is authored UNWRAPPED. Terminal.svelte measures the terminal and
// re-wraps to its column count on every resize. Do NOT hard-code line breaks.
//
// Beats do NOT end with a prompt row. A terminal has exactly one cursor and it
// is at the bottom, so Terminal appends a single one after the last beat.

export const windowTitle = 'Wortel/Web';
export const windowSubtitle = '~/Developer/wortel';

// The agent enters at this beat; Claude Code's status strip exists from here on.
export const AGENT_BEAT = 3;

export const STORY = [
  // 0 · you just opened the app. A cd, then a look at where the repo is.
  //     These three lines are the History pane's top three rows.
  {
    cwd: '~/Developer/wortel/web',
    rows: [
      { g: '›', t: 'cd web' },
      { t: '' },
      { g: '›', t: 'git log --oneline -3' },
      { cls: 'dim', t: '0393580 Release 2026.29.11' },
      { cls: 'dim', t: 'e7a3827 Git History: harden accordion correctness and performance' },
      { cls: 'dim', t: '4dfe045 Git History: render images inline, size them, single scroll, sticky headers' },
      { t: '' },
    ],
  },

  // 1 · the engine section, where both panels are closed and the terminal is at
  //     its widest. This install is what the package.json/lock changes are.
  {
    rows: [
      { g: '›', t: 'npm install @astrojs/svelte' },
      { cls: 'dim', t: 'added 9 packages in 1s' },
      { t: '' },
      { g: '›', t: 'npm run build' },
      { cls: 'dim', t: 'building client (vite)' },
      { cls: 'dim', t: '312 modules transformed' },
      { cls: 'dim', t: 'dist/_astro/WortelApp.js   73.92 kB │ gzip: 26.26 kB' },
      { t: '**Complete!**' },
      { t: '' },
    ],
  },

  // 2 · a long-running process is the reason a second session exists at all,
  //     which is what the sidebar beside this beat is showing.
  {
    rows: [
      { g: '›', t: 'npm run dev' },
      { cls: 'dim', t: 'astro v5.18.2 ready in 214 ms' },
      { cls: 'dim', t: 'Local [http://localhost:4321/](#)' },
      { cls: 'dim', t: 'watching for file changes…' },
      { t: '' },
    ],
  },

  // 3 · the agent arrives, and is asked for the change the panel is showing
  {
    rows: [
      { g: '›', t: 'claude' },
      { t: '' },
      {
        block: true,
        g: '❯',
        t: 'wire the svelte demo into astro, and pull the shared variables into their own file',
      },
      { t: '' },
      { g: '●', t: 'Reading **astro.config.mjs**' },
      { t: '' },
      { g: '✳', gcls: 'active', cls: 'active', t: 'Tinkering… (9s · thinking more with high effort)' },
      { t: '' },
    ],
  },

  // 4 · it answers, and the Changes pane opens on the diff it just made
  {
    rows: [
      { g: '●', t: 'Registered the integration in [astro.config.mjs](#), and the shared variables are their own file now at [src/demo/tokens.css](#).' },
      { t: '' },
      { t: 'The island stays client-side, so the landing page itself is still fully static.' },
      { t: '' },
      { g: '●', t: 'Four files changed: **astro.config.mjs**, **package-lock.json**, **package.json**, and the new **src/demo/tokens.css**.' },
      { t: '' },
      { g: '✳', gcls: 'dim', cls: 'dim', t: 'Cogitated for 14s' },
      { t: '' },
    ],
  },

  // 5 · the worktree beat, and the only one that changes the SIDEBAR (views.js
  //     turns on `agents` here and leaves it on). It sits after the agent's turn
  //     rather than during it for a reason the demo cannot cheat: a terminal has
  //     one cursor, so nothing can be typed here while the agent holds it.
  //
  //     `wortel new` is run from this session and does not switch to what it
  //     opens, which is the real command's real behaviour: it orders windows
  //     front and never activates the app, so a call from a hook cannot steal
  //     your keyboard. The ids are what it prints, one per session, on stdout.
  //     The paths are the real layout, ~/.wortel/worktrees/<repo>/<branch>, and
  //     all three sit on 0393580 because that is HEAD in beat 0's git log and a
  //     new worktree branches from it.
  {
    rows: [
      { g: '›', t: 'wortel new --branch preview-window' },
      { cls: 'dim', t: '9c1f0e2a-4b7d-4a31-9f60-2e8c5d7a1b34' },
      { g: '›', t: 'wortel new --branch worktree-git' },
      { cls: 'dim', t: '4f83b6d1-77ce-4e02-8a19-c6b0d94e5f27' },
      { t: '' },
      { g: '›', t: 'git worktree list' },
      { cls: 'dim', t: '~/Developer/wortel                         0393580 [web-app-demo]' },
      { cls: 'dim', t: '~/.wortel/worktrees/wortel/preview-window  0393580 [preview-window]' },
      { cls: 'dim', t: '~/.wortel/worktrees/wortel/worktree-git    0393580 [worktree-git]' },
      { t: '' },
    ],
  },

  // 6 · survival, and the one claim on the page that an app window cannot show:
  //     you would have to quit the app to see it, and the app is the demo. So it
  //     is asked, in the register beats 7 and 8 already use.
  {
    rows: [
      { block: true, g: '❯', t: 'if I quit Wortel right now, what happens to you?' },
      { t: '' },
      { g: '●', t: 'Nothing. My shell runs under the keeper process rather than under the app, so quitting closes the window and leaves the work. Open it again and this session is still here, with everything I printed while you were gone.' },
      { t: '' },
    ],
  },

  // 7 · zero config, asked rather than demonstrated: by now you are talking to
  //     the agent, not to a shell, and a story cannot step back out of that.
  {
    rows: [
      { block: true, g: '❯', t: 'where does wortel keep its settings?' },
      { t: '' },
      { g: '●', t: 'It doesn’t. The whole configuration is one read-only file inside the app bundle, and your [~/.config/ghostty](#) is never read.' },
      { t: '' },
    ],
  },

  // 8 · and the shortcut the last section is about
  {
    rows: [
      { block: true, g: '❯', t: 'if I leave you running, how do I find you again?' },
      { t: '' },
      { g: '●', t: 'The sidebar marks me while I work, and again when I stop. **⌥⇧⌘↓** jumps straight to whichever session is waiting on you.' },
      { t: '' },
    ],
  },
];

// Terminal's fallback when nothing is driving it.
export const transcript = STORY[0].rows;

// ---- status bar -----------------------------------------------------------
// Claude Code's TUI, so it only exists once the agent is running (AGENT_BEAT).
// A status line cannot wrap, so Terminal.svelte drops trailing segments until it
// fits: the full strip at a wide terminal, and just the mode and the shell count
// beside an open inspector.
export const statusBar = [
  { t: '▶▶', cls: 'amber' },
  { t: ' auto mode on', cls: 'amber' },
  { t: ' · ', cls: 'dim' },
  { t: '1 shell', cls: 'teal' },
  { t: ' · ', cls: 'dim' },
  { t: 'esc to interrupt', cls: 'dim' },
  { t: ' · ', cls: 'dim' },
  { t: '↓ to manage', cls: 'dim' },
];
export const statusBarRight = { t: '/rc', cls: 'rc' };

// ---- git panel · Changes ---------------------------------------------------
export const branch = 'web-app-demo';

export const changes = [
  {
    status: 'M', kind: 'm', name: 'astro.config.mjs', path: 'web', lang: 'js',
    hunks: [
      {
        header: '@@ -1,9 +1,13 @@',
        lines: [
          { k: 'ctx', o: 1, n: 1, t: '// @ts-check' },
          { k: 'ctx', o: 2, n: 2, t: "import { defineConfig } from 'astro/config';" },
          { k: 'add', o: null, n: 3, t: "import svelte from '@astrojs/svelte';" },
          { k: 'ctx', o: 3, n: 4, t: '' },
          { k: 'ctx', o: 4, n: 5, t: '// The landing page is fully static. Astro builds' },
          { k: 'ctx', o: 5, n: 6, t: '// Cloudflare Worker in wrangler.jsonc serves as st' },
          { k: 'add', o: null, n: 7, t: '// Svelte powers the interactive product demo (src/' },
          { k: 'add', o: null, n: 8, t: '// client island on /demo; the landing page itself' },
          { k: 'ctx', o: 6, n: 9, t: 'export default defineConfig({' },
          { k: 'ctx', o: 7, n: 10, t: "  site: 'https://wortel.sh'," },
          { k: 'ctx', o: 8, n: 11, t: "  output: 'static'," },
          { k: 'add', o: null, n: 12, t: '  integrations: [svelte()],' },
          { k: 'ctx', o: 9, n: 13, t: '});' },
        ],
      },
    ],
  },
  { status: 'M', kind: 'm', name: 'package-lock.json', path: 'web', lang: 'json', hunks: [] },
  { status: 'M', kind: 'm', name: 'package.json', path: 'web', lang: 'json', hunks: [] },
  { status: '?', kind: 'q', name: 'tokens.css', path: 'web/src/demo', lang: 'css', hunks: [] },
];

// ---- git panel · History ---------------------------------------------------
// rail: 'main' rides the orange line; 'side' rows sit on the blue branch.
export const commits = [
  {
    sha: '0393580', subject: 'Release 2026.29.11', author: 'Giel', when: '1h',
    refs: [
      { label: 'web-app-demo', icon: 'check' },
      { label: 'origin/main', icon: 'cloud' },
      { label: 'main' },
    ],
  },
  { sha: 'e7a3827', subject: 'Git History: harden accordion correctness and performance', author: 'Giel', when: '1h' },
  { sha: '4dfe045', subject: 'Git History: render images inline, size them, single scroll, sticky headers', author: 'Giel', when: '1h' },
  { sha: '3ebe86e', subject: 'Release 2026.29.10', author: 'Giel', when: '1h' },
  { sha: 'd01186c', subject: 'Git History: per-commit changed-files accordion', author: 'Giel', when: '1h' },
  { sha: 'efae530', subject: 'Housekeeping: nonisolated notification callbacks', author: 'Giel', when: '1h' },
  { sha: '5388c4a', subject: 'Rename field: native text-editing shortcuts', author: 'Giel', when: '2h' },
  { sha: '9608a5e', subject: 'App icon: new layered artwork; fix Icon Composer break', author: 'Giel', when: '3h' },
  { sha: '4d8dc94', subject: 'Release 2026.29.9', author: 'Giel', when: '3h' },
  { sha: '70d1494', subject: 'Merge: diff syntax highlighting + toolbar buttons', author: 'Giel', when: '3h', merge: true },
  {
    sha: '643fe42', subject: 'Git panel: native branch chip in the toolbar + instant right-click menus', author: 'Giel', when: '3h',
    refs: [{ label: 'diff-highlighting-and-toolbar', branch: true }],
    side: true,
  },
  { sha: '84dc1cb', subject: 'Diff view: tree-sitter syntax highlighting', author: 'Giel', when: '3h', side: true },
  { sha: 'b56eec8', subject: 'web: full-bleed app shot with a mini feature list', author: 'Giel', when: '4h' },
  { sha: 'aeb1f30', subject: 'History: draw the log the way Fork does', author: 'Giel', when: '14h' },
];

// changed files of the selected commit (0393580), as shown in the accordion
export const commitFiles = [
  {
    status: 'M', kind: 'm', name: 'BUILD', path: 'macos/releases',
    add: 1, del: 1, lang: 'text', open: false,
    hunks: [
      { header: '@@ -1 +1 @@', lines: [
        { k: 'del', o: 1, n: null, t: '2026.29.10' },
        { k: 'add', o: null, n: 1, t: '2026.29.11' },
      ] },
    ],
  },
  {
    status: 'M', kind: 'm', name: 'appcast.xml', path: 'macos/releases',
    add: 8, del: 8, lang: 'xml', open: true,
    hunks: [
      { header: '@@ -2,6 +2,14 @@', lines: [
        { k: 'ctx', o: 2, n: 2, t: '<rss xmlns:sparkle="http://www.andymatuschak.org/xm' },
        { k: 'ctx', o: 3, n: 3, t: '  <channel>' },
        { k: 'ctx', o: 4, n: 4, t: '    <title>Wortel</title>' },
        { k: 'add', o: null, n: 5, t: '    <item>' },
        { k: 'add', o: null, n: 6, t: '      <title>2026.29.11</title>' },
        { k: 'add', o: null, n: 7, t: '      <pubDate>Thu, 16 Jul 2026 13:20:24 -040' },
        { k: 'add', o: null, n: 8, t: '      <sparkle:version>2026.29.11</sparkle:ve' },
        { k: 'add', o: null, n: 9, t: '      <sparkle:shortVersionString>2026.29.11<' },
        { k: 'add', o: null, n: 10, t: '      <sparkle:minimumSystemVersion>14.0</spa' },
        { k: 'add', o: null, n: 11, t: '      <enclosure url="https://updates.wortel.' },
        { k: 'add', o: null, n: 12, t: '    </item>' },
        { k: 'ctx', o: 5, n: 13, t: '    <item>' },
        { k: 'ctx', o: 6, n: 14, t: '      <title>2026.29.10</title>' },
        { k: 'ctx', o: 7, n: 15, t: '      <pubDate>Thu, 16 Jul 2026 12:32:09 -040' },
      ] },
      { header: '@@ -18,13 +26,5 @@', lines: [
        { k: 'ctx', o: 18, n: 26, t: '      <sparkle:minimumSystemVersion>14.0</spa' },
        { k: 'ctx', o: 19, n: 27, t: '      <enclosure url="https://updates.wortel.' },
        { k: 'ctx', o: 20, n: 28, t: '    </item>' },
        { k: 'del', o: 21, n: null, t: '    <item>' },
        { k: 'del', o: 22, n: null, t: '      <title>2026.29.8</title>' },
      ] },
    ],
  },
];
