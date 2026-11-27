// Run with `npm test` (node strips the types; there is no build step).
//
// The letter's decisions, without D1 or the mail binding: what counts as an
// address, what a form post says, what the mail reads. One mail a day per
// address is the database's to keep: letter-routes.test.ts. The requests in a
// browser are checked by hand under `wrangler dev` (web/README.md, The letter).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  confirmationMail, encodeToken, isToken, newToken, normaliseEmail, parseJoin,
} from './letter.ts';

const form = (fields: Record<string, string>) => new URLSearchParams(fields);

test('an address is trimmed and lowercased', () => {
  assert.equal(normaliseEmail('  You@Example.COM '), 'you@example.com');
});

test('unusual addresses that work are accepted', () => {
  for (const ok of ['a+tag@example.com', 'first.last@sub.example.co.uk', 'x@xn--bcher-kva.example', 'o\'neil@example.ie']) {
    assert.equal(normaliseEmail(ok), ok, ok);
  }
});

test('things that are not addresses are turned away', () => {
  for (const bad of ['', 'you', 'you@', '@example.com', 'you@example', 'you@@example.com', 'a@b@example.com',
    'you @example.com', 'you@exa mple.com', 'you@-example.com', 'you@example.c', 'you@example..com',
    '<you@example.com>', 'you@example.com, them@example.com', `${'a'.repeat(65)}@example.com`]) {
    assert.equal(normaliseEmail(bad), null, JSON.stringify(bad));
  }
  assert.equal(normaliseEmail(undefined), null);
  assert.equal(normaliseEmail(42), null);
});

test('a form post is an address and where it came from', () => {
  assert.deepEqual(parseJoin(form({ email: 'You@Example.com', source: 'download' })),
    { kind: 'join', email: 'you@example.com', source: 'download' });
});

test('an unknown or missing source counts as the letter page', () => {
  assert.deepEqual(parseJoin(form({ email: 'you@example.com', source: 'elsewhere' })),
    { kind: 'join', email: 'you@example.com', source: 'letter' });
  assert.deepEqual(parseJoin(form({ email: 'you@example.com' })),
    { kind: 'join', email: 'you@example.com', source: 'letter' });
});

test('the hidden field filled in is a bot, even with a good address', () => {
  assert.deepEqual(parseJoin(form({ email: 'you@example.com', website: 'https://spam.example' })), { kind: 'bot' });
});

test('the hidden field left empty, or only spaces, is a person', () => {
  assert.equal(parseJoin(form({ email: 'you@example.com', website: '' })).kind, 'join');
  assert.equal(parseJoin(form({ email: 'you@example.com', website: '  ' })).kind, 'join');
});

test('a bad address is invalid', () => {
  assert.deepEqual(parseJoin(form({ email: 'nope' })), { kind: 'invalid' });
  assert.deepEqual(parseJoin(form({})), { kind: 'invalid' });
});

test('a token is 43 url-safe characters', () => {
  const t = newToken();
  assert.match(t, /^[A-Za-z0-9_-]{43}$/);
  assert.ok(isToken(t));
  assert.notEqual(newToken(), t);
  // The bytes that become + and / in plain base64 come out as - and _.
  assert.equal(encodeToken(new Uint8Array(32).fill(0xff)), '_'.repeat(42) + '8');
  assert.equal(encodeToken(new Uint8Array(32).fill(0xfb)), '-_v7'.repeat(10) + '-_s');
});

test('anything else is not a token', () => {
  for (const bad of [null, undefined, '', 'short', 'a'.repeat(42), 'a'.repeat(44), `${'a'.repeat(42)}=`, `${'a'.repeat(42)}+`]) {
    assert.equal(isToken(bad), false, JSON.stringify(bad));
  }
});

test('the mail links to the confirm page on the same origin, and nowhere else', () => {
  const t = newToken();
  const mail = confirmationMail('https://wortel.sh', t);
  const link = `https://wortel.sh/letter/confirm?t=${t}`;
  assert.ok(mail.text.includes(link));
  assert.ok(mail.html.includes(`href="${link}"`));
  const hrefs = [...mail.html.matchAll(/href="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(hrefs, [link, 'https://wortel.sh']);
  assert.ok(!/<img/i.test(mail.html), 'no images, so no tracking pixel');
});

test('the mail has no em-dash or en-dash, and says how to ignore it', () => {
  const mail = confirmationMail('https://wortel.sh', newToken());
  for (const part of [mail.subject, mail.text, mail.html]) assert.ok(!/[—–]/.test(part));
  assert.ok(mail.text.includes('Ignore this email and nothing happens'));
});
