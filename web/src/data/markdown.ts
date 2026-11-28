// The site as Markdown, for agents. One renderer per page, built from the same
// modules the pages render from, so the Markdown cannot describe a different
// product than the HTML does.
//
// Two consumers:
//   pages/llms-full.txt.ts   everything, concatenated, for one-shot retrieval
//   pages/*.md.ts            one page each (/index.md, /docs.md, /compare.md,
//                            /updates.md), linked from that page's <head> as
//                            rel="alternate" type="text/markdown"
//
// THE COMPARISON IS RENDERED IN FULL, not linked. A model asked "how does
// Wortel compare to Conductor" has one shot at a fetch, and a dump that answers
// everything EXCEPT the comparison sends it to a third party's page instead.
// The verdict is spelled out as a word: "●" and "◐" mean nothing in plain text,
// and "not published" has to read as itself rather than as a quiet no.
import { getCollection } from 'astro:content';
import { compareVersions, publicRelease } from '../content.config';
import { SITE, SECTIONS, FAQ, SPECS, DOCS, DOCS_SECTIONS, FEATURE_PAGES, LEARN, betaNote as beta, type Block, type FeaturePage, type Step } from './site';
import { COMPARE, APPS, AXES, GROUPS, type Verdict } from './compare';

const abs = (p: string) => new URL(p, SITE.url).href;

export const renderBlock = (b: Block): string => {
  if ('p' in b) return b.p;
  if ('h' in b) return `**${b.h}**`;
  if ('list' in b) return b.list.map((li) => `- ${li}`).join('\n');
  if ('code' in b) return ['```', b.code, '```'].join('\n');
  const { head, rows, mono } = b.table;
  // In a table of commands "(beta)" goes with what the command does, where it
  // cannot be read as part of the command.
  return [
    `| ${head[0]} | ${head[1]} |`,
    '| --- | --- |',
    ...rows.map(([k, v, f]) => (mono === 'first' ? `| ${k} | ${v}${beta(f)} |` : `| ${k}${beta(f)} | ${v} |`)),
  ].join('\n');
};

/** The verdict as a word. `unknown` renders as the note alone, which already
    says "not published": "unknown: Not published" reads like a bug. */
const verdict = (v: Verdict, note: string) =>
  v === 'unknown' ? note : `${v}: ${note}`;

const hashes = (n: number) => '#'.repeat(n);

/** The facts every page's Markdown opens with, so a single fetched file is
    never missing where to get the app or what it needs. */
const facts = (): string[] => [
  `Download: ${SITE.download}`,
  `Requires: macOS ${SITE.minMacOS} ${SITE.minMacOSName} or later`,
  `Price: free`,
];

const footer = (): string[] => ['', '---', '', `© ${SITE.author}. ${SITE.name} is Dutch for "root".`, ''];

// ---- the pieces -------------------------------------------------------------

export const homeSections = (): string[] => {
  const out: string[] = [];
  for (const section of SECTIONS) {
    out.push('', `## ${section.title}${beta(section)}`, '');
    if (section.lead) out.push(section.lead, '');
    out.push(section.blocks.map(renderBlock).join('\n\n'));
  }
  return out;
};

export const faq = (): string[] => [
  '', '## Frequently asked questions', '',
  FAQ.map((f) => `### ${f.q}\n\n${f.a}`).join('\n\n'),
];

export const specs = (): string[] => [
  '', '## At a glance', '',
  '| | |', '| --- | --- |', ...SPECS.map(([k, v]) => `| ${k} | ${v} |`),
];

/** The reference's sections, their headings at `level`. */
export const docsSections = (level: number): string[] => {
  const out: string[] = [];
  for (const section of DOCS_SECTIONS) {
    out.push('', `${hashes(level)} ${section.title}${beta(section)}`, '');
    if (section.lead) out.push(section.lead, '');
    // The feature's own page, where the section has one.
    if (section.page) out.push(`[${section.page[0]}](${abs(section.page[1])})`, '');
    out.push(section.blocks.map(renderBlock).join('\n\n'));
  }
  return out;
};

/** The comparison grid, one table per group, under a heading at `level`. */
export const compareTables = (level: number): string[] => {
  const byId = new Map(AXES.map((a) => [a.id, a]));
  const head = `| Question | ${APPS.map((a) => a.name).join(' | ')} |`;
  const rule = `| --- | ${APPS.map(() => '---').join(' | ')} |`;
  const out: string[] = ['', `${hashes(level)} ${COMPARE.tableHeading}`, '', COMPARE.tableLead, ''];

  for (const group of GROUPS) {
    out.push(`${hashes(level + 1)} ${group.title}`, '', group.blurb, '', head, rule);
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

/** A feature page's parts and its reference rows, their headings at `level`. */
export const featureSections = (page: FeaturePage, level: number): string[] => {
  const out: string[] = [];
  for (const part of page.parts) {
    out.push('', `${hashes(level)} ${part.title}${part.tone ? `: ${part.tone}` : ''}`, '');
    if (part.body) out.push(part.body);
    if (part.code) out.push('', `${part.code.label}:`, '', '```', part.code.text, '```');
    if (part.facts) out.push('', part.facts.map(([k, v]) => `- **${k}.** ${v}`).join('\n'));
  }
  for (const section of page.reference) {
    out.push('', `${hashes(level)} ${section.title}${beta(section)}`, '');
    if (section.lead) out.push(section.lead, '');
    out.push(section.blocks.map(renderBlock).join('\n\n'));
  }
  return out;
};

/** A step as a list item: its name, what is pressed, and the sentence. */
const stepMd = (st: Step) => `- **${st.name}**${st.keys ? ` (${st.keys.map((k) => (k.startsWith('`') ? k : `\`${k}\``)).join(', ')})` : ''}: ${st.text}`;

/** /learn's day, a part at a time, its headings at `level`. What a part shows
 *  as a picture is written out: the worktree folders, the sidebar's signals,
 *  the commands typed, the four moments of a quit. */
export const learnSections = (level: number): string[] => {
  const out: string[] = [];
  for (const part of LEARN.parts) {
    out.push('', `${hashes(level)} ${part.at}, ${part.title}: ${part.tone}${beta(part)}`, '');
    if (part.body) out.push(part.body);
    if (part.id === 'branches') {
      const b = LEARN.branches;
      out.push('', [b.repo, ...b.trees].map((t) => `- \`${t.path}\` on \`${t.branch}\`: ${t.who}`).join('\n'), '', b.shared);
    }
    if (part.id === 'signals') out.push('', LEARN.signals.map((sg) => `- **${sg.name}.** ${sg.text}`).join('\n'));
    if (part.id === 'together') out.push('', '```', ...LEARN.together.lines.flatMap((l) => [`$ ${l.cmd}`, ...('out' in l ? l.out : [])]), '```');
    if (part.id === 'keys') out.push('', `Every shortcut, as a table: ${abs('/docs#shortcuts')}`);
    const steps: readonly Step[] = part.id === 'roots' ? LEARN.waterline.steps : (part.steps ?? []);
    if (steps.length) out.push('', steps.map(stepMd).join('\n'));
    if (part.link) out.push('', `More: [${part.link[0]}](${abs(part.link[1])})`);
  }
  out.push('', `${hashes(level)} ${LEARN.closing.title}: ${LEARN.closing.tone}`, '', LEARN.closing.body, '',
    LEARN.more.map((m) => `- [${m.name}](${abs(m.href)}): ${m.blurb}`).join('\n'));
  return out;
};

// ---- the pages --------------------------------------------------------------

export const llmsFull = (): string => [
  `# ${SITE.name}: ${SITE.tagline}`,
  '',
  `> ${SITE.description}`,
  '',
  `Source: ${SITE.url}`,
  ...facts(),
  '',
  '---',
  ...homeSections(),
  // The reference is flattened in too, for the same reason as the comparison:
  // a dump that answers everything except "what are the shortcuts" is the one
  // that sends a model off to guess.
  '', `## ${DOCS.heading}: ${DOCS.lead}`, '', `Source: ${abs('/docs')}`, '',
  ...docsSections(3),
  // Each feature page, in full: what the homepage's section says once, a part at a time.
  ...FEATURE_PAGES.flatMap((page) => [
    '', `## ${page.heading}: ${page.tone}${beta(page)}`, '', page.lead, '', `Source: ${abs(page.path)}`,
    ...featureSections(page, 3),
  ]),
  // The guided day, for a model asked how to get started.
  '', `## ${LEARN.heading}: ${LEARN.tone}`, '', LEARN.lead, '', `Source: ${abs(LEARN.path)}`,
  ...learnSections(3),
  ...faq(),
  ...compareTables(2),
  ...specs(),
  ...footer(),
].join('\n');

export const homeMd = (): string => [
  `# ${SITE.name}: ${SITE.tagline}`,
  '',
  `> ${SITE.description}`,
  '',
  `Source: ${SITE.url}`,
  ...facts(),
  `Reference: ${abs('/docs.md')}`,
  `Comparison: ${abs('/compare.md')}`,
  `Changelog: ${abs('/updates.md')}`,
  '',
  '---',
  ...homeSections(),
  ...faq(),
  ...specs(),
  ...footer(),
].join('\n');

export const docsMd = (): string => [
  `# ${SITE.name} ${DOCS.heading.toLowerCase()}`,
  '',
  `> ${DOCS.lead}`,
  '',
  `Source: ${abs('/docs')}`,
  ...facts(),
  '',
  '---',
  ...docsSections(2),
  ...footer(),
].join('\n');

/** A feature page (/mark-up, /layouts) as Markdown. */
export const featureMd = (page: FeaturePage): string => [
  `# ${page.heading}: ${page.tone}${beta(page)}`,
  '',
  `> ${page.lead}`,
  '',
  `Source: ${abs(page.path)}`,
  ...facts(),
  `Reference: ${abs('/docs.md')}`,
  '',
  '---',
  ...featureSections(page, 2),
  '', '## More', '',
  [...FEATURE_PAGES.filter((other) => other !== page).map((other) => `- [${other.name}](${abs(other.path)}): ${other.blurb}`),
    ...page.more.map((m) => `- [${m.name}](${abs(m.href)}): ${m.blurb}`)].join('\n'),
  ...footer(),
].join('\n');

/** /learn as Markdown. */
export const learnMd = (): string => [
  `# ${LEARN.heading}: ${LEARN.tone}`,
  '',
  `> ${LEARN.lead}`,
  '',
  `Source: ${abs(LEARN.path)}`,
  ...facts(),
  `Reference: ${abs('/docs.md')}`,
  '',
  '---',
  ...learnSections(2),
  ...footer(),
].join('\n');

export const compareMd = (): string => [
  `# ${COMPARE.heading}`,
  '',
  `> ${COMPARE.lead}`,
  '',
  `Source: ${abs('/compare')}`,
  ...facts(),
  '',
  '---',
  ...compareTables(2),
  ...footer(),
].join('\n');

export const updatesMd = async (): Promise<string> => {
  const releases = (await getCollection('releases', publicRelease)).sort((a, b) => compareVersions(b.id, a.id));
  const day = (d: Date) => d.toISOString().slice(0, 10);
  return [
    `# ${SITE.name} changelog`,
    '',
    `> Every release of ${SITE.name}, newest first. ${SITE.name} updates itself through Sparkle; versions are CalVer (year.ISO-week.nth release that week).`,
    '',
    `Source: ${abs('/updates')}`,
    ...facts(),
    `Appcast: ${SITE.appcast}`,
    '',
    '---',
    ...releases.flatMap((r) => [
      '',
      `## ${r.id}: ${r.data.title}`,
      '',
      `Released ${day(r.data.date)}. ${abs(`/updates/${r.id}`)}`,
      '',
      (r.body ?? '').trim(),
    ]),
    ...footer(),
  ].join('\n');
};

export const markdownResponse = (body: string) =>
  new Response(body, { headers: { 'Content-Type': 'text/markdown; charset=utf-8' } });
