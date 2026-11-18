// ==========================================================================
// /compare: where Wortel sits among the tools people actually weigh it against.
//
// THE COLUMNS ARE NAMED APPS, NOT CATEGORIES. Nobody wonders how a terminal
// compares to "agent manager apps"; they wonder how it compares to Conductor.
// The categories still exist, as the cards at the top of the page, because they
// are how you find the right column. But the grid answers about products.
//
// The cost of that is repetition: Ghostty and iTerm2 give the same answer nine
// times out of ten, and so do tmux and herdr. That is fine and it is the point.
// A reader comparing against one app reads one column, and a column that says
// the same as its neighbour is information, not noise.
//
// EVERY CELL IS SOURCED, AND `unknown` IS A REAL ANSWER. Each claim below was
// read off that product's own site, docs or repository, never off a competitor's
// comparison page. Where a product does not publish something, the cell says so
// rather than guessing: `unknown` renders as "?" and reads "not published". A
// matrix that quietly rounds an unknown down to "no" is the reason nobody
// believes comparison pages, and it is also how you end up wrong in public
// about someone else's software.
//
// Checked against, at the time of writing:
//   Ghostty, iTerm2, tmux    their own docs and long-standing behaviour
//   Warp                     docs.warp.dev (agent notifications, Rust/GPU client)
//   cmux                     github.com/manaflow-ai/cmux README
//   Conductor                conductor.build and its docs
//   Emdash                   github.com/generalaction/emdash and emdash.ai
//   Superset                 github.com/superset-sh/superset README
//   herdr                    herdr.dev and its compare page
//
// HOUSE RULE, same as site.ts: no em dashes anywhere in copy.
// ==========================================================================

import { SITE } from './site';

/** A cell's verdict. `unknown` is not a hedge, it is "they do not say". */
export type Verdict = 'yes' | 'no' | 'partial' | 'unknown';

export type App = {
  key: string;
  /** How the product spells itself. */
  name: string;
  /** One line under the name in the column head: what kind of thing it is. */
  kind: string;
};

/** The apps, in the order the pickers list them. Wortel first: it is the one
    every other column is being compared against. */
export const APPS: App[] = [
  { key: 'wortel', name: SITE.name, kind: 'Native terminal on Ghostty' },
  { key: 'ghostty', name: 'Ghostty', kind: 'Terminal emulator' },
  { key: 'iterm2', name: 'iTerm2', kind: 'Terminal emulator' },
  { key: 'warp', name: 'Warp', kind: 'Terminal with an agent in it' },
  { key: 'cmux', name: 'cmux', kind: 'Agent terminal on Ghostty' },
  { key: 'conductor', name: 'Conductor', kind: 'Agent manager' },
  { key: 'emdash', name: 'Emdash', kind: 'Agent manager' },
  { key: 'superset', name: 'Superset', kind: 'Agent manager' },
  { key: 'herdr', name: 'herdr', kind: 'Agent runtime' },
  { key: 'tmux', name: 'tmux', kind: 'Terminal multiplexer' },
];

export type Axis = {
  id: string;
  /** The question, spelled out. */
  q: string;
  /** The caption printed under the answer in every cell. Lowercase and short
      because it repeats once per column: this is the "unified memory" under
      Apple's "16GB", not a heading. */
  short: string;
  /** A row that describes rather than scores, so it draws no mark. */
  descriptive?: boolean;
  cells: Record<string, { v: Verdict; note: string }>;
};

export const AXES: Axis[] = [
  {
    id: 'kind',
    q: 'What kind of thing is it',
    short: 'what it is',
    descriptive: true,
    cells: {
      wortel: { v: 'yes', note: 'A terminal, with the review tools in it' },
      ghostty: { v: 'yes', note: 'A terminal emulator' },
      iterm2: { v: 'yes', note: 'A terminal emulator' },
      warp: { v: 'yes', note: 'A terminal with an agent built in' },
      cmux: { v: 'yes', note: 'A terminal arranged for agents' },
      conductor: { v: 'yes', note: 'An app that runs agents for you' },
      emdash: { v: 'yes', note: 'An app that runs agents for you' },
      superset: { v: 'yes', note: 'An app that runs agents, with a terminal in it' },
      herdr: { v: 'yes', note: 'A server your terminal attaches to' },
      tmux: { v: 'yes', note: 'A multiplexer inside your terminal' },
    },
  },
  {
    id: 'terminal',
    q: 'A real terminal you type in',
    short: 'a real terminal',
    cells: {
      wortel: { v: 'yes', note: 'Ghostty’s engine, unmodified' },
      ghostty: { v: 'yes', note: 'The whole point' },
      iterm2: { v: 'yes', note: 'The whole point' },
      warp: { v: 'yes', note: 'A Rust, GPU rendered client' },
      cmux: { v: 'yes', note: 'Ghostty’s engine too' },
      conductor: { v: 'partial', note: 'One per task, inside the app' },
      emdash: { v: 'partial', note: 'It runs CLI agents, in the app' },
      superset: { v: 'yes', note: 'Built in, with tabs and splits' },
      herdr: { v: 'partial', note: 'Inside the terminal you supply' },
      tmux: { v: 'partial', note: 'Inside the terminal you supply' },
    },
  },
  {
    id: 'native',
    q: 'Fully native macOS',
    short: 'fully native macOS',
    cells: {
      wortel: { v: 'yes', note: 'Swift, AppKit, SwiftUI, Metal' },
      ghostty: { v: 'yes', note: 'Swift and AppKit on macOS' },
      iterm2: { v: 'yes', note: 'Objective-C and AppKit' },
      warp: { v: 'partial', note: 'Rust and GPU, drawn rather than AppKit' },
      cmux: { v: 'yes', note: 'Swift and AppKit' },
      conductor: { v: 'unknown', note: 'A Mac app; the stack is not published' },
      emdash: { v: 'no', note: 'Cross-platform desktop app' },
      superset: { v: 'no', note: 'Electron' },
      herdr: { v: 'no', note: 'A terminal user interface' },
      tmux: { v: 'no', note: 'A terminal user interface' },
    },
  },
  {
    id: 'survives',
    q: 'The work survives the window closing',
    short: 'survives quitting',
    cells: {
      wortel: { v: 'yes', note: 'Shells run under a keeper process' },
      ghostty: { v: 'no', note: 'The shell is a child of the app' },
      iterm2: { v: 'no', note: 'The shell is a child of the app' },
      warp: { v: 'no', note: 'The shell is a child of the app' },
      cmux: { v: 'no', note: 'The shell is a child of the app' },
      conductor: { v: 'unknown', note: 'Not published' },
      emdash: { v: 'unknown', note: 'Not published' },
      superset: { v: 'partial', note: 'Sessions survive a restart; processes not stated' },
      herdr: { v: 'yes', note: 'The server owns the shells' },
      tmux: { v: 'yes', note: 'The server owns the shells' },
    },
  },
  {
    id: 'worktree',
    q: 'A git worktree per agent',
    short: 'a worktree per agent',
    cells: {
      wortel: { v: 'yes', note: 'A session opens on a branch' },
      ghostty: { v: 'no', note: 'You run git yourself' },
      iterm2: { v: 'no', note: 'You run git yourself' },
      warp: { v: 'no', note: 'You run git yourself' },
      cmux: { v: 'no', note: 'You run git yourself' },
      conductor: { v: 'yes', note: 'A workspace and a branch per task' },
      emdash: { v: 'yes', note: 'Its core idea' },
      superset: { v: 'yes', note: 'Its core idea' },
      herdr: { v: 'no', note: 'Pairs with a tool that does' },
      tmux: { v: 'no', note: 'You run git yourself' },
    },
  },
  {
    id: 'attention',
    q: 'Knows which agent is waiting on you',
    short: 'knows who is waiting',
    cells: {
      wortel: { v: 'yes', note: 'Read off the terminal stream' },
      ghostty: { v: 'no', note: 'A bell, at best' },
      iterm2: { v: 'no', note: 'A bell, at best' },
      warp: { v: 'yes', note: 'Agent notifications, on by default' },
      cmux: { v: 'yes', note: 'Rings, badges, a notification panel' },
      conductor: { v: 'unknown', note: 'Not published' },
      emdash: { v: 'unknown', note: 'Not published' },
      superset: { v: 'yes', note: 'Indicators, chimes and a Dock badge' },
      herdr: { v: 'yes', note: 'Working, blocked or idle, per pane' },
      tmux: { v: 'no', note: 'Nothing reads the pane' },
    },
  },
  {
    id: 'untouched',
    q: 'Works without touching your agent’s config',
    short: 'touches no agent config',
    cells: {
      wortel: { v: 'yes', note: 'Nothing is installed into any agent' },
      ghostty: { v: 'yes', note: 'Nothing to install' },
      iterm2: { v: 'yes', note: 'Nothing to install' },
      warp: { v: 'partial', note: 'Codex needs a line in its own config' },
      cmux: { v: 'no', note: 'Writes hooks into each agent' },
      conductor: { v: 'unknown', note: 'Not published' },
      emdash: { v: 'yes', note: 'Detects the CLIs you have installed' },
      superset: { v: 'unknown', note: 'Not published' },
      herdr: { v: 'partial', note: 'Prefers hooks, works without them' },
      tmux: { v: 'yes', note: 'Nothing to install' },
    },
  },
  {
    id: 'review',
    q: 'Diffs and history in the same window',
    short: 'diffs in the window',
    cells: {
      wortel: { v: 'yes', note: 'Changes, History, Files and previews' },
      ghostty: { v: 'no', note: 'Another app' },
      iterm2: { v: 'no', note: 'Another app' },
      warp: { v: 'no', note: 'Another app' },
      cmux: { v: 'partial', note: 'Branch and PR status, not diffs' },
      conductor: { v: 'yes', note: 'Review the diff, open a PR, merge' },
      emdash: { v: 'yes', note: 'Diffs, pull requests and CI checks' },
      superset: { v: 'yes', note: 'Inspect, comment on and edit the changes' },
      herdr: { v: 'no', note: 'No window to put it in' },
      tmux: { v: 'no', note: 'No window to put it in' },
    },
  },
  {
    id: 'driveable',
    q: 'Agents can drive it themselves',
    short: 'agents can drive it',
    cells: {
      wortel: { v: 'yes', note: 'A bundled wortel command, over a socket' },
      ghostty: { v: 'partial', note: 'Some CLI actions, no session API' },
      iterm2: { v: 'yes', note: 'A Python API and AppleScript' },
      warp: { v: 'unknown', note: 'Agent APIs; session control not published' },
      cmux: { v: 'yes', note: 'A CLI and a socket API' },
      conductor: { v: 'yes', note: 'A Conductor API' },
      emdash: { v: 'unknown', note: 'Not published' },
      superset: { v: 'yes', note: 'A superset binary and a TypeScript SDK' },
      herdr: { v: 'yes', note: 'The CLI is the API' },
      tmux: { v: 'yes', note: 'send-keys, and a full command set' },
    },
  },
  {
    id: 'noconfig',
    q: 'Next to nothing to configure',
    short: 'next to nothing to configure',
    cells: {
      wortel: { v: 'yes', note: 'Five settings. No config file' },
      ghostty: { v: 'no', note: 'A config file, often a large one' },
      iterm2: { v: 'no', note: 'A large settings window' },
      warp: { v: 'no', note: 'Settings, themes and agent profiles' },
      cmux: { v: 'no', note: 'Reads your Ghostty config' },
      conductor: { v: 'unknown', note: 'Not published' },
      emdash: { v: 'partial', note: 'Detects your CLIs; providers to set up' },
      superset: { v: 'partial', note: 'An optional .superset/config.json' },
      herdr: { v: 'no', note: 'Config, plugins and keybinds' },
      tmux: { v: 'no', note: 'A .tmux.conf' },
    },
  },
];

/** The row groups. Ten ungrouped questions is a wall. */
export const GROUPS: { title: string; blurb: string; axes: string[] }[] = [
  {
    title: 'What kind of tool it is',
    blurb: 'The category each one belongs to, before any feature is counted, and whether the shell is the product or a panel inside it.',
    axes: ['kind', 'terminal', 'native'],
  },
  {
    title: 'Several agents at once',
    blurb: 'What happens when there are four of them: whether they edit the same files, which one is waiting on you, and what survives you quitting.',
    axes: ['survives', 'worktree', 'attention', 'untouched'],
  },
  {
    title: 'Reviewing and driving them',
    blurb: 'What it takes to see what an agent did, to let it act on the app itself, and to keep the whole thing running.',
    axes: ['review', 'driveable', 'noconfig'],
  },
];

// ---- the cards ------------------------------------------------------------
// The categories, which is how you find the right column below. They carry no
// verdicts: everything a card could score is answered in the grid, once, and a
// summary that restates those answers disagrees with them on its third edit.
export type Category = {
  key: string;
  kind: string;
  what: string;
  /** The apps in this category, named. */
  examples: string;
  /** Ours is a download button instead. */
  useIf?: string;
};

export const CATEGORIES: Category[] = [
  {
    key: 'wortel',
    kind: SITE.name,
    what: 'A terminal, with the review tools in it',
    examples: 'Native, on Ghostty’s engine',
  },
  {
    key: 'terminals',
    kind: 'Terminal emulators',
    what: 'A terminal, and nothing else',
    examples: 'Ghostty, iTerm2, Kitty, Alacritty',
    useIf: 'Pick one if you run a single agent and want a terminal, nothing more. Ghostty is excellent, and Wortel runs its engine.',
  },
  {
    key: 'agentTerminals',
    kind: 'Agent terminals',
    what: 'A terminal arranged for agents',
    examples: 'cmux, Warp',
    useIf: 'Pick one if tab layout and notifications are the problem you actually have, and you want your own Ghostty config respected.',
  },
  {
    key: 'managers',
    kind: 'Agent manager apps',
    what: 'An app that runs agents for you',
    examples: 'Conductor, Emdash, Superset',
    useIf: 'Pick one if you want a task board, a review queue and a pull request at the end, and you do not mind the terminal being a panel inside it.',
  },
  {
    key: 'runtimes',
    kind: 'Multiplexers and runtimes',
    what: 'A server your terminal attaches to',
    examples: 'tmux, Zellij, herdr',
    useIf: 'Pick one if the work has to outlive the machine you are sitting at, and you are happy driving it from a terminal you bring yourself.',
  },
];

export const COMPARE = {
  title: `${SITE.name} compared: Ghostty, Warp, cmux, Conductor and more`,
  description:
    `How ${SITE.name} compares with Ghostty, iTerm2 and Warp, with agent managers like ` +
    `Conductor, Emdash and Superset, and with cmux, herdr and tmux, feature by feature.`,
  heading: 'Where Wortel sits',
  lead:
    'Four kinds of tool have grown up around running coding agents, and they are not really competing for the same job. This is the map, with Wortel on it.',

  intro: [
    'If you run one agent at a time, a terminal is a terminal and you should use whichever you like. The moment there are four, three questions start to matter: which one is waiting on you, whether they are editing the same files, and what happens to them when you close the lid.',
    'The manager apps answered the second one first, by giving each agent its own git worktree, and built review tools around that. The multiplexers answered the third, by owning the shells in a background server so the client can go away. The agent terminals answered the first, with rings and badges and notification panels. Wortel is the one that is a real terminal and answers all three.',
  ],

  tableHeading: 'Compare, app by app',
  tableLead:
    'Pick any two, or more if your screen has room. Every answer was read off that product’s own site, docs or repository.',

  caveat:
    'These tools ship weekly and this page does not, so check anything that decides it for you. Where a product does not publish an answer the cell says "not published" rather than guessing: that is not a polite way of saying no. Corrections are welcome, and anything wrong here is a mistake rather than a position.',
} as const;
