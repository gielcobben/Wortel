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


// ---- the story -------------------------------------------------------------
// ONE session, told in beats. Scrolling the page does not swap the terminal's
// contents, it CONTINUES them: each section appends its beat to the same
// transcript, older output rides up and off the top the way scrollback does,
// and only the newly arrived lines animate in. Scroll back up and the story
// rewinds to that point.
//
// So it has to read as one sitting at one machine. You land in the repo, build
// it, start the dev server, hand the work to an agent, watch it find and fix
// something, and then just talk to it. Nothing here changes directory or
// session, because a single story cannot.
//
// Rows: { g: gutter glyph, cls: colour class, t: text with inline markup }.
// Markup: **bold**, *italic*, [text](#) renders in the link colour. Blank t is
// an empty line. `block: true` is the agent's user-message card.
//
// Text is authored UNWRAPPED. Terminal.svelte measures the terminal and
// re-wraps to its column count on every resize, exactly like the real thing.
// Do NOT hard-code line breaks in here.
//
// Everything is invented EXCEPT the bug, which is real (macos/CLAUDE.md, on
// FileTreeDecorations). Deliberately no benchmark numbers: a fabricated
// measurement on a landing page is a claim, and this is a replica, not a claim.

export const windowTitle = 'Wortel/Web';
export const windowSubtitle = '~/Developer/wortel';

// The agent enters at this beat; Claude Code's status strip exists from here on.
export const AGENT_BEAT = 3;

export const STORY = [
  // 0 · you just opened the app
  [
    { g: '›', t: 'git status -sb' },
    { cls: 'dim', t: '## web-app-demo' },
    // Short enough to survive the hero's 33 columns; a longer path wraps and
    // strands the ' M ' status flag alone on a line.
    { t: ' M web/src/demo/data.js' },
    { t: '' },
  ],

  // 1 · the engine section, where both panels are closed and the terminal is
  //     at its widest. Give it output worth the width.
  [
    { g: '›', t: 'xcodebuild -scheme Wortel -configuration Release build' },
    { cls: 'dim', t: 'CompileSwift normal arm64 GhosttyRuntime.swift' },
    { cls: 'dim', t: 'CompileSwift normal arm64 SurfaceView.swift' },
    { cls: 'dim', t: 'Ld Wortel.app normal arm64' },
    // ** ** is the inline bold marker, so xcodebuild's literal asterisks would
    // be eaten either way; bold is the better reading of them anyway.
    { t: '**BUILD SUCCEEDED**' },
    { t: '' },
  ],

  // 2 · a long-running process is the reason a second session exists at all,
  //     which is what the sidebar beside this beat is showing.
  [
    { g: '›', t: 'npm run dev' },
    { cls: 'dim', t: 'VITE ready in 214 ms' },
    { cls: 'dim', t: 'Local: [http://localhost:4321/](#)' },
    { t: '' },
  ],

  // 3 · the agent arrives
  [
    { g: '›', t: 'claude' },
    { t: '' },
    {
      block: true,
      g: '❯',
      t: 'the file tree lights up the wrong folders when I edit something. take a look?',
    },
    { t: '' },
    { g: '●', t: 'Reading **FileTreeDecorations.swift**' },
    { t: '' },
    { g: '✳', gcls: 'active', cls: 'active', t: 'Tinkering… (9s · thinking more with high effort)' },
    { t: '' },
  ],

  // 4 · it answers, and the inspector opens on the diff it just made
  [
    { t: 'The ancestor roll-up compares with **hasPrefix**, so editing a file in [src/foo](#) also decorates [src/foobar](#). It needs a path-component compare, not a string one.' },
    { t: '' },
    { t: 'The reverse is worse: a collapsed directory that fails to roll up just looks clean. Neither direction throws, so a test is the only thing that catches either.' },
    { t: '' },
    { g: '●', t: 'Fixed, and pinned both directions in **FileTreeDecorationTests**.' },
    { t: '' },
    { g: '✳', gcls: 'dim', cls: 'dim', t: 'Cogitated for 14s' },
    { t: '' },
  ],

  // 5 · zero config, asked rather than demonstrated: by now you are talking to
  //     the agent, not to a shell, and a story cannot step back out of that.
  [
    { block: true, g: '❯', t: 'where does wortel keep its settings?' },
    { t: '' },
    { g: '●', t: 'It doesn’t. The whole configuration is one read-only file inside the app bundle, and your [~/.config/ghostty](#) is never read. There is nothing to keep in sync.' },
    { t: '' },
  ],

  // 6 · and the shortcut that the last section is about
  [
    { block: true, g: '❯', t: 'if I leave you running, how do I find you again?' },
    { t: '' },
    { g: '●', t: 'The sidebar marks me while I work and again when I stop. **⌘⌥]** jumps straight to whichever session is waiting on you.' },
    { t: '' },
  ],
];

// Beats do NOT end with a prompt row. A terminal has exactly one cursor and it
// is at the bottom, so Terminal appends a single one after the last beat; giving
// each beat its own left four of them stacked down the transcript.

// Terminal's fallback when nothing is driving it.
export const transcript = STORY[0];

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
