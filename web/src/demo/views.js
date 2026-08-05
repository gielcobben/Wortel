// What the window shows for each section of the page. Shared, because two very
// different things read it: Tour.svelte drives the ONE pinned window on desktop,
// and index.astro renders a separate framed window per section on mobile, where
// there is no room to pin anything beside the prose.
//
//   sidebar / pane · which panels are open, replayed through the same
//                    open/close calls the toolbar buttons make.
//   beat           · how far into the story the terminal has got. The desktop
//                    window shows every beat up to it; a mobile window shows the
//                    same, so both tell the story in the same order.
//   focus          · WHICH PART OF THE WINDOW MATTERS HERE. On mobile the window
//                    is rendered at its real width, far wider than a phone, and
//                    panned so this pane is the part on screen. The rest falls
//                    off both edges. It is never scaled.
export const VIEWS = {
  'what-is-wortel': { sidebar: true,  pane: 'history', beat: 0, focus: 'sidebar' },
  'ghostty-engine': { sidebar: false, pane: null,      beat: 1, focus: 'terminal' },
  'sessions':       { sidebar: true,  pane: null,      beat: 2, focus: 'sidebar' },
  'coding-agents':  { sidebar: true,  pane: null,      beat: 3, focus: 'sidebar' },
  'git-and-files':  { sidebar: false, pane: 'changes', beat: 4, focus: 'inspector' },
  'zero-config':    { sidebar: false, pane: null,      beat: 5, focus: 'terminal' },
  'keyboard':       { sidebar: true,  pane: 'history', beat: 6, focus: 'inspector' },
};

export const FIRST_SECTION = Object.keys(VIEWS)[0];
