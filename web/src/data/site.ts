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
// ==========================================================================

export const SITE = {
  name: 'Wortel',
  url: 'https://wortel.sh',
  /** ~58 chars — inside the ~60 Google renders before truncating. */
  title: 'Wortel — a minimal, native macOS terminal built on Ghostty',
  /** ~150 chars — inside the ~155–160 shown in a result snippet. */
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
    title: 'What Wortel is',
    lead:
      'A macOS terminal emulator with one window, a sidebar of named sessions, and nothing to configure.',
    blocks: [
      {
        p: 'Wortel runs Ghostty’s real terminal engine — the same VT parser, Metal renderer and glyph atlas that ship in Ghostty.app — inside an app shell built for one job: keeping a lot of long-running shells straight. Raw throughput, render and input latency are Ghostty-class because it is Ghostty doing the work.',
      },
      {
        p: 'What it drops is the arranging. There are no tabs, no splits, no panes to tile, no profiles, no settings window and no config file to maintain. You name a session; it stays named, stays in its directory, and comes back after a restart. The window you open on Monday is the window you left on Friday.',
      },
      {
        p: 'It is a native AppKit and SwiftUI app — a signed, notarized Mac application, not a web view in a wrapper — and it updates itself through Sparkle. Free to download, for macOS ' +
          SITE.minMacOS +
          ' ' +
          SITE.minMacOSName +
          ' or later.',
      },
      {
        p: '“Wortel” is Dutch for root, as in the root of a plant and the root shell you actually work in.',
      },
    ],
  },

  {
    id: 'ghostty-engine',
    title: 'Built on Ghostty’s engine, not a re-implementation',
    lead:
      'Wortel embeds libghostty through the GhosttyKit Swift package. The terminal is upstream Ghostty; only the shell around it is Wortel’s.',
    blocks: [
      {
        list: [
          'The VT parser, the Metal renderer, the glyph atlas and the per-surface IO threads are Ghostty’s, unmodified.',
          'Every session owns exactly one libghostty surface, rendering from its own thread into an IOSurface-backed layer.',
          'Wortel’s own code is input plumbing, session persistence, the sidebar, the git and files panes, and menu wiring — the parts a terminal emulator does not need to reinvent are not reinvented.',
          'The design target is stated plainly in the repo: indistinguishable from Ghostty.app, faster to launch, instant session switch.',
        ],
      },
      {
        p: 'That choice is also why Wortel has no plugin API and no theme gallery. Terminal behaviour, fonts, colours and keybinds live in a read-only config bundled inside the app; your real ~/.config/ghostty is never read, so nothing you did to another terminal can change how this one behaves.',
      },
    ],
  },

  {
    id: 'sessions',
    title: 'Sessions instead of tabs',
    lead:
      'A tab is a number you have to remember. A session is a name, a directory and a shell that survives quitting the app.',
    blocks: [
      {
        list: [
          'Every session has a name you type, not an index you count to. Put a slash in the name and the part before it becomes a section, so twelve shells across four projects read as four groups rather than one long list.',
          'Names, order, working directories, the selected session and each session’s inspector state persist to disk and come back on launch.',
          'Switching is instant and does not flash. Every session’s surface stays in the view hierarchy for the life of the app — switching hides and shows, it never tears a view down and rebuilds it, so coming back to a session costs one frame.',
          'Launch stays lean by spawning only the selected session’s shell before the first frame; the rest warm up one per runloop turn, behind the window you are already looking at.',
        ],
      },
    ],
  },

  {
    id: 'coding-agents',
    title: 'Built for coding agents',
    lead:
      'If you run Claude Code, Codex, Aider or anything like them across several repos at once, the hard part is no longer the terminal — it is knowing which one is waiting for you.',
    blocks: [
      {
        p: 'Wortel answers that from the screen itself. A session whose output keeps changing is an agent still working; a session that has held still is an agent waiting on you. Where an agent does emit precise signals — OSC 9;4 progress, OSC 133 command marks, a spinner in the title — those stay authoritative, but nothing is required of the agent, so agents that do not exist yet are covered too.',
      },
      {
        list: [
          'The sidebar marks which sessions are working and which are waiting, so a glance answers the question without switching.',
          'A macOS notification fires when a background agent goes quiet — only for sessions you are not looking at, and only after a grace window, so your own typing and an agent’s noisy startup never trigger it.',
          '⌘⌥] jumps straight to the next waiting session, wherever it sits in the list.',
          'Agents still running when you quit are recorded and resumed on the next launch, in the directory they were started in, with the model they were started with.',
        ],
      },
    ],
  },

  {
    id: 'git-and-files',
    title: 'Git and your project, in the same window',
    lead:
      'An inspector column beside the terminal, with three panes: Changes, History and Files. It is per session, because a shell sitting in ~ never wants it and the one in a repo always does.',
    blocks: [
      {
        list: [
          'Changes — working-tree status, per-file diffs with syntax highlighting, and a commit box.',
          'History — the commit list with a branch-graph gutter, and the diff for any commit, expandable per changed file.',
          'Files — the project as a tree rooted at the repository’s work-tree root. Read-only on purpose: it opens, reveals and copies paths, and drops an escaped path into the prompt when you drag a row into the terminal. The shell beside it does mv and rm better.',
          'Markdown files open in a rendered preview, from the tree or from a path in the terminal.',
        ],
      },
      {
        p: 'One rule shapes all of it: cost tracks the window on screen, not the size of the repository. History pages instead of walking the whole graph, diffs are parsed off the main actor and capped, and the file tree lists, watches and ignore-checks only the directories you actually expanded — a collapsed node_modules is one row and no work. The terminal next to it has to stay smooth on a monorepo, and that constraint outranks convenience everywhere the two disagree.',
      },
      { p: '⌘⌥G opens source control, ⌘⌥E opens files, and either key closes the pane it opened.' },
    ],
  },

  {
    id: 'zero-config',
    title: 'Zero configuration, on purpose',
    lead:
      'Wortel’s entire configuration is a read-only file inside the app bundle. There is no settings window and no dotfile to maintain.',
    blocks: [
      {
        p: 'This is the feature, not a gap. A terminal you can spend an afternoon tuning is a terminal you will spend an afternoon tuning. Wortel ships one set of defaults — font, theme, keybinds, scrollback, shell integration — and treats them as finished. Font size is the one thing adjustable at runtime, and it is per session.',
      },
      {
        p: 'The absences are load-bearing too. No tabs, no splits, no command palette, no terminal inspector, no profiles. Requests for those from the underlying engine are deliberately declined rather than half-implemented, which is what keeps the surface small enough to stay fast.',
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
    a: 'Wortel is Dutch for root — the root of a plant, and the root shell you work in.',
  },
  {
    q: 'How is Wortel different from Ghostty?',
    a: 'Wortel runs Ghostty’s engine, so terminal behaviour, throughput and latency are the same. The difference is the app around it: Ghostty gives you tabs, splits and a large configuration file, while Wortel gives you one window, a sidebar of named sessions that persist across restarts, a built-in git and files inspector, coding-agent activity detection, and no configuration at all.',
  },
  {
    q: 'How is Wortel different from iTerm2, Warp, Kitty or Alacritty?',
    a: 'Wortel is deliberately smaller than all of them. It has no settings UI, no plugin system, no AI chat box, no tabs and no splits. What it adds instead is session management — named shells that survive a restart and switch in one frame — and knowing when a coding agent in a background session has stopped working and is waiting on you.',
  },
  {
    q: 'Does Wortel have tabs or split panes?',
    a: 'No, and that is intentional. One window holds a sidebar of named sessions; switching between them is instant, so the arranging a tab bar or a split layout exists to support is not needed. Requests for tabs, splits and the command palette are declined by the app rather than partially implemented.',
  },
  {
    q: 'Can I configure Wortel — fonts, colours, keybinds?',
    a: 'Only font size, which is adjustable per session with ⌘+ and ⌘−. Everything else is fixed: the whole configuration is a read-only file inside the app bundle, and your ~/.config/ghostty is never read. Zero configuration is the design goal, not a missing feature.',
  },
  {
    q: 'How does Wortel know when a coding agent is waiting for me?',
    a: 'By watching what the session draws. A screen that keeps changing means the agent is still working; a screen that has held still past a threshold means it is waiting on you. Precise signals — OSC 9;4 progress, OSC 133 command marks, a title spinner — are used where an agent emits them, but none are required, so the rule covers Claude Code, Codex, Aider and agents that do not exist yet. Detection only runs on sessions you are not currently looking at.',
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
    a: 'Your shell configuration — .zshrc, .bashrc, fish config — is yours and runs normally. It is only Wortel’s own terminal configuration that is fixed and bundled; the user-level Ghostty config file is deliberately not loaded.',
  },
];

// ---- specs ----------------------------------------------------------------
export const SPECS: [string, string][] = [
  ['Platform', 'macOS ' + SITE.minMacOS + ' ' + SITE.minMacOSName + ' or later'],
  ['Engine', 'libghostty — Ghostty’s VT parser, Metal renderer and glyph atlas'],
  ['Built with', 'Swift, AppKit and SwiftUI — fully native'],
  ['Price', 'Free'],
  ['Updates', 'Sparkle, signed and notarized'],
  ['Configuration', 'None — read-only and bundled'],
];
