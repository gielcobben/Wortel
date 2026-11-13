#!/usr/bin/env node
// The social cards for the inner pages: public/og/<page>.png, 1200x630.
//
//   node scripts/og/render.mjs            all of them
//   node scripts/og/render.mjs docs       one
//
// Each card is a small HTML page screenshotted by the Chrome already on the
// Mac (headless, 1x), so this needs no dependency and no build step. The output
// is committed: the site never runs this, and a card only changes when its copy
// does. The homepage keeps public/og.png, which has the app window in it.
//
// The look is the homepage card's: fog background, the icon top left, a
// headline whose second line is grey, and one of the site's lake photos below
// with something from the page on glass. Copy here is user-facing, so no
// em-dashes (the repo's rule; check.sh greps dist/ for them).
//
// Nothing here is read from src/data on purpose: a card is a picture of the
// page, cached by every social network for days, so it should say things that
// stay true (no version numbers, no release counts).
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = resolve(fileURLToPath(new URL('.', import.meta.url)), '../..');
const PUB = join(WEB, 'public');
const OUT = join(PUB, 'og');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** @type {Record<string, { title: string, sub: string, photo: string, at?: string, body: string }>} */
const CARDS = {
  docs: {
    title: 'Reference.',
    sub: 'Every command and shortcut.',
    photo: 'lake.jpg',
    at: '50% 62%',
    body: `<div class="glass term">${[
      ['wortel list', 'The open sessions, in sidebar order'],
      ['wortel new --branch fix-login', 'A session, in its own worktree'],
      ['wortel read api', 'Prints the text on a session’s screen'],
      ['wortel send api "run the tests"', 'Types text into a session'],
      ['wortel wait api', 'Waits until something happens'],
    ].map(([c, d]) => `<div class="row"><span class="cmd"><i>$</i> ${esc(c)}</span><span class="d">${esc(d)}</span></div>`).join('')}</div>`,
  },
  compare: {
    title: 'Where Wortel sits.',
    sub: 'Against nine named apps.',
    photo: 'hills.jpg',
    body: `<div class="chips">${['Ghostty', 'iTerm2', 'Warp', 'cmux', 'Conductor', 'Emdash', 'Superset', 'herdr', 'tmux']
      .map((n) => `<span class="glass chip">${n}</span>`).join('')}</div>`,
  },
  updates: {
    title: 'Changelog.',
    sub: 'Every release, newest first.',
    photo: 'haze.jpg',
    body: `<div class="glass note"><img src="ICON" alt="" /><div><b>Wortel updated itself</b><span>Quietly, in the background. The notes are all here.</span></div></div>`,
  },
  download: {
    title: 'Download Wortel.',
    sub: 'Free, for macOS 14 or later.',
    photo: 'skye.jpg',
    body: `<figure class="file"><img src="ICON" alt="" /><figcaption>Wortel</figcaption></figure>`,
  },
  about: {
    title: 'Wortel is Dutch for root.',
    sub: 'Why it exists, what it believes.',
    photo: 'lake.jpg',
    at: '50% 40%',
    body: `<div class="glass entry"><p class="w">wor·tel <span>noun, Dutch</span></p><p>1. The root of a plant: the part below the surface that holds everything up.</p><p>2. The root shell, where the real work happens.</p></div>`,
  },
};

const page = (card) => `<!doctype html>
<html><head><meta charset="utf-8"><style>
  * { box-sizing: border-box; margin: 0; }
  html, body { width: 1200px; height: 630px; overflow: hidden; background: #fbfaf7; }
  body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif; color: #1b1b17; -webkit-font-smoothing: antialiased; }
  .icon { position: absolute; left: 48px; top: 60px; width: 96px; height: 96px; }
  h1 { position: absolute; left: 168px; top: 52px; right: 48px; font-weight: 600; font-size: 60px; line-height: 64px; letter-spacing: -0.035em; }
  h1 span { display: block; color: #a3a196; }
  .photo { position: absolute; left: 48px; right: 48px; top: 208px; height: 480px; border-radius: 24px; overflow: hidden;
           background: url(PHOTO) var(--at, 50% 50%) / cover no-repeat; box-shadow: 0 0 0 1px rgb(0 0 0 / 0.06);
           display: flex; align-items: flex-start; justify-content: center; padding-top: 64px; }
  .glass { background: color-mix(in srgb, #fbfaf7 78%, transparent); backdrop-filter: blur(24px) saturate(1.6);
           box-shadow: 0 0 0 0.5px rgb(0 0 0 / 0.12), 0 8px 24px rgb(0 0 0 / 0.12); }
  .term { border-radius: 16px; padding: 24px 32px; width: 880px; }
  .row { display: flex; justify-content: space-between; gap: 32px; font: 500 20px/40px "SF Mono", ui-monospace, Menlo, monospace; }
  .row i { font-style: normal; color: #a3a196; }
  .row .d { font: 400 18px/40px -apple-system, system-ui, sans-serif; color: #6b6960; }
  .chips { display: flex; flex-wrap: wrap; justify-content: center; gap: 16px; width: 920px; padding-top: 24px; }
  .chip { border-radius: 999px; padding: 0 28px; font: 500 26px/64px -apple-system, system-ui, sans-serif; letter-spacing: -0.01em; }
  .note { display: flex; gap: 20px; align-items: center; border-radius: 24px; padding: 24px 32px 24px 24px; margin-top: 40px; }
  .note img { width: 72px; height: 72px; }
  .note b { display: block; font-size: 26px; line-height: 36px; font-weight: 600; letter-spacing: -0.01em; }
  .note span { display: block; font-size: 20px; line-height: 28px; color: #6b6960; }
  .file { text-align: center; margin-top: 48px; }
  .file img { width: 160px; height: 160px; filter: drop-shadow(0 12px 24px rgb(0 0 0 / 0.25)); }
  .file figcaption { margin-top: 8px; font: 600 22px/32px -apple-system, system-ui, sans-serif; color: #fff; text-shadow: 0 1px 4px rgb(0 0 0 / 0.4); }
  .entry { border-radius: 20px; padding: 32px 40px; width: 840px; font-size: 22px; line-height: 32px; color: #45433c; }
  .entry p + p { margin-top: 8px; }
  .entry .w { font-size: 34px; line-height: 48px; font-weight: 600; letter-spacing: -0.02em; color: #1b1b17; margin-bottom: 8px; }
  .entry .w span { font-size: 20px; font-weight: 400; font-style: italic; color: #77746a; letter-spacing: 0; margin-left: 12px; }
</style></head><body>
  <img class="icon" src="ICON" alt="" />
  <h1>${esc(card.title)}<span>${esc(card.sub)}</span></h1>
  <div class="photo" style="--at: ${card.at ?? '50% 50%'}">${card.body}</div>
</body></html>`;

if (!existsSync(CHROME)) {
  console.error(`No Chrome at ${CHROME}. Set CHROME=/path/to/chrome.`);
  process.exit(1);
}

const only = process.argv.slice(2);
const names = only.length ? only : Object.keys(CARDS);
const tmp = mkdtempSync(join(tmpdir(), 'wortel-og-'));
mkdirSync(OUT, { recursive: true });

for (const name of names) {
  const card = CARDS[name];
  if (!card) { console.error(`No card "${name}". Known: ${Object.keys(CARDS).join(', ')}`); process.exit(1); }
  const html = page(card)
    .replaceAll('ICON', `file://${join(PUB, 'icon-512.png')}`)
    .replace('PHOTO', `file://${join(PUB, 'img', card.photo)}`);
  const src = join(tmp, `${name}.html`);
  writeFileSync(src, html);
  const out = join(OUT, `${name}.png`);
  execFileSync(CHROME, [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
    '--default-background-color=fbfaf7ff', '--allow-file-access-from-files',
    '--window-size=1200,630', `--screenshot=${out}`, `file://${src}`,
  ], { stdio: 'ignore' });
  console.log(`og/${name}.png`);
}
