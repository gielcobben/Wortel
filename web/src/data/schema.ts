// The homepage's structured data: one @graph so crawlers resolve the @id
// cross-references (the app is the page's mainEntity, the person publishes
// both). FAQ answers come from site.ts, the same sentences the page renders.
import { SITE, FAQ } from './site';
import { plain } from './inline';
import type { Release } from './release';

/** GPL-3.0-or-later, by its SPDX address. */
const LICENSE = 'https://spdx.org/licenses/GPL-3.0-or-later.html';

export function homeSchema(LATEST: Release | null) {
  const abs = (p: string) => new URL(p, SITE.url).href;

  const person = {
    '@type': 'Person',
    '@id': abs('/#author'),
    name: SITE.author,
    url: SITE.authorUrl,
  };

  const app = {
    '@type': 'SoftwareApplication',
    '@id': abs('/#app'),
    name: SITE.name,
    alternateName: 'Wortel Terminal',
    description: SITE.description,
    applicationCategory: 'DeveloperApplication',
    applicationSubCategory: 'Terminal Emulator',
    operatingSystem: `macOS ${SITE.minMacOS}.0 or later`,
    softwareRequirements: `macOS ${SITE.minMacOS} ${SITE.minMacOSName} or later`,
    url: SITE.url,
    downloadUrl: SITE.download,
    installUrl: SITE.url,
    screenshot: abs('/og.png'),
    image: abs('/og.png'),
    author: { '@id': person['@id'] },
    publisher: { '@id': person['@id'] },
    ...(LATEST?.version && { softwareVersion: LATEST.version, releaseNotes: abs(`/updates/${LATEST.version}`) }),
    isAccessibleForFree: true,
    license: LICENSE,
    sameAs: [SITE.repo],
    ...(LATEST?.date && { datePublished: LATEST.date }),
    ...(LATEST?.size && { fileSize: LATEST.size }),
    offers: {
      '@type': 'Offer',
      price: '0',
      priceCurrency: 'USD',
      availability: 'https://schema.org/InStock',
      url: SITE.url,
    },
    featureList: [
      'A real terminal first: an agent is one more command, and a new session can start yours',
      'Named, persistent terminal sessions instead of tabs',
      'Instant session switching with no flash or rebuild',
      'Runs Ghostty’s VT parser, Metal renderer and glyph atlas via libghostty',
      'A git worktree per session, so several coding agents can share one repository',
      'Shells run outside the app and keep working after you quit or it crashes',
      'More than one window, with sessions that move between them',
      'Shows what Claude Code, Codex, Pi and other agents report they are doing',
      'Notifies you when a background agent stops working and waits on you',
      'Resumes agents that were still running at quit',
      'Built-in git panel: working-tree changes, commit history with a branch graph, and diffs',
      'Project file tree with drag-to-terminal path insertion',
      'Preview windows for source, diffs, rendered Markdown and Quick Look',
      'A bundled wortel command that scripts the app over a socket, with no installer',
      'Almost nothing to configure: five settings and no dotfile',
    ],
  };

  const website = {
    '@type': 'WebSite',
    '@id': abs('/#website'),
    url: SITE.url,
    name: SITE.name,
    description: SITE.description,
    inLanguage: 'en',
    publisher: { '@id': person['@id'] },
  };

  const webpage = {
    '@type': ['WebPage', 'FAQPage'],
    '@id': abs('/#webpage'),
    url: SITE.url,
    name: SITE.title,
    description: SITE.description,
    isPartOf: { '@id': website['@id'] },
    about: { '@id': app['@id'] },
    mainEntity: FAQ.map((item) => ({
      '@type': 'Question',
      name: item.q,
      acceptedAnswer: { '@type': 'Answer', text: plain(item.a) },
    })),
    primaryImageOfPage: { '@type': 'ImageObject', url: abs('/og.png') },
    inLanguage: 'en',
  };


  // The source, as its own node: what it is written in, where it is, under
  // which licence, and which app it builds.
  const source = {
    '@type': 'SoftwareSourceCode',
    '@id': abs('/#source'),
    name: `${SITE.name} source code`,
    codeRepository: SITE.repo,
    programmingLanguage: 'Swift',
    runtimePlatform: 'macOS',
    license: LICENSE,
    author: { '@id': person['@id'] },
    targetProduct: { '@id': app['@id'] },
  };

  return [website, webpage, person, app, source];
}
