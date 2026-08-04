<script>
  // The page's ONE app window. It is the hero, it is interactive, and it is
  // pinned beside the prose for the whole scroll, showing whichever part of the
  // app the section you're reading is about.
  //
  // The window is never scaled. When the rail is narrow the window is a NARROWER
  // macOS window, and the container queries inside auto-collapse panels exactly
  // as dragging the real app's edge would. That is why a view below can ask for
  // a panel the window has no room for and still get the right answer.
  import WortelApp from './WortelApp.svelte';
  import { SCENES } from './data.js';

  let { sidebar = true, initialTab = 'history' } = $props();

  // Section id -> what the window shows: which panels are open AND which scene
  // is in the terminal. Every adjacent pair differs in at least one of the two,
  // so no section boundary is silent. Panels alone were not enough: `sessions`
  // and `coding-agents` want the same panels, and scrolling between them did
  // nothing at all.
  //
  // The scenes run as a narrative rather than a slideshow: land in a shell,
  // build, move to another project, start the agent, read what it found, and
  // check there is nothing to configure. See SCENES in data.js.
  const VIEWS = {
    'what-is-wortel': { sidebar: true,  pane: 'history', scene: SCENES.arrive },
    'ghostty-engine': { sidebar: false, pane: null,      scene: SCENES.build },
    'sessions':       { sidebar: true,  pane: null,      scene: SCENES.sessions },
    'coding-agents':  { sidebar: true,  pane: null,      scene: SCENES.agent },
    'git-and-files':  { sidebar: false, pane: 'changes', scene: SCENES.answer },
    'zero-config':    { sidebar: false, pane: null,      scene: SCENES.noconfig },
    'keyboard':       { sidebar: true,  pane: 'history', scene: SCENES.answer },
  };

  // null until a section actually reaches the reading band. The hero's authored
  // state (sidebar + History) then stands untouched while you're still looking
  // at the first screen; anything else would flip the window the instant the
  // island hydrates.
  let active = $state(null);
  let view = $state(null);

  // Apply ONLY when the active section changes, never on every render. That is
  // what lets you take the window over: click a pane and it stays on your pane,
  // because your click doesn't change `active`. Cross into the next section and
  // the tour picks it up again. No pause flag, no timers, no fighting.
  $effect(() => {
    const id = active;
    if (id && VIEWS[id]) view = VIEWS[id];
  });

  $effect(() => {
    const els = [...document.querySelectorAll('[data-view]')];
    if (!els.length) return;

    // Which sections currently cross the middle band of the viewport. A Set
    // rather than "last entry wins": entries arrive in whatever order the
    // observer batches them, so on a fast scroll the last one is not reliably
    // the lowest on screen. Resolving against document order is.
    const inBand = new Set();
    const order = new Map(els.map((el, i) => [el, i]));

    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) inBand.add(e.target);
          else inBand.delete(e.target);
        }
        if (!inBand.size) return;  // between bands: hold the last view
        let best = null;
        for (const el of inBand) {
          if (!best || order.get(el) < order.get(best)) best = el;
        }
        active = best.dataset.view;
      },
      // A thin strip across the middle of the viewport. A section is "the one
      // you're reading" while it crosses that strip, which tracks reading
      // position far better than "is it visible at all" on a tall page.
      { rootMargin: '-45% 0px -45% 0px', threshold: 0 },
    );

    els.forEach((el) => io.observe(el));
    return () => io.disconnect();
  });
</script>

<WortelApp {view} {sidebar} {initialTab} scene={view?.scene ?? SCENES.arrive} />
