// ==========================================================================
// The wortel.sh Worker.
//
// It does two things: it puts PostHog on the site's own origin (/ph/*, this
// file), and it answers the letter's signup, confirm and leave requests
// (/letter/*, letter-routes.ts). Once a day, by the cron in wrangler.jsonc, it
// also deletes the letter's addresses that were never confirmed. Everything else on this domain is a static
// file, and static files are still served without this code ever running
// (Cloudflare matches an asset first and only falls through to the Worker when
// nothing matches, which is why the letter's routes have no file behind them).
// So the landing page costs exactly what it cost before.
//
// WHY PROXY AT ALL. Wortel's audience is developers, which is the audience most
// likely to block a request to a third-party analytics host. A same-origin
// request is not blocked by the usual lists, needs no preconnect, and adds no
// third-party origin to a page whose whole pitch is that it is small. The cost
// is this file.
//
// WHY /ph AND NOT /analytics. PostHog's own advice: the obvious names are on
// the blocklists too. Renaming it later is a config change on both ends, so it
// is worth picking something unremarkable now.
//
// The two upstreams are not interchangeable. Ingestion goes to the API host;
// the posthog-js bundle itself comes off the asset host, which is a CDN and
// wants caching. The snippet in Analytics.astro derives the second from the
// first by string replacement, which is why the /static/ split below has to
// match what it expects.
// ==========================================================================

import { forgetUnconfirmed, letter, type LetterEnv } from './letter-routes.ts';

const PREFIX = '/ph';

// EU region, matching the project. If the project ever moves to US cloud these
// two and the api_host in Analytics.astro all change together.
const API_HOST = 'eu.i.posthog.com';
const ASSET_HOST = 'eu-assets.i.posthog.com';

type Env = LetterEnv;

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === PREFIX || url.pathname.startsWith(`${PREFIX}/`)) {
      return proxy(request, url);
    }

    if (url.pathname.startsWith('/letter/')) {
      const answer = await letter(request, url, env, ctx);
      if (answer) return answer;
    }

    // Not an asset (or we would not be running) and not ours: hand it back so
    // the assets layer produces the 404 rather than inventing one here.
    return env.ASSETS.fetch(request);
  },

  // The cron: /privacy says an address not confirmed within a week is
  // deleted, and that has to be true on a week when nobody signs up.
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    const gone = await forgetUnconfirmed(env.DB, Math.floor(Date.now() / 1000));
    // A count only: never an address.
    if (gone) console.log(`letter: forgot ${gone} unconfirmed`);
  },
};

async function proxy(request: Request, url: URL): Promise<Response> {
  const path = url.pathname.slice(PREFIX.length) || '/';
  // /ph/static/array.js is the library; everything else is ingestion.
  const isAsset = path.startsWith('/static/');

  const target = new URL(url.toString());
  target.protocol = 'https:';
  target.port = '';
  target.hostname = isAsset ? ASSET_HOST : API_HOST;
  target.pathname = path;

  // Events are read and rewritten first: building `outbound` from `request`
  // below hands it the body, after which it can't be read here.
  if (request.method === 'POST' && INGEST.test(path)) {
    return ingest(request, target);
  }

  // Built from `request` so method, body and content-type carry over. The
  // headers on a Request constructed this way are mutable, which the ones on
  // the original are not.
  const outbound = new Request(target.toString(), request);

  forwardHeaders(request, outbound.headers);

  // Host is derived from the URL by the runtime; setting it by hand is ignored.

  if (isAsset) {
    return fetch(outbound, {
      cf: { cacheEverything: true, cacheTtl: 60 * 60 },
    });
  }

  return fetch(outbound);
}

function forwardHeaders(request: Request, headers: Headers): void {
  // The site sets no cookies of its own, but anything a visitor picked up on
  // this domain would otherwise be forwarded to PostHog for no reason.
  headers.delete('cookie');

  // Without this every event arrives from a Cloudflare edge address. PostHog
  // reads X-Forwarded-For for the daily cookieless hash, so dropping it would
  // collapse every visitor behind one colo into a single "person".
  const ip = request.headers.get('CF-Connecting-IP');
  if (ip) headers.set('X-Forwarded-For', ip);
}

async function ingest(request: Request, target: URL): Promise<Response> {
  const country = (request as { cf?: { country?: string } }).cf?.country;
  const events = await readEvents(request);
  // Fail closed: an event this cannot read is one it cannot strip the
  // location from, and /privacy promises there is none. Losing a pageview
  // costs less than breaking that.
  if (!events) return new Response('{"status":1}', { status: 200 });
  for (const event of events) stampCountry(event, country);

  target.searchParams.delete('compression');
  const headers = new Headers(request.headers);
  forwardHeaders(request, headers);
  headers.set('content-type', 'application/json');
  headers.delete('content-encoding');
  headers.delete('content-length');
  return fetch(target.toString(), { method: 'POST', headers, body: JSON.stringify(events) });
}

// ---- location: the country and nothing finer ---------------------------------
//
// PostHog looks every event's IP address up and stores the city, the postal
// code and coordinates beside it. /privacy says the site learns an approximate
// country, so this does the lookup itself: `$geoip_disable` turns PostHog's off,
// and the country Cloudflare already resolved for the request goes in instead.
// It also keeps the country under cookieless mode, which drops the address
// before PostHog's lookup ever sees it.
//
// Only the event endpoints carry properties; /flags and the rest pass through.

const INGEST = /^\/(e|i\/v0\/e|batch|capture|track)\/?$/;

type PHEvent = { properties?: Record<string, unknown> } & Record<string, unknown>;

// Caps, because this unpacks whatever anyone POSTs: a few KB of gzip can
// expand to gigabytes. A real batch from the site is a few KB either way, so
// these are far above anything legitimate and anything over them is dropped.
const MAX_BODY = 256 * 1024;
const MAX_PLAIN = 2 * 1024 * 1024;
const MAX_EVENTS = 200;

/** The events in a capture request, or null when the body is not one we know. */
async function readEvents(request: Request): Promise<PHEvent[] | null> {
  try {
    if (Number(request.headers.get('content-length') ?? 0) > MAX_BODY) return null;
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes.length > MAX_BODY) return null;
    // Gzip is told apart by its magic bytes, which is what PostHog does too:
    // posthog-js 1.447 sends a gzipped body with no `compression` parameter
    // and no content-encoding, so trusting either one dropped every event.
    const gzip = bytes[0] === 0x1f && bytes[1] === 0x8b;
    const plain = gzip ? await gunzip(bytes) : bytes;
    if (!plain || plain.length > MAX_PLAIN) return null;
    const parsed: unknown = JSON.parse(new TextDecoder().decode(plain));
    const list = Array.isArray(parsed) ? parsed
      : (parsed as { batch?: unknown }).batch ?? [parsed];
    if (!Array.isArray(list) || list.length > MAX_EVENTS) return null;
    if (!list.every((e) => e && typeof e === 'object')) return null;
    return list as PHEvent[];
  } catch {
    return null;
  }
}

/** Decompressed, or null the moment it passes MAX_PLAIN. */
async function gunzip(bytes: Uint8Array): Promise<Uint8Array | null> {
  const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip')).getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > MAX_PLAIN) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const chunk of chunks) {
    out.set(chunk, at);
    at += chunk.length;
  }
  return out;
}

function stampCountry(event: PHEvent, country: string | undefined): void {
  const properties = (event.properties ??= {});
  for (const key of Object.keys(properties)) {
    if (key.startsWith('$geoip_')) delete properties[key];
  }
  properties.$geoip_disable = true;
  // XX is Cloudflare's "unknown", T1 is Tor: neither is a country.
  if (country && country !== 'XX' && country !== 'T1') properties.$geoip_country_code = country;
}
