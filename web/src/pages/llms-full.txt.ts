// /llms-full.txt, the whole page as Markdown, for a retrieval agent that would
// otherwise have to strip an interactive Svelte island out of the HTML to find
// four paragraphs of prose. Rendered from the same src/data/site.ts the page
// renders from, so it cannot describe a different product.
import type { APIRoute } from 'astro';
import { SITE, SECTIONS, FAQ, SPECS, type Block } from '../data/site';

const renderBlock = (b: Block): string => {
  if ('p' in b) return b.p;
  if ('list' in b) return b.list.map((li) => `- ${li}`).join('\n');
  const { head, rows } = b.table;
  return [
    `| ${head[0]} | ${head[1]} |`,
    '| --- | --- |',
    ...rows.map(([k, v]) => `| ${k} | ${v} |`),
  ].join('\n');
};

export const GET: APIRoute = () => {
  const parts: string[] = [
    `# ${SITE.name}: ${SITE.tagline}`,
    '',
    `> ${SITE.description}`,
    '',
    `Source: ${SITE.url}`,
    `Download: ${SITE.download}`,
    `Requires: macOS ${SITE.minMacOS} ${SITE.minMacOSName} or later`,
    `Price: free`,
    '',
    '---',
  ];

  for (const section of SECTIONS) {
    parts.push('', `## ${section.title}`, '');
    if (section.lead) parts.push(section.lead, '');
    parts.push(section.blocks.map(renderBlock).join('\n\n'));
  }

  parts.push('', '## Frequently asked questions', '');
  parts.push(FAQ.map((f) => `### ${f.q}\n\n${f.a}`).join('\n\n'));

  parts.push('', '## At a glance', '');
  parts.push('| | |', '| --- | --- |', ...SPECS.map(([k, v]) => `| ${k} | ${v} |`));

  parts.push('', '---', '', `© ${SITE.author}. ${SITE.name} is Dutch for "root".`, '');

  return new Response(parts.join('\n'), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
};
