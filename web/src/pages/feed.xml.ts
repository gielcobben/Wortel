// /feed.xml: the changelog as an Atom feed, one entry per release with its
// notes in full, for feed readers and for anything that watches a project by
// its feed. Built from the same Markdown files as /updates.
import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { compareVersions } from '../content.config';
import { SITE } from '../data/site';

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const abs = (p: string) => new URL(p, SITE.url).href;
/** Noon UTC on the day it shipped: the notes carry a date, not a time. */
const stamp = (d: Date) => `${d.toISOString().slice(0, 10)}T12:00:00Z`;

export const GET: APIRoute = async () => {
  const releases = (await getCollection('releases')).sort((a, b) => compareVersions(b.id, a.id));
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>${esc(SITE.name)} changelog</title>
  <subtitle>Every release of ${esc(SITE.name)}, the native macOS terminal for coding agents.</subtitle>
  <id>${abs('/updates')}</id>
  <link href="${abs('/updates')}" />
  <link rel="self" type="application/atom+xml" href="${abs('/feed.xml')}" />
  <updated>${releases[0] ? stamp(releases[0].data.date) : new Date().toISOString()}</updated>
  <author><name>${esc(SITE.author)}</name><uri>${SITE.authorUrl}</uri></author>
  <icon>${abs('/favicon-96.png')}</icon>
${releases.map((r) => `  <entry>
    <title>${esc(`${SITE.name} ${r.id}: ${r.data.title}`)}</title>
    <id>${abs(`/updates/${r.id}`)}</id>
    <link href="${abs(`/updates/${r.id}`)}" />
    <updated>${stamp(r.data.date)}</updated>
    <published>${stamp(r.data.date)}</published>${r.data.summary ? `
    <summary>${esc(r.data.summary)}</summary>` : ''}
    <content type="html">${esc(r.rendered?.html ?? '')}</content>
  </entry>`).join('\n')}
</feed>
`;
  return new Response(body, { headers: { 'Content-Type': 'application/atom+xml; charset=utf-8' } });
};
