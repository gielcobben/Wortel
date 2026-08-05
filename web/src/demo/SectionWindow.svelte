<script>
  // One window per section on mobile, framed on the part of the app that section
  // is about. This is the phone's answer to the pinned window on desktop, where
  // there is no room to put anything beside the prose.
  //
  // The window is NEVER scaled, the same rule the desktop one follows. Framing
  // is done by ALIGNING it to an edge, with the hero's 36px gutter, and letting
  // the rest fall off the other side:
  //
  //   start · the window's left edge on x=36, so its corner and traffic lights
  //           show and the sidebar is what you are looking at. Bleeds right.
  //   end   · the inspector's left edge on the gutter, so filenames read from
  //           their first character. Bleeds off both sides.
  //   fit   · both edges in, whole window on screen. Used when the section has
  //           no panels open: with nothing to pan between, a cropped window is
  //           just a cropped window, and the terminal is better whole.
  //
  // Alignment is enough on its own, which is why there is no measuring here. An
  // earlier version centred the target pane with getBoundingClientRect, and
  // `content-visibility: auto` below meant the off-screen frames reported
  // geometry from a layout that never ran.
  import WortelApp from './WortelApp.svelte';
  import { STORY, AGENT_BEAT } from './data.js';

  let { beat = 0, sidebar = false, pane = null, focus = 'terminal' } = $props();

  // Rendered client:only and gated here rather than hidden with CSS. Six of
  // these is 2200 DOM nodes and 150KB of markup; desktop should not pay for a
  // thing it never shows, and neither should the HTML everyone downloads.
  let narrow = $state(false);
  $effect(() => {
    const mq = matchMedia('(max-width: 900px)');
    const sync = () => (narrow = mq.matches);
    sync();
    mq.addEventListener('change', sync);
    return () => mq.removeEventListener('change', sync);
  });

  // No panels open means nothing to pan to, so show the whole window.
  const mode = $derived(!sidebar && !pane ? 'fit' : focus === 'inspector' ? 'end' : 'start');

  const beats = $derived(STORY.slice(0, beat + 1).map((b) => b.rows));
  const cwd = $derived(
    [...STORY.slice(0, beat + 1)].reverse().find((b) => b.cwd)?.cwd ?? '~/Developer/wortel',
  );
  const view = $derived({ sidebar, pane });
</script>

{#if narrow}
  <!-- aria-hidden: the prose above it already says this, and the hero holds the
       window a reader can actually reach. inert + pointer-events keep a thumb
       scrolling the page instead of grabbing a titlebar or a resize grip. -->
  <div class="swin {mode}" inert aria-hidden="true">
    <div class="swin-app">
      <WortelApp {view} {beats} {cwd} {sidebar} arriving={-1} status={beat >= AGENT_BEAT} />
    </div>
  </div>
{/if}

<style>
  .swin {
    position: relative;
    /* Out to both gutters: the prose column's 36px padding is undone here so the
       window can sit on the grid line itself, exactly like the hero's does. */
    width: 100vw;
    height: 468px; /* 13 cells */
    /* One shorthand, all four sides. Written as `margin-left` plus a later
       `margin: 28px 0 76px` it silently lost the -36 and every frame sat a
       gutter to the right of where it belonged.
       Left -36 undoes the prose column's padding so the frame reaches the
       viewport edge; the bottom 76 is room for the drop-shadow, which falls
       about that far below the window (--w-shadow is 0 36px 80px). */
    margin: 28px 0 76px -36px;
    /* clip, and on ONE axis. `hidden` cut the shadow flat along the bottom;
       clipping only the horizontal bleed lets the shadow fall past the frame
       the way the hero's does. */
    overflow-x: clip;
    overflow-y: visible;
    /* A picture, not a control. A thumb dragging here scrolls the page. */
    pointer-events: none;
    /* NO content-visibility: auto here, tempting as it is. It skips layout for
       the off-screen frames, and Terminal.svelte measures its own width to know
       how many columns to wrap to. Measuring a layout that never ran left it on
       its 33-column default, and the text overran a 318px window. */
  }

  .swin-app {
    position: absolute;
    top: 0;
    bottom: 0;
    /* The reference window snapped to whole cells. Wide enough that the app's
       own container queries keep BOTH panels open, which is the whole point:
       under 900 it drops the sidebar and under 560 the inspector, and then
       there is nothing left to frame. */
    width: 1260px;
  }
  .swin.start .swin-app { left: 36px; }
  /* END frames the inspector, so the inspector is sized to the space a phone
     actually has instead of being cropped to fit it. --git-w cascades into the
     app (WortelApp leaves it unset so a stylesheet can win) and 450px stays the
     cap, so a wide tablet still gets the reference width.
     Its left edge then goes on the gutter: the pane starts 1260 - its width
     into the window, and we pull that back to 36. */
  .swin.end {
    --pane-w: min(450px, calc(100vw - 72px));
    --git-w: var(--pane-w);
  }
  .swin.end .swin-app { left: calc(36px - 1260px + var(--pane-w)); }
  /* Fitted: both gutters honoured and the width falls out of them. */
  .swin.fit .swin-app { left: 36px; right: 36px; width: auto; }
  /* WortelApp carries `min-width: 480px`, and its comment says why: on a
     desktop stage, below that it should bleed rather than scale. A phone is the
     other case. Held at 480 the "fitted" window was really 480 inside a 318 box
     with 126px clipped off, so the terminal wrapped to 44 columns and lost the
     end of every line. Released, the app is a genuinely narrow macOS window,
     its container queries collapse the panels by themselves, and the terminal
     re-wraps to what is actually there. Only in this mode, and only because
     these sections asked for no panels in the first place. */
  .swin.fit .swin-app > :global(.wortel-app) { min-width: 0; }

  .swin-app > :global(.wortel-app) { width: 100%; height: 100%; }
</style>
