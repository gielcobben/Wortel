#!/usr/bin/env node
// The pictures of this site that the browser splits in the films show:
// public/img/page-<wide|narrow>-<light|dark>.webp.
//
//   npm run dev                              the site, on http://localhost:4340
//   node scripts/pages/capture.mjs           all four
//   node scripts/pages/capture.mjs wide      one width
//   SITE=http://localhost:4350 node scripts/pages/capture.mjs
//
// Each is the homepage from its top with the landing sequence held at its end
// (/?t=30), in one colour scheme, at 2x:
//   wide    1074 points wide, for a browser that has most of the window
//   narrow   537 points wide, the width of a browser split beside a terminal,
//           and the layout the canvas drew its marks on (scripts/app.ts,
//           retaken)
// and 1600 points tall, which is more than any split shows of it. A split
// draws the page at its own width and cuts it off at its foot, so the height
// a picture needs is the split's height times the picture's width over the
// split's width. README, "The page in a browser split", has what each split
// asks for. A picture that ran out before its split did left a band of the
// page's ground under it.
//
// Chrome takes them, headless, on a profile of its own in a temporary folder,
// driven over its debugging port: no dependency and no build step (Node 22 or
// later, for its WebSocket). The page is given real seconds, not a time
// budget: the landing sequence, the photos (a stage asks for its own when it
// nears) and the arrival of what is in view all take their time, and a
// picture taken before they finished had an empty box where the window on
// the lake is. cwebp (brew install webp) writes the files.
//
// Retake them when the homepage's first two screens change. The marks the
// films draw over the page are placed by what is where in these pictures:
// the paragraph and the Download button (scripts/markup.ts).
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, existsSync, statSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = resolve(fileURLToPath(new URL('.', import.meta.url)), '../..');
const OUT = join(WEB, 'public/img');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const SITE = process.env.SITE ?? 'http://localhost:4340';
/** Points. */
const WIDTHS = { wide: 1074, narrow: 537 };
const HEIGHT = 1600;
/** Seconds the page is given before its picture is taken, and then what is
 *  at its foot to arrive. */
const SETTLE = 8, ARRIVE = 3;

const only = process.argv.slice(2);
const names = Object.keys(WIDTHS).filter((n) => !only.length || only.includes(n));
if (!existsSync(CHROME)) { console.error(`No Chrome at ${CHROME}. Set CHROME to one.`); process.exit(1); }

const tmp = mkdtempSync(join(tmpdir(), 'wortel-pages-'));
const chrome = spawn(CHROME, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--user-data-dir=${join(tmp, 'profile')}`, '--remote-debugging-port=0', 'about:blank',
], { stdio: ['ignore', 'ignore', 'pipe'] });
const sleep = (s) => new Promise((done) => setTimeout(done, s * 1000));

try {
  // Chrome says where it listens on its error stream.
  const port = await new Promise((found, failed) => {
    let said = '';
    chrome.stderr.on('data', (d) => { said += d; const m = /DevTools listening on ws:\/\/[^:]+:(\d+)\//.exec(said); if (m) found(m[1]); });
    chrome.on('exit', () => failed(new Error('Chrome quit before it could be reached')));
    setTimeout(() => failed(new Error('Chrome did not open its debugging port')), 15000);
  });
  const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((open, failed) => { ws.onopen = open; ws.onerror = failed; });
  const waiting = new Map();
  let last = 0;
  ws.onmessage = ({ data }) => { const m = JSON.parse(data); if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } };
  const send = (method, params = {}) => new Promise((done, failed) => {
    const id = ++last;
    waiting.set(id, (m) => (m.error ? failed(new Error(`${method}: ${m.error.message}`)) : done(m.result)));
    ws.send(JSON.stringify({ id, method, params }));
  });

  await send('Page.enable');
  for (const name of names) {
    for (const scheme of ['light', 'dark']) {
      await send('Emulation.setDeviceMetricsOverride', { width: WIDTHS[name], height: HEIGHT, deviceScaleFactor: 2, mobile: false });
      await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] });
      await send('Page.navigate', { url: `${SITE}/?t=30` });
      await sleep(SETTLE);
      // What is near the foot of so tall a window has not arrived yet (a
      // section comes in when it is a tenth of the window up from its foot):
      // bring it in, and its stage's photo, and give those their time too.
      await send('Runtime.evaluate', { expression: `document.querySelectorAll('[data-reveal]').forEach((el) => el.classList.add('in')); document.querySelectorAll('[data-photo]').forEach((el) => { el.dataset.near = ''; });` });
      await sleep(ARRIVE);
      const shot = await send('Page.captureScreenshot', { format: 'png' });
      const png = join(tmp, `${name}-${scheme}.png`), out = join(OUT, `page-${name}-${scheme}.webp`);
      writeFileSync(png, Buffer.from(shot.data, 'base64'));
      execFileSync('cwebp', ['-quiet', '-q', '82', '-m', '6', png, '-o', out]);
      console.log(`img/page-${name}-${scheme}.webp  ${Math.round(statSync(out).size / 1024)} KB`);
    }
  }
  ws.close();
} finally {
  chrome.kill();
  await sleep(0.3);
  rmSync(tmp, { recursive: true, force: true });
}
