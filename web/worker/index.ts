// ==========================================================================
// The wortel.sh Worker.
//
// It exists for one reason: to put PostHog on the site's own origin. Everything
// else on this domain is a static file, and static files are still served
// without this code ever running (Cloudflare matches an asset first and only
// falls through to the Worker when nothing matches). So the landing page costs
// exactly what it cost before; the Worker is reached by /ph/* and nothing else.
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

const PREFIX = '/ph';

// EU region, matching the project. If the project ever moves to US cloud these
// two and the api_host in Analytics.astro all change together.
const API_HOST = 'eu.i.posthog.com';
const ASSET_HOST = 'eu-assets.i.posthog.com';

interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === PREFIX || url.pathname.startsWith(`${PREFIX}/`)) {
      return proxy(request, url);
    }

    // Not an asset (or we would not be running) and not ours: hand it back so
    // the assets layer produces the 404 rather than inventing one here.
    return env.ASSETS.fetch(request);
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

  // Built from `request` so method, body and content-type carry over. The
  // headers on a Request constructed this way are mutable, which the ones on
  // the original are not.
  const outbound = new Request(target.toString(), request);

  // The site sets no cookies of its own, but anything a visitor picked up on
  // this domain would otherwise be forwarded to PostHog for no reason.
  outbound.headers.delete('cookie');

  // Without this every event arrives from a Cloudflare edge address. PostHog
  // reads X-Forwarded-For for the daily cookieless hash, so dropping it would
  // collapse every visitor behind one colo into a single "person".
  const ip = request.headers.get('CF-Connecting-IP');
  if (ip) outbound.headers.set('X-Forwarded-For', ip);

  // Host is derived from the URL by the runtime; setting it by hand is ignored.

  if (isAsset) {
    return fetch(outbound, {
      cf: { cacheEverything: true, cacheTtl: 60 * 60 },
    });
  }

  return fetch(outbound);
}
