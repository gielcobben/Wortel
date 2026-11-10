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
// The one exception is the changelog, which is per-release rather than standing
// copy and lives in src/content/releases/ as one Markdown file per version. See
// src/content.config.ts.
//
// HOUSE RULE: no em dashes anywhere in copy. Use a colon, a full stop, a
// semicolon or parentheses instead. This applies to every string in this file,
// to the templates, and to any HTML comment that ships in the build.
// ==========================================================================

export const SITE = {
  name: 'Wortel',
  url: 'https://wortel.sh',
  /** ~48 chars, inside the ~60 Google renders before truncating. */
  title: 'Wortel: a native macOS terminal for coding agents',
  /** ~151 chars, inside the ~155-160 shown in a result snippet. */
  description:
    'A zero-config macOS terminal on Ghostty’s real engine. Named sessions instead of tabs, a worktree per agent, and shells that keep running when you quit.',
  tagline: 'A native macOS terminal your agents can live in.',
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
  ['Agents', 'Told apart at a glance'],
  ['Worktrees', 'One repo, no collisions'],
  ['Survival', 'Quit, and they keep going'],
  ['Engine', 'Ghostty VT parser + Metal'],
];

// ---- the prose below the fold ---------------------------------------------
// A block is one of: a paragraph, a bullet list, or a two-column table. Keeping
// the shape this narrow is what lets llms-full.txt.ts render Markdown from the
// same array without a second copy of the copy.
export type Block =
  | { p: string }
  | { list: string[] }
  | {
      table: {
        head: [string, string];
        rows: [string, string][];
        /** Which column holds literal keys/values and is set in mono. */
        mono?: 'first' | 'last';
      };
    };

export type Section = {
  id: string;
  title: string;
  lead?: string;
  blocks: Block[];
};

// THE HOMEPAGE IS THE PITCH, NOT THE MANUAL. Each section makes its point once
// and stops. Reference material (the command list, the shortcut table) and the
// second and third pass at a mechanism live on /docs, in DOCS_SECTIONS below,
// which is a page rather than a footnote: it is linked, indexed, and in
// llms-full.txt like everything else. When a paragraph here starts explaining
// HOW something works rather than what it does for you, it belongs over there.
export const SECTIONS: Section[] = [
  {
    id: 'what-is-wortel',
    title: 'A terminal you never have to arrange',
    lead: 'One window. A sidebar of names. Several agents, none of them in each other’s way.',
    blocks: [
      {
        p: 'Wortel is a fully native macOS terminal built on Ghostty’s engine: Swift and AppKit, no web view. Open it and the work is where you left it, every session still named and still in its own directory. No grid of panes to tile.',
      },
      {
        p: 'Point it at a repository and each agent gets its own branch and its own files, with the diff of what they did beside them. None of it stops when you quit.',
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
        p: 'Which is why there is no plugin API and no theme gallery. Fonts, colours and keybinds live in a read-only file inside the app, and your ~/.config/ghostty is never read.',
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
        p: 'Switching costs a single frame, because every surface stays alive inside the window.',
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
        p: 'Wortel reads that off the screen. Output that keeps moving is an agent working; a screen gone still is one waiting on you. Where an agent announces itself Wortel takes its word for it, and where it says nothing, which is most of them, Wortel still knows.',
      },
      {
        p: 'The sidebar marks what is working and what is waiting, a notification arrives when a background agent goes quiet, and ⌥⇧⌘↓ jumps to the next one waiting. Anything still running when you quit is picked back up on the next launch.',
      },
      {
        p: 'It ships no per-agent integrations on purpose: a terminal that adapts to six agents by name is a terminal that is wrong about the seventh. A bundled wortel command sits on every session’s PATH instead, so anything that can run a command can drive the app.',
      },
    ],
  },

  {
    id: 'git-and-files',
    title: 'Your repository, in the same window',
    lead: 'An inspector beside the terminal, with three panes: Changes, History and Files.',
    blocks: [
      {
        p: 'Changes is the working tree file by file, with syntax-highlighted diffs and somewhere to write the commit. History is the commit list with its branch graph. Files is the project as a tree: drag a row into the terminal and the escaped path lands at your prompt.',
      },
      {
        p: 'Double-click a file in any of the three, or ⌘-click a path in the terminal, and it opens in a window of its own: source, the diff, rendered Markdown, and Quick Look for everything that is not text.',
      },
    ],
  },

  {
    id: 'worktrees',
    title: 'Several agents, one repository',
    lead: 'Two agents in one checkout is two agents editing the same files. A worktree each, and the problem stops existing.',
    blocks: [
      {
        p: 'Open a session on a branch and Wortel checks it out in its own directory, with its own files, sharing the repository’s history, objects and remotes. It costs a directory rather than a clone.',
      },
      {
        p: 'So five agents work on five branches, none of them changing the ground under another mid-task, and each one’s inspector shows only its own work. The worktrees live outside the repository, where they cannot be committed by accident.',
      },
    ],
  },

  {
    id: 'survival',
    title: 'Quit the app, keep the work',
    lead: 'Your shells are not the app’s children. They run under a small process beside it, so closing the window stops being a decision about the work.',
    blocks: [
      {
        p: 'An agent that was thinking when you quit is still thinking when you come back, and the session reattaches to the shell it already had, scrollback included. A crash is the same story. This is on by default and there is nothing to switch on.',
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
];

// ==========================================================================
// /docs: the reference the homepage stopped being.
//
// Everything here was on the landing page and made it 13 screens long. None of
// it is cut: a shortcut table nobody can find is worse than a long homepage,
// and these are the pages a search actually lands on ("wortel keyboard
// shortcuts", "wortel worktree branch"). Same Section type as above, so
// pages/docs.astro and llms-full.txt render it with the same code.
// ==========================================================================
export const DOCS = {
  /** ~52 chars. */
  title: 'Wortel reference: commands, shortcuts and behaviour',
  description:
    'The wortel command, every keyboard shortcut, and how sessions, worktrees and the git panel behave. Reference for the native macOS terminal built on Ghostty.',
  heading: 'Reference',
  lead: 'The command, the shortcuts, and the parts that are worth knowing exactly.',
} as const;

export const DOCS_SECTIONS: Section[] = [
  {
    id: 'command',
    title: 'The wortel command',
    lead:
      'Bundled inside the app and on every session’s PATH, with no installer and no admin prompt. It speaks to the running app over a socket.',
    blocks: [
      {
        table: {
          head: ['Command', 'What it does'],
          mono: 'first',
          rows: [
            ['wortel open <path>', 'Opens a file in a tab'],
            ['wortel new --branch <name>', 'A session, in its own worktree'],
            ['wortel new --branch <name> --from <ref>', 'Forks the new branch from something else'],
            ['wortel rename <name>', 'Renames the session it was run in'],
            ['wortel notify <text>', 'This session wants you'],
            ['wortel mark <colour>', 'Colours the session in the sidebar'],
            ['wortel list', 'The open sessions, in sidebar order'],
            ['wortel read <session>', 'Prints the text on a session\'s screen'],
            ['wortel send <session> <text>', 'Types text into a session as a paste'],
            ['wortel wait <session>', 'Waits until something happens in a session'],
          ],
        },
      },
      {
        p: 'This is how Wortel avoids shipping an integration per agent. An agent that just wrote a file opens a preview of it. A hook you wrote names the session after the ticket you are on. A build that finishes raises attention.',
      },
    ],
  },

  {
    id: 'shortcuts',
    title: 'Keyboard shortcuts',
    blocks: [
      {
        table: {
          // Action first: you arrive knowing what you want to do, not which
          // keys do it. The shortcut is the answer, so it reads on the right.
          head: ['Action', 'Shortcut'],
          mono: 'last',
          rows: [
            ['New session', '⌘N'],
            ['New session at home', '⌥⌘N'],
            ['New worktree session / open folder', '⇧⌘N / ⌘O'],
            ['Go to a session, or bring back an archived one', '⌘P'],
            ['Run a command', '⇧⌘P'],
            ['Find a prompt you typed to an agent', '⌘Y'],
            ['Pin or unpin session', '⌥⌘P'],
            ['Mark session as unread', '⇧⌘U'],
            ['Back / forward through the sessions you were on', '⌃⌘[ / ⌃⌘]'],
            ['Rename session', '⌥⌘R'],
            ['Close tab / close session', '⌘W / ⇧⌘W'],
            ['Previous / next session', '⌥⌘↑ / ⌥⌘↓'],
            ['Jump to session by position', '⌘1 … ⌘9'],
            ['Jump to the next waiting session', '⌥⇧⌘↓'],
            ['Show or hide the sidebar', '⌘B'],
            ['Show or hide the side column', '⌥⌘B'],
            ['Show or hide the bottom strip', '⌘J or ⌃`'],
            ['Show changes / history / files', '⌃⌘1 / ⌃⌘2 / ⌃⌘3'],
            ['Show source control', '⌃⇧G'],
            ['Focus the list in the side column', '⌥⌘L'],
            ['New terminal tab where you are', '⌘T'],
            ['New terminal in the side column', '⌘D'],
            ['New terminal in the bottom strip', '⇧⌘D'],
            ['New browser tab', '⇧⌘L'],
            ['Reopen closed tab', '⇧⌘T'],
            ['Next / previous tab', '⇧⌘] / ⇧⌘[ or ⌃Tab ⌃⇧Tab'],
            ['Focus the next / previous area', '⌘] / ⌘['],
            ['Browser: address field', '⌘L'],
            ['Browser: reload', '⌘R'],
            ['Browser: back / forward', '⌘[ / ⌘]'],
            ['Find in a file, next / previous match', '⌘F, ⌘G / ⇧⌘G'],
            ['Clear the terminal', '⌘K'],
            ['Increase / decrease / reset font size', '⌘+ / ⌘− / ⌘0'],
            ['Select all (⌘A clears the input line)', '⇧⌘A'],
            ['Full screen', '⌃⌘F'],
            ['Open this list', '⌘/'],
          ],
        },
      },
    ],
  },

  {
    id: 'agent-detection',
    title: 'How the agent detection works',
    blocks: [
      {
        p: 'Where an agent announces itself, with OSC 9;4 progress, OSC 133 command marks or a spinner in the title, Wortel uses that. None of it is required: the fallback is the screen itself, so an agent that emits nothing is still read correctly, including one that does not exist yet.',
      },
      {
        p: 'Nothing is written into any agent’s configuration to make this work, and detection only runs on sessions you are not currently looking at. A notification never arrives for the session in front of you.',
      },
    ],
  },

  {
    id: 'worktree-behaviour',
    title: 'What a worktree session does',
    blocks: [
      {
        p: 'The session takes the branch’s name, and a branch that already has a worktree opens the one it has instead of failing.',
      },
      {
        p: 'Its row carries a small branch mark, because the name alone cannot tell you: a session named for its branch otherwise reads as an ordinary shell that happens to be called the same thing, and which one you are looking at decided where your last commit went.',
      },
      {
        p: 'A new branch forks from the repository’s default branch, not from wherever you happen to be standing. Opening one from inside another agent’s worktree would otherwise fork that agent’s half-finished branch, which is a thing you find out about later. Both the dialog and the command let you pick something else to fork from.',
      },
    ],
  },

  {
    id: 'internals',
    title: 'The parts underneath',
    blocks: [
      {
        p: 'The process holding your shells knows nothing about terminals, git or rendering. It forks what it is told to fork and keeps reading when nobody is attached, which is what makes it small enough to trust with outliving everything else.',
      },
      {
        p: 'Switching sessions costs a single frame because every surface stays alive inside the window. Only the one you had selected starts before the first frame; the rest warm up behind it.',
      },
      {
        p: 'The inspector belongs to the session, because a shell in your home directory never wants it and one inside a repository always does. Cost tracks the window on screen, never the size of the repository: a collapsed node_modules is one row and no work at all.',
      },
    ],
  },
];

// ---- FAQ ------------------------------------------------------------------
// Also the source for the FAQPage JSON-LD. Answers are written to stand alone:
// each one has to make sense as a snippet quoted with no page around it.
//
// AUTHORED IN THEMATIC ORDER, SHIPPED IN LENGTH ORDER. Keep writing them in
// groups down here, where "how is it different from X" sitting next to the
// other two of its kind is what stops the set drifting into three answers to
// the same question. What the page renders is the sorted view below.
const FAQ_AUTHORED: { q: string; a: string }[] = [
  {
    q: 'What is Wortel?',
    a: 'Wortel is a fully native macOS terminal emulator built on Ghostty’s engine. It replaces tabs and splits with a sidebar of named, persistent sessions, gives each coding agent its own git worktree so several can work one repository at once, keeps those shells running after you quit the app, and ships with no configuration to maintain. A git panel, a file tree and agent activity detection are built in.',
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
    a: 'Wortel runs Ghostty’s engine, so terminal behaviour, throughput and latency are the same. The difference is the app around it: Ghostty gives you tabs, splits and a large configuration file, while Wortel gives you one window, a sidebar of named sessions that persist across restarts, a git worktree per session, shells that keep running after the app quits, a built-in git and files inspector, coding-agent activity detection, and no configuration at all.',
  },
  {
    q: 'How is Wortel different from iTerm2, Warp, Kitty or Alacritty?',
    a: 'Wortel has no settings UI, no plugin system, no AI chat box and no splits. What it has instead is built around running coding agents: named shells that survive a restart and switch in one frame, a git worktree per session so several agents can work one repository at once, shells that keep running after you quit the app, a git and files inspector beside the terminal, and detection of which background agent has stopped and is waiting on you.',
  },
  {
    q: 'How is Wortel different from Conductor, Emdash or Superset?',
    a: 'Those are agent manager apps: a window holding worktrees, diffs and a review queue, with a terminal as a detail inside it. Wortel is the terminal, and the worktrees and diffs are in it. The practical difference is what happens when you quit. Wortel’s shells run under a separate process, so an agent mid-task keeps working whether or not the app is open, and everything you type is a real terminal on Ghostty’s engine rather than a box in a form.',
  },
  {
    q: 'How is Wortel different from herdr, tmux or Zellij?',
    a: 'Those are multiplexers: a background server plus a client that runs inside whatever terminal you already supply. Wortel is the terminal, and it holds sessions the same way, under a process outside the app, so quitting Wortel does not stop them. What it adds is the part a multiplexer has no window for: a git panel with diffs, history and a branch graph, a project file tree, preview windows, and a worktree per session, all beside the shell rather than in another tool.',
  },
  {
    q: 'Does Wortel have tabs or split panes?',
    a: 'Tabs, yes; splits, no. Each session has three rows of tabs: the main area with its terminal, a side column, and a strip under the terminal, and any tab (a terminal, a browser, a file, the git panes) can be dragged between them. What Wortel does not do is split a terminal into a grid of panes: the sidebar of named sessions is where you switch work, and ⌘P finds any of them by name.',
  },
  {
    q: 'Can I configure Wortel’s fonts, colours and keybinds?',
    a: 'Only font size, which is adjustable per session with ⌘+ and ⌘−. Everything else is fixed: the whole configuration is a read-only file inside the app bundle, and your ~/.config/ghostty is never read. Zero configuration is the design goal, not a missing feature.',
  },
  {
    q: 'How does Wortel know when a coding agent is waiting for me?',
    a: 'By watching what the session draws. A screen that keeps changing means the agent is still working; a screen that has held still past a threshold means it is waiting on you. Precise signals (OSC 9;4 progress, OSC 133 command marks, a title spinner) are used where an agent emits them, but none are required, so the rule covers Claude Code, Codex, Aider and agents that do not exist yet. Nothing is written into any agent’s configuration to make this work, and detection only runs on sessions you are not currently looking at.',
  },
  {
    q: 'Can I run several coding agents on one repository at once?',
    a: 'Yes, and that is what git worktrees are for here. Opening a session on a branch checks that branch out in its own directory with its own files, sharing the repository’s history, objects and remotes, so it costs a directory rather than a clone. Each agent then edits its own files on its own branch, nothing changes the ground under a running agent, and each session’s git panel shows only that worktree’s work. A branch that already has a worktree opens the one it has, a new one forks from the repository’s default branch rather than from whichever worktree you opened it in, and the sidebar marks which rows are worktrees.',
  },
  {
    q: 'Do my sessions keep running if I quit Wortel?',
    a: 'Yes. Shells run under a small keeper process outside the app rather than as its children, so quitting Wortel, or Wortel crashing, does not stop them. An agent that was working when you quit is still working when you launch again, and the session reattaches to the shell it already had, with the output from while you were gone. This is on by default and there is nothing to switch on.',
  },
  {
    q: 'Can I control Wortel from the command line or from an agent?',
    a: 'Yes. A wortel command ships inside the app bundle and is on the PATH of every session, with no installer and no admin prompt. It speaks to the running app over a socket: wortel open opens a file in a tab, wortel new --branch opens a session in its own worktree, wortel rename renames the session it was run in, and wortel notify raises attention on it. wortel list, read, send and wait let one session drive another. That is how Wortel avoids shipping a separate integration per agent: anything that can run a command can drive it, including your own hooks and scripts.',
  },
  {
    q: 'Does Wortel work with Claude Code, Codex and Aider?',
    a: 'Yes. They run as ordinary shell commands in any session, with no per-agent setup and no changes to their configuration files. Beyond that, Wortel marks in the sidebar which agents are working and which are waiting, notifies you when a background agent goes quiet, jumps to the next waiting session with ⌥⇧⌘↓, gives each one its own worktree so they can share a repository, keeps them running when the app is closed, and resumes agents that were still running when you last quit.',
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

/**
 * The FAQ as it ships: shortest question first.
 *
 * Sorted HERE and not in the template, because three things render this array
 * (the page, the FAQPage node in the JSON-LD, and llms-full.txt) and sorting in
 * one of them would leave the other two in a different order. A model reading
 * the flattened text and a person reading the page should meet these in the
 * same sequence.
 *
 * Sorting is stable in every engine this builds on, so the two 15-character
 * questions keep the order they were authored in.
 */
export const FAQ = [...FAQ_AUTHORED].sort((a, b) => a.q.length - b.q.length);

// ---- specs ----------------------------------------------------------------
export const SPECS: [string, string][] = [
  ['Platform', 'macOS ' + SITE.minMacOS + ' ' + SITE.minMacOSName + ' or later'],
  ['Engine', 'libghostty: Ghostty’s VT parser, Metal renderer and glyph atlas'],
  ['Built with', 'Swift, AppKit and SwiftUI, fully native'],
  ['Sessions', 'Held by a keeper process: they outlive the app'],
  ['Repositories', 'A git worktree per session, on its own branch'],
  ['Scripting', 'A bundled wortel command, no installer'],
  ['Price', 'Free'],
  ['Updates', 'Sparkle, signed and notarized'],
  ['Configuration', 'None: read-only and bundled'],
];
