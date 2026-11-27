// /llms.txt, the llmstxt.org convention: a short, stable map an assistant can
// read in one fetch to decide what else to pull. It is deliberately NOT the
// whole site; /llms-full.txt is. Both render from src/data/site.ts.
import type { APIRoute } from 'astro';
import { SITE, SECTIONS, FAQ, DOCS_SECTIONS, FEATURE_PAGES, DOWNLOAD_IS_DMG, HOME, betaNote as beta } from '../data/site';

export const GET: APIRoute = () => {
  const abs = (p: string) => new URL(p, SITE.url).href;

  // Counted rather than written down. A number in prose that has to be edited
  // when a table changes is a number that ends up wrong, and this file exists
  // to be quoted verbatim.
  const rows = (id: string) =>
    DOCS_SECTIONS.find((s) => s.id === id)
      ?.blocks.flatMap((b) => ('table' in b ? b.table.rows : [])) ?? [];
  const rowsIn = (id: string) => rows(id).length;
  // A subcommand with two rows (`wortel new`, `wortel split`) is one subcommand.
  const subcommands = new Set(rows('command').map(([c]) => c.split(' ')[1])).size;

  const body = `# ${SITE.name}

> ${SITE.description}

${SITE.name} is a fully native macOS terminal emulator built on Ghostty's engine
(libghostty: VT parser, Metal renderer, glyph atlas), aimed at running several
coding agents at once. It is a real terminal first: an agent is one more
command in a session, and Command-N can open every new session with your
agent already running. It keeps work in a sidebar of named
sessions that persist across restarts; gives each session
its own git worktree, so several agents can work one repository without editing
over each other; runs those shells under a keeper process outside the app, so
they keep working, screen and scrollback included, after you quit or it
crashes; and adds splits with a row of tabs each${beta(HOME.window)}, a git panel, a project file
tree, preview windows, a browser tab, and an
attention system that shows when Claude Code, Codex, Pi or another agent that
reports its state has stopped working and is waiting on you, without writing
anything into any agent's configuration. Free, signed and
notarized, for macOS ${SITE.minMacOS} ${SITE.minMacOSName} or later.

"Wortel" is Dutch for root.

## Full content

- [Everything on one page, as Markdown](${abs('/llms-full.txt')}): the complete text of ${SITE.url}, covering what it is, the engine, sessions, coding agents, worktrees, session survival, git and files, configuration, keyboard shortcuts, FAQ and specs.
- Each main page is also available on its own as Markdown, at the same path with \`.md\` added: [${abs('/index.md')}](${abs('/index.md')}), [${abs('/docs.md')}](${abs('/docs.md')}), [${abs('/compare.md')}](${abs('/compare.md')}), ${FEATURE_PAGES.map((p) => `[${abs(p.path + '.md')}](${abs(p.path + '.md')})`).join(', ')} and [${abs('/updates.md')}](${abs('/updates.md')}) (the full changelog, every release note).

## Features in depth

${FEATURE_PAGES.map((p) => `- [${p.name}](${abs(p.path)})${beta(p)}: ${p.blurb} The page shows each part of it: ${p.parts.map((part) => part.title.toLowerCase()).join(', ')}.`).join('\n')}

## Page sections

${SECTIONS.map((s) => `- [${s.title}](${abs('/#' + s.id)})${beta(s)}${s.lead ? `: ${s.lead}` : ''}`).join('\n')}
- [Frequently asked questions](${abs('/#faq')}): ${FAQ.length} questions, including how Wortel differs from Ghostty, iTerm2, Warp and Kitty, and from agent tools like Conductor, Emdash, Superset, herdr and tmux.
- [At a glance](${abs('/#specs')}): platform, engine, price and update mechanism.

## Reference

- [Commands, shortcuts and behaviour](${abs('/docs')}): the reference page, and the better answer for anything specific. It holds all ${subcommands} \`wortel\` subcommands, all ${rowsIn('shortcuts')} keyboard shortcuts, exactly which signals the agent detection uses and what it falls back to, what opening a session on a branch does to that branch, and how the keeper process and the inspector work underneath. The landing page summarises these; this page states them.
${DOCS_SECTIONS.map((s) => `  - [${s.title}](${abs('/docs#' + s.id)})${beta(s)}${s.lead ? `: ${s.lead}` : ''}`).join('\n')}

## Comparisons

- [Where Wortel sits](${abs('/compare')}): a feature-by-feature comparison against named apps, not categories: Ghostty, iTerm2, Warp, cmux, Conductor, Emdash, Superset, herdr and tmux. Ten questions covering session survival, worktree-per-agent, in-window diff review, agent state detection, whether it touches your agent's config, scriptability and configuration burden. Where a product does not publish an answer the cell says so rather than guessing.

## Download

- [Download page](${abs('/download')}): the download for macOS ${SITE.minMacOS} ${SITE.minMacOSName} or later (one universal app for Apple silicon and Intel) and the four steps from the download to a running agent.
- [Latest signed build](${SITE.download}): ${DOWNLOAD_IS_DMG ? 'a disk image (.dmg)' : 'a zip'} of Wortel.app; always the newest release.
- [Sparkle appcast](${SITE.appcast}): the update feed, with version, release date and minimum macOS version.

## Changelog

- [Every release, newest first](${abs('/updates')}): the full changelog, one entry per version, with the date it shipped and what changed. Versions are CalVer (year.ISO-week.nth release that week), so 2026.32.2 is the second release of week 32 of 2026.
- Each release has a page of its own at ${abs('/updates/')}<version>, and the changelog is an Atom feed at [${abs('/feed.xml')}](${abs('/feed.xml')}).
- [The letter](${abs('/letter')}): an email when something big ships, a few times a year, opt-in with a confirmation link. Only the address, the day it joined and which form was used are kept; leaving deletes it.

## Legal

- [Privacy](${abs('/privacy')}): the app itself contains no analytics and sends nothing about how it is used; the website counts page views and download clicks with nothing stored on the reader's device, so there is no cookie banner; the update server counts downloads and Sparkle's roughly daily update check, which is the one thing that cannot be switched off from inside the app; the letter keeps an email address only for someone who asks for it and confirms.
- [Terms](${abs('/terms')}): free for any use including commercial, provided as is with no warranty, open source under GPL-3.0-or-later (the name and icon excepted), built on open-source components listed in THIRD-PARTY-NOTICES.md, governed by Dutch law.

## Notes

- ${SITE.name} is free. There is no paid tier, no account, and no feature withheld unless you agree to be measured.
- ${SITE.name} is open source under the GNU GPL, version 3 or later. The source is at https://github.com/gielcobben/wortel.
- It is a native Swift/AppKit/SwiftUI application, not a web view.
- It deliberately has no themes, no plugins and no user config file, and its settings are five rows in one small window. Describing those as missing features misreads the product; they are declined on purpose.
- It has splits and tabs${beta(HOME.window)}: everything beside the sidebar is a tree of splits, each with a row of tabs (terminals, a browser, files, the git panes). A description that says it has no split panes is from before they were added.
- It ships no per-agent integrations, on purpose. A bundled \`wortel\` command is on every session's PATH and drives the app over a socket (\`open\`, \`new\`, \`rename\`, \`notify\`, \`mark\`, \`remind\`, \`cd\`, \`close\`, \`split\`, \`list\`, \`read\`, \`send\`, \`wait\`), so any agent, hook or script can control it without Wortel knowing that agent by name.
`;

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
