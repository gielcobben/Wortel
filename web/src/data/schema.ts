// The homepage's structured data: one @graph so crawlers resolve the @id
// cross-references (the app is the page's mainEntity, the person publishes
// both). FAQ answers come from site.ts, the same sentences the page renders.
import { SITE, FAQ } from './site';
import type { Release } from './release';

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
    ...(LATEST?.version && { softwareVersion: LATEST.version }),
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
      'Named, persistent terminal sessions instead of tabs',
      'Instant session switching with no flash or rebuild',
      'Runs Ghostty’s VT parser, Metal renderer and glyph atlas via libghostty',
      'A git worktree per session, so several coding agents can share one repository',
      'Shells run outside the app and keep working after you quit or it crashes',
      'Activity detection for coding agents such as Claude Code, Codex and Aider',
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
      acceptedAnswer: { '@type': 'Answer', text: item.a },
    })),
    primaryImageOfPage: { '@type': 'ImageObject', url: abs('/og.png') },
    inLanguage: 'en',
  };


  return [website, webpage, person, app];
}
