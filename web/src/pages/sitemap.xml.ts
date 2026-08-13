// Hand-rolled rather than @astrojs/sitemap: the site is small enough that a
// build step walking the route table is more moving parts than the thing it
// produces. Add routes to PAGES when there are more.
//
// /release-notes/* is deliberately absent: those are fragments for Sparkle's
// update dialog, not pages, and the same text is already on /updates. They also
// carry `X-Robots-Tag: noindex` now (see public/_headers).
//
// The URLs here have NO trailing slash, matching the canonical tags, which are
// built from the same kind of path prop. That pairing is load-bearing and is
// what `html_handling: "drop-trailing-slash"` in wrangler.jsonc exists to hold
// up: before it, Astro's directory output meant every one of these 307'd.
import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { execFileSync } from 'node:child_process';
import { SITE } from '../data/site';

// ---- lastmod ---------------------------------------------------------------
// A date a crawler can act on, which means a date that moves when the CONTENT
// moved and stays put otherwise.
//
// This used to be `new Date()` for every URL. The comment defending it said it
// only moved on redeploy, which was true and still wrong: release.sh --publish
// redeploys the whole site, so shipping one Markdown file republished all five
// URLs claiming all five had changed. Google's documented response to a lastmod
// that behaves like that is to stop believing the field, at which point the
// honest ones stop working too.
//
// So: ask git when the files behind each page last changed. Only content
// sources are listed, never the stylesheet or the layout, because a spacing
// change is not a reason to tell anyone the page is new.
//
// Committer date (%cs), already YYYY-MM-DD. Uncommitted edits are invisible to
// this by design: the question is when the published text changed, and text
// that is not committed is not published.
const gitDate = (paths: string[]): string | null => {
  try {
    const out = execFileSync('git', ['log', '-1', '--format=%cs', '--', ...paths], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    return /^\d{4}-\d{2}-\d{2}$/.test(out) ? out : null;
  } catch {
    // No git (a tarball, a shallow CI checkout): fall through to the build date
    // rather than fail the build over a hint field.
    return null;
  }
};

const BUILD_DATE = new Date().toISOString().slice(0, 10);
const iso = (d: Date) => d.toISOString().slice(0, 10);

// changefreq and priority are kept, and are hints nobody acts on: Google has
// said for years it ignores both. lastmod is the one field in this document
// that changes behaviour, which is the whole reason the block above exists.
const PAGES: { path: string; changefreq: string; priority: string; sources: string[] }[] = [
  {
    path: '/',
    changefreq: 'weekly',
    priority: '1.0',
    sources: ['src/data/site.ts', 'src/pages/index.astro'],
  },
  {
    path: '/compare',
    changefreq: 'monthly',
    priority: '0.7',
    sources: ['src/data/compare.ts', 'src/pages/compare.astro'],
  },
  {
    // Shares src/data/site.ts with the homepage, so the two move together: the
    // reference is written in the same module as the copy it was cut out of.
    path: '/docs',
    changefreq: 'monthly',
    priority: '0.7',
    sources: ['src/data/site.ts', 'src/pages/docs.astro'],
  },
];

export const GET: APIRoute = async () => {
  // /updates does not need git: the page IS the release folder, so the newest
  // release date is exactly when it last changed, and it is already a real date
  // in the frontmatter.
  const releases = await getCollection('releases');
  const newestRelease = releases
    .map((entry) => entry.data.date)
    .sort((a, b) => b.getTime() - a.getTime())[0];

  // Same idea: the legal collection carries `updated` in its schema, which the
  // page already prints as "Last updated". Reusing it means the sitemap cannot
  // disagree with what the page says about itself. Yearly and low priority:
  // they matter, and they are not what anyone is searching for.
  const legal = (await getCollection('legal')).map((entry) => ({
    path: `/${entry.id}`,
    changefreq: 'yearly',
    priority: '0.3',
    lastmod: iso(entry.data.updated),
  }));

  const urls = [
    ...PAGES.map((p) => ({ ...p, lastmod: gitDate(p.sources) ?? BUILD_DATE })),
    {
      path: '/updates',
      changefreq: 'weekly',
      priority: '0.6',
      lastmod: newestRelease ? iso(newestRelease) : BUILD_DATE,
    },
    ...legal,
  ];

  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls
  .map(
    (p) => `  <url>
    <loc>${new URL(p.path, SITE.url).href}</loc>
    <lastmod>${p.lastmod}</lastmod>
    <changefreq>${p.changefreq}</changefreq>
    <priority>${p.priority}</priority>
  </url>`,
  )
  .join('\n')}
</urlset>
`;

  return new Response(body, {
    headers: { 'Content-Type': 'application/xml; charset=utf-8' },
  });
};
