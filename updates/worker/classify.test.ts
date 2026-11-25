// Run with `npm test` (node strips the types; there is no build step).
//
// The cases that matter are the ones where two different populations ask for
// the same object and only the agent tells them apart. Getting that backwards
// does not throw, it just reports your existing users as new downloads.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classify, appVersion, isCrawler, cacheControl } from './classify.ts';

const SPARKLE = 'Wortel/2026.32.2 Sparkle/2.9.0';
const BROWSER =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';

test('the website download is a new user', () => {
  assert.deepEqual(classify('Wortel-latest.zip', BROWSER), {
    event: 'app_downloaded',
    props: { source: 'web' },
  });
});

test('the website download is the DMG, and it is a new user too', () => {
  assert.deepEqual(classify('Wortel-latest.dmg', BROWSER), {
    event: 'app_downloaded',
    props: { source: 'web' },
  });
});

test('a versioned DMG is a direct download', () => {
  assert.deepEqual(classify('Wortel-2026.32.3.dmg', BROWSER), {
    event: 'app_downloaded',
    props: { source: 'direct', version: '2026.32.3' },
  });
});

test('latest is still a download when Sparkle is not involved at all', () => {
  // curl -LO of the stable link. A real download, not an upgrade.
  assert.equal(classify('Wortel-latest.zip', 'curl/8.7.1')?.event, 'app_downloaded');
});

test('a versioned zip fetched by Sparkle is an upgrade, not a download', () => {
  assert.deepEqual(classify('Wortel-2026.32.3.zip', SPARKLE), {
    event: 'app_updated',
    props: { to_version: '2026.32.3', from_version: '2026.32.2' },
  });
});

test('the same object without Sparkle is a direct download', () => {
  assert.deepEqual(classify('Wortel-2026.32.3.zip', BROWSER), {
    event: 'app_downloaded',
    props: { source: 'direct', version: '2026.32.3' },
  });
});

test('the feed carries the installed version, which is the install base', () => {
  assert.deepEqual(classify('appcast.xml', SPARKLE), {
    event: 'update_checked',
    props: { app_version: '2026.32.2' },
  });
});

test('a feed request from something that is not Sparkle still counts, with no version', () => {
  assert.deepEqual(classify('appcast.xml', BROWSER), {
    event: 'update_checked',
    props: {},
  });
});

test('anything that is not an archive or the feed is not counted', () => {
  assert.equal(classify('appcast.xml.bak', SPARKLE), null);
  assert.equal(classify('old_updates/Wortel-2026.1.1.zip', SPARKLE), null);
  assert.equal(classify('Wortel.zip', BROWSER), null);
  assert.equal(classify('Wortel.dmg', BROWSER), null);
  assert.equal(classify('Wortel-2026.32.3.dmg.bak', BROWSER), null);
  assert.equal(classify('', BROWSER), null);
});

test('CalVer versions survive the regex intact', () => {
  // The version is (.+), so a dot in it must not truncate.
  assert.equal(classify('Wortel-2026.32.10.zip', BROWSER)?.props.version, '2026.32.10');
});

test('appVersion only reads our own agent', () => {
  assert.equal(appVersion(SPARKLE), '2026.32.2');
  assert.equal(appVersion(BROWSER), null);
  // Not ours, and must not be mistaken for ours.
  assert.equal(appVersion('WortelKeeper/1.0'), null);
});

test('crawlers are excluded and real command line tools are not', () => {
  assert.ok(isCrawler('Googlebot/2.1 (+http://www.google.com/bot.html)'));
  assert.ok(isCrawler('facebookexternalhit/1.1'));
  assert.ok(isCrawler('HeadlessChrome/120.0.0.0'));
  assert.ok(!isCrawler('curl/8.7.1'));
  assert.ok(!isCrawler('Wget/1.21.4'));
  assert.ok(!isCrawler(SPARKLE));
  assert.ok(!isCrawler(BROWSER));
});

test('the moving links are never cached long and the frozen ones always are', () => {
  // A stale appcast is a release nobody sees.
  assert.match(cacheControl('appcast.xml'), /max-age=300/);
  assert.match(cacheControl('Wortel-latest.zip'), /max-age=300/);
  assert.match(cacheControl('Wortel-latest.dmg'), /max-age=300/);
  // A versioned archive is the same bytes forever.
  assert.match(cacheControl('Wortel-2026.32.3.zip'), /immutable/);
  assert.match(cacheControl('Wortel-2026.32.3.dmg'), /immutable/);
});
