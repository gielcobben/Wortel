<script>
  // The page's ONE app window. It is the hero, it is interactive, and it is
  // pinned beside the prose for the whole scroll, showing whichever part of the
  // app the section you're reading is about.
  //
  // The window is never scaled. When the rail is narrow the window is a NARROWER
  // macOS window, and the container queries inside auto-collapse panels exactly
  // as dragging the real app's edge would. That is why a view below can ask for
  // a panel the window has no room for and still get the right answer.
  import WortelApp from './App.svelte';
  import { STORY, AGENT_BEAT, windowSubtitle } from './data.js';
  import { VIEWS, FIRST_SECTION } from './views.js';

  let { sidebar = true, initialTab = 'history' } = $props();

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
  //
  // The same change lights the section in the prose. It is done from here, and
  // not from a second observer in the page, because the text and the window
  // have to name the SAME section: two observers with their own thresholds
  // would eventually disagree, and a lit paragraph beside the wrong pane is
  // worse than no highlight at all.
  $effect(() => {
    const id = active;
    if (id && VIEWS[id]) view = VIEWS[id];
    // Falls back to the first section so nothing is dimmed-but-unlit: while you
    // are still on the hero, and on the way into the first heading before it
    // reaches the reading band, the section you are heading for is already lit.
    const shown = id ?? FIRST_SECTION;
    for (const el of document.querySelectorAll('[data-view]')) {
      el.classList.toggle('lit', el.dataset.view === shown);
    }
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

    // The dimming is opt-in from JS: without this attribute the stylesheet
    // leaves every section at full opacity, so a reader with no JS gets plain
    // legible prose rather than a page permanently dimmed to 38%.
    const doc = els[0].closest('.doc-tour');
    doc?.setAttribute('data-lit', '');

    return () => {
      io.disconnect();
      doc?.removeAttribute('data-lit');
      els.forEach((el) => el.classList.remove('lit'));
    };
  });
</script>

<WortelApp {view} {sidebar} {initialTab} {beats} {cwd} arriving={beat} status={beat >= AGENT_BEAT} />
