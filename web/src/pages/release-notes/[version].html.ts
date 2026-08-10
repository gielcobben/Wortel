// The same release notes as /updates, one standalone HTML file per version,
// for Sparkle's in-app update dialog.
//
// macos/scripts/release.sh copies dist/release-notes/<version>.html next to the
// archive in macos/releases/ before running generate_appcast, which embeds any
// same-named .html as CDATA in the appcast item (it treats a file with no
// DOCTYPE or <body> as a fragment, which is why this emits neither). That is
// what puts the notes inside the dialog rather than behind a network fetch, so
// they render on a machine that is offline or behind a captive portal.
//
// Styling has to travel with the fragment: the dialog is a plain WKWebView with
// no stylesheet of ours. It is deliberately minimal, and follows the system
// appearance rather than the site's palette, because it is Sparkle's window and
// should look like it.
import type { APIRoute, GetStaticPaths } from 'astro';
import { getCollection } from 'astro:content';

const STYLE = `
  :root { color-scheme: light dark; }
  body {
    font: 13px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    margin: 0; padding: 12px 14px;
    color: #16171b; background: transparent;
  }
  @media (prefers-color-scheme: dark) { body { color: #e8e8ea; } }
  h1 { font-size: 15px; font-weight: 600; margin: 0 0 2px; }
  .date { font-size: 11px; opacity: 0.55; margin: 0 0 12px; }
  p { margin: 0 0 10px; }
  ul { margin: 0 0 10px; padding-left: 18px; }
  li { margin-bottom: 5px; }
  strong { font-weight: 600; }
  code {
    font: 11.5px ui-monospace, "SF Mono", Menlo, monospace;
    padding: 1px 4px; border-radius: 4px;
    background: color-mix(in srgb, currentColor 10%, transparent);
  }
  a { color: #0070f5; }
`;

export const getStaticPaths: GetStaticPaths = async () => {
  const releases = await getCollection('releases');
  return releases.map((entry) => ({ params: { version: entry.id }, props: { entry } }));
};

export const GET: APIRoute = ({ props }) => {
  const { entry } = props as { entry: Awaited<ReturnType<typeof getCollection<'releases'>>>[number] };

  // The glob loader renders Markdown at load time and keeps the HTML on the
  // entry. Empty would mean a note whose body is blank, which should never
  // reach a release: fail the build here rather than ship an empty dialog.
  const html = entry.rendered?.html;
  if (!html) {
    throw new Error(
      `Release note ${entry.id} rendered to nothing. ` +
        `src/content/releases/${entry.id}.md needs a body below its frontmatter.`,
    );
  }

  const date = entry.data.date.toISOString().slice(0, 10);
  const body = `<style>${STYLE}</style>
<h1>${entry.data.title}</h1>
<p class="date">Wortel ${entry.id} &middot; ${date}</p>
${html}`;

  return new Response(body, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
};
