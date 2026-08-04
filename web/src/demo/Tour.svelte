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
  import { STORY, AGENT_BEAT, windowSubtitle } from './data.js';

  let { sidebar = true, initialTab = 'history' } = $props();

  // Section id -> which panels are open AND how far into the story we are.
  // `beat` indexes STORY: the terminal shows every beat up to it, so reading
  // down the page continues one session rather than replacing its contents,
  // and reading back up rewinds it. Every adjacent pair differs in the beat, so
  // no section boundary is silent even where the panels are the same.
  const VIEWS = {
    'what-is-wortel': { sidebar: true,  pane: 'history', beat: 0 },
    'ghostty-engine': { sidebar: false, pane: null,      beat: 1 },
    'sessions':       { sidebar: true,  pane: null,      beat: 2 },
    'coding-agents':  { sidebar: true,  pane: null,      beat: 3 },
    'git-and-files':  { sidebar: false, pane: 'changes', beat: 4 },
    'zero-config':    { sidebar: false, pane: null,      beat: 5 },
    'keyboard':       { sidebar: true,  pane: 'history', beat: 6 },
  };

  // The story so far. Before any section reaches the reading band we are still
  // on the hero, which is beat 0.
  const beat = $derived(view?.beat ?? 0);
  const story = $derived(STORY.slice(0, beat + 1));
  const beats = $derived(story.map((b) => b.rows));
  // The titlebar follows the last `cd` the story has actually reached, so the
  // window's directory and its transcript can never disagree.
  const cwd = $derived([...story].reverse().find((b) => b.cwd)?.cwd ?? windowSubtitle);

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

<WortelApp {view} {sidebar} {initialTab} {beats} {cwd} arriving={beat} status={beat >= AGENT_BEAT} />
