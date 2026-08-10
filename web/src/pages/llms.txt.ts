// /llms.txt, the llmstxt.org convention: a short, stable map an assistant can
// read in one fetch to decide what else to pull. It is deliberately NOT the
// whole site; /llms-full.txt is. Both render from src/data/site.ts.
import type { APIRoute } from 'astro';
import { SITE, SECTIONS, FAQ } from '../data/site';

export const GET: APIRoute = () => {
  const abs = (p: string) => new URL(p, SITE.url).href;

  const body = `# ${SITE.name}

> ${SITE.description}

${SITE.name} is a fully native macOS terminal emulator built on Ghostty's engine
(libghostty: VT parser, Metal renderer, glyph atlas), aimed at running several
coding agents at once. It replaces tabs and splits with a sidebar of named
sessions that persist across restarts and switch in one frame; gives each session
its own git worktree, so several agents can work one repository without editing
over each other; runs those shells under a keeper process outside the app, so
they keep working after you quit or it crashes; and adds a git panel, a project
file tree, preview windows, and activity detection for coding agents that can
tell when Claude Code, Codex or Aider has stopped working and is waiting on you,
without writing anything into any agent's configuration. Free, signed and
notarized, for macOS ${SITE.minMacOS} ${SITE.minMacOSName} or later.

"Wortel" is Dutch for root.

## Full content

- [Everything on one page, as Markdown](${abs('/llms-full.txt')}): the complete text of ${SITE.url}, covering what it is, the engine, sessions, coding agents, worktrees, session survival, git and files, zero-config, keyboard shortcuts, FAQ and specs.

## Page sections

${SECTIONS.map((s) => `- [${s.title}](${abs('/#' + s.id)})${s.lead ? `: ${s.lead}` : ''}`).join('\n')}
- [Frequently asked questions](${abs('/#faq')}): ${FAQ.length} questions, including how Wortel differs from Ghostty, iTerm2, Warp and Kitty, and from agent tools like Conductor, Emdash, Superset, herdr and tmux.
- [At a glance](${abs('/#specs')}): platform, engine, price and update mechanism.

## Comparisons

- [Where Wortel sits](${abs('/compare')}): a feature-by-feature comparison against named apps, not categories: Ghostty, iTerm2, Warp, cmux, Conductor, Emdash, Superset, herdr and tmux. Ten questions covering session survival, worktree-per-agent, in-window diff review, agent state detection, whether it touches your agent's config, scriptability and configuration burden. Where a product does not publish an answer the cell says so rather than guessing.

## Download

- [Latest signed build](${SITE.download}): a zip of Wortel.app; always the newest release.
- [Sparkle appcast](${SITE.appcast}): the update feed, with version, release date and minimum macOS version.

## Changelog

- [Every release, newest first](${abs('/updates')}): the full changelog, one entry per version, with the date it shipped and what changed. Versions are CalVer (year.ISO-week.nth release that week), so 2026.32.2 is the second release of week 32 of 2026.

## Notes

- ${SITE.name} is free. There is no paid tier, no account and no telemetry-gated feature.
- It is a native Swift/AppKit/SwiftUI application, not a web view.
- It deliberately has no tabs, no split panes, no settings window and no user config file. Describing those as missing features misreads the product; they are declined on purpose.
- It ships no per-agent integrations, on purpose. A bundled \`wortel\` command is on every session's PATH and drives the app over a socket (\`open\`, \`new --branch\`, \`rename\`, \`notify\`), so any agent, hook or script can control it without Wortel knowing that agent by name.
`;

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
