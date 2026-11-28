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

// ---- the letter: an email when something big ships ------------------------
// The form (components/LetterForm.astro) is on /download after the click, at
// the foot of /updates, and on /letter. The requests behind it are
// worker/letter-routes.ts; what is kept is written up in privacy.md.
export const LETTER = {
  name: 'By email',
  line: 'An email when something big ships, a few times a year. Nothing else, and every one has a link to leave.',
  /** On /download, under "Downloading", while the reader waits. */
  whileDownloading: 'While it downloads: an email when something big ships, a few times a year?',
  field: 'Email address',
  placeholder: 'you@example.com',
  button: 'Subscribe',
  /** The form, answered in place. */
  sent: 'Check your inbox and press Confirm in the mail. Until then the address is not on the list.',
  sorry: 'That didn’t go through. Check the address, or try again in a minute.',
  feed: 'Rather not give an address? The changelog is also a feed.',
  kept: 'Only the address, the day you joined and which form you used. Unconfirmed addresses are forgotten after a week, and leaving deletes the address.',
  /** The pages the requests end on (pages/letter/[state].astro). `form` puts the form under the words; `button` is a page whose form the Worker fills with the token from the link. */
  states: {
    sent: { title: 'Check your inbox', lead: 'A mail is on its way. Press Confirm in it and you’re on the list. Nothing there after a few minutes? Look in spam, or check the address and send it again.', form: true },
    confirming: { title: 'One more press', lead: 'Press Confirm for an email when something big ships, a few times a year.', button: 'Confirm', action: '/letter/confirm' },
    joined: { title: 'You’re on the list', lead: 'The next letter comes when something big ships. Every one has a link to leave.' },
    leaving: { title: 'Leave the letter', lead: 'Press Leave and the address is deleted, not just switched off.', button: 'Leave', action: '/letter/leave' },
    left: { title: 'You’re off the list', lead: 'The address is deleted, and nothing else about you was kept.' },
    expired: { title: 'This link has expired', lead: 'A link is good for a week. After that an unconfirmed address is forgotten, so send it again here.', form: true },
    sorry: { title: 'That didn’t go through', lead: 'Check the address, or try again in a minute.', form: true },
  },
} as const;
export type LetterState = keyof typeof LETTER.states;

// ---- the beta -------------------------------------------------------------
// While a beta is out (2026.48.2, to a few testers, since 2026-11-27), what
// only the beta has carries `beta: true` here: a homepage heading in HOME, a
// section in SECTIONS or DOCS_SECTIONS, or a table row as its third item. The
// pages draw a small "Beta" beside it (components/Beta.astro, `.beta` in
// styles/site.css). Plain text (the Markdown, the llms files, the structured
// data's feature list) says "(beta)" after it through betaNote(), and never
// puts the word in a title. The splits and mark-up lines in data/schema.ts
// and pages/llms.txt.ts read the flags on HOME.window and HOME.markup.
// WHEN THE BETA BECOMES A REGULAR RELEASE THE FLAGS COME OFF: delete every
// `beta: true` in this file, and that is all. The rest stays for the next beta.
export const BETA = { label: 'Beta', text: '(beta)' } as const;
/** What only the beta has. */
export type Beta = { beta?: true };
/** " (beta)" after what only the beta has, for plain text; nothing otherwise. */
export const betaNote = (b?: Beta): string => (b?.beta ? ` ${BETA.text}` : '');

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
  /** Something as it is typed or pasted, on lines of its own. */
  | { code: string }
  | {
      table: {
        head: [string, string];
        /** A row's third item marks it as only in the beta (BETA, above). */
        rows: [string, string, Beta?][];
        /** Which column holds literal keys/values and is set in mono. */
        mono?: 'first' | 'last';
      };
    };

export type Section = Beta & {
  id: string;
  title: string;
  lead?: string;
  /** The feature's own page (/layouts, /mark-up), linked under the section's
   *  name on /docs and after its lead in the Markdown. */
  page?: readonly [text: string, href: string];
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
        p: 'It is fully native: Swift and AppKit, no web view. Open it and the work is where you left it, every session still named and still in its own directory. No layout to build first.',
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
    id: 'splits',
    title: 'Split it anywhere',
    beta: true,
    lead: 'Everything beside the sidebar is made of splits, and every split has its own row of tabs.',
    blocks: [
      {
        p: '`⌘D` splits the split you are in to the right and `⇧⌘D` splits it down, each with a new terminal. A tab let go on the edge of a split makes a new one there, and let go on its middle moves into it. The + in a row opens a tab that asks what it should be: a terminal, a browser, Changes, History or Files.',
      },
      {
        p: 'Wortel opens the first two for you, where they have always been: `⌥⌘B` opens Changes and Files beside the terminal and `⌘J` a second shell under it. So the window is useful before you arrange anything, and arranging it is never a setting. `⇧⌘↩` zooms the split you are in to the whole window and back.',
      },
    ],
  },

  {
    id: 'mark-up',
    title: 'Show it what you mean',
    beta: true,
    lead: 'Point at what a preview shows, say something about it, and paste it to an agent.',
    blocks: [
      {
        p: 'Mark Up `⇧⌘M` works over a page in a browser tab, a file’s source, its diff, rendered Markdown and an image. A click picks an element of a page, and a drag draws around anything, with a box, a pen, an arrow or a highlighter. Each mark gets a colour and a number.',
      },
      {
        p: 'Your note goes in a bar at the bottom of the preview, with each mark in it as a chip, so the sentence is written around them. Return copies it as plain text, with a picture of each mark and the page or file it was about. Paste it to the agent in this session or another. Nothing is typed or sent for you.',
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
        p: 'Settings `⌘,` is two short tabs: what a new session starts with, whether Source Control shows its commit box, where a local server opens, automatic updates, and anonymous usage data. A setting is only added for something you decide once and that really differs from one person to the next.',
      },
    ],
  },
];

// ---- the bento: what is around the terminal ---------------------------------
// One calm poster under "Everything around the terminal": ten tiles, each ONE
// piece of the product and a label of a few words, in the order they are
// read (components/home/Bento.astro places them). No sentences on the
// poster: `body` is the sentence a screen reader and a crawler get instead.
//
// It is not the list of features. What has a section of its own on the
// homepage has no tile (any agent as a command, who needs you, the diff, a
// rendered plan, the browser), and neither do the two facts the paragraph
// over the poster states (five settings, free). All of it is in SECTIONS
// above, DOCS_SECTIONS and SPECS below, which the Markdown pages print.
export type Tile = {
  scene: 'hero' | 'worktree' | 'palette' | 'splits' | 'markup' | 'history' | 'files' | 'send' | 'looks' | 'quit';
  label: string;
  body: string;
};

export const BENTO: { tiles: Tile[] } = {
  tiles: [
    { scene: 'hero', label: 'Ghostty’s engine, in every session', body: 'Every session is a real terminal on Ghostty’s engine, unmodified. An agent is one more command in it.' },
    { scene: 'worktree', label: 'A worktree per agent', body: 'A session on a branch gets its own directory and files, so several agents share one repository without colliding.' },
    { scene: 'palette', label: 'Every command on ⇧⌘P', body: 'A command palette on ⇧⌘P runs any command, and ⌘P goes to any session by name, or any file in its project.' },
    { scene: 'splits', label: 'Splits, each with its own tabs', body: 'Everything beside the sidebar is made of splits, and every split has its own row of tabs: a terminal, a browser, a file, your changes.' },
    { scene: 'markup', label: 'Mark up what you see', body: 'Mark Up draws on a page, a diff, source, rendered Markdown or an image, and copies your note as text an agent can read.' },
    { scene: 'history', label: 'The branch graph', body: 'History is the commit list with its branch graph, in a tab beside the terminal.' },
    { scene: 'files', label: 'The project tree', body: 'Files is the project as a tree. Drag a row into the terminal and its path lands at your prompt.' },
    { scene: 'quit', label: 'Outlives the app', body: 'Shells run outside the app. After a quit, an update or a crash, each session is as you left it.' },
    { scene: 'looks', label: 'Follows light and dark', body: 'Every terminal follows the system between light and dark, at once.' },
    { scene: 'send', label: 'Agents that work together', body: 'Every session has the wortel command on its PATH. One agent can hand another a task, wait for it, and read what it said.' },
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
export type Head = Beta & {
  title: string;
  tone?: string;
  body?: string;
  /** Where it goes further, under the heading: the feature's own page
   *  (/layouts, /mark-up), or a part of /docs. */
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
    body: 'Every session is a real shell on Ghostty’s engine. Type `claude`, `codex` or `pi` and the agent runs in it. Name yours once in Settings and `⌘N` opens every new session with it already running.',
    link: ['How new sessions start', '/docs#new-sessions'],
  },
  agents: {
    title: 'Know which one needs you',
    tone: 'The agent says so, Wortel shows it',
    body: 'Claude Code, Codex, Pi, opencode and others report when they are working, waiting on you, done or failed. A dot in the sidebar, a notification for a session out of sight, and `⌥⇧⌘↓` takes you there.',
    link: ['How the agents report', '/docs#agent-detection'],
  },
  // This entry, the section that reads it (components/home/Review.astro) and
  // its line in pages/index.astro go together. The keys it names are the
  // beta's, so it carries the flag.
  review: {
    title: 'See what it did',
    tone: 'The diff, the commits, the files',
    body: 'When an agent says it is done, its work is one key away. `⇧⌘C` opens Changes beside the terminal, `⇧⌘H` the commits with their graph and `⇧⌘F` the project as a tree. Pick a file and it opens in a preview tab: its source, its diff or rendered Markdown.',
    link: ['The keys for each', '/docs#shortcuts'],
    beta: true,
  },
  window: {
    title: 'Split it anywhere',
    tone: 'Every split has its own tabs',
    body: '`⌘D` splits where you are and `⇧⌘D` splits it down. Drag a tab to the edge of any split and it makes a new one there. Every split has its own row of tabs: a terminal, a browser, a file, your changes. `⇧⌘↩` gives one the whole window.',
    link: ['Everything a layout does', '/layouts'],
    beta: true,
  },
  // This entry, the section that reads it (components/home/Markup.astro) and
  // its line in pages/index.astro go together.
  markup: {
    title: 'Show it what you mean',
    tone: 'Point at it, say it, paste it',
    body: 'Mark Up `⇧⌘M` works on a page, a diff, source, rendered Markdown or an image. Click an element or draw around anything, write one sentence around the marks, and Return copies it as text an agent can read. Nothing is sent for you.',
    link: ['Everything mark-up does', '/mark-up'],
    beta: true,
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
// The feature pages: one feature, in depth. /mark-up and /layouts.
//
// A feature page sits between the homepage, which makes the point once, and
// /docs, which states it exactly: it shows everything the feature does, a
// part at a time. components/FeaturePage.astro lays one out from a
// FeaturePage, and data/markdown.ts writes its Markdown from the same object:
//   heading, tone, lead   the page's opening lines, over its first film
//   parts                 one section each, opening with the homepage's row
//                         (a two-line heading, one short paragraph, a link)
//                         over what the page file puts in the slot named for
//                         the part's id, with short facts under it
//   reference             rows to read, as /docs has them: keys, the exact
//                         behaviour
//   more                  where to go from here: the other feature pages and
//                         the reference
// To add a page: write its FeaturePage here, add it to FEATURE_PAGES, and
// give it a file in pages/ that fills the slots (pages/mark-up.astro), a
// Markdown twin (pages/mark-up.md.ts) and a line in pages/sitemap.xml.ts.
// ==========================================================================
export type FeaturePart = Head & {
  id: string;
  /** Short points under what the part shows: a few words, then a sentence. */
  facts?: [string, string][];
  /** Something the part shows as text (what is on the clipboard): the page
   *  file places it, and the Markdown prints it under the paragraph. */
  code?: { label: string; text: string };
};
export type FeaturePage = Beta & {
  path: string;
  /** The link to it, where another page lists it, and the sentence beside it. */
  name: string;
  blurb: string;
  /** Under about 60 characters, and about 150. */
  title: string;
  description: string;
  heading: string;
  tone: string;
  lead: string;
  /** The quiet button beside Download: the part of /docs that goes further. */
  docs: readonly [text: string, href: string];
  parts: FeaturePart[];
  reference: Section[];
  /** Where to go from here, after the other feature pages. */
  more: { name: string; blurb: string; href: string }[];
};

/** The note the page's two tiles show, first in its bar and then as Return
 *  puts it on the clipboard: what is typed, around the two marks the canvas
 *  draws on the page (a link picked with a click, a box drawn round the
 *  paragraph). It is the film's note with a second sentence, so the bar
 *  stands as tall as the text it becomes. */
/** The labels of the tiles on /mark-up (components/markup/Tiles.astro). */
export const MARKUP_TILES = {
  pick: 'A click picks an element',
  draw: 'A drag draws on anything',
  bar: 'The note, in its bar',
} as const;
export const MARKUP_NOTE = {
  words: ['Make ', ' the accent colour, and ', ' needs more room above it. On a phone it runs to four lines and touches the button.'],
  marks: ['link “Download for macOS”', 'box'],
} as const;
/** That note as it is copied: the sentence with each mark as its name and
 *  its picture's path, an empty line, the page, the picture of the whole and
 *  the details file (macos/Wortel/Markup/MarkupNote.swift, copied). The
 *  folders are the ones a first note of a day gets, with the cache folder cut
 *  short. */
const MARKUP_COPIED = [
  MARKUP_NOTE.words.map((w, i) => (i ? `${MARKUP_NOTE.marks[i - 1]} (~/Library/Caches/…/Markup/2026-11-27/1/${i}.png)` : '') + w).join(''),
  '',
  'Page: http://localhost:4321/',
  'All marks: ~/Library/Caches/…/Markup/2026-11-27/1/whole.png',
  'Details: ~/Library/Caches/…/Markup/2026-11-27/1/details.json',
].join('\n');

export const MARKUP_PAGE: FeaturePage = {
  path: '/mark-up',
  name: 'Mark-up',
  blurb: 'Point at what a preview shows, write one sentence around the marks, and paste it to an agent.',
  /** 46 chars. */
  title: 'Mark-up in Wortel: show an agent what you mean',
  /** 152 chars. */
  description:
    'Mark Up draws on a page, a diff, source, rendered Markdown or an image in Wortel, and copies your note as plain text with pictures, for any coding agent.',
  heading: 'Mark up what you see',
  tone: 'Then paste it to an agent',
  lead: 'Mark Up `⇧⌘M` draws on what a preview shows: a page, a file, its diff, an image. You write one sentence around the marks, and Return copies it as text any agent can read.',
  docs: ['Mark-up in the docs', '/docs#mark-up'],
  beta: true,
  parts: [
    {
      id: 'surfaces',
      title: 'On whatever is in front',
      tone: 'A page, a file, its diff, an image',
      body: 'Mark Up is a button in every preview’s header. It works over a page in a browser tab, a file’s source, its diff, rendered Markdown and an image, in a tab or in a preview window. Not over a PDF, or anything else Quick Look shows.',
      link: ['The browser tab', '/docs#browser'],
    },
    {
      id: 'marks',
      title: 'Click it, or draw on it',
      tone: 'Each mark gets a colour and a number',
      body: 'A click picks an element of a page. A drag draws around anything, with a box, a pen, an arrow or a highlighter. Each mark lands in your note as a chip with its number, and deleting the chip removes the mark.',
    },
    {
      id: 'note',
      title: 'Write around the marks',
      tone: 'Return copies it as plain text',
      body: 'A bar at the bottom of the preview holds your note, with each mark in it as a chip. Return copies it and turns mark-up off. Paste it to the agent in this session or another. Nothing is typed into a terminal and nothing is sent.',
      link: ['Exactly what is copied', '/docs#mark-up'],
      code: { label: 'On the clipboard', text: MARKUP_COPIED },
    },
  ],
  reference: [
    {
      id: 'keys',
      title: 'The keys',
      blocks: [
        {
          table: {
            head: ['Action', 'Shortcut'],
            mono: 'last',
            rows: [
              ['Mark up the page or file in front, and stop', '⇧⌘M'],
              ['Copy the note, and stop', 'Return'],
              ['Stop, and keep the note', 'Esc'],
            ],
          },
        },
        { p: 'Mark Up is also a button in a preview’s header, and View ▸ Mark Up.' },
      ],
    },
    {
      id: 'kept',
      title: 'What is kept',
      blocks: [
        { p: 'Esc stops and keeps the note. The note is dropped when the preview goes elsewhere: another address, a reload, a file switched between Diff, Source and Rendered, a closed tab.' },
        { p: 'The pictures stay on your Mac, in Wortel’s cache folder, and are removed after seven days.' },
      ],
    },
  ],
  more: [
    { name: 'The reference', blurb: 'Every shortcut and command, and the parts worth knowing exactly.', href: '/docs' },
    { name: 'Everything around the terminal', blurb: 'Worktrees, the command palette, a browser, and sessions that outlive the app.', href: '/#more' },
  ],
};

export const LAYOUTS_PAGE: FeaturePage = {
  path: '/layouts',
  name: 'Layouts',
  blurb: 'Splits, tabs, zoom and windows: how the window bends to the work.',
  /** 49 chars. */
  title: 'Layouts in Wortel: splits, tabs, zoom and windows',
  /** 151 chars. */
  description:
    'Split a Wortel window anywhere with ⌘D or by dragging a tab. Every split has its own tabs, ⇧⌘↩ gives one the whole window, and ⇧⌘N opens another window.',
  heading: 'Arrange it as you go',
  tone: 'Splits, tabs, zoom and windows',
  lead: 'Everything beside the sidebar is made of splits. `⌘D` splits where you are and `⇧⌘D` splits it down, a dragged tab makes a split where you let it go, and `⇧⌘↩` gives one the whole window.',
  docs: ['Splits in the docs', '/docs#splits'],
  beta: true,
  parts: [
    {
      id: 'tabs',
      title: 'Every split has its own tabs',
      tone: 'A terminal, a browser, a file, your changes',
      body: 'A split holds a row of tabs, and a tab is a terminal, a browser, a file or one of the git panes: Changes, History, Files. So the diff can sit beside the agent that made it, with the plan in front of its terminal. A split is there while it holds a tab, and gone when its last one closes.',
      link: ['Splits and tabs', '/docs#splits'],
      facts: [
        ['A new tab asks', 'The + in a split’s row, or `⌥⌘T`, opens an empty tab that lists what it can become. Click one, or press its first letter.'],
        ['Or skip the list', '`⌘T` is a terminal, `⇧⌘B` a browser, `⇧⌘C` Changes, `⇧⌘H` History and `⇧⌘F` Files.'],
        ['A file is a tab too', 'A file you pick in Changes or Files opens in a preview tab, and the next one you pick takes its place. Double-click it to keep it.'],
      ],
    },
    {
      id: 'windows',
      title: 'More than one window',
      tone: 'Each with a sidebar of its own',
      body: 'Window ▸ New Window `⇧⌘N` opens another window with its own sidebar. Drag a session onto another window’s sidebar to move it there, or out of the window to give it one of its own. It keeps running as it is, agent and all.',
      link: ['More than one window', '/docs#windows'],
      facts: [
        ['From a session’s menu', 'Move to New Window and Move to Window do the same without a drag.'],
        ['Back to one', 'Window ▸ Merge All Windows puts every session back in one window.'],
        ['Closing asks first', 'Closing a window closes its sessions, and asks first if something is still running in them.'],
      ],
    },
  ],
  reference: [
    {
      id: 'start',
      title: 'Where it starts',
      blocks: [
        { p: 'A session starts with one split, its terminal, and Wortel opens two more where they have always been: `⌥⌘B` opens Changes and Files in a split at the right edge and closes them again, and `⌘J` takes you to a terminal under the main one, making it if there is none. So there is no layout to build before the window is useful.' },
        { p: 'Nothing is hidden with its tabs kept. When the splits have got away from you, View ▸ Reset Layout puts every tab back where a session starts with it, and closes nothing.' },
      ],
    },
    {
      id: 'keys',
      title: 'The keys',
      blocks: [
        {
          table: {
            head: ['Action', 'Shortcut'],
            mono: 'last',
            rows: [
              ['Split right, with a new terminal', '⌘D'],
              ['Split down, with a new terminal', '⇧⌘D'],
              ['New tab that asks what it should be', '⌥⌘T'],
              ['Focus the next / previous split', '⌘] / ⌘['],
              ['Focus the split to the left / right / above / below', '⌃⌥⌘ ← → ↑ ↓'],
              ['Move the tab in front to the split on that side', '⌃⌘ ← → ↑ ↓'],
              ['Zoom the split you are in, and show all of them again', '⇧⌘↩'],
              ['Make the splits equal', '⌃⌘='],
              ['Show or hide the sidebar', '⌘B'],
              ['New window', '⇧⌘N'],
            ],
          },
        },
        { p: 'The two buttons at the end of a split’s row split it the same two ways, with an empty tab that asks what goes there. The line between two splits drags.' },
      ],
    },
    {
      id: 'command',
      title: 'From a command',
      blocks: [
        { p: 'An agent, a hook or a script can split the window too, with the `wortel` command every session has on its `PATH`.' },
        {
          table: {
            head: ['Command', 'What it does'],
            mono: 'first',
            rows: [
              ['wortel split', 'A new terminal in a split beside the session’s own. The keyboard stays where it is'],
              ['wortel split down -- <command>', 'The same under it, running a command: a dev server, a log'],
            ],
          },
        },
      ],
    },
  ],
  more: [
    { name: 'The reference', blurb: 'Every shortcut and command, and the parts worth knowing exactly.', href: '/docs' },
    { name: 'Everything around the terminal', blurb: 'Worktrees, the command palette, a browser, and sessions that outlive the app.', href: '/#more' },
  ],
};

/** Every feature page, in the order another page lists them. */
export const FEATURE_PAGES: FeaturePage[] = [LAYOUTS_PAGE, MARKUP_PAGE];

// ==========================================================================
// /learn: Wortel in the order a day asks for it.
//
// The homepage makes each point once, /docs states it exactly, and a feature
// page shows one feature in depth. /learn is the guided walk between them:
// one working day, from the first agent in the morning to the ones still
// working after you quit, in parts that each show the real window and say
// which keys to press. A part's `steps` are the film's chapters, in order
// (components/learn/Steps.astro follows the film and the film follows them);
// a part with no film has steps that stand on their own.
//
// The page's thread is the name: wortel is root. The window is what is above
// the surface; under it are the branches an agent works on (worktrees) and
// the process that keeps every shell running when the window is gone. The
// last part says so out loud, with the window taken away and put back.
//
// pages/learn.astro lays it out, pages/learn.md.ts writes the same words as
// Markdown, and llms-full.txt carries them.
// ==========================================================================
export type Step = {
  /** A word or two over it: with a film, the chapter's own name. */
  name: string;
  /** What is pressed or typed, each chord one item: '⇧⌘C', 'Return', '`claude`'. */
  keys?: string[];
  text: string;
};
export type LearnPart = Head & {
  id: string;
  /** The time of day the part happens at, over its heading. */
  at: string;
  /** In order. With a film, one per chapter. */
  steps?: Step[];
};
export const LEARN = {
  path: '/learn',
  /** 53 chars. */
  title: 'Learn Wortel: a working day with agents, step by step',
  /** 150 chars. */
  description:
    'A guided day in Wortel, the macOS terminal for coding agents: start an agent, give it a branch, see what it did, and quit while it keeps on working.',
  heading: 'A day with Wortel',
  tone: 'Learn it in the order you need it',
  lead: 'One working day, from the first agent in the morning to the ones still working after you quit. Each part shows the real window, then the keys to try it with.',
  /** The index under the opening: the day, part by part. */
  dayLabel: 'The day, part by part',
  parts: [
    {
      id: 'start',
      at: '08:30',
      title: 'Start an agent',
      tone: 'It is one more command',
      body: 'A session is a real shell on Ghostty’s engine, and an agent is whatever you type in it. Tell Settings which one is yours, and every new session opens with it running.',
      link: ['How new sessions start', '/docs#new-sessions'],
      steps: [
        { name: 'A shell', keys: ['⌘N'], text: 'A new session is a shell, with a row of its own in the sidebar.' },
        { name: 'An agent', keys: ['`claude`'], text: 'Type your agent’s command, `claude`, `codex` or `pi`, and it runs right there.' },
        { name: 'Settings', keys: ['⌘,'], text: 'In Settings, “New sessions start with” takes that command, or one Wortel found on your Mac.' },
        { name: 'Every new session', keys: ['⌘N'], text: 'Now every new session opens with your agent running. `⌃⌘N` still opens a plain shell.' },
      ],
    },
    {
      id: 'branches',
      at: '09:15',
      title: 'Give each agent a branch',
      tone: 'One repository, no collisions',
      body: 'Two agents in one checkout edit the same files. A worktree session checks a branch out in a folder of its own that shares the repository’s history, so each agent has its own files, and it costs a folder rather than a clone.',
      link: ['What a worktree session does', '/docs#worktree-behaviour'],
      steps: [
        { name: 'A worktree session', keys: ['⌥⇧⌘N'], text: 'New Worktree Session asks for a branch. A new one forks from the default branch, not from where you are.' },
        { name: 'Or from a command', keys: ['`wortel new --branch hero-photo`'], text: 'The same from a terminal, so an agent can start one too.' },
        { name: 'Closing keeps it', keys: ['⇧⌘W'], text: 'Closing it keeps the branch and its work, and `⌘P` brings the session back.' },
      ],
    },
    {
      id: 'signals',
      at: '10:40',
      title: 'Read the sidebar',
      tone: 'Colour only when something happened',
      body: 'Every session is a row, named for its work. The only colour in the sidebar is what an agent reported about itself: working, needs you, done. Point at a signal to see where it shows up.',
      link: ['How the agents report', '/docs#agent-detection'],
    },
    {
      id: 'needs-you',
      at: '11:20',
      title: 'Go where you are needed',
      tone: 'One key to the next one waiting',
      body: 'While you work in one session the others carry on. One that stops for you out of sight sends a notification with the start of its question, and one key takes you there.',
      steps: [
        { name: 'At work', text: 'You work in one session. The others carry on, each with its status in the sidebar.' },
        { name: 'Needs you', text: 'One stops for your permission: an orange dot, and a notification, because it is out of sight.' },
        { name: 'Go to it', keys: ['⌥⇧⌘↓'], text: 'Takes you to the next session waiting. A click on the notification or the row does the same.' },
        { name: 'Answered', keys: ['Return'], text: 'Answer, and it gets back to work. The dot is gone once you have seen it.' },
      ],
    },
    {
      id: 'review',
      at: '13:30',
      title: 'See what it did',
      tone: 'The diff, the commits, the files',
      body: 'When the dot says done, the work is one key away, in a split beside the terminal: the diff, the commits with their graph, and the project as a tree.',
      link: ['The keys for each', '/docs#shortcuts'],
      beta: true,
      steps: [
        { name: 'Changes', keys: ['⇧⌘C'], text: 'The working tree file by file, each with its diff, and a place to write the commit.' },
        { name: 'History', keys: ['⇧⌘H'], text: 'The commits, with their branch graph, beside the terminal.' },
        { name: 'Files', keys: ['⇧⌘F'], text: 'The project as a tree. Drag a row into the terminal and its path lands at the prompt.' },
        { name: 'Preview', keys: ['Space'], text: 'A file opens in a preview tab: source, diff or rendered Markdown. Double-click it to keep it.' },
      ],
    },
    {
      id: 'mark-up',
      at: '14:10',
      title: 'Show it what you mean',
      tone: 'Point at it, say it, paste it',
      body: '“This one, a bit higher” is hard to type. Mark Up draws on a page, a diff, source or an image, and copies your sentence with its marks as text any agent can read.',
      link: ['Everything mark-up does', '/mark-up'],
      beta: true,
      steps: [
        { name: 'Point', keys: ['⇧⌘M'], text: 'Mark Up, over the page. Click an element, or drag around anything.' },
        { name: 'Say it', text: 'Write one sentence around the marks. Each sits in it as a chip with its number.' },
        { name: 'Copy', keys: ['Return'], text: 'Copies the note, with a picture of each mark, and turns mark-up off.' },
        { name: 'Paste', keys: ['⌘V'], text: 'Paste it to the agent. Nothing was typed or sent for you.' },
      ],
    },
    {
      id: 'arrange',
      at: '15:45',
      title: 'Make room',
      tone: 'Split it, drag it, zoom it',
      body: 'Everything beside the sidebar is made of splits, and each has its own tabs. Split where you are, drag a tab where you want it, and give one split the whole window for as long as you need it.',
      link: ['Everything a layout does', '/layouts'],
      beta: true,
      steps: [
        { name: 'Split', keys: ['⇧⌘D'], text: 'Splits the terminal down, with a new shell for the dev server. `⌘D` splits to the right.' },
        { name: 'Drag a tab', text: 'Drag a tab to the edge of a split to make a new one there, or onto its middle to join it.' },
        { name: 'Zoom', keys: ['⇧⌘↩'], text: 'Gives the split you are in the whole window. Press it again for the rest.' },
      ],
    },
    {
      id: 'together',
      at: '17:00',
      title: 'Let them work together',
      tone: 'The wortel command, in every session',
      body: 'Every session has `wortel` on its `PATH`. One agent can hand another a task, wait for it and read what it said. A hook or a script can open a file, a split or a session the same way.',
      link: ['Every command', '/docs#command'],
      steps: [
        { name: 'Hand it a task', keys: ['`wortel send`'], text: 'Types into another session as a paste. `--enter` presses Return after it.' },
        { name: 'Wait for it', keys: ['`wortel wait`'], text: 'Waits until that session is idle, or until some text appears on its screen.' },
        { name: 'Read what it said', keys: ['`wortel read`'], text: 'Prints what is on its screen, for the agent that asked.' },
      ],
    },
    {
      id: 'keys',
      at: '18:30',
      title: 'Learn the keys as you go',
      tone: 'Hold a modifier to see what it does',
      body: 'Most of Wortel is a key away, and the keys follow the Mac’s own habits. Hold `⌘`, `⇧` or `⌥` on your keyboard, or press them below, and the keys that do something light up. In the app, `⌘/` lists them all.',
      link: ['Every shortcut', '/docs#shortcuts'],
    },
    {
      id: 'roots',
      at: '23:00',
      title: 'Quit, and it carries on',
      tone: 'Wortel is Dutch for root',
      body: 'The window is what you see. Under it, a small process holds every shell and what it printed. Quit, update or crash: the agents keep working, and the window comes back to them as they are.',
      link: ['The parts underneath', '/docs#internals'],
    },
  ] satisfies LearnPart[],
  /** The worktree diagram (components/learn/Branches.astro): one repository
   *  at the surface, and the folders its branches grow into under it. */
  branches: {
    repo: { path: '~/Developer/shop', branch: 'main', who: 'You' },
    trees: [
      { path: '~/.wortel/worktrees/shop/hero-photo', branch: 'hero-photo', who: 'Claude Code' },
      { path: '~/.wortel/worktrees/shop/pricing-copy', branch: 'pricing-copy', who: 'Codex' },
      { path: '~/.wortel/worktrees/shop/checkout-bug', branch: 'checkout-bug', who: 'Pi' },
    ],
    shared: 'Each folder shares the repository’s history, objects and remotes.',
  },
  /** The sidebar's signals (components/learn/Signals.astro), as DESIGN.md
   *  lists them under "A session, in the sidebar". `dot` is how it is drawn. */
  signals: [
    { dot: 'working', name: 'Working', text: 'Three small dots in a wave: a turn or a long command is running.' },
    { dot: 'attention', name: 'Needs you', text: 'An orange dot: a permission, a question. Also on the Dock and, out of sight, a notification.' },
    { dot: 'done', name: 'Done', text: 'A mint dot: the agent’s turn ended. Your move.' },
    { dot: 'failed', name: 'Failed', text: 'A red dot: the turn or the command ended in an error.' },
    { dot: 'branch', name: 'On a branch', text: 'A grey line under the name, with a branch mark: a worktree session.' },
    { dot: 'folder', name: 'In a folder', text: 'Sessions filed together under one name. Folded, it shows the loudest dot inside it.' },
  ],
  /** The together part's terminal (components/learn/Together.astro): what is
   *  typed in the session in front, and what the other session prints. */
  together: {
    to: 'Pricing FAQ copy',
    lines: [
      { cmd: 'wortel send Pricing "Shorten each answer to two sentences." --enter' },
      { cmd: 'wortel wait Pricing --timeout 5m' },
      { cmd: 'wortel read Pricing --lines 2', out: ['⏺ Done. Every answer is two sentences now, and', '  none of them lost a fact.'] },
    ],
  },
  /** The keyboard (components/learn/Keyboard.astro). */
  keyboard: {
    hint: 'Hold a modifier, or press one here',
    none: 'Nothing in Wortel on these keys.',
  },
  /** The last part's film (components/learn/Waterline.astro): the window
   *  above the surface, and under it the process that holds every shell,
   *  printing on whether the window is there or not. Each shell's lines are
   *  what it prints, a chapter at a time. */
  waterline: {
    above: 'What you see',
    below: 'What keeps it running',
    keeper: 'The process that keeps your terminals running',
    gone: 'Wortel is not running. The shells are.',
    shells: [
      { name: 'Landing page hero', agent: 'claude', lines: ['Resizing hero.jpg to 2400 wide', 'Inlining the critical CSS', 'Running npm run build', 'Done. The hero loads in half the time.'] },
      { name: 'Pricing FAQ copy', agent: 'codex', lines: ['Reading pricing.md', 'Rewriting answer 3 of 9', 'Rewriting answer 7 of 9', 'Done. Nine answers, two sentences each.'] },
      { name: 'Changelog typography', agent: 'pi', lines: ['Reading the changelog styles', 'Setting dates in tabular figures', 'Tightening the heading leading', 'Checking it in light and dark'] },
    ],
    /** The film's chapters, and the steps under it. */
    steps: [
      { name: 'At work', text: 'Three agents at work, each in a session of its own.' },
      { name: 'Quit', keys: ['⌘Q'], text: 'The window goes. Nothing under it stops.' },
      { name: 'Still at work', text: 'The shells keep printing, and an agent can finish its turn with nobody watching.' },
      { name: 'Open again', text: 'Each session comes back to the shell it had, with everything it printed meanwhile.' },
    ] satisfies Step[],
  },
  /** Where to go after the day: the feature pages, then the rest. */
  more: [
    ...FEATURE_PAGES.map((p) => ({ name: p.name, blurb: p.blurb, href: p.path })),
    { name: 'The reference', blurb: 'Every shortcut and command, and the parts worth knowing exactly.', href: '/docs' },
    { name: 'About', blurb: 'Why Wortel exists, and the six things it will not trade away.', href: '/about' },
  ],
  closing: {
    title: 'Tomorrow, at first light',
    tone: 'Everything where you left it',
    body: 'Open the lid and the sessions are there, with what they printed overnight. The reference has every key and command, and the feature pages go deeper.',
  },
} as const;

// ---- the keys, for the keyboard on /learn ---------------------------------
// What each key does with each set of modifiers held, from the shortcut table
// in DOCS_SECTIONS (#shortcuts) below: change one with the other. A set is
// written in the order macOS writes it, ⌃⌥⇧⌘. A key is named as its cap
// says (components/learn/Keyboard.astro): a letter, a digit, a sign, or
// Return, Tab and the four arrows. `1…9` is the nine digits, one row.
export const KEYMAP: Record<string, [key: string, action: string, Beta?][]> = {
  '⌘': [
    ['N', 'New session'], ['T', 'New terminal tab where you are'], ['W', 'Close tab'],
    ['D', 'Split right, with a new terminal', { beta: true }], ['P', 'Go to a session or a file'],
    ['B', 'Show or hide the sidebar'], ['J', 'The terminal below, making one if there is none'],
    ['K', 'Clear the terminal'], ['O', 'Open a folder'], ['Y', 'Find a prompt you typed to an agent'],
    ['L', 'Browser: address field'], ['R', 'Browser: reload'], ['F', 'Find in a file or a page'], ['G', 'Next match'],
    ['A', 'Clear the input line'],
    ['1…9', 'Jump to a session by its place in the sidebar'],
    ['0', 'Reset font size'], ['-', 'Smaller font'], ['=', 'Larger font'],
    ['[', 'Focus the previous split'], [']', 'Focus the next split'],
    [',', 'Settings'], ['/', 'List every shortcut'],
    ['↑', 'Jump to the previous prompt'], ['↓', 'Jump to the next prompt'],
  ],
  '⇧⌘': [
    ['N', 'New window'], ['P', 'Run a command'], ['D', 'Split down, with a new terminal', { beta: true }],
    ['W', 'Close session'], ['T', 'Reopen closed tab'], ['B', 'New browser tab', { beta: true }],
    ['C', 'Show Changes', { beta: true }], ['H', 'Show History', { beta: true }], ['F', 'Show Files', { beta: true }],
    ['M', 'Mark up the page or file in front', { beta: true }], ['U', 'Mark session as unread'],
    ['A', 'Select all'], ['G', 'Previous match'], ['Return', 'Zoom the split you are in, and back', { beta: true }],
    ['[', 'Previous tab'], [']', 'Next tab'],
  ],
  '⌥⌘': [
    ['N', 'New session at home'], ['P', 'Pin or unpin session'], ['R', 'Rename session'],
    ['T', 'New tab that asks what it should be', { beta: true }], ['B', 'Changes and Files beside the terminal'],
    ['L', 'Focus the list in Changes, History or Files'], ['U', 'Browser: a page from a file, its source and back', { beta: true }],
    ['↑', 'Previous session'], ['↓', 'Next session'],
  ],
  '⌥⇧⌘': [['N', 'New worktree session'], ['↓', 'Jump to the next waiting session']],
  '⌃⌘': [
    ['N', 'New terminal, without the command Settings starts'], ['F', 'Full screen'],
    ['=', 'Make the splits equal', { beta: true }], ['[', 'Back through the sessions and tabs you were on'], [']', 'Forward again'],
    ['←', 'Move the tab to the split on the left', { beta: true }], ['→', 'Move the tab to the split on the right', { beta: true }],
    ['↑', 'Move the tab to the split above', { beta: true }], ['↓', 'Move the tab to the split below', { beta: true }],
  ],
  '⌃⌥⌘': [
    ['N', 'New terminal at home, without the command'],
    ['←', 'Focus the split on the left', { beta: true }], ['→', 'Focus the split on the right', { beta: true }],
    ['↑', 'Focus the split above', { beta: true }], ['↓', 'Focus the split below', { beta: true }],
  ],
  '⌃⇧': [['G', 'Show source control'], ['`', 'New terminal tab under the main terminal'], ['Tab', 'Previous tab']],
  '⌃': [['`', 'The terminal below, and back'], ['Tab', 'Next tab']],
};

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
  /** For someone who came here first: the guided day. */
  learn: ['New to Wortel? Learn it in a day', '/learn'],
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
            ['wortel open <path>', 'Opens a file in a tab, an .html file as a page'],
            ['wortel new --branch <name>', 'A session, in its own worktree'],
            ['wortel new --branch <name> --from <ref>', 'Forks the new branch from something else'],
            ['wortel rename <name>', 'Renames the session it was run in'],
            ['wortel notify <text>', 'This session wants you'],
            ['wortel mark <colour>', 'Colours the session in the sidebar'],
            ['wortel remind <when>', 'Brings the session back to you later'],
            ['wortel cd <dir>', 'Moves the session, and its agent, to another folder'],
            ['wortel close', 'Closes the session when the agent is done, and its worktree with it'],
            ['wortel split', 'A new terminal in a split beside the session’s own. The keyboard stays where it is', { beta: true }],
            ['wortel split down -- <command>', 'The same under it, running a command: a dev server, a log', { beta: true }],
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
      {
        p: '`wortel new` files its session by where the command was run, not by what is selected: in the folder that covers its directory, right after the session that ran it. Closing the new session takes you back there.',
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
            ['Open Changes and Files beside the terminal, or close them', '⌥⌘B'],
            ['Go to the terminal below, making one if there is none, and back', '⌘J or ⌃`'],
            ['Show Changes / History / Files', '⇧⌘C / ⇧⌘H / ⇧⌘F', { beta: true }],
            ['Show source control', '⌃⇧G'],
            ['Focus the list in Changes, History or Files', '⌥⌘L'],
            ['New tab that asks what it should be', '⌥⌘T', { beta: true }],
            ['New terminal tab where you are', '⌘T'],
            ['Split right, with a new terminal', '⌘D', { beta: true }],
            ['Split down, with a new terminal', '⇧⌘D', { beta: true }],
            ['New terminal tab under the main terminal', '⌃⇧`'],
            ['New browser tab', '⇧⌘B', { beta: true }],
            ['Reopen closed tab', '⇧⌘T'],
            ['Next / previous tab', '⇧⌘] / ⇧⌘[ or ⌃Tab ⌃⇧Tab'],
            ['Focus the next / previous split', '⌘] / ⌘['],
            ['Focus the split to the left / right / above / below', '⌃⌥⌘ ← → ↑ ↓', { beta: true }],
            ['Move the tab in front to the split on that side', '⌃⌘ ← → ↑ ↓', { beta: true }],
            ['Zoom the split you are in, and show all of them again', '⇧⌘↩', { beta: true }],
            ['Make the splits equal', '⌃⌘=', { beta: true }],
            ['Browser: address field', '⌘L'],
            ['Browser: reload', '⌘R'],
            ['Browser: back / forward', '⌘[ / ⌘]'],
            ['Browser: a page from a file, its source and back', '⌥⌘U', { beta: true }],
            ['Find in a file or a page, next / previous match', '⌘F, ⌘G / ⇧⌘G'],
            ['Mark up the page or file in front, and stop', '⇧⌘M', { beta: true }],
            ['Mark-up: copy the note, and stop', 'Return', { beta: true }],
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
        p: 'In Settings `⌘,`, “New sessions start with” takes any command. Type one, like `claude` or `codex`, or pick one of the agents Wortel finds on your Mac from the menu beside it, and every new session starts with it: `⌘N`, `⌥⌘N`, `⌥⇧⌘N`, `⌘O`, a folder’s + and a folder dropped on the sidebar.',
      },
      {
        p: 'Session ▸ New Terminal `⌃⌘N` opens one without it, and only exists while the field is filled. Left empty, a new session is a plain terminal. `wortel new` and the sessions brought back at launch never use it.',
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
    id: 'splits',
    title: 'Splits and tabs',
    beta: true,
    lead: 'Everything beside the sidebar is made of splits, and each split has a row of tabs of its own.',
    page: ['Layouts, shown step by step', '/layouts'],
    blocks: [
      {
        p: 'A session starts with one split, its terminal, and Wortel opens two more where they have always been: `⌥⌘B` opens Changes and Files in a split at the right edge and closes them again, and `⌘J` takes you to a terminal under the main one, making it if there is none. So there is no layout to build before the window is useful.',
      },
      {
        p: '`⌘D` splits the split you are in to the right and `⇧⌘D` splits it down, each with a new terminal. The two buttons at the end of a split’s row split it the same two ways, with an empty tab that asks what goes there. A tab let go on the edge of a split makes a split there, and let go on its middle moves into it. A split is there while it holds a tab and gone when its last one closes.',
      },
      { h: 'A new tab' },
      {
        p: 'The + in a split’s row, or `⌥⌘T`, opens an empty tab that lists what it can become: Terminal, Browser, Changes, History or Files. Click one, or press its first letter. Each has a key that skips the list: `⌘T`, `⇧⌘B`, `⇧⌘C`, `⇧⌘H` and `⇧⌘F`.',
      },
      { h: 'Moving around' },
      {
        p: '`⌘]` and `⌘[` walk the splits in reading order. ⌃⌥⌘ and an arrow goes to the split on that side, and ⌃⌘ and an arrow moves the tab in front there. The line between two splits drags, and `⌃⌘=` makes them equal.',
      },
      {
        p: 'Nothing is hidden with its tabs kept. To have the whole window for one split, zoom it with `⇧⌘↩`, and press that again for the rest. When the splits have got away from you, View ▸ Reset Layout puts every tab back where a session starts with it, and closes nothing.',
      },
    ],
  },

  {
    id: 'windows',
    title: 'More than one window',
    blocks: [
      {
        p: 'Window ▸ New Window `⇧⌘N` opens another window with a sidebar of its own. Drag a session onto another window’s sidebar to move it there, or out of the window to give it one of its own. It keeps running as it is, agent and all. A session’s menu has Move to New Window and Move to Window, and Window ▸ Merge All Windows puts everything back in one.',
      },
      {
        p: 'Closing a window closes its sessions, and asks first if something is still running in them. New Worktree Session is `⌥⇧⌘N`, since `⇧⌘N` opens a window.',
      },
    ],
  },

  {
    id: 'browser',
    title: 'The browser tab',
    // The tab itself is in 2026.48.1, on ⇧⌘L. What this section says (⇧⌘B,
    // find in a page, an .html file as a page, downloads) is the beta's.
    beta: true,
    blocks: [
      {
        p: '`⇧⌘B` opens a browser tab in the split beside your work, for the site an agent is building. `⌘L`, `⌘R` and `⌘F` reach the browser in front from anywhere, the terminal included: change something, `⌘R`, look.',
      },
      {
        p: 'An `.html` file opens as the page it makes, from `wortel open report.html` or a ⌘-click on its path, and the page loads again when the file changes on disk. `⌥⌘U` shows its source in the same tab, and back.',
      },
      {
        p: 'A download is saved to `~/Downloads` and never replaces a file. Nothing downloaded is opened. A button in the tab’s header lists what was saved.',
      },
    ],
  },

  {
    id: 'mark-up',
    title: 'Marking up a preview',
    beta: true,
    lead: 'Point at what a preview shows and say something about it, for an agent to read.',
    page: ['Mark-up, shown step by step', '/mark-up'],
    blocks: [
      {
        p: 'Mark Up is a button in a preview’s header, View ▸ Mark Up, and `⇧⌘M`. It works over a page in a browser tab, a file’s source, its diff, rendered Markdown and an image, in a tab or a preview window. Not over a PDF or anything else Quick Look shows. A click picks an element of a page, and a drag draws around anything, with a box, a pen, an arrow or a highlighter. Each mark gets a colour and a number.',
      },
      {
        p: 'A bar at the bottom of the preview holds your note, with each mark in it as a chip, so the sentence is written around them. Return copies the note as plain text and turns mark-up off: the sentence, the path of a picture of each mark, the page or file it was about, a picture of the whole with every mark on it, and a file of details. Paste it to an agent, in this session or another. Nothing is typed into a terminal and nothing is sent.',
      },
      {
        p: 'Esc stops and keeps the note, and deleting a chip removes its mark. The note is dropped when you take the preview elsewhere: another address, a reload, a file switched between Diff, Source and Rendered, a closed tab. A reload the page makes by itself, like a dev server’s after an agent saves a file, waits until you copy or press Esc, and Reload in the tab’s header shows a dot while it does. The pictures stay on your Mac, in Wortel’s cache folder, and are removed after seven days.',
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
    a: 'Wortel is a fully native macOS terminal emulator built on Ghostty’s engine, made for working next to coding agents. It is a real terminal first: an agent is one more command in a session, and `⌘N` can start yours for you. It keeps your work in a sidebar of named, persistent sessions, gives each coding agent its own git worktree so several can work one repository at once, keeps those shells running after you quit the app, and ships with no configuration to maintain. A git panel, a file tree and agent activity detection are built in.',
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
    a: 'Wortel runs Ghostty’s engine, so terminal behaviour, throughput and latency are the same. The difference is the app around it. Ghostty gives you tabs, splits and a large configuration file. Wortel has tabs and splits too, on the same keys, `⌘T`, `⌘D` and `⇧⌘D`, and adds a sidebar of named sessions that persist across restarts, a git worktree per session, shells that keep running after the app quits, a built-in git and files inspector, coding-agent activity detection, and next to nothing to configure.',
  },
  {
    q: 'How is Wortel different from iTerm2, Warp, Kitty or Alacritty?',
    a: 'Wortel has no themes, no plugin system and no AI chat box, and its settings are five rows. What it has instead is built around running coding agents: named shells that survive a restart and switch on a click, a git worktree per session so several agents can work one repository at once, shells that keep running after you quit the app, a git and files inspector beside the terminal, and detection of which background agent has stopped and is waiting on you.',
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
    a: 'Both. Everything beside the sidebar is made of splits, each with its own row of tabs, and a tab is a terminal, a browser, a file or one of the git panes. `⌘D` splits where you are to the right and `⇧⌘D` down, and a tab dragged to the edge of a split makes a new one there. Wortel opens two for you where they have always been, Changes and Files beside the terminal on `⌥⌘B` and a second terminal under it on `⌘J`, so there is no layout to build first. A file tab can also be dragged out of the window into a preview window of its own, and back. Switching work is still the sidebar’s job: a split holds tabs, never another session, and `⌘P` finds any session by name.',
  },
  {
    q: 'Can I configure Wortel’s fonts, colours and keybinds?',
    a: 'Only font size, which is adjustable per session with `⌘+` and `⌘−`. Everything else about how the terminal looks and types is fixed: its whole configuration is a read-only file inside the app bundle, and your `~/.config/ghostty` is never read. Settings `⌘,` holds five things that differ per person, such as what a new session starts with, and none of them is about the look. Next to nothing to configure is the design goal, not a missing feature.',
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
    a: 'Yes. A `wortel` command ships inside the app bundle and is on the `PATH` of every session, with no installer and no admin prompt. It speaks to the running app over a socket: `wortel open` opens a file in a tab, `wortel new --branch` opens a session in its own worktree, `wortel rename` renames the session it was run in, `wortel notify` raises attention on it, and `wortel split` opens a terminal in a split beside it, for a dev server or a log. `wortel list`, `read`, `send` and `wait` let one session drive another. That is how Wortel avoids shipping a separate integration per agent: anything that can run a command can drive it, including your own hooks and scripts.',
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
