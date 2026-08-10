// ==========================================================================
// The changelog: one Markdown file per release, in src/content/releases/.
//
// THE FILENAME IS THE VERSION. `2026.32.2.md` is release 2026.32.2, and that
// is the only place the version is written down, so a note can't disagree with
// its own frontmatter. macos/scripts/release.sh looks the file up by the
// version it is about to publish and refuses to publish without it.
//
// Two consumers render from these files and nothing else:
//   pages/updates.astro              the changelog a person reads
//   pages/release-notes/[version]    the same notes, as the HTML fragment
//                                    Sparkle embeds in the in-app update dialog
//
// To add a release: write src/content/releases/<version>.md. Nothing else.
//
// HOUSE RULE, same as src/data/site.ts: no em dashes anywhere in copy. Use a
// colon, a full stop, a semicolon or parentheses instead.
// ==========================================================================
import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const releases = defineCollection({
  // `.md` only, and no subdirectories: the flat list is what makes the
  // filename-as-version rule hold.
  //
  // generateId is not optional here. The default slugifies the filename, which
  // eats the dots: `2026.32.2.md` would load with the id `2026322`, and every
  // version on the page and in the Sparkle lookup would be silently wrong in a
  // way that still builds. Keep the stem verbatim.
  loader: glob({
    pattern: '*.md',
    base: './src/content/releases',
    generateId: ({ entry }) => entry.replace(/\.md$/, ''),
  }),
  schema: z.object({
    /** Release date, ISO. Matches the appcast's pubDate for that version. */
    date: z.coerce.date(),
    /** The headline. A sentence fragment, not "Version 2026.32.2". */
    title: z.string().min(1),
    /** One line, used as the lead in the Sparkle dialog. Optional. */
    summary: z.string().optional(),
  }),
});

// ==========================================================================
// The legal pages, in src/content/legal/.
//
// THE FILENAME IS THE ROUTE. `privacy.md` is /privacy. pages/[legal].astro
// builds one page per file, so adding /security or /licences later is one
// Markdown file and nothing else: no route, no template, and no footer edit,
// because the footer reads this collection too.
//
// They are Markdown and not src/data/site.ts, unlike every other word on this
// site, because these are the pages most likely to be edited by someone who is
// not editing code, in a hurry, to correct something that has become untrue.
// Prose in a .md file can be fixed without opening a template.
//
// HOUSE RULE, same as everywhere else: no em dashes anywhere in copy.
// ==========================================================================
const legal = defineCollection({
  loader: glob({
    pattern: '*.md',
    base: './src/content/legal',
    generateId: ({ entry }) => entry.replace(/\.md$/, ''),
  }),
  schema: z.object({
    /** The <h1> and the <title>. */
    title: z.string().min(1),
    /** Meta description, and the standfirst under the heading. */
    description: z.string().min(1),
    /** Shown as "Last updated". Bump it whenever the text changes. */
    updated: z.coerce.date(),
    /** Label used in the site footer. */
    nav: z.string().min(1),
    /** Footer order. Lower sorts first. */
    order: z.number().default(100),
  }),
});

export const collections = { releases, legal };

/**
 * Sort key for CalVer strings (`2026.32.2`). Compares component by component
 * as integers, which is what Sparkle's own comparator does: string sort would
 * put 2026.29.10 before 2026.29.4, and date sort can't separate the three
 * releases that shipped on 2026-07-30.
 */
export function compareVersions(a: string, b: string): number {
  const pa = a.split('.').map(Number);
  const pb = b.split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}
