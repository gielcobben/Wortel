// Hand-rolled rather than @astrojs/sitemap: the site is small enough that a
// build step walking the route table is more moving parts than the thing it
// produces. Add routes to PAGES when there are more.
//
// /release-notes/* is deliberately absent: those are fragments for Sparkle's
// update dialog, not pages, and the same text is already on /updates.
import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { SITE } from '../data/site';

const PAGES: { path: string; changefreq: string; priority: string }[] = [
  { path: '/', changefreq: 'weekly', priority: '1.0' },
  { path: '/compare', changefreq: 'monthly', priority: '0.7' },
  { path: '/updates', changefreq: 'weekly', priority: '0.6' },
];

export const GET: APIRoute = async () => {
  // The legal pages are read from the collection rather than listed above, so
  // a new Markdown file reaches the sitemap without anyone remembering that
  // this file exists. Yearly and low priority: they matter, and they are not
  // what anyone is searching for.
  const legal = (await getCollection('legal')).map((entry) => ({
    path: `/${entry.id}`,
    changefreq: 'yearly',
    priority: '0.3',
  }));

  // Build date, not "now at request time". The output is prerendered, and a
  // lastmod that claims today on every crawl is a lastmod crawlers learn to
  // ignore. This one only moves when the site is actually redeployed.
  const lastmod = new Date().toISOString().slice(0, 10);

  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${[...PAGES, ...legal].map(
  (p) => `  <url>
    <loc>${new URL(p.path, SITE.url).href}</loc>
    <lastmod>${lastmod}</lastmod>
    <changefreq>${p.changefreq}</changefreq>
    <priority>${p.priority}</priority>
  </url>`,
).join('\n')}
</urlset>
`;

  return new Response(body, {
    headers: { 'Content-Type': 'application/xml; charset=utf-8' },
  });
};
