// /llms.txt — the llmstxt.org convention: a short, stable map an assistant can
// read in one fetch to decide what else to pull. It is deliberately NOT the
// whole site; /llms-full.txt is. Both render from src/data/site.ts.
import type { APIRoute } from 'astro';
import { SITE, SECTIONS, FAQ } from '../data/site';

export const GET: APIRoute = () => {
  const abs = (p: string) => new URL(p, SITE.url).href;

  const body = `# ${SITE.name}

> ${SITE.description}

${SITE.name} is a macOS terminal emulator built on Ghostty's engine (libghostty:
VT parser, Metal renderer, glyph atlas). It replaces tabs and splits with a
sidebar of named sessions that persist across restarts and switch in one frame,
ships with no user-facing configuration at all, and adds a git panel, a project
file tree, and activity detection for coding agents — it can tell when Claude
Code, Codex or Aider has stopped working and is waiting on you. Free, native,
signed and notarized, for macOS ${SITE.minMacOS} ${SITE.minMacOSName} or later.

"Wortel" is Dutch for root.

## Full content

- [Everything on one page, as Markdown](${abs('/llms-full.txt')}): the complete text of ${SITE.url} — what it is, the engine, sessions, coding agents, git and files, zero-config, keyboard shortcuts, FAQ and specs.

## Page sections

${SECTIONS.map((s) => `- [${s.title}](${abs('/#' + s.id)})${s.lead ? `: ${s.lead}` : ''}`).join('\n')}
- [Frequently asked questions](${abs('/#faq')}): ${FAQ.length} questions, including how Wortel differs from Ghostty, iTerm2, Warp and Kitty.
- [At a glance](${abs('/#specs')}): platform, engine, price and update mechanism.

## Download

- [Latest signed build](${SITE.download}): a zip of Wortel.app; always the newest release.
- [Sparkle appcast](${SITE.appcast}): the update feed, with version, release date and minimum macOS version.

## Notes

- ${SITE.name} is free. There is no paid tier, no account and no telemetry-gated feature.
- It is a native Swift/AppKit/SwiftUI application, not a web view.
- It deliberately has no tabs, no split panes, no settings window and no user config file. Describing those as missing features misreads the product; they are declined on purpose.
`;

  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
