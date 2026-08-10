<script>
  import { untrack } from 'svelte';
  import './tokens.css';
  import './tokens27.css';
  import Sidebar from './Sidebar27.svelte';
  import Terminal from './Terminal.svelte';
  import GitPanel from './GitPanel27.svelte';
  import { createDrawer } from './drawer.svelte.js';
  import { windowTitle, windowSubtitle, branch } from './data.js';

  // The macOS 27 build of the window. Same behaviour, same props and the same
  // shared parts (Terminal, Diff, data.js, drawer.svelte.js) as WortelApp.svelte;
  // what differs is everything the OS draws. See tokens27.css for the palette
  // and look.svelte.js for who gets which.
  let {
    sidebar = false,
    initialTab = 'changes',
    view = null,
    beats = undefined,
    cwd = windowSubtitle,
    arriving = -1,
    status = false,
  } = $props();

  let probeEl = $state();
  const getProbe = () => probeEl;

  const left = createDrawer(sidebar, '--fits-sidebar', getProbe);   // sidebar
  const right = createDrawer(true, '--fits-git', getProbe);         // inspector

  let gitTab = $state(initialTab);

  // Drive the window from `view` when the tour supplies one. untrack() around
  // the writes is load-bearing: set() reads `wanted` on its way to writing it,
  // and an effect that both reads and writes the same state re-runs forever.
  $effect(() => {
    if (!view) return;
    const wantSidebar = !!view.sidebar;
    const pane = view.pane ?? null;
    untrack(() => {
      if (wantSidebar) left.open(); else left.close();
      if (pane) { gitTab = pane; right.open(); } else { right.close(); }
    });
  });

  // Pane-button behaviour, ported from MainToolbar.swift: clicking the inactive
  // pane switches to it (opening the inspector), clicking the ACTIVE pane closes
  // it. macOS 27 draws the group as a segmented control, so it adds one rule:
  // the divider between two segments is drawn only when NEITHER is selected.
  function paneClicked(pane) {
    if (right.shownNow() && gitTab === pane) {
      right.close();
    } else {
      gitTab = pane;
      right.open();
    }
  }
  const anySelected = $derived(right.wanted);

  // ---- resize grips ----
  // Both edge panels are draggable, exactly as they are in the app: three real
  // split panes, each with its own minimum and maximum thickness. The sidebar's
  // 180…400 comes straight from MainSplitViewController.swift.
  let dragging = $state(false);   // suppress the inspector's slide transition
  let sbDragging = $state(false); // …and the sidebar's
  let mainEl = $state();
  let appEl = $state();
  let userW = $state(null);
  let sbW = $state(null);

  const SB_MIN = 180;
  const SB_MAX = 400;

  // One drag loop for both grips: `sign` is +1 when dragging right widens the
  // panel (the sidebar) and -1 when it narrows it (the inspector).
  function drag(e, { startW, sign, min, max, set, flag }) {
    e.preventDefault();
    flag(true);
    const startX = e.clientX;
    const move = (ev) => set(Math.max(min, Math.min(max, startW + sign * (ev.clientX - startX))));
    const up = () => {
      flag(false);
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  }

  function sbGrab(e) {
    drag(e, {
      startW: appEl?.querySelector('.overlay')?.getBoundingClientRect().width ?? 236,
      sign: 1,
      min: SB_MIN,
      max: Math.min(SB_MAX, (appEl?.clientWidth ?? 1304) * 0.45),
      set: (w) => (sbW = w),
      flag: (v) => (sbDragging = v),
    });
  }

  function gripDown(e) {
    drag(e, {
      startW: mainEl?.querySelector('.inspector')?.getBoundingClientRect().width ?? 450,
      sign: -1,
      min: 220,
      max: (mainEl?.clientWidth ?? 1304) * 0.7,
      set: (w) => (userW = w),
      flag: (v) => (dragging = v),
    });
  }
</script>

<!-- Architecture is unchanged from WortelApp.svelte (both edge panels are
     sliding overlays, the terminal pads to make room, width tiers decided by
     container queries on a hidden probe). What macOS 27 changed:
     · the window's corner radius, 26 → 15
     · the sidebar: floating inset card → flush 236px panel, same material as
       the inspector, with no rim and no shadow
     · the sidebar toggle: bare glyph → a 36px glass circle
     · the toolbar: taller glass pills, and the button group is a segmented
       control whose divider hides next to the selected segment -->
<div class="wortel-app m27" bind:this={appEl}
  class:open={left.wanted} class:force-open={left.force}
  class:sb-dragging={sbDragging}
  class:git-closed={!right.wanted} class:git-force={right.force}
  style={sbW == null ? null : `--w-sb-w: ${sbW}px`}>
  <!-- hidden probe: container queries stamp the width tier onto it -->
  <b class="cq-probe" bind:this={probeEl} aria-hidden="true"></b>

  <Sidebar open={left.wanted} force={left.force} dragging={sbDragging} ongrab={sbGrab}
           agents={!!view?.agents} />

  <div class="lights">
    <span class="light r"></span><span class="light y"></span><span class="light g"></span>
  </div>
  <button class="toggle" type="button" aria-label="Toggle sidebar" onclick={left.toggle}>
    <!-- sidebar.left (SF Symbols): rounded rect, a divider at 6.5, and three
         short rules in the left column. Measured ink: 19.5 x 15, stroke 1.5,
         divider 1.0 wide. Lucide's panel-left has no rules, so this is drawn. -->
    <svg class="ic-sb" viewBox="0 0 19.5 15" width="19.5" height="15" fill="none"
      stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <rect x="0.75" y="0.75" width="18" height="13.5" rx="2.6" stroke-width="1.5" />
      <path d="M7 0.9 V14.1" stroke-width="1" />
      <path d="M2.9 3.75 H5.1 M2.9 6 H5.1 M2.9 8.25 H5.1" stroke-width="1" />
    </svg>
  </button>
  <div class="title">
    <div class="t1">{windowTitle}</div>
    <div class="t2">{cwd}</div>
  </div>

  <!-- pane toolbar: window chrome, survives the panel collapsing under it.
       The branch chip rides with the panel (inserted/removed), the buttons stay. -->
  <div class="toolbar">
    {#if right.wanted}
      <button class="chip" type="button">
        <!-- arrow.triangle.branch (SF Symbols): a stem forking into two arrows.
             Lucide's git-branch is a node-and-line glyph, a different drawing.
             Measured ink: 11 x 11 at chip-relative x27.5. -->
        <span class="fork">
          <svg viewBox="0 0 11 11" width="11" height="11" fill="none" stroke="currentColor"
            stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M5.5 10.4 V6.2 L1.5 1.6 M5.5 6.2 L9.5 1.6" />
            <path d="M1.1 4.2 L1.2 1.2 L4.1 1.3" />
            <path d="M9.9 4.2 L9.8 1.2 L6.9 1.3" />
          </svg>
        </span>
        <span class="branch">{branch}</span>
        <span class="spacer"></span>
        <!-- chevron.up.chevron.down (SF Symbols): measured ink 5.5 x 7.5 -->
        <span class="chev">
          <svg viewBox="0 0 5.5 7.5" width="5.5" height="7.5" fill="none" stroke="currentColor"
            stroke-width="1.05" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M0.6 2.5 L2.75 0.5 L4.9 2.5" />
            <path d="M0.6 5 L2.75 7 L4.9 5" />
          </svg>
        </span>
      </button>
    {/if}
    <div class="btns" class:none-on={!anySelected}>
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
      <span class="seg"></span>
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

  <div class="main" class:dragging bind:this={mainEl} style={userW == null ? null : `--git-w: ${userW}px`}>
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

  .wortel-app {
    position: relative;
    width: 100%;
    height: 100%;
    min-width: 480px;   /* below this it bleeds off-screen rather than scaling */
    min-height: 380px;
    container: wortelapp / inline-size;
    /* The sidebar's width, dragged by its grip. --sb-shown-w is what everything
       that has to agree with it actually reads: the panel, the terminal's
       padding, and how far the toggle and the title travel. */
    --sb-shown-w: clamp(180px, var(--w-sb-w, 236px), 45cqi);
    overflow: hidden;
    /* measured: the corner arc fits a circle of R=15 */
    border-radius: var(--w-radius);
    border: 0.5px solid var(--w-border);
    box-shadow: var(--w-shadow);
    /* No base fill: the sidebar and the inspector are translucent, and a colour
       painted under them would be the only thing they ever sampled. The
       terminal paints its own, clipped to itself (see .termcol). */
    background: transparent;
    color: var(--w-chrome-text);
    -webkit-font-smoothing: antialiased;
    font-family: var(--w-sans);
    text-align: left;
    -webkit-user-select: none;  /* Safari < 17 */
    user-select: none;
  }

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

  .termcol {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    padding-right: var(--git-shown-w);
    transition: padding-left 0.28s cubic-bezier(0.3, 0.9, 0.3, 1),
                padding-right 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
    /* content-box: the padding is the room the panels occupy, so the terminal's
       colour must stop there rather than paint on under their glass */
    background: var(--w-terminal-bg);
    background-clip: content-box;
  }
  .main.dragging .termcol { transition: none; }
  .sb-dragging .termcol,
  .sb-dragging .toggle,
  .sb-dragging .title { transition: none; }

  .inspector {
    position: absolute;
    top: 0; right: 0; bottom: 0;
    width: var(--git-shown-w);
    transform: translateX(0);
    transition: transform 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
    z-index: 2;
  }
  .main.dragging .inspector { transition: none; }
  .termcol, .inspector { --git-shown-w: min(var(--git-w, 450px), 55cqi); }

  .git-grip {
    position: absolute;
    left: -3px; top: 52px; bottom: 0;
    width: 8px;
    cursor: col-resize;
    z-index: 3;
  }

  .git-closed .inspector { transform: translateX(100%); }
  .git-closed .termcol { padding-right: 0; }

  @container wortelapp (max-width: 559px) {
    .wortel-app:not(.git-force) .inspector { transform: translateX(100%); }
    .wortel-app:not(.git-force) .termcol { padding-right: 0; }
    .wortel-app:not(.git-force) .chip { display: none; }
    /* highlight marks "the pane you're looking at" — none while collapsed */
    .wortel-app:not(.git-force) .cbtn.on { background: transparent; }
    .wortel-app:not(.git-force) .seg { opacity: 1; }
  }

  /* ---- floating pane toolbar ----
     measured: pills top 8, height 36, radius 18; group right edge 1295.5 in a
     1304 window (8.5), and 4px between the chip and the group. */
  .toolbar {
    position: absolute;
    top: 7.5px;
    right: 8.5px;
    display: flex;
    align-items: center;
    gap: 4px;
    z-index: 5;
  }

  /* one material for every floating control: fill, bright rim, soft shadow */
  .chip, .btns, .toggle {
    background: var(--w-pill-fill);
    -webkit-backdrop-filter: var(--w-pill-blur);
    backdrop-filter: var(--w-pill-blur);
    border: 0;
    box-shadow: var(--w-pill-shadow), inset 0 0.5px 0 0 var(--w-pill-rim);
  }

  .chip {
    height: 36px;
    display: flex; align-items: center; gap: 5.5px;
    /* measured: fork ink at x1093 in a chip starting at 1065.5, chevron ink
       ending 13.5 short of the right edge */
    padding: 0 13.5px 0 27.5px;
    border-radius: 18px;
    color: var(--w-chrome-text);
    font-family: var(--w-sans);
    font-size: 13px; font-weight: 600;
    cursor: pointer; white-space: nowrap;
  }
  .chip .branch { letter-spacing: -0.02em; }
  .chip .fork { color: var(--w-chrome-sub); flex-shrink: 0; display: grid; place-items: center; }
  /* the gap the popup keeps between the name and its chevron (measured 23) */
  .chip .spacer { flex: 1; min-width: 17.5px; }
  .chip .chev { color: var(--w-chrome-sub); flex-shrink: 0; display: grid; place-items: center; }
  /* crisp Lucide rendering: block display kills baseline offsets */
  .wortel-app :global(svg.lucide) { display: block; }
  .ic-sb, .chip .chev svg, .chip .fork svg { display: block; }

  .btns {
    /* 2px pad + 36px segments — measured group 1184→1295.5 for three of them */
    height: 36px;
    display: flex; align-items: center;
    padding: 0 2px;
    border-radius: 18px;
  }
  .cbtn {
    width: 36px; height: 36px;
    border-radius: 50%;
    border: 0; background: transparent;
    color: var(--w-chrome-text);
    display: grid; place-items: center;
    cursor: pointer;
    --w-btn-fill: var(--w-pill-solid); /* what sits behind the doc icon — must be
                                          opaque, or the back page shows through */
  }
  .cbtn:hover {
    background: color-mix(in srgb, var(--w-chrome-text) 8%, transparent);
    --w-btn-fill: color-mix(in srgb, var(--w-chrome-text) 8%, var(--w-pill-solid));
  }
  /* the selected segment is a 28px filled circle inside its 36px slot */
  .cbtn.on {
    background:
      radial-gradient(circle at 50% 50%, var(--w-btn-active) 0 14px, transparent 14px);
    --w-btn-fill: var(--w-btn-active);
  }
  /* segmented control: the divider shows only between two UNSELECTED segments */
  .seg {
    width: 1px; height: 20px;
    background: var(--w-seg-divider);
    opacity: 0;
    align-self: center;
    margin: 0 -0.5px;
  }
  .btns.none-on .seg { opacity: 1; }

  /* terminal pads-left by exactly the sidebar's current width */
  .open .termcol { padding-left: var(--sb-shown-w); }
  @container wortelapp (max-width: 899px) {
    .open:not(.force-open) .termcol { padding-left: 0; }
  }
  /* the 52px titlebar strip; its hairline lives ONLY on the terminal side */
  .tb-term {
    flex-shrink: 0;
    height: 52px;
    background: var(--w-titlebar-bg);
    border-bottom: 0.5px solid var(--w-hairline);
  }

  /* ---- window chrome (above the sidebar overlay) ---- */
  .lights {
    /* measured: red 18.67→32.83, pitch 23 → 14px circles at 18.75 with a 9 gap */
    position: absolute;
    left: 18.75px;
    top: 18.75px;
    display: flex;
    gap: 9px;
    z-index: 5;
  }
  .light { width: 14px; height: 14px; border-radius: 50%; }
  .light.r { background: var(--w-light-red); }
  .light.y { background: var(--w-light-amber); }
  .light.g { background: var(--w-light-green); }

  /* the toggle is a control now: a 36px glass circle, measured at left 192 with
     the sidebar open (so 108 closed, the same +84 the title travels) */
  .toggle {
    position: absolute;
    left: 108px;
    top: 7.5px;
    width: 36px; height: 36px;
    border-radius: 50%;
    background: var(--w-toggle-fill);
    color: var(--w-toggle-ink);
    display: grid; place-items: center;
    cursor: pointer;
    z-index: 5;
    transition: transform 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
  }
  .toggle:hover { background: color-mix(in srgb, var(--w-chrome-text) 7%, var(--w-pill-fill)); }
  .open .toggle { transform: translateX(calc(var(--sb-shown-w) - 152px)); }

  .title {
    position: absolute;
    left: 173px;
    top: 11px;
    min-width: 0;
    z-index: 1;
    transition: transform 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
  }
  .open .title { transform: translateX(calc(var(--sb-shown-w) - 152px)); }
  /* auto-hide (must come AFTER the +84 rules to win on equal specificity):
     when the sidebar can't fit, snap the toggle + title back to closed */
  @container wortelapp (max-width: 899px) {
    .open:not(.force-open) .toggle { transform: translateX(0); }
    .open:not(.force-open) .title { transform: translateX(0); }
  }
  .t1 { font-size: 13px; font-weight: 700; line-height: 16px; }
  .t2 { font-size: 11px; line-height: 13px; color: var(--w-chrome-sub); }
</style>
