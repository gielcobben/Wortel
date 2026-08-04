<script>
  import { untrack } from 'svelte';
  import './tokens.css';
  import PanelLeft from '@lucide/svelte/icons/panel-left';
  import GitBranch from '@lucide/svelte/icons/git-branch';
  import ChevronsUpDown from '@lucide/svelte/icons/chevrons-up-down';
  import Sidebar from './Sidebar.svelte';
  import Terminal from './Terminal.svelte';
  import GitPanel from './GitPanel.svelte';
  import { createDrawer } from './drawer.svelte.js';
  import { windowTitle, windowSubtitle, branch } from './data.js';

  // `view` is the scroll-driven tour's handle on this window: { sidebar, pane }.
  // Leave it null and the window is purely user-driven, which is what the hero
  // wants. Set it and each change is replayed through the SAME open/close calls
  // the toolbar buttons make, so a driven window can't reach a state a clicked
  // one couldn't. See Tour.svelte.
  // `beats`/`arriving`/`status` are the story the terminal is telling; see
  // Tour.svelte. The titlebar does NOT follow them: it is one session in one
  // directory for the whole page, which is the point of it being one story.
  let {
    sidebar = false,
    initialTab = 'changes',
    view = null,
    beats = undefined,
    arriving = -1,
    status = false,
  } = $props();

  // The app renders at native 1:1 always (never scaled); it stays usable by
  // RESPONDING like a real macOS window. As it's squeezed the app makes default
  // decisions (auto-collapse the sidebar, then the inspector) — each a default
  // you can OVERRIDE with the toggle and squeeze further.
  //
  // BOTH edge panels are OVERLAYS that SLIDE (translateX) — same model, same
  // 0.28s transition — and the terminal pads on that side to make room. The
  // left sidebar is a fixed-width card; the right inspector is resizable via a
  // grip on its inner edge (width clamped to 55% of the app so it stays sane
  // when the window is narrow). Shared rules via createDrawer (drawer.svelte.js).
  let probeEl = $state();
  const getProbe = () => probeEl;

  const left = createDrawer(sidebar, '--fits-sidebar', getProbe);   // sidebar
  const right = createDrawer(true, '--fits-git', getProbe);         // inspector

  let gitTab = $state(initialTab);

  // Drive the window from `view` when the tour supplies one.
  //
  // untrack() around the writes is load-bearing: set() reads `wanted` on its way
  // to writing it, and an effect that both reads and writes the same state
  // re-runs itself forever. Only the two fields of `view` are meant to be
  // dependencies, so they're read outside and the state work happens inside.
  //
  // The drawers are asked to open even when the tour's window is too narrow to
  // fit them; that's the `force` path in createDrawer, i.e. the same "keep it
  // open and squeeze the window" the real toggle does at narrow widths.
  $effect(() => {
    if (!view) return;
    const wantSidebar = !!view.sidebar;
    const pane = view.pane ?? null;
    untrack(() => {
      if (wantSidebar) left.open(); else left.close();
      if (pane) { gitTab = pane; right.open(); } else { right.close(); }
    });
  });

  // Pane-button behavior, ported from MainToolbar.swift: clicking the inactive
  // pane switches to it (opening the inspector), clicking the ACTIVE pane closes
  // it. Open/close semantics (incl. the auto-collapse override) come from the
  // shared drawer — identical to the sidebar toggle.
  function paneClicked(pane) {
    if (right.shownNow() && gitTab === pane) {
      right.close();
    } else {
      gitTab = pane;
      right.open();
    }
  }

  // ---- inspector resize grip (replaces paneforge for the horizontal split so
  //      the inspector can slide rather than flex-squeeze) ----
  let dragging = $state(false); // suppress the slide transition while dragging
  let mainEl = $state();

  // 450px, measured off the reference screenshots, and it stays literal.
  // Deriving it from the window width (as a share) does make the terminal wider
  // when the window is under the 1266px reference, but it also stops this being
  // a 1:1 replica: at 375px the commit rows truncate earlier and the History
  // graph gutter sits at the wrong x. Fidelity wins. The terminal's answer is
  // its own copy being short, not the inspector being the wrong size.
  let gitW = $state(450);

  function gripDown(e) {
    e.preventDefault();
    dragging = true;
    const startX = e.clientX;
    const startW = gitW;
    const maxW = (mainEl?.clientWidth ?? 1266) * 0.7;
    const move = (ev) => {
      gitW = Math.max(220, Math.min(maxW, startW + (startX - ev.clientX)));
    };
    const up = () => {
      dragging = false;
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  }
</script>

<!-- Fixed 1266×797 canvas (the real window size); scale externally as needed.
     Architecture (matches the app):
     · content = a full-height horizontal PaneGroup (paneforge — the Svelte
       port of react-resizable-panels): terminal column | resizer | git panel.
       The divider stays put when the sidebar toggles (measured: x=816 in all
       refs) — only the terminal column pads itself for the sidebar.
     · the git panel is a full-height surface; its toolbar floats and content
       scrolls beneath it (no titlebar hairline on the panel side — measured).
     · window chrome floats on top: static traffic lights; the toggle and the
       title are the only elements that slide (both +84px). -->
<div class="wortel-app"
  class:open={left.wanted} class:force-open={left.force}
  class:git-closed={!right.wanted} class:git-force={right.force}>
  <!-- hidden probe: container queries stamp the width tier onto it -->
  <b class="cq-probe" bind:this={probeEl} aria-hidden="true"></b>

  <Sidebar open={left.wanted} force={left.force} />

  <div class="lights">
    <span class="light r"></span><span class="light y"></span><span class="light g"></span>
  </div>
  <button class="toggle" type="button" aria-label="Toggle sidebar" onclick={left.toggle}>
    <PanelLeft size={20} strokeWidth={1.5} absoluteStrokeWidth aria-hidden="true" />
  </button>
  <div class="title">
    <div class="t1">{windowTitle}</div>
    <div class="t2">{windowSubtitle}</div>
  </div>

  <!-- pane toolbar: window chrome, survives the panel collapsing under it.
       The branch chip rides with the panel (inserted/removed), the buttons stay. -->
  <div class="toolbar">
    {#if right.wanted}
      <button class="chip" type="button">
        <span class="fork"><GitBranch size={14} strokeWidth={1.5} absoluteStrokeWidth aria-hidden="true" /></span>
        <span class="branch">{branch}</span>
        <span class="chev"><ChevronsUpDown size={14} strokeWidth={1.5} absoluteStrokeWidth aria-hidden="true" /></span>
      </button>
    {/if}
    <div class="btns">
      <button class="cbtn" class:on={right.wanted && gitTab === 'changes'} type="button" aria-label="Changes"
        onclick={() => paneClicked('changes')}>
        <!-- doc.on.doc (SF Symbols): two portrait docs w/ folded corners, front
             bottom-left; front is filled with the button bg to occlude the back -->
        <svg class="ic-doc" viewBox="0 0 24 24" width="23.5" height="23.5" fill="none"
          stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M10.5 3 H15.5 L19 6.5 V14.7 A1.8 1.8 0 0 1 17.2 16.5 H10.5 A1.8 1.8 0 0 1 8.7 14.7 V4.8 A1.8 1.8 0 0 1 10.5 3 Z" />
          <path d="M15.5 3 V5.1 A1.4 1.4 0 0 0 16.9 6.5 H19" />
          <path d="M6.5 7.5 H11.5 L15 11 V19.2 A1.8 1.8 0 0 1 13.2 21 H6.5 A1.8 1.8 0 0 1 4.7 19.2 V9.3 A1.8 1.8 0 0 1 6.5 7.5 Z"
            fill="var(--w-btn-fill, var(--w-pill-fill))" />
          <path d="M11.5 7.5 V9.6 A1.4 1.4 0 0 0 12.9 11 H15" />
        </svg>
      </button>
      <button class="cbtn" class:on={right.wanted && gitTab === 'history'} type="button" aria-label="History"
        onclick={() => paneClicked('history')}>
        <!-- clock (SF Symbols): hands at 12 and 3 -->
        <svg class="ic-clock" viewBox="0 0 24 24" width="21.5" height="21.5" fill="none"
          stroke="currentColor" stroke-width="1.53" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <circle cx="12" cy="12" r="8.6" />
          <path d="M12 6.9 V12 H16.7" />
        </svg>
      </button>
    </div>
  </div>

  <!-- terminal fills the width; the inspector overlays the right and the
       terminal pads-right to make room — mirror image of the left sidebar.
       .dragging suppresses the slide transition so resize tracks the pointer. -->
  <div class="main" class:dragging bind:this={mainEl} style="--git-w: {gitW}px">
    <div class="termcol">
      <div class="tb-term"></div>
      <Terminal {beats} {arriving} {status} />
    </div>

    <div class="inspector">
      <!-- a mouse-only drag handle in a decorative demo, not a real ARIA widget:
           role="separator" would demand aria-valuenow we'd only be faking -->
      <div class="git-grip" onpointerdown={gripDown} aria-hidden="true"></div>
      <GitPanel tab={gitTab} />
    </div>
  </div>
</div>

<style>
  /* self-contained box model — don't depend on the page's reset */
  .wortel-app, .wortel-app :global(*) { box-sizing: border-box; }

  /* fluid: the embedding wrapper decides the size — index.astro snaps it to the
     36px grid and caps it at the 1266×797 reference window */
  .wortel-app {
    position: relative;
    width: 100%;
    height: 100%;
    min-width: 480px;   /* below this it bleeds off-screen rather than scaling */
    min-height: 380px;
    /* query container so the sidebar can auto-hide by the app's OWN width
       (not the viewport) — works at any embed size, no JS */
    container: wortelapp / inline-size;
    overflow: hidden;
    border-radius: var(--w-radius);
    border: 0.5px solid var(--w-border);
    box-shadow: var(--w-shadow);
    background: var(--w-terminal-bg);
    color: var(--w-chrome-text);
    -webkit-font-smoothing: antialiased;
    font-family: var(--w-sans);
    text-align: left;
    /* A replica, not a document: every label here is chrome, so none of it is
       selectable — native sidebars and titlebars aren't either, and dragging the
       window would otherwise leave a trail of highlighted text. The page's own
       copy, outside this box, stays selectable. */
    -webkit-user-select: none;  /* Safari < 17 */
    user-select: none;
  }

  /* width tiers, decided purely in CSS and read by JS off this probe.
     --fits-sidebar: room for the left sidebar. --fits-git: room to keep the
     inspector open. Defaults = 1 (fits); container queries knock them to 0. */
  .cq-probe {
    position: absolute;
    width: 0; height: 0;
    pointer-events: none;
    --fits-sidebar: 1;
    --fits-git: 1;
  }
  @container wortelapp (max-width: 899px) { .cq-probe { --fits-sidebar: 0; } }
  @container wortelapp (max-width: 559px)  { .cq-probe { --fits-git: 0; } }

  .main { position: absolute; inset: 0; }

  /* the terminal fills the window; when the inspector is shown it pads-right by
     the inspector's (clamped) width — mirror of the sidebar's padding-left. */
  .termcol {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    padding-right: var(--git-shown-w);
    transition: padding-left 0.28s cubic-bezier(0.3, 0.9, 0.3, 1),
                padding-right 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
    background: var(--w-terminal-bg);
  }
  .main.dragging .termcol { transition: none; }

  /* the inspector is an OVERLAY on the right that SLIDES (translateX), exactly
     like the sidebar on the left. Width clamped to 55% of the app (55cqi) so it
     stays sane when the window is narrow. */
  .inspector {
    position: absolute;
    top: 0; right: 0; bottom: 0;
    width: var(--git-shown-w);
    transform: translateX(0);
    transition: transform 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
    z-index: 2;
  }
  .main.dragging .inspector { transition: none; }
  /* shared clamped width used by both the overlay and the terminal padding.
     cqi resolves against the .wortel-app container. */
  .termcol, .inspector { --git-shown-w: min(var(--git-w, 450px), 55cqi); }

  .git-grip {
    position: absolute;
    left: -3px; top: 51px; bottom: 0;
    width: 8px;
    cursor: col-resize;
    z-index: 3;
  }

  /* Collapse = SLIDE the inspector off the right + drop the terminal padding,
     driven by the same two rules as the sidebar (both animated by the
     transitions above):
       1. user closed it (.git-closed), any tier
       2. auto-collapse at the narrow tier, unless forced (.git-force) */
  .git-closed .inspector { transform: translateX(100%); }
  .git-closed .termcol { padding-right: 0; }

  @container wortelapp (max-width: 559px) {
    .wortel-app:not(.git-force) .inspector { transform: translateX(100%); }
    .wortel-app:not(.git-force) .termcol { padding-right: 0; }
    .wortel-app:not(.git-force) .chip { display: none; }
    /* highlight marks "the pane you're looking at" — none while collapsed */
    .wortel-app:not(.git-force) .cbtn.on { background: transparent; }
  }

  /* ---- floating pane toolbar (window chrome, above the collapsing panel) ---- */
  .toolbar {
    position: absolute;
    top: 8px;
    right: 21px;
    display: flex;
    align-items: center;
    gap: 13px;
    z-index: 5;
  }
  .chip {
    height: 36px;
    display: flex; align-items: center; gap: 5px;
    padding: 0 10px;
    border-radius: 18px;
    background: var(--w-pill-fill);
    -webkit-backdrop-filter: var(--w-pill-blur);
    backdrop-filter: var(--w-pill-blur);
    border: 0;
    box-shadow: var(--w-pill-shadow);
    color: var(--w-chrome-text);
    font-family: var(--w-sans);
    font-size: 13px; font-weight: 600;
    cursor: pointer; white-space: nowrap;
  }
  .chip .branch { letter-spacing: -0.02em; }
  .chip .fork { color: var(--w-chrome-sub); flex-shrink: 0; display: grid; place-items: center; }
  .chip .chev { color: var(--w-chrome-sub); flex-shrink: 0; margin-left: 1px; display: grid; place-items: center; }
  /* crisp Lucide rendering: block display kills baseline offsets */
  .wortel-app :global(svg.lucide) { display: block; }
  .btns {
    /* 2px pad + 32px circle + 2px pad — no rim, so the height is exactly 36 and
       the 16px inner radius matches the circles' own. */
    height: 36px;
    display: flex; align-items: center; gap: 1px;
    padding: 2px;
    border-radius: 18px;
    background: var(--w-pill-fill);
    -webkit-backdrop-filter: var(--w-pill-blur);
    backdrop-filter: var(--w-pill-blur);
    border: 0;
    box-shadow: var(--w-pill-shadow);
  }
  .cbtn {
    width: 32px; height: 32px;
    border-radius: 50%;
    border: 0; background: transparent;
    color: var(--w-chrome-text);
    display: grid; place-items: center;
    cursor: pointer;
    --w-btn-fill: var(--w-pill-solid); /* what sits behind the doc icon — must be
                                          opaque, or the back page shows through */
  }
  /* the doc icon's front page has to track the hover wash, or it stays a bright
     patch against the darkened circle instead of occluding invisibly */
  .cbtn:hover {
    background: color-mix(in srgb, var(--w-chrome-text) 8%, transparent);
    --w-btn-fill: color-mix(in srgb, var(--w-chrome-text) 8%, var(--w-pill-solid));
  }
  .cbtn.on { background: var(--w-btn-active); --w-btn-fill: var(--w-btn-active); }

  /* terminal pads-left when the sidebar is open (its divider never moves) */
  .open .termcol { padding-left: 228px; }
  /* auto-hide: below 900 the app is too narrow for the sidebar. Drop the
     padding AND snap the toggle + title back to their closed positions —
     everything the sidebar moves must move back together, exactly like a
     manual toggle (the Sidebar itself slides out via the same @container). */
  @container wortelapp (max-width: 899px) {
    .open:not(.force-open) .termcol { padding-left: 0; }
  }
  /* the 51px titlebar strip; its hairline lives ONLY on the terminal side */
  .tb-term {
    flex-shrink: 0;
    height: 51px;
    background: var(--w-titlebar-bg);
    border-bottom: 1px solid var(--w-hairline);
  }

  /* ---- window chrome (above the sidebar overlay) ---- */
  .lights {
    position: absolute;
    left: 19px;
    top: 18.5px;
    display: flex;
    gap: 9px;
    z-index: 5;
  }
  .light { width: 14px; height: 14px; border-radius: 50%; }
  .light.r { background: var(--w-light-red); }
  .light.y { background: var(--w-light-amber); }
  .light.g { background: var(--w-light-green); }

  .toggle {
    position: absolute;
    left: 107px;
    top: 8.5px;
    width: 34px; height: 34px;
    border-radius: 50%;
    border: 0;
    background: transparent;
    color: var(--w-chrome-sub);
    display: grid; place-items: center;
    cursor: pointer;
    z-index: 5;
    transition: transform 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
  }
  .toggle:hover { background: color-mix(in srgb, var(--w-chrome-text) 7%, transparent); }
  .open .toggle { transform: translateX(84px); }

  .title {
    position: absolute;
    left: 164.5px;
    top: 11px;
    min-width: 0;
    z-index: 1;
    transition: transform 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
  }
  .open .title { transform: translateX(84px); }
  /* auto-hide (must come AFTER the +84 rules to win on equal specificity):
     when the sidebar can't fit, snap the toggle + title back to closed */
  @container wortelapp (max-width: 899px) {
    .open:not(.force-open) .toggle { transform: translateX(0); }
    .open:not(.force-open) .title { transform: translateX(0); }
  }
  .t1 { font-size: 13px; font-weight: 700; line-height: 16px; }
  .t2 { font-size: 11px; line-height: 13px; color: var(--w-chrome-sub); }
</style>
