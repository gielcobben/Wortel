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

export const windowTitle = 'Wortel/Web';
export const windowSubtitle = '~/Developer/wortel';

// ---- terminal transcript --------------------------------------------------
// The live demo currently shows an EMPTY terminal (just the prompt); the full
// transcribed session below is kept as `transcriptFull` to wire back in later.
export const transcript = [
  { g: '›', caret: true },
];

// rows: { g: gutter glyph, cls: color class, t: text with inline markup }
// markup: **bold**, *italic*, [text](#) → link color. Blank t = empty line.
export const transcriptFull = [
  { g: '›', cls: '', t: '        /var/folders/wt/4961wd_x4xx1kgr95wm_pxqm0000gn/T/claude-chrome (148.3K' },
  { flow: true, cls: '', t: '[image]  -screenshots-dK6Bfg/screenshot-1784226033738-0.jpg                B)' },
  { t: '' },
  { g: '●', cls: '', t: '✅ **Screenshots confirmed working.** Full pipeline is live:' },
  { t: '' },
  { t: '- **Dev server** running at [http://localhost:4321/](#) (background, auto-reloads on' },
  { t: 'file changes)', ind: 1 },
  { t: '- **Chrome tab** open on it (tabId [864128900](#))' },
  { t: '- **Capture → save → send** all working, as you can see above' },
  { t: '' },
  { t: 'So the remote-control loop is ready: I edit a component → the server' },
  { t: 'hot-reloads → I screenshot → I send it to you → you tell me what to change. I' },
  { t: 'can also zoom into regions for pixel-level detail on chrome/spacing.' },
  { t: '' },
  { t: 'One thing the test shot reveals: the landing page currently embeds a *real* PNG' },
  { t: 'screenshot of the app ([app-shot-dark.png](#)) in the stage, that’s exactly the' },
  { t: 'thing we’re replacing with the live Svelte faux-app.' },
  { t: '' },
  { t: 'Ready to start building. Want me to kick off with the **window shell + sessions**' },
  { t: '**sidebar** (the outer chrome, traffic lights, and the named-sessions list on the' },
  { t: 'left), then screenshot it against that reference PNG so you can compare?' },
  { t: '' },
  { g: '✳', gcls: 'dim', cls: 'dim', t: 'Cogitated for 1m 4s · 1 shell still running' },
  { t: '' },
  {
    block: true,
    g: '❯',
    lines: [
      'Alright, now run the app or make a screenshot of the app were im typing in',
      'and make you u have the latest. the once in public are outdated. Also the',
      'whole re-creation of the app should work light and dark mode and switch based',
      'on the OS appearance. We already do this for the website.',
    ],
  },
  { t: '' },
  { g: '✳', gcls: 'active', cls: 'active', t: 'Tinkering… (27s · thinking more with high effort)' },
  { g: '└', gcls: 'dim', cls: 'dim', t: 'Tip: Ask Claude to create a todo list when working on complex tasks to', ind: 1 },
  { cls: 'dim', t: ' track progress and remain on track', ind: 1 },
  { cls: 'dim', t: 'Still working. [Check in from your phone](#)', right: true },
  { t: '' },
  { g: '›', caret: true },
];

// ---- status bar -----------------------------------------------------------
export const statusBar = [
  { t: '▶▶', cls: 'amber' },
  { t: ' auto mode on', cls: 'amber' },
  { t: ' · ', cls: 'dim' },
  { t: '1 shell', cls: 'teal' },
  { t: ' · ', cls: 'dim' },
  { t: 'esc to interrupt', cls: 'dim' },
  { t: ' · ', cls: 'dim' },
  { t: '← 1 agent', cls: 'dim' },
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
