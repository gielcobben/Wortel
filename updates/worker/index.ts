// ==========================================================================
// updates.wortel.sh — the Sparkle feed, the signed zips, and the only place
// Wortel's downloads are ever counted.
//
// This used to be the wortel-updates R2 bucket on a custom domain, with no
// code in front of it. That is why the download count before this Worker
// existed is not a number anyone has: nothing was ever asked to keep one.
//
// SERVING COMES FIRST AND COUNTING CANNOT AFFECT IT. Every event is sent
// inside ctx.waitUntil() after the response has been constructed, wrapped in a
// catch that swallows. PostHog being slow, broken or blocked must not be able
// to delay a download or fail an update check, because the thing on the other
// end of this is an app updating itself unattended.
//
// THREE POPULATIONS HIT THIS BUCKET and lumping them together is the trap.
// Sparkle's scheduled check runs roughly once per install per day, so raw
// request counts are dominated by existing users and a naive "downloads"
// number would mostly be measuring people who already have the app:
//
//   Wortel-latest.zip      a new user, from the website
//   Wortel-<version>.zip   with a Sparkle agent: an existing user upgrading
//   Wortel-<version>.zip   without one: a direct or scripted download
//   appcast.xml            an install that still exists and still checks in
//
// That last one is the most valuable thing here. Sparkle puts the app version
// in its User-Agent, so the feed request alone gives version distribution
// across the entire install base, including every user who turned the app's
// own telemetry off. Which is exactly why /privacy has to say it happens: an
// opt-out that quietly does not cover this would be a lie.
//
// NOBODY IS IDENTIFIED. The distinct_id is a truncated hash of address, agent
// and the date, so it rotates at midnight and cannot be joined across days or
// back to a person. No address is stored, and every event is anonymous
// ($process_person_profile: false), so PostHog builds no profile from them.
// ==========================================================================

import { classify, isCrawler, cacheControl } from './classify.ts';

interface Env {
  BUCKET: R2Bucket;
  POSTHOG_KEY: string;
  // Not a secret in the cryptographic sense, but it is what stops the daily
  // visitor hash from being reproducible by anyone holding an address list.
  HASH_SALT: string;
}

const POSTHOG = 'https://eu.i.posthog.com/i/v0/e/';

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method Not Allowed', {
        status: 405,
        headers: { allow: 'GET, HEAD' },
      });
    }

    // The bucket has no index, and this hostname is one people paste into a
    // browser after seeing it in a release note. Send them somewhere real.
    if (url.pathname === '/') {
      return Response.redirect('https://wortel.sh/updates', 302);
    }

    // A malformed percent-escape (`/%zz`) makes decodeURIComponent throw, and
    // an uncaught throw here is a 500 on the one hostname every installed copy
    // checks unattended. It is a request for a key that cannot exist, so it
    // gets the answer a key that does not exist gets.
    let key: string;
    try {
      key = decodeURIComponent(url.pathname.slice(1));
    } catch {
      return new Response('Not Found', { status: 404 });
    }

    if (request.method === 'HEAD') {
      const head = await env.BUCKET.head(key);
      if (!head) return new Response(null, { status: 404 });
      const headers = new Headers();
      head.writeHttpMetadata(headers);
      headers.set('etag', head.httpEtag);
      headers.set('content-length', String(head.size));
      headers.set('cache-control', cacheControl(key));
      // Same answer as the GET, because a HEAD is how a download manager asks
      // whether it may resume. Omitting it here would have them fetch whole
      // archives again after a dropped connection.
      headers.set('accept-ranges', 'bytes');
      // Deliberately uncounted: a HEAD is a client asking about a file, not
      // taking one. Sparkle and every download manager send them.
      return new Response(null, { status: 200, headers });
    }

    let object: R2Object | R2ObjectBody | null;
    try {
      object = await env.BUCKET.get(key, {
        range: request.headers,
        onlyIf: request.headers,
      });
    } catch (error) {
      // R2 throws on a range it cannot satisfy (past the end of the object,
      // or malformed). Uncaught, that is a 500 on the hostname every
      // installed copy checks unattended. Only a request that asked for a
      // range is answered this way; anything else is a real failure.
      if (!request.headers.has('range')) throw error;
      const head = await env.BUCKET.head(key);
      if (!head) return new Response('Not Found', { status: 404 });
      return new Response(null, {
        status: 416,
        headers: { 'content-range': `bytes */${head.size}`, 'accept-ranges': 'bytes' },
      });
    }

    if (!object) return new Response('Not Found', { status: 404 });

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set('etag', object.httpEtag);
    headers.set('cache-control', cacheControl(key));
    headers.set('accept-ranges', 'bytes');

    // R2 hands back an object with no body in two cases: a conditional request
    // whose precondition failed (304, or 412 for If-Match and
    // If-Unmodified-Since), and a HEAD. Losing this check would
    // send `null` as a 200 and hand Sparkle a zero-byte archive.
    const body = (object as R2ObjectBody).body;
    if (!body) {
      const status = preconditionFailedStatus(request.headers);
      return new Response(null, { status, headers });
    }

    const ranged = !!object.range && request.headers.has('range');
    if (ranged) {
      headers.set('content-range', contentRange(object.range!, object.size));
    } else {
      headers.set('content-length', String(object.size));
    }

    const response = new Response(body, { status: ranged ? 206 : 200, headers });

    // Counted only when a whole file actually starts transferring. A range
    // request is a resumed or chunked download of something already counted,
    // and counting those would report a flaky connection as extra users.
    if (!ranged) {
      ctx.waitUntil(count(request, env, key));
    }

    return response;
  },
};

// ---- counting -------------------------------------------------------------

async function count(request: Request, env: Env, key: string): Promise<void> {
  try {
    const ua = request.headers.get('user-agent') ?? '';
    if (isCrawler(ua)) return;

    const what = classify(key, ua);
    if (!what) return;

    const day = new Date().toISOString().slice(0, 10);
    const ip = request.headers.get('CF-Connecting-IP') ?? '';
    const country = (request as { cf?: { country?: string } }).cf?.country;

    await fetch(POSTHOG, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        api_key: env.POSTHOG_KEY,
        event: what.event,
        distinct_id: await visitorId(ip, ua, day, env.HASH_SALT),
        properties: {
          ...what.props,
          ...(country ? { country } : {}),
          platform: 'updates',
          $process_person_profile: false,
        },
      }),
    });
  } catch {
    // Counting is the least important thing this Worker does.
  }
}

/// Address + agent + date, hashed and truncated. The date is what makes it
/// rotate: the same machine tomorrow is a different id, so these cannot be
/// stitched into a history of one person's downloads.
async function visitorId(ip: string, ua: string, day: string, salt: string): Promise<string> {
  const bytes = new TextEncoder().encode([ip, ua, day, salt].join('|'));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest).slice(0, 16)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

// ---- serving details ------------------------------------------------------

/// R2 gave back an object and no body: a precondition in the request failed.
/// Which status that is depends on which precondition it was. Only the two
/// "has it changed?" headers mean Not Modified; a failed If-Match or
/// If-Unmodified-Since is a client being told its copy is NOT the current
/// one, and answering 304 there says the opposite.
export function preconditionFailedStatus(request: Headers): 304 | 412 {
  const notModified = request.has('if-none-match') || request.has('if-modified-since');
  const mustMatch = request.has('if-match') || request.has('if-unmodified-since');
  return mustMatch && !notModified ? 412 : 304;
}

/// The Content-Range line for a 206.
///
/// **Read the suffix check before touching this.** Measured against the live
/// bucket, R2 answers every range with the same shape:
///
///     bytes=-500  ->  {"offset":18421343,"length":500}  keys: offset|length|suffix
///
/// It normalises a suffix request into an offset, and `suffix` is present as a
/// key on every result while being undefined on all of them. So `'suffix' in
/// range` is TRUE for an ordinary `bytes=0-99`, and the suffix branch then
/// computes `size - undefined` and emits `bytes NaN-18421842/18421843`. That
/// is a 206 carrying exactly the right bytes under a header a strict client is
/// entitled to reject: a resumed Sparkle download failing while the archive
/// itself is perfectly intact, with nothing about the payload to point at the
/// cause. Check the value, never the key.
export function contentRange(range: R2Range, size: number): string {
  if (typeof (range as { suffix?: number }).suffix === 'number') {
    const suffix = (range as { suffix: number }).suffix;
    return `bytes ${size - suffix}-${size - 1}/${size}`;
  }
  const offset = (range as { offset?: number }).offset ?? 0;
  const length = (range as { length?: number }).length ?? size - offset;
  return `bytes ${offset}-${offset + length - 1}/${size}`;
}
