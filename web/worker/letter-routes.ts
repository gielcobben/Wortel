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
// ==========================================================================

import { confirmationMail, isToken, mayMail, newToken, parseJoin, PENDING_TTL } from './letter.ts';

export interface LetterEnv {
  ASSETS: { fetch(request: Request | string): Promise<Response> };
  DB: D1Database;
  EMAIL: SendEmail;
  JOIN_LIMIT: RateLimit;
}

const FROM = { name: 'Wortel', email: 'letter@wortel.sh' };
/** A form post is an address and two short fields; anything bigger is not one. */
const MAX_BODY = 4096;

interface Row {
  token: string;
  confirmed_at: number | null;
  mailed_at: number;
  created_at: number;
}

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
  // Unconfirmed addresses older than a week are forgotten here rather than by
  // a cron: the table only grows through this request, so this is enough.
  await env.DB.prepare('DELETE FROM subscribers WHERE confirmed_at IS NULL AND created_at < ?')
    .bind(now - PENDING_TTL).run();

  const row = await env.DB.prepare('SELECT token, confirmed_at, mailed_at, created_at FROM subscribers WHERE email = ?')
    .bind(asked.email).first<Row>();

  // Already on the list: nothing to do, and nothing to say about it.
  if (row?.confirmed_at) return answer(true);
  // Waiting, and mailed recently: the mail already in their inbox still works.
  if (row && !mayMail(row.mailed_at, now)) return answer(true);

  const token = row?.token ?? newToken();
  if (row) {
    // Waiting, and the last mail is a day old: send it again, and the week
    // the mail promises starts from this one.
    await env.DB.prepare('UPDATE subscribers SET mailed_at = ?, created_at = ?, source = ? WHERE email = ?')
      .bind(now, now, asked.source, asked.email).run();
  } else {
    // INSERT OR IGNORE: two posts of the same new address at once must not
    // send two mails or fail one of them.
    const put = await env.DB.prepare(
      'INSERT OR IGNORE INTO subscribers (email, token, source, created_at, confirmed_at, mailed_at) VALUES (?, ?, ?, ?, NULL, ?)',
    ).bind(asked.email, token, asked.source, now, now).run();
    if (!put.meta.changes) return answer(true);
  }

  // Behind the custom domain the links are always https://wortel.sh; anywhere
  // else (wrangler dev) they point back at wherever the form was sent from.
  const origin = url.hostname === 'wortel.sh' ? 'https://wortel.sh' : url.origin;
  const mail = confirmationMail(origin, token);
  try {
    await env.EMAIL.send({ from: FROM, to: asked.email, ...mail });
  } catch (err) {
    console.error('letter: confirmation mail failed', err instanceof Error ? err.message : String(err));
    // Put things back as they were, so trying again sends again.
    if (row) {
      await env.DB.prepare('UPDATE subscribers SET mailed_at = ?, created_at = ? WHERE email = ?')
        .bind(row.mailed_at, row.created_at, asked.email).run();
    } else {
      await env.DB.prepare('DELETE FROM subscribers WHERE email = ? AND confirmed_at IS NULL').bind(asked.email).run();
    }
    return answer(false, 503);
  }
  return answer(true);
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
  // Pending past its week counts as gone, even if no join has swept it yet.
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

async function readForm(request: Request): Promise<FormData | null> {
  const length = Number(request.headers.get('content-length') ?? '0');
  if (length > MAX_BODY) return null;
  const type = request.headers.get('content-type') ?? '';
  if (!type.includes('application/x-www-form-urlencoded') && !type.includes('multipart/form-data')) return null;
  try {
    return await request.formData();
  } catch {
    return null;
  }
}

/** 303: after a POST, the browser GETs the page that says what happened. */
function see(url: URL, path: string): Response {
  return new Response(null, { status: 303, headers: { location: new URL(path, url.origin).href, 'cache-control': 'no-store' } });
}

function notAllowed(allow: string): Response {
  return new Response('Method Not Allowed', { status: 405, headers: { allow } });
}
