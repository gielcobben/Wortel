// ==========================================================================
// The site's content, in one place.
//
// Three consumers render from this module and nothing else:
//   pages/index.astro    the page a person reads
//   pages/llms.txt.ts    the short map a model fetches first
//   pages/llms-full.txt.ts   the same content as plain Markdown
// plus the JSON-LD in layouts/Layout.astro, which derives its featureList and
// FAQPage entries from FEATURES/FAQ below.
//
// The point of the single source is that the three can't drift: an answer a
// model reads out of llms-full.txt is the same sentence a person reads on the
// page, and the structured data can't advertise a feature the copy dropped.
// Add content HERE, not in the templates.
//
// HOUSE RULE: no em dashes anywhere in copy. Use a colon, a full stop, a
// semicolon or parentheses instead. This applies to every string in this file,
// to the templates, and to any HTML comment that ships in the build.
// ==========================================================================

export const SITE = {
  name: 'Wortel',
  url: 'https://wortel.sh',
  /** ~56 chars, inside the ~60 Google renders before truncating. */
  title: 'Wortel: a minimal, native macOS terminal built on Ghostty',
  /** ~150 chars, inside the ~155-160 shown in a result snippet. */
  description:
    'A zero-config macOS terminal on Ghostty’s real engine. Named sessions instead of tabs, instant launch and switching, with git, files and coding agents built in.',
  tagline: 'A minimal, native macOS terminal.',
  author: 'Giel Cobben',
  /** release.sh --publish always mirrors the newest signed zip here. */
  download: 'https://updates.wortel.sh/Wortel-latest.zip',
  appcast: 'https://updates.wortel.sh/appcast.xml',
  /** Sparkle's minimumSystemVersion, minus the ".0" that reads as noise. */
  minMacOS: '14',
  minMacOSName: 'Sonoma',
} as const;

// ---- the five-line summary in the hero's left column ----------------------
// Short enough to sit in a 96px/1fr grid; these are the deck, not the article.
export const FEATURES: [string, string][] = [
  ['Sessions', 'Named, not numbered'],
  ['Launch', 'Cold start stays lean'],
  ['Switching', 'One frame, no flash'],
  ['No config', 'No tabs, splits, or settings'],
  ['Engine', 'Ghostty VT parser + Metal'],
];

// ---- the prose below the fold ---------------------------------------------
// A block is one of: a paragraph, a bullet list, or a two-column table. Keeping
// the shape this narrow is what lets llms-full.txt.ts render Markdown from the
// same array without a second copy of the copy.
export type Block =
  | { p: string }
  | { list: string[] }
  | { table: { head: [string, string]; rows: [string, string][] } };

export type Section = {
  id: string;
  title: string;
  lead?: string;
  blocks: Block[];
};

export const SECTIONS: Section[] = [
  {
    id: 'what-is-wortel',
    title: 'A terminal you never have to arrange',
    lead: 'One window. A sidebar of names. Nothing to set up, and nothing to tidy.',
    blocks: [
      {
        p: 'Wortel is a native macOS terminal built on Ghostty’s engine. Open it and the work is where you left it: every session still named, still in its own directory. No tabs to count, no panes to tile, no profiles to keep in step.',
      },
      {
        p: 'Free, signed and notarized, for macOS ' +
          SITE.minMacOS +
          ' ' +
          SITE.minMacOSName +
          ' or later. Wortel is Dutch for root.',
      },
    ],
  },

  {
    id: 'ghostty-engine',
    title: 'Ghostty’s engine, exactly as it ships',
    lead: 'The terminal inside Wortel is Ghostty. Not a port of it. Not inspired by it.',
    blocks: [
      {
        p: 'Wortel embeds libghostty, so the VT parser, the Metal renderer and the glyph atlas are upstream’s, unmodified. Its own code is only the shell around them.',
      },
      {
        p: 'Which is why there is no plugin API and no theme gallery. Fonts, colours and keybinds live in a read-only file inside the app; your ~/.config/ghostty is never read.',
      },
    ],
  },

  {
    id: 'sessions',
    title: 'Sessions, not tabs',
    lead: 'A tab is a number you have to remember. A session is a name you chose.',
    blocks: [
      {
        p: 'Name a session and it keeps the name. Put a slash in it and everything before the slash becomes a section, so twelve shells across four projects read as four groups. Names, directories and selection come back on launch.',
      },
      {
        p: 'Switching costs a single frame, because every surface stays alive inside the window. Only the one you had selected starts before the first frame; the rest warm up behind it.',
      },
    ],
  },

  {
    id: 'coding-agents',
    title: 'A coding agent in every session',
    lead:
      'Hand one repository to Claude Code, another to Codex, a third to Aider, and the terminal stops being the hard part. Knowing which one needs you becomes the hard part.',
    blocks: [
      {
        p: 'Wortel reads that off the screen. Output that keeps moving is an agent working; a screen gone still is one waiting on you. Where an agent announces itself, with OSC 9;4 progress or a spinner in the title, Wortel takes its word for it. Where it says nothing, which is most of them, Wortel still knows.',
      },
      {
        p: 'The sidebar marks what is working and what is waiting. A notification arrives when a background agent goes quiet, never for the session in front of you. ⌘⌥] jumps to the next one waiting, and anything still running when you quit is picked back up on the next launch.',
      },
    ],
  },

  {
    id: 'git-and-files',
    title: 'Your repository, in the same window',
    lead: 'An inspector beside the terminal, with three panes: Changes, History and Files.',
    blocks: [
      {
        p: 'Changes is the worktree file by file, with syntax-highlighted diffs and somewhere to write the commit. History is the commit list with its branch graph. Files is the project as a tree: drag a row into the terminal and the escaped path lands at your prompt.',
      },
      {
        p: 'It belongs to the session, because a shell in your home directory never wants it and one inside a repository always does. Cost tracks the window on screen, never the size of the repository: a collapsed node_modules is one row and no work at all.',
      },
    ],
  },

  {
    id: 'zero-config',
    title: 'Nothing to configure, on purpose',
    lead:
      'Wortel’s entire configuration is one read-only file inside the app. There is no settings window, and there is no dotfile.',
    blocks: [
      {
        p: 'This is the feature. A terminal you can spend an afternoon tuning is a terminal you will. Wortel chooses the font, the theme, the keybinds and the scrollback once, and treats them as finished. Font size is the one thing you can change.',
      },
    ],
  },

  {
    id: 'keyboard',
    title: 'Keyboard shortcuts',
    blocks: [
      {
        table: {
          head: ['Shortcut', 'Action'],
          rows: [
            ['⌘N or ⌘T', 'New session'],
            ['⌘⇧N', 'New section'],
            ['⌘R', 'Rename session'],
            ['⌘W', 'Close session'],
            ['⌘⇧[ / ⌘⇧]', 'Previous / next session'],
            ['⌘⌥↑ / ⌘⌥↓', 'Previous / next session'],
            ['⌘1 … ⌘9', 'Jump to session by position'],
            ['⌘⌥]', 'Jump to the next waiting session'],
            ['⌘⌥G', 'Show source control'],
            ['⌘⌥E', 'Show files'],
            ['⌘⌥S', 'Toggle sidebar'],
            ['⌘⌥L', 'Focus the source-control list'],
            ['⌘+ / ⌘− / ⌘0', 'Increase / decrease / reset font size'],
            ['⌘⇧A', 'Select all (⌘A clears the input line)'],
          ],
        },
      },
    ],
  },
];

// ---- FAQ ------------------------------------------------------------------
// Also the source for the FAQPage JSON-LD. Answers are written to stand alone:
// each one has to make sense as a snippet quoted with no page around it.
export const FAQ: { q: string; a: string }[] = [
  {
    q: 'What is Wortel?',
    a: 'Wortel is a minimal, native macOS terminal emulator built on Ghostty’s engine. It replaces tabs and splits with a sidebar of named, persistent sessions, ships with no configuration to maintain, and includes a git panel, a file tree and activity detection for coding agents.',
  },
  {
    q: 'Is Wortel free?',
    a: 'Yes. Wortel is a free download for macOS ' + SITE.minMacOS + ' or later, and updates itself through Sparkle.',
  },
  {
    q: 'What does “Wortel” mean?',
    a: 'Wortel is Dutch for root: the root of a plant, and the root shell you work in.',
  },
  {
    q: 'How is Wortel different from Ghostty?',
    a: 'Wortel runs Ghostty’s engine, so terminal behaviour, throughput and latency are the same. The difference is the app around it: Ghostty gives you tabs, splits and a large configuration file, while Wortel gives you one window, a sidebar of named sessions that persist across restarts, a built-in git and files inspector, coding-agent activity detection, and no configuration at all.',
  },
  {
    q: 'How is Wortel different from iTerm2, Warp, Kitty or Alacritty?',
    a: 'Wortel is deliberately smaller than all of them. It has no settings UI, no plugin system, no AI chat box, no tabs and no splits. What it adds instead is session management (named shells that survive a restart and switch in one frame) plus knowing when a coding agent in a background session has stopped working and is waiting on you.',
  },
  {
    q: 'Does Wortel have tabs or split panes?',
    a: 'No, and that is intentional. One window holds a sidebar of named sessions; switching between them is instant, so the arranging a tab bar or a split layout exists to support is not needed. Requests for tabs, splits and the command palette are declined by the app rather than partially implemented.',
  },
  {
    q: 'Can I configure Wortel’s fonts, colours and keybinds?',
    a: 'Only font size, which is adjustable per session with ⌘+ and ⌘−. Everything else is fixed: the whole configuration is a read-only file inside the app bundle, and your ~/.config/ghostty is never read. Zero configuration is the design goal, not a missing feature.',
  },
  {
    q: 'How does Wortel know when a coding agent is waiting for me?',
    a: 'By watching what the session draws. A screen that keeps changing means the agent is still working; a screen that has held still past a threshold means it is waiting on you. Precise signals (OSC 9;4 progress, OSC 133 command marks, a title spinner) are used where an agent emits them, but none are required, so the rule covers Claude Code, Codex, Aider and agents that do not exist yet. Detection only runs on sessions you are not currently looking at.',
  },
  {
    q: 'Does Wortel work with Claude Code, Codex and Aider?',
    a: 'Yes. They run as ordinary shell commands in any session. Beyond that, Wortel marks in the sidebar which agents are working and which are waiting, notifies you when a background agent goes quiet, jumps to the next waiting session with ⌘⌥], and resumes agents that were still running when you last quit.',
  },
  {
    q: 'What are the system requirements?',
    a: 'macOS ' + SITE.minMacOS + ' ' + SITE.minMacOSName + ' or later. Wortel is a signed and notarized native application; the download is roughly 17 MB.',
  },
  {
    q: 'Does Wortel read my existing shell configuration?',
    a: 'Your shell configuration (.zshrc, .bashrc, fish config) is yours and runs normally. It is only Wortel’s own terminal configuration that is fixed and bundled; the user-level Ghostty config file is deliberately not loaded.',
  },
];

// ---- specs ----------------------------------------------------------------
export const SPECS: [string, string][] = [
  ['Platform', 'macOS ' + SITE.minMacOS + ' ' + SITE.minMacOSName + ' or later'],
  ['Engine', 'libghostty: Ghostty’s VT parser, Metal renderer and glyph atlas'],
  ['Built with', 'Swift, AppKit and SwiftUI, fully native'],
  ['Price', 'Free'],
  ['Updates', 'Sparkle, signed and notarized'],
  ['Configuration', 'None: read-only and bundled'],
];
