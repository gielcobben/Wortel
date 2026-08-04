// Hand-rolled rather than @astrojs/sitemap: the site is one page, and a build
// step that walks the route table to discover a single URL is more moving parts
// than the thing it produces. Add routes to PAGES when there are more.
import type { APIRoute } from 'astro';
import { SITE } from '../data/site';

const PAGES: { path: string; changefreq: string; priority: string }[] = [
  { path: '/', changefreq: 'weekly', priority: '1.0' },
];

export const GET: APIRoute = () => {
  // Build date, not "now at request time". The output is prerendered, and a
  // lastmod that claims today on every crawl is a lastmod crawlers learn to
  // ignore. This one only moves when the site is actually redeployed.
  const lastmod = new Date().toISOString().slice(0, 10);

  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${PAGES.map(
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
