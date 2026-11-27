// ==========================================================================
// The letter's three requests: join, confirm, leave.
//
//   POST /letter/join      an address from one of the forms. Stored as
//                          pending and sent a confirmation mail.
//   GET  /letter/confirm   the page the mail links to, with a Confirm button
//                          (the static /letter/confirming, token filled in).
//   POST /letter/confirm   the button: the address is on the list.
//   GET  /letter/leave     the page a letter will link to, with a Leave button
//                          (the static /letter/leaving, token filled in).
//   POST /letter/leave     the button, or a mail client's one-click
//                          unsubscribe (RFC 8058): the address is deleted.
//
// WHY A BUTTON AND NOT A LINK. Mail scanners (Outlook's Safe Links and the
// like) open every link in a message before the person does. A link that
// confirmed on opening would put every address anyone typed onto the list;
// one that unsubscribed would empty it. So a GET only shows a page, and only
// a POST changes anything.
//
// WHY THE SAME ANSWER EVERY TIME. Join says "check your inbox" whether the
// address was new, already waiting, already on the list, or a bot's. Anything
// else would let the form be used to find out who is on the list.
//
// WHAT LIMITS ABUSE. Someone can type other people's addresses into the form,
// and those people get a mail they did not ask for. Three things keep that
// small: the hidden field bots fill in, a per-IP rate limit (the binding
// counts in memory and stores nothing), and one mail per address per day.
// There is no Turnstile, because that is a third-party script on the page.
//
// WHAT IS FORGOTTEN. An address not confirmed within a week of its last mail
// is deleted by forgetUnconfirmed(), once a day by a cron and on every join.
// ==========================================================================

import { confirmationMail, isToken, MAIL_COOLDOWN, newToken, parseJoin, PENDING_TTL } from './letter.ts';

export interface LetterEnv {
  ASSETS: { fetch(request: Request | string): Promise<Response> };
  DB: D1Database;
  EMAIL: SendEmail;
  JOIN_LIMIT: RateLimit;
}

const FROM = { name: 'Wortel', email: 'letter@wortel.sh' };
/** A form post is an address and two short fields; anything bigger is not one. */
const MAX_BODY = 4096;

/** The letter's answer to a request, or null when the request is not the letter's. */
export async function letter(request: Request, url: URL, env: LetterEnv): Promise<Response | null> {
  switch (url.pathname) {
    case '/letter/join':
      return request.method === 'POST' ? join(request, url, env) : notAllowed('POST');
    case '/letter/confirm':
      if (request.method === 'GET' || request.method === 'HEAD') return page(url, env, 'confirm');
      return request.method === 'POST' ? confirm(request, url, env) : notAllowed('GET, HEAD, POST');
    case '/letter/leave':
      if (request.method === 'GET' || request.method === 'HEAD') return page(url, env, 'leave');
      return request.method === 'POST' ? leave(request, url, env) : notAllowed('GET, HEAD, POST');
    default:
      return null;
  }
}

async function join(request: Request, url: URL, env: LetterEnv): Promise<Response> {
  const json = (request.headers.get('accept') ?? '').includes('application/json');
  const answer = (ok: boolean, status = 200) =>
    json
      ? Response.json({ ok }, { status: ok ? 200 : status, headers: { 'cache-control': 'no-store' } })
      : see(url, ok ? '/letter/sent' : '/letter/sorry');

  const ip = request.headers.get('cf-connecting-ip') ?? 'unknown';
  const { success } = await env.JOIN_LIMIT.limit({ key: ip });
  if (!success) return answer(false, 429);

  const form = await readForm(request);
  if (!form) return answer(false, 400);
  const asked = parseJoin(form);
  if (asked.kind === 'bot') return answer(true);
  if (asked.kind === 'invalid') return answer(false, 400);

  const now = Math.floor(Date.now() / 1000);
  // The daily sweep is what keeps the week. This one is so that an address
  // past its week, not swept yet, starts again below with a new token rather
  // than having its old mail's link brought back to life.
  await forgetUnconfirmed(env.DB, now);

  // Whether to mail is decided by this one statement, and only it, so two
  // posts of the same address at once cannot both decide to (a SELECT, then a
  // write, let every concurrent post through). It returns the token to mail:
  //   - a new address is inserted, with a new token;
  //   - one still waiting whose last mail is a day old or more is claimed:
  //     mailed_at moves to now, and so does created_at, because the mail says
  //     the address is forgotten in seven days and that must hold for the
  //     latest one;
  //   - anything else (on the list, or mailed within the day) is left as it
  //     is and returns nothing, and gets the same answer.
  const fresh = newToken();
  const claimed = await env.DB.prepare(
    `INSERT INTO subscribers (email, token, source, created_at, confirmed_at, mailed_at) VALUES (?1, ?2, ?3, ?4, NULL, ?4)
     ON CONFLICT (email) DO UPDATE SET mailed_at = excluded.mailed_at, created_at = excluded.created_at, source = excluded.source
     WHERE subscribers.confirmed_at IS NULL AND subscribers.mailed_at <= ?5
     RETURNING token`,
  ).bind(asked.email, fresh, asked.source, now, now - MAIL_COOLDOWN).first<{ token: string }>();
  if (!claimed) return answer(true);
  const token = claimed.token;

  // Behind the custom domain the links are always https://wortel.sh; anywhere
  // else (wrangler dev) they point back at wherever the form was sent from.
  const origin = url.hostname === 'wortel.sh' ? 'https://wortel.sh' : url.origin;
  const mail = confirmationMail(origin, token);
  try {
    await env.EMAIL.send({ from: FROM, to: asked.email, ...mail });
  } catch (err) {
    console.error('letter: confirmation mail failed', err instanceof Error ? err.message : String(err));
    // Undo the claim, so trying again sends again: a new address is
    // forgotten, a waiting one may be mailed again at once. Both only if the
    // row is still the one this request wrote.
    if (token === fresh) {
      await env.DB.prepare('DELETE FROM subscribers WHERE email = ? AND token = ? AND confirmed_at IS NULL')
        .bind(asked.email, token).run();
    } else {
      await env.DB.prepare('UPDATE subscribers SET mailed_at = 0 WHERE email = ? AND token = ? AND mailed_at = ? AND confirmed_at IS NULL')
        .bind(asked.email, token, now).run();
    }
    return answer(false, 503);
  }
  return answer(true);
}

/**
 * Deletes every address that was not confirmed within a week of its last
 * confirmation mail. Run once a day by the cron in wrangler.jsonc
 * (index.ts, `scheduled`), so the week /privacy promises holds when nobody
 * signs up, and on every join. confirm() already treats a row past its week as
 * gone, so the hours until the next sweep change nothing anyone can see.
 */
export async function forgetUnconfirmed(db: D1Database, now: number): Promise<number> {
  const gone = await db.prepare('DELETE FROM subscribers WHERE confirmed_at IS NULL AND created_at < ?')
    .bind(now - PENDING_TTL).run();
  return gone.meta.changes;
}

/**
 * The confirm or leave page, with the token from the link put into its form.
 * The page itself is a static file (/letter/confirming or /letter/leaving,
 * src/pages/letter/[state].astro), deliberately at another address: a path
 * with a file behind it never reaches this Worker. This fills in the one
 * hidden field, so the button works without JavaScript.
 */
async function page(url: URL, env: LetterEnv, which: 'confirm' | 'leave'): Promise<Response> {
  const t = url.searchParams.get('t');
  const row = isToken(t)
    ? await env.DB.prepare('SELECT confirmed_at FROM subscribers WHERE token = ?').bind(t).first<{ confirmed_at: number | null }>()
    : null;
  if (which === 'confirm') {
    if (!row) return see(url, '/letter/expired');
    if (row.confirmed_at) return see(url, '/letter/joined');
  } else if (!row) {
    // Not on the list (any more): that is what they came for.
    return see(url, '/letter/left');
  }

  const asset = await env.ASSETS.fetch(new Request(new URL(which === 'confirm' ? '/letter/confirming' : '/letter/leaving', url.origin)));
  const res = new HTMLRewriter()
    .on('input[name="t"]', { element: (el) => { el.setAttribute('value', t as string); } })
    .transform(asset);
  const headers = new Headers(res.headers);
  // The token is in the address: never cached, never sent on as a referrer.
  headers.set('cache-control', 'no-store');
  headers.set('referrer-policy', 'no-referrer');
  return new Response(res.body, { status: res.status, headers });
}

async function confirm(request: Request, url: URL, env: LetterEnv): Promise<Response> {
  const t = (await readForm(request))?.get('t');
  if (!isToken(t)) return see(url, '/letter/expired');
  const now = Math.floor(Date.now() / 1000);
  // Pending past its week counts as gone, even before the daily sweep has run.
  const done = await env.DB.prepare(
    'UPDATE subscribers SET confirmed_at = COALESCE(confirmed_at, ?) WHERE token = ? AND (confirmed_at IS NOT NULL OR created_at >= ?)',
  ).bind(now, t, now - PENDING_TTL).run();
  return see(url, done.meta.changes ? '/letter/joined' : '/letter/expired');
}

async function leave(request: Request, url: URL, env: LetterEnv): Promise<Response> {
  const form = await readForm(request);
  // One-click unsubscribe posts `List-Unsubscribe=One-Click` to the address in
  // the mail's List-Unsubscribe header, so the token rides in the query there.
  const t = form?.get('t') ?? url.searchParams.get('t');
  if (isToken(t)) await env.DB.prepare('DELETE FROM subscribers WHERE token = ?').bind(t).run();
  // Gone either way: an unknown token means there is nothing left to delete.
  if (form?.get('List-Unsubscribe') === 'One-Click') return new Response(null, { status: 200 });
  return see(url, '/letter/left');
}

/**
 * The form a POST carries, or null. The cap is on the bytes actually read,
 * not on Content-Length, which a chunked request leaves out: the body is read
 * into a buffer that stops at MAX_BODY, and only that buffer is parsed.
 * Multipart is kept because RFC 8058 has mail clients send one-click
 * unsubscribe that way.
 */
async function readForm(request: Request): Promise<FormData | null> {
  const type = request.headers.get('content-type') ?? '';
  if (!type.includes('application/x-www-form-urlencoded') && !type.includes('multipart/form-data')) return null;
  if (Number(request.headers.get('content-length') ?? '0') > MAX_BODY) return null;
  const body = await readCapped(request.body, MAX_BODY);
  if (!body) return null;
  try {
    return await new Request('https://letter.invalid/', { method: 'POST', headers: { 'content-type': type }, body }).formData();
  } catch {
    return null;
  }
}

/** Past the cap, how much more is read and thrown away before giving up on the body. */
const MAX_DRAIN = 1024 * 1024;

/**
 * The whole stream if it is at most `max` bytes, else null. Past `max` nothing
 * more is kept: the rest is read and dropped, so memory stays at `max`.
 * Dropping rather than cancelling at once because a cancelled body left
 * wrangler dev's proxy unable to answer the next POST (measured 2026-11-26);
 * a body past MAX_DRAIN is cancelled anyway.
 */
async function readCapped(stream: ReadableStream<Uint8Array> | null, max: number): Promise<Uint8Array | null> {
  if (!stream) return new Uint8Array(0);
  const reader = stream.getReader();
  const out = new Uint8Array(max);
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return size > max ? null : out.slice(0, size);
    if (size + value.byteLength <= max) out.set(value, size);
    size += value.byteLength;
    if (size > max + MAX_DRAIN) {
      await reader.cancel();
      return null;
    }
  }
}

/** 303: after a POST, the browser GETs the page that says what happened. */
function see(url: URL, path: string): Response {
  return new Response(null, { status: 303, headers: { location: new URL(path, url.origin).href, 'cache-control': 'no-store' } });
}

function notAllowed(allow: string): Response {
  return new Response('Method Not Allowed', { status: 405, headers: { allow } });
}
