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
// An agent doing ordinary work in this repo: read a bug, explain it, fix it.
// It is invented, but the bug is real (see macos/CLAUDE.md on
// FileTreeDecorations), which is why it reads like a session and not like copy.
//
// Rows: { g: gutter glyph, cls: colour class, t: text with inline markup }.
// Markup: **bold**, *italic*, [text](#) renders in the link colour. Blank t is
// an empty line. Line breaks are HARD-CODED and never re-wrapped.
//
// WIDTH IS THE WHOLE CONSTRAINT. In the hero the window is 1044px with the
// sidebar (228) and the inspector (450) both open, which leaves the terminal
// 366px, and the text column inside that is 335px: THIRTY-THREE characters.
// So every `t` below is <= 33 rendered characters (markup excluded) and the
// copy is written short rather than wrapped long and clipped. That is also why
// it reads as minimal: at this width, minimal is the only honest option.
export const transcript = [
  {
    block: true,
    g: '❯',
    lines: ['fix the file tree decoration bug'],
  },
  { t: '' },
  { g: '●', t: 'Reading **FileTreeDecorations**' },
  { t: '' },
  { t: 'The ancestor roll-up compares' },
  { t: 'with **hasPrefix**, so editing' },
  { t: '[src/foo](#) also decorates' },
  { t: '[src/foobar](#). It needs a' },
  { t: 'path-component compare.' },
  { t: '' },
  { t: 'Neither direction throws, so' },
  { t: 'the test is the only way to' },
  { t: 'see it.' },
  { t: '' },
  { g: '●', t: 'Fixed, and pinned both ways.' },
  { t: '' },
  { g: '✳', gcls: 'dim', cls: 'dim', t: 'Cogitated for 14s' },
  { t: '' },
  { g: '›', caret: true },
];

// ---- status bar -----------------------------------------------------------
// Claude Code's TUI, i.e. terminal content, and it lives under the same 33-char
// ceiling as the transcript: the full "esc to interrupt / 1 agent / to manage"
// strip clips to nonsense at this width.
export const statusBar = [
  { t: '▶▶', cls: 'amber' },
  { t: ' auto mode on', cls: 'amber' },
  { t: ' · ', cls: 'dim' },
  { t: '1 shell', cls: 'teal' },
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
