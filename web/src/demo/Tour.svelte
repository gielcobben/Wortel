<script>
  // One app window, pinned beside the prose, showing whichever part of the app
  // the section you're reading is about.
  //
  // It is the SAME component as the hero's, at a different size. The window is
  // never scaled: a narrower tour window is a narrower macOS window, and the
  // container queries inside it auto-collapse panels exactly as they would if
  // you dragged the real app's edge in. That is why the views below can ask for
  // a panel the window has no room for and still get the right answer.
  import WortelApp from './WortelApp.svelte';

  // Section id -> what the window shows. Deliberately fewer distinct views than
  // sections: neighbours that are about the same surface share one, so the
  // window changes at the points where the subject actually changes rather than
  // twitching at every heading.
  const VIEWS = {
    'what-is-wortel': { sidebar: true, pane: 'changes' },   // the whole app
    'ghostty-engine': { sidebar: false, pane: null },       // just the terminal
    'sessions':       { sidebar: true, pane: null },        // the sidebar
    'coding-agents':  { sidebar: true, pane: null },        // ...and its indicators
    'git-and-files':  { sidebar: false, pane: 'changes' },  // the inspector
    'zero-config':    { sidebar: false, pane: null },
    'keyboard':       { sidebar: true, pane: 'history' },
  };

  const FIRST = 'what-is-wortel';
  let active = $state(FIRST);
  const view = $derived(VIEWS[active] ?? VIEWS[FIRST]);

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
        if (!inBand.size) return;  // between bands: hold the last view, don't reset
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

<WortelApp {view} sidebar={true} initialTab="changes" />
