// /llms-full.txt, every page as Markdown, for a retrieval agent that would
// otherwise have to strip an interactive Svelte island out of the HTML to find
// four paragraphs of prose. Rendered from the same modules the pages render
// from, so it cannot describe a different product.
//
// THE COMPARISON IS HERE TOO, not just linked from llms.txt. A model asked
// "how does Wortel compare to Conductor" has one shot at a fetch, and a
// full-text dump that answers everything EXCEPT the comparison is the one that
// sends it to a third party's page instead. The grid is a table per group, with
// the verdict spelled out as a word: "●" and "◐" mean nothing in plain text,
// and "not published" has to read as itself rather than as a quiet no.
import type { APIRoute } from 'astro';
import { SITE, SECTIONS, FAQ, SPECS, type Block } from '../data/site';
import { COMPARE, APPS, AXES, GROUPS, type Verdict } from '../data/compare';

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

/** The verdict as a word. `unknown` renders as the note alone, which already
    says "not published": "unknown: Not published" reads like a bug. */
const verdict = (v: Verdict, note: string) =>
  v === 'unknown' ? note : `${v}: ${note}`;

const compareTables = (): string[] => {
  const byId = new Map(AXES.map((a) => [a.id, a]));
  const head = `| Question | ${APPS.map((a) => a.name).join(' | ')} |`;
  const rule = `| --- | ${APPS.map(() => '---').join(' | ')} |`;
  const out: string[] = ['', `## ${COMPARE.tableHeading}`, '', COMPARE.tableLead, ''];

  for (const group of GROUPS) {
    out.push(`### ${group.title}`, '', group.blurb, '', head, rule);
    for (const id of group.axes) {
      const axis = byId.get(id)!;
      const cells = APPS.map((app) => {
        const cell = axis.cells[app.key];
        return axis.descriptive ? cell.note : verdict(cell.v, cell.note);
      });
      out.push(`| ${axis.q} | ${cells.join(' | ')} |`);
    }
    out.push('');
  }

  out.push(COMPARE.caveat, '');
  return out;
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

  parts.push(...compareTables());

  parts.push('', '## At a glance', '');
  parts.push('| | |', '| --- | --- |', ...SPECS.map(([k, v]) => `| ${k} | ${v} |`));

  parts.push('', '---', '', `© ${SITE.author}. ${SITE.name} is Dutch for "root".`, '');

  return new Response(parts.join('\n'), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
  });
};
