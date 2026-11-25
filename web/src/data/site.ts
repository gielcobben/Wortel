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

// The download is the DMG that release.sh --publish uploads. Until the bucket
// has one (a site deployed before the first release that uploads it), linking
// there would put a 404 behind every Download button, so the build keeps the
// zip until a HEAD finds the DMG. Only a definite 404 falls back: an offline
// build links the DMG, and a deploy is never offline.
const DMG = 'https://updates.wortel.sh/Wortel-latest.dmg';
const ZIP = 'https://updates.wortel.sh/Wortel-latest.zip';
const DOWNLOAD = await fetch(DMG, { method: 'HEAD' }).then(
  (r) => (r.status === 404 ? ZIP : DMG),
  () => DMG,
);
/** Whether the download is the disk image, which the steps and llms.txt say. */
export const DOWNLOAD_IS_DMG = DOWNLOAD === DMG;

export const SITE = {
  name: 'Wortel',
  url: 'https://wortel.sh',
  /** ~48 chars, inside the ~60 Google renders before truncating. */
  title: 'Wortel: a native macOS terminal for coding agents',
  /** ~151 chars, inside the ~155-160 shown in a result snippet. */
  description:
    'A native macOS terminal on Ghostty’s real engine, built for coding agents: ⌘N starts yours, each gets a worktree, and shells keep running when you quit.',
  tagline: 'A terminal for your agents. Any of them, side by side.',
  author: 'Giel Cobben',
  authorUrl: 'https://gielcobben.com',
  /** The source, under the GPL. */
  repo: 'https://github.com/gielcobben/wortel',
  /** release.sh --publish always mirrors the newest notarized DMG here. */
  download: DOWNLOAD,
  appcast: 'https://updates.wortel.sh/appcast.xml',
  /** Sparkle's minimumSystemVersion, minus the ".0" that reads as noise. */
  minMacOS: '14',
  minMacOSName: 'Sonoma',
} as const;

// ---- /download: from the disk image to a running agent --------------------
export const INSTALL_STEPS: [string, string][] = [
  ...(DOWNLOAD_IS_DMG
    ? ([
        ['Open Wortel.dmg', 'It is in Downloads. A window opens with Wortel and your Applications folder side by side.'],
        ['Drag it to Applications', 'From there it can replace itself when a new version comes out. Then eject the disk image.'],
        ['Open it from Applications', 'macOS asks once whether to open an app from the internet. Say yes, and you are in.'],
      ] as [string, string][])
    : ([
        ['Open the zip', 'Safari unzips it for you, so Wortel is already waiting in Downloads.'],
        ['Drag it to Applications', 'From there it can replace itself when a new version comes out.'],
        ['Open it', 'macOS asks once whether to open an app from the internet. Say yes, and you are in.'],
      ] as [string, string][])),
  ['Start an agent', 'Wortel does not come with one. Install Claude Code, Codex or Pi, then type its name in a session.'],
];

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
  /** A small heading inside a section, where it holds more than one subject. */
  | { h: string }
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
    lead: 'A sidebar of names. Several agents, none of them in each other’s way.',
    blocks: [
      {
        p: 'Most agent apps are a chat window with a small terminal inside, and an ordinary terminal runs your agents but does not keep track of them. Wortel is a real terminal first: every session is a shell on Ghostty’s engine, and an agent is one more command in it, so Claude Code, Codex, Gemini, opencode, Pi or anything else runs as it is. Once you name yours in Settings, ⌘N opens every new session with it already running.',
      },
      {
        p: 'It is fully native: Swift and AppKit, no web view. Open it and the work is where you left it, every session still named and still in its own directory. No grid of panes to tile.',
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
        p: 'Name a session and it keeps the name. Put a slash in it and everything before the slash becomes a section, so twelve shells across four projects read as four groups. Each section sorts by recent activity, date created, name or by hand, from Sort By in its “…”. Names, directories and selection come back on launch.',
      },
      {
        p: 'A click switches on the press, and the terminal is there at its full size. One you have not looked at for a minute gives its memory back and comes back exactly as it was when you select it.',
      },
    ],
  },

  {
    id: 'coding-agents',
    title: 'A coding agent in every session',
    lead:
      'Hand one repository to Claude Code, another to Codex, a third to Pi, and the terminal stops being the hard part. Knowing which one needs you becomes the hard part.',
    blocks: [
      {
        p: 'The agent tells Wortel itself. Claude Code, Codex, Pi, opencode and others report what they are doing as they do it: working, waiting for your approval, asking a question, finished, failed. Wortel takes them at their word and guesses nothing, so a dot in the sidebar means what the agent said, not what its screen looked like.',
      },
      {
        p: 'The sidebar marks what is working and what is waiting, a notification arrives when a background agent finishes or needs you, and ⌥⇧⌘↓ jumps to the next one waiting. Anything still running when you quit is picked back up on the next launch.',
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
        p: 'A file you pick in Changes or Files shows in a preview tab, its title in italics, and the next file you pick takes its place. Double-click it, or its tab, to keep it. With the terminal in front a click only selects, so the agent stays in view: Space or a double-click opens the preview. A file opens as source, the diff, rendered Markdown, or Quick Look for everything that is not text.',
      },
      {
        p: '⌘P finds any file in the session’s repository or folder once you type, and `name:120` opens it at that line. ⌘-click a path in the terminal and it opens the same way, even when an agent broke it over two rows. The diff under the Changes list can be put away from View ▸ Show Diff in Changes.',
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
        p: 'An agent that was thinking when you quit is still thinking when you come back, and the session reattaches to the shell it already had. Each terminal’s screen and scrollback are kept by the process that keeps the shells while Wortel is closed, so after a quit, an update or a crash they come back exactly as they were, with whatever the agent drew meanwhile. This is on by default and there is nothing to switch on.',
      },
    ],
  },

  {
    id: 'zero-config',
    title: 'Almost nothing to configure, on purpose',
    lead:
      'The terminal’s whole configuration is one read-only file inside the app. Settings has five things in it, for what differs per person. There is no dotfile.',
    blocks: [
      {
        p: 'This is the feature. A terminal you can spend an afternoon tuning is a terminal you will. Wortel chooses the font, the theme, the keybinds and the scrollback once, and treats them as finished. Font size is the one thing about the look you can change.',
      },
      {
        p: 'Settings (⌘,) is two short tabs: what a new session starts with, whether Source Control shows its commit box, where a local server opens, automatic updates, and anonymous usage data. A setting is only added for something you decide once and that really differs from one person to the next.',
      },
    ],
  },
];

// ---- the bento: Wortel at a glance -------------------------------------------
// One poster of what Wortel is, built the way Apple closes a keynote section
// (studied from its 2025 slides): the product itself in the middle, tiles of
// very different sizes around it, and on each tile ONE piece of the product
// and a label of a few words. Almost no tile is only type: on Apple's macOS
// slide one in fourteen is. No sentences on the poster: `body` is the
// sentence a screen reader and a crawler get instead. `big` is for the rare
// tile whose picture is its own word or number.
// The same facts are SPECS below, which the Markdown pages render as a table.
export type Tile = {
  scene:
    | 'worktree' | 'agents' | 'send' | 'diff' | 'plan' | 'hero' | 'palette' | 'quit' | 'status'
    | 'browser' | 'settings' | 'free' | 'looks';
  label: string;
  big?: string;
  body: string;
};

export const BENTO: { tiles: Tile[] } = {
  tiles: [
    { scene: 'worktree', label: 'A worktree per agent', body: 'A session on a branch gets its own directory and files, so several agents share one repository without colliding.' },
    // The commands, as you would type them: a few of the agents Wortel
    // recognises by name. Any other command runs the same way.
    { scene: 'agents', label: 'Whichever agent you use', body: 'Claude Code, Codex, Gemini, opencode, Pi, Amp, Goose, Aider: an agent is one more command in a real terminal, so whichever you use runs as it is.' },
    { scene: 'send', label: 'Agents that work together', body: 'Every session has the wortel command on its PATH. One agent can hand another a task, wait for it, and read what it said.' },
    { scene: 'diff', label: 'Every change, beside it', body: 'The working tree file by file, with syntax-highlighted diffs and somewhere to write the commit.' },
    { scene: 'plan', label: 'Plans, rendered', body: 'A file opens in a tab of its own: source, the diff, or rendered Markdown.' },
    { scene: 'hero', label: 'Ghostty’s engine, in every session', body: 'Every session is a real terminal on Ghostty’s engine, unmodified. An agent is one more command in it.' },
    { scene: 'palette', label: 'Every command on ⇧⌘P', body: 'A command palette on ⇧⌘P runs any command, and ⌘P goes to any session by name, or any file in its project.' },
    { scene: 'quit', label: 'Outlives the app', body: 'Shells run outside the app. After a quit, an update or a crash, each session is as you left it.' },
    { scene: 'status', label: 'Who needs you', body: 'Agents report whether they are working, waiting on you, done or failed, and the sidebar shows it.' },
    { scene: 'browser', label: 'A browser in the window', body: 'A browser tab beside the terminal, to preview the site an agent is building.' },
    { scene: 'settings', big: '5', label: 'settings', body: 'The font, the theme and the keybinds were chosen once. Settings is five rows long.' },
    { scene: 'free', big: 'Free', label: 'No account', body: 'Wortel is free, and has no account.' },
    { scene: 'looks', label: 'Follows light and dark', body: 'Every terminal follows the system between light and dark, at once.' },
  ],
};

// ==========================================================================
// The homepage's own words: the hero, and the row each section opens with
// (components/Section.astro). A heading is two short lines, the claim and its
// other half, with no full stops; the body is one short paragraph. They stay
// as they are while the section's film plays, so nothing here is written per
// chapter. The longer version of each section is SECTIONS above, which the
// Markdown pages render.
// ==========================================================================
export type Head = {
  title: string;
  tone?: string;
  body?: string;
  link?: readonly [text: string, href: string];
};

export const HOME = {
  hero: {
    title: 'Meet Wortel',
    tone: 'A terminal for your agents.',
    body: 'Claude Code, Codex, Pi or your own: any agent runs in Wortel as it is, side by side with the rest, and a dot says which one needs you.',
  },
  terminal: {
    title: 'A terminal first',
    tone: 'An agent is one more command',
    body: 'Every session is a real shell on Ghostty’s engine. Type claude, codex or pi and the agent has it. Name yours once in Settings and ⌘N opens every new session with it already running.',
    link: ['How new sessions start', '/docs#new-sessions'],
  },
  agents: {
    title: 'Know which one needs you',
    tone: 'The agent says so, Wortel shows it',
    body: 'Claude Code, Codex, Pi, opencode and others report when they are working, waiting on you, done or failed. A dot in the sidebar, a notification for a session out of sight, and ⌥⇧⌘↓ takes you there.',
    link: ['How the agents report', '/docs#agent-detection'],
  },
  window: {
    title: 'One window, four places',
    tone: 'Arranged the way you work',
    body: 'Sessions on the left, the terminal in the middle, your changes, history and files beside it, a second shell underneath. Every place folds away, and nothing in it is a setting.',
    link: ['Every shortcut', '/docs#shortcuts'],
  },
  glance: {
    title: 'Everything around the terminal',
    tone: 'Native, made for a day of agents',
    body: 'Worktrees, a command palette, previews and a browser, sessions that outlive the app, and five settings. Free, and nothing about your work leaves your Mac.',
  },
  questions: {
    title: 'The short answers',
    tone: 'The exact ones are in the docs',
    body: 'How it differs from Ghostty, iTerm2 and the agent apps, what it runs on, and what it keeps.',
    link: ['Read the docs', '/docs'],
  },
} as const satisfies { hero: Required<Pick<Head, 'title' | 'tone' | 'body'>> } & Record<string, Head>;

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
      'Bundled inside the app and on every session’s `PATH`, with no installer and no admin prompt. It speaks to the running app over a socket.',
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
            ['wortel remind <when>', 'Brings the session back to you later'],
            ['wortel cd <dir>', 'Moves the session, and its agent, to another folder'],
            ['wortel close', 'Closes the session when the agent is done, and its worktree with it'],
            ['wortel list', 'The open sessions, in sidebar order'],
            ['wortel read <session>', 'Prints the text on a session’s screen'],
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
            ['New worktree session / open folder', '⌥⇧⌘N / ⌘O'],
            ['New window', '⇧⌘N'],
            ['New terminal, without the command Settings starts', '⌃⌘N'],
            ['The same, at home', '⌃⌥⌘N'],
            ['Go to a session or a file, or bring back an archived session', '⌘P'],
            ['Run a command', '⇧⌘P'],
            ['Find a prompt you typed to an agent', '⌘Y'],
            ['Pin or unpin session', '⌥⌘P'],
            ['Mark session as unread', '⇧⌘U'],
            ['Back / forward through the sessions and tabs you were on', '⌃⌘[ / ⌃⌘]'],
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
            ['Jump to the previous / next prompt', '⌘↑ / ⌘↓'],
            ['Clear the terminal', '⌘K'],
            ['Increase / decrease / reset font size', '⌘+ / ⌘− / ⌘0'],
            ['Select all (⌘A clears the input line)', '⇧⌘A'],
            ['Full screen', '⌃⌘F'],
            ['Settings', '⌘,'],
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
        p: 'Agents report their own state through the Program Status Protocol, an open standard a program uses to tell its terminal that it is working, blocked on you, done or failed. Claude Code, Codex, Pi, opencode, crush, Qwen Code, GitHub Copilot CLI and Amp speak it. Wortel listens for the protocol and not for a list of names, so the next agent that speaks it works the day it ships.',
      },
      {
        p: 'An agent that does not report shows no spinner and no turn end. Wortel used to guess those from the title and the screen, and stopped: a guess that is right most of the time is a false alarm the rest of it. A version too old to report is marked in the sidebar with the version it needs. Nothing is written into any agent’s configuration, and a notification never arrives for the session in front of you.',
      },
    ],
  },

  {
    id: 'new-sessions',
    title: 'Starting an agent in every new session',
    blocks: [
      {
        p: 'In Settings (`⌘,`), “New sessions start with” takes any command. Type one, like `claude` or `codex`, or pick one of the agents Wortel finds on your Mac from the menu beside it, and every new session starts with it: `⌘N`, `⌥⌘N`, `⌥⇧⌘N`, `⌘O`, a folder’s + and a folder dropped on the sidebar.',
      },
      {
        p: 'Session ▸ New Terminal (`⌃⌘N`) opens one without it, and only exists while the field is filled. Left empty, a new session is a plain terminal. `wortel new` and the sessions brought back at launch never use it.',
      },
      { h: 'A folder of its own' },
      {
        p: 'An agent session that would start in your home folder gets a folder of its own instead, in `~/Wortel`, named for the day: `~/Wortel/2026-11-19/1`, then `2`. Files the agent makes for you are there.',
      },
      {
        p: 'Claude Code asks whether to trust a folder the first time it runs in it, and never remembers the answer for your home folder, so the first one starts in `~/Wortel` itself and asks once. Every one after that is covered by that answer.',
      },
      {
        p: 'When a conversation there turns to a project somewhere else, Claude offers to move the session to it, and once you agree, the same conversation carries on in that folder, with its git. Claude Code learns what it can ask Wortel for from a skill Wortel puts in `~/.claude/skills/wortel`. Edit it and Wortel leaves it alone; delete it and it stays deleted.',
      },
      { h: 'Memory given back' },
      {
        p: 'A Claude Code agent that has finished its turn, in a session that has not been on screen for an hour, is ended to give its memory back (130 to 400 MB each), and the shell stays. Select the session and the same conversation is resumed.',
      },
      {
        p: 'One waiting on your answer, with something still running under it, with a prompt typed and not sent, or with Remote Control on, gets eight hours instead. A working agent and the session in front of you are never touched, and neither is an agent in your home folder, where Claude Code would ask again whether to trust it.',
      },
    ],
  },

  {
    id: 'reminders',
    title: 'Reminders',
    blocks: [
      {
        p: 'Remind Me, in a session’s menu or the Session menu, brings a session back to you later: in 30 minutes, in 1 hour, in 3 hours, tomorrow at 09:00, on Monday at 09:00, or at a day and time you pick with Custom…. While it waits, the row says when on a small grey line under its name.',
      },
      {
        p: 'When the time comes, the session gets the unread ring and you get a notification, or only a flash of the ring if you are already looking at it. A reminder that came due while Wortel was closed goes off when you open it. A session has one reminder, setting another replaces it, and closing the session ends it.',
      },
      { h: 'From a terminal' },
      {
        table: {
          head: ['`wortel remind` takes', 'For example'],
          rows: [
            ['A duration', '`20m`, `1h`'],
            ['A time on the clock', '`15:00`, `3pm`'],
            ['A day', '`fri`, `friday 14:00`, `tomorrow 3pm`'],
            ['A date', '`2026-12-03 10:00`'],
          ],
        },
      },
      {
        p: '`wortel remind none` cancels it. A day on its own means 09:00.',
      },
    ],
  },

  {
    id: 'windows',
    title: 'More than one window',
    blocks: [
      {
        p: 'Window ▸ New Window (`⇧⌘N`) opens another window with a sidebar of its own. Drag a session onto another window’s sidebar to move it there, or out of the window to give it one of its own. It keeps running as it is, agent and all. A session’s menu has Move to New Window and Move to Window, and Window ▸ Merge All Windows puts everything back in one.',
      },
      {
        p: 'Closing a window closes its sessions, and asks first if something is still running in them. New Worktree Session is `⌥⇧⌘N`, since `⇧⌘N` opens a window.',
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
        p: 'The process holding your shells keeps each one’s terminal too: it reads everything a shell prints, whether or not Wortel is open, so the screen and scrollback are always current. It knows nothing about git, sessions or drawing, which is what makes it small enough to trust with outliving everything else.',
      },
      {
        p: 'Only the terminals on screen are drawn. One out of sight for a minute gives back its screen’s memory and is copied back from the keeper when you select it, so a session costs what you are looking at, not how many you have open. At launch, the session you had selected comes up first and the rest follow behind it.',
      },
      {
        p: 'The inspector belongs to the session, because a shell in your home directory never wants it and one inside a repository always does. Cost tracks the window on screen, never the size of the repository: a collapsed `node_modules` is one row and no work at all.',
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
    a: 'Wortel is a fully native macOS terminal emulator built on Ghostty’s engine, made for working next to coding agents. It is a real terminal first: an agent is one more command in a session, and `⌘N` can start yours for you. It replaces tabs and splits with a sidebar of named, persistent sessions, gives each coding agent its own git worktree so several can work one repository at once, keeps those shells running after you quit the app, and ships with no configuration to maintain. A git panel, a file tree and agent activity detection are built in.',
  },
  {
    q: 'Is Wortel free?',
    a: 'Yes. Wortel is a free download for macOS ' + SITE.minMacOS + ' or later, and updates itself through Sparkle.',
  },
  {
    q: 'Is Wortel open source?',
    a: 'Yes. Wortel is open source under the GNU General Public License, version 3 or later, and the source is on GitHub at github.com/gielcobben/wortel. The name Wortel and its icon are not part of that licence.',
  },
  {
    q: 'What does “Wortel” mean?',
    a: 'Wortel is Dutch for root: the root of a plant, and the root shell you work in.',
  },
  {
    q: 'How is Wortel different from Ghostty?',
    a: 'Wortel runs Ghostty’s engine, so terminal behaviour, throughput and latency are the same. The difference is the app around it: Ghostty gives you tabs, splits and a large configuration file, while Wortel gives you a sidebar of named sessions that persist across restarts, a git worktree per session, shells that keep running after the app quits, a built-in git and files inspector, coding-agent activity detection, and no configuration at all.',
  },
  {
    q: 'How is Wortel different from iTerm2, Warp, Kitty or Alacritty?',
    a: 'Wortel has no themes, no plugin system, no AI chat box and no splits, and its settings are five rows. What it has instead is built around running coding agents: named shells that survive a restart and switch on a click, a git worktree per session so several agents can work one repository at once, shells that keep running after you quit the app, a git and files inspector beside the terminal, and detection of which background agent has stopped and is waiting on you.',
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
    a: 'Tabs, yes; splits, no. Each session has three rows of tabs: the main area with its terminal, a side column, and a strip under the terminal, and any tab (a terminal, a browser, a file, the git panes) can be dragged between them. A file tab can also be dragged out of the window into a preview window of its own, and back. What Wortel does not do is split a terminal into a grid of panes: the sidebar of named sessions is where you switch work, and `⌘P` finds any of them by name.',
  },
  {
    q: 'Can I configure Wortel’s fonts, colours and keybinds?',
    a: 'Only font size, which is adjustable per session with `⌘+` and `⌘−`. Everything else about how the terminal looks and types is fixed: its whole configuration is a read-only file inside the app bundle, and your `~/.config/ghostty` is never read. Settings (`⌘,`) holds five things that differ per person, such as what a new session starts with, and none of them is about the look. Next to nothing to configure is the design goal, not a missing feature.',
  },
  {
    q: 'How does Wortel know when a coding agent is waiting for me?',
    a: 'The agent says so. Claude Code, Codex, Pi, opencode and others report their own state through the Program Status Protocol: working, waiting for your approval, asking a question, done or failed. Wortel shows what they report and guesses nothing from the screen. An agent that does not report yet shows no status, and one in a version too old to report is marked with the version it needs. Nothing is written into any agent’s configuration to make this work.',
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
    a: 'Yes. A `wortel` command ships inside the app bundle and is on the `PATH` of every session, with no installer and no admin prompt. It speaks to the running app over a socket: `wortel open` opens a file in a tab, `wortel new --branch` opens a session in its own worktree, `wortel rename` renames the session it was run in, and `wortel notify` raises attention on it. `wortel list`, `read`, `send` and `wait` let one session drive another. That is how Wortel avoids shipping a separate integration per agent: anything that can run a command can drive it, including your own hooks and scripts.',
  },
  {
    q: 'Does Wortel work with Claude Code, Codex and other coding agents?',
    a: 'Yes. Any agent runs as an ordinary shell command in any session, with no per-agent setup and no changes to its configuration files. Each can have its own worktree so several share a repository, keeps running when the app is closed, and is resumed if it was still running when you last quit. For the agents that report their own state, like Claude Code, Codex, Pi and opencode, Wortel also marks in the sidebar which are working and which are waiting, notifies you when a background agent finishes or needs you, and jumps to the next waiting session with `⌥⇧⌘↓`.',
  },
  {
    q: 'What are the system requirements?',
    a: 'macOS ' + SITE.minMacOS + ' ' + SITE.minMacOSName + ' or later. Wortel is a signed and notarized native application. It does not come with an agent: install Claude Code, Codex, Pi or another one the way its own site says, and it runs in any session. Worktrees and the git panes need git, which comes with Apple’s command line tools. On a Mac without them Wortel says so and opens Apple’s installer for you.',
  },
  {
    q: 'Does Wortel read my existing shell configuration?',
    a: 'Your shell configuration (`.zshrc`, `.bashrc`, fish config) is yours and runs normally. It is only Wortel’s own terminal configuration that is fixed and bundled; the user-level Ghostty config file is deliberately not loaded.',
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
  ['Source', 'Open, under the GPL (version 3 or later): github.com/gielcobben/wortel'],
  ['Updates', 'Sparkle, signed and notarized'],
  ['Configuration', 'Five settings. The terminal’s own is read-only and bundled'],
];
