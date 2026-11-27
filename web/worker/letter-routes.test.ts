// Run with `npm test`.
//
// The letter's requests against a real SQLite (node:sqlite, the schema from
// migrations/) standing in for D1, and a mail binding that counts. What this
// is for is the database's half of the promises: one mail a day however many
// posts arrive together, and what happens when a mail fails. Every database
// call waits a turn of the event loop first, as a call to D1 does, so two
// requests started together interleave the way they would at the edge.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join as path } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { forgetUnconfirmed, letter, type LetterEnv } from './letter-routes.ts';
import { MAIL_COOLDOWN, PENDING_TTL } from './letter.ts';

type Value = string | number | null;

function fakeD1(db: DatabaseSync) {
  const turn = () => new Promise((resolve) => setImmediate(resolve));
  return {
    prepare(sql: string) {
      let args: Value[] = [];
      const statement = {
        bind(...values: Value[]) {
          args = values;
          return statement;
        },
        async run() {
          await turn();
          return { meta: { changes: Number(db.prepare(sql).run(...args).changes) } };
        },
        async first<T>() {
          await turn();
          return (db.prepare(sql).get(...args) ?? null) as T | null;
        },
      };
      return statement;
    },
  };
}

function setup({ mailFails = false } = {}) {
  const db = new DatabaseSync(':memory:');
  db.exec(readFileSync(path(import.meta.dirname, '../migrations/0001_subscribers.sql'), 'utf8'));
  const mails: { to: string; text: string }[] = [];
  const env = {
    ASSETS: { fetch: async () => new Response('not found', { status: 404 }) },
    DB: fakeD1(db),
    EMAIL: {
      async send(message: { to: string; text: string }) {
        await new Promise((resolve) => setImmediate(resolve));
        if (mailFails) throw new Error('not onboarded');
        mails.push({ to: message.to, text: message.text });
      },
    },
    JOIN_LIMIT: { limit: async () => ({ success: true }) },
  } as unknown as LetterEnv;
  return { db, env, mails };
}

function join(env: LetterEnv, email: string) {
  const url = new URL('https://wortel.sh/letter/join');
  const request = new Request(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
    body: new URLSearchParams({ email, source: 'letter' }).toString(),
  });
  return letter(request, url, env);
}

interface Row {
  email: string;
  token: string;
  created_at: number;
  confirmed_at: number | null;
  mailed_at: number;
}

const rows = (db: DatabaseSync) => db.prepare('SELECT * FROM subscribers ORDER BY email').all() as unknown as Row[];
const nowSeconds = () => Math.floor(Date.now() / 1000);
const TOKEN = 'T'.repeat(43);

function put(db: DatabaseSync, row: Partial<Row> & { email: string }) {
  db.prepare('INSERT INTO subscribers (email, token, source, created_at, confirmed_at, mailed_at) VALUES (?, ?, ?, ?, ?, ?)')
    .run(row.email, row.token ?? TOKEN, 'letter', row.created_at ?? 0, row.confirmed_at ?? null, row.mailed_at ?? 0);
}

async function answers(responses: (Response | null)[]) {
  return Promise.all(responses.map(async (r) => [r?.status, await r?.json()]));
}

test('a new address is kept as waiting and sent one mail with its token', async () => {
  const { db, env, mails } = setup();
  assert.deepEqual(await answers([await join(env, 'You@Example.com')]), [[200, { ok: true }]]);
  const [row] = rows(db);
  assert.equal(row.email, 'you@example.com');
  assert.equal(row.confirmed_at, null);
  assert.equal(mails.length, 1);
  assert.ok(mails[0].text.includes(`/letter/confirm?t=${row.token}`));
});

test('the same new address posted five times at once gets one mail', async () => {
  const { db, env, mails } = setup();
  const all = await Promise.all(Array.from({ length: 5 }, () => join(env, 'you@example.com')));
  assert.deepEqual(await answers(all), Array(5).fill([200, { ok: true }]));
  assert.equal(rows(db).length, 1);
  assert.equal(mails.length, 1);
});

test('a waiting address last mailed a day ago gets one more mail however many posts arrive', async () => {
  const { db, env, mails } = setup();
  const then = nowSeconds() - MAIL_COOLDOWN - 60;
  put(db, { email: 'you@example.com', created_at: then, mailed_at: then });
  const all = await Promise.all(Array.from({ length: 5 }, () => join(env, 'you@example.com')));
  assert.deepEqual(await answers(all), Array(5).fill([200, { ok: true }]));
  assert.equal(mails.length, 1);
  assert.ok(mails[0].text.includes(`?t=${TOKEN}`), 'the link in the first mail keeps working');
  const [row] = rows(db);
  // The mail says seven days from now, so the week starts again.
  assert.ok(row.mailed_at >= nowSeconds() - 5 && row.created_at === row.mailed_at);
});

test('a waiting address mailed within the day is not mailed again', async () => {
  const { db, env, mails } = setup();
  const then = nowSeconds() - MAIL_COOLDOWN + 60;
  put(db, { email: 'you@example.com', created_at: then, mailed_at: then });
  assert.deepEqual(await answers([await join(env, 'you@example.com')]), [[200, { ok: true }]]);
  assert.equal(mails.length, 0);
  assert.equal(rows(db)[0].mailed_at, then);
});

test('an address on the list is left alone, with the same answer', async () => {
  const { db, env, mails } = setup();
  put(db, { email: 'you@example.com', created_at: 1, confirmed_at: 2, mailed_at: 1 });
  assert.deepEqual(await answers([await join(env, 'you@example.com')]), [[200, { ok: true }]]);
  assert.equal(mails.length, 0);
  assert.deepEqual(rows(db).map((r) => [r.created_at, r.confirmed_at, r.mailed_at]), [[1, 2, 1]]);
});

test('a mail that fails leaves a new address forgotten', async () => {
  const { db, env } = setup({ mailFails: true });
  await join(env, 'you@example.com');
  assert.equal(rows(db).length, 0);
});

test('a mail that fails leaves a waiting address free to be mailed again', async () => {
  const { db, env } = setup({ mailFails: true });
  const then = nowSeconds() - MAIL_COOLDOWN - 60;
  put(db, { email: 'you@example.com', created_at: then, mailed_at: then });
  await join(env, 'you@example.com');
  assert.equal(rows(db)[0].mailed_at, 0);
  assert.equal(rows(db)[0].token, TOKEN);
});

test('the sweep forgets addresses not confirmed within a week, and nothing else', async () => {
  const { db, env } = setup();
  const now = nowSeconds();
  put(db, { email: 'old@example.com', token: 'a'.repeat(43), created_at: now - PENDING_TTL - 1, mailed_at: now - PENDING_TTL - 1 });
  put(db, { email: 'week@example.com', token: 'b'.repeat(43), created_at: now - PENDING_TTL, mailed_at: now - PENDING_TTL });
  put(db, { email: 'on@example.com', token: 'c'.repeat(43), created_at: 1, confirmed_at: 2, mailed_at: 1 });
  assert.equal(await forgetUnconfirmed(env.DB, now), 1);
  assert.deepEqual(rows(db).map((r) => r.email), ['on@example.com', 'week@example.com']);
});

test('an address past its week starts again with a new token', async () => {
  const { db, env, mails } = setup();
  const then = nowSeconds() - PENDING_TTL - 60;
  put(db, { email: 'you@example.com', created_at: then, mailed_at: then });
  await join(env, 'you@example.com');
  assert.equal(mails.length, 1);
  assert.notEqual(rows(db)[0].token, TOKEN);
});
