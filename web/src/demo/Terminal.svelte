<script>
  import { transcript, statusBar, statusBarRight } from './data.js';
  import { parseInline, wrapSegments } from './util.js';

  // Which scene to draw. `sceneId` is the re-stream trigger: when the tour
  // moves to a new section the rows are rebuilt from scratch, so their CSS
  // reveal animations run again and the output visibly types itself in. A width
  // change must NOT do that, which is why the key is the scene and not the rows.
  let { rows = transcript, sceneId = 'arrive', status = false } = $props();

  // Rows are authored UNWRAPPED and re-wrapped here to whatever width the
  // terminal currently is, because that is what a terminal does. This window is
  // a different width in every section of the tour (both panels open in the
  // hero leaves 33 columns; both closed leaves over 100), and a hard-coded
  // break is only ever right at the one width it was written for.

  // The row grid is `23px 1fr` behind 8px of left padding, so the text column
  // is the terminal minus 31px. A user block additionally sits inside 4px/12px
  // margins and 4px of padding, so it loses 12 more.
  const GUTTER = 31;
  const BLOCK_INSET = 43;

  let scrollEl = $state();
  let probeEl = $state();

  // 33 is the hero's width. Defaulting to it means the server-rendered wrap is
  // already right for the first screen, and the re-wrap after measuring lands
  // long before the reveal starts, so it is never visible.
  let cols = $state(33);
  let blockCols = $state(31);

  $effect(() => {
    if (!scrollEl || !probeEl) return;
    const measure = () => {
      // Measure the advance rather than trusting --w-term-cell: if the font
      // falls back, the token is wrong and every line would wrap early.
      const cell = probeEl.getBoundingClientRect().width / 40;
      if (!cell) return;
      const w = scrollEl.clientWidth;
      cols = Math.max(12, Math.floor((w - GUTTER) / cell));
      blockCols = Math.max(12, Math.floor((w - BLOCK_INSET) / cell));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(scrollEl);
    return () => ro.disconnect();
  });

  // Source rows become items carrying their wrapped lines plus the index of
  // their first line, so the reveal staggers continuously down the OUTPUT
  // rather than jumping several steps at a paragraph.
  const items = $derived.by(() => {
    let i = 0;
    return rows.map((row) => {
      const width = row.block ? blockCols : cols;
      const lines = row.caret ? [[]] : wrapSegments(parseInline(row.t ?? ''), width);
      const item = { row, lines, i0: i };
      i += lines.length;
      return item;
    });
  });

  // an empty terminal is just the prompt at the top; a filled one pins the
  // prompt to the bottom. The status strip is Claude Code's, so it belongs to
  // the scenes where an agent is actually running.
  const filled = $derived(rows.length > 1);

  // The status line is a TUI, not prose: it cannot wrap, so it drops trailing
  // segments until it fits, the way a real status line truncates itself.
  const statusLeft = $derived.by(() => {
    const budget = cols - statusBarRight.t.length - 2;
    const out = [];
    let n = 0;
    for (const s of statusBar) {
      if (n + s.t.length > budget) break;
      out.push(s);
      n += s.t.length;
    }
    return out;
  });

  // The reveal runs once per SCENE. Reading sceneId is what re-arms it; the
  // effect then clears the flag when the last line has landed, so a re-wrap
  // (a panel opening, the window resizing) redraws without re-animating.
  let streaming = $state(true);
  $effect(() => {
    // Reading sceneId is what re-arms the reveal. Bound to `key` rather than
    // left as a bare expression so the timer below can compare against it.
    const key = sceneId;
    if (typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches) {
      streaming = false;
      return;
    }
    streaming = true;
    // The guard is why `key` is used rather than voided: a scene that changes
    // again mid-reveal must not have the outgoing scene's timer clear its flag.
    const id = setTimeout(() => {
      if (key === sceneId) streaming = false;
    }, 2600);
    return () => clearTimeout(id);
  });
</script>

<div class="term">
  <!-- 40 characters of the terminal's own font, measured for the cell advance -->
  <span class="cellprobe" bind:this={probeEl} aria-hidden="true">MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM</span>

  <div class="scroll" class:filled class:streaming bind:this={scrollEl}>
    <!-- keyed on the scene: a new section rebuilds every line, which is what
         restarts the reveal. {#key} emits no element, so `.scroll > .row`
         still selects them. -->
    {#key sceneId}
    {#each items as item}
      {#if item.row.block}
        <!-- user message block: the background wraps every wrapped line -->
        <div class="ublock" style="--i:{item.i0}">
          {#each item.lines as line, j}
            <div class="row">
              <span class="g">{j === 0 ? (item.row.g ?? '') : ''}</span>
              <span class="t">{#each line as seg}{#if seg.link}<a class="lnk" href="#top" tabindex="-1">{seg.t}</a>{:else if seg.bold}<b>{seg.t}</b>{:else if seg.italic}<i>{seg.t}</i>{:else}{seg.t}{/if}{/each}</span>
            </div>
          {/each}
        </div>
      {:else}
        {#each item.lines as line, j}
          <div class="row {item.row.cls ?? ''}" style="--i:{item.i0 + j}">
            <!-- a wrapped continuation carries no gutter glyph, like the app -->
            <span class="g {item.row.gcls ?? ''}">{j === 0 ? (item.row.g ?? '') : ''}</span>
            <span class="t" class:ind={item.row.ind}>
              {#if item.row.caret}<span class="caret"></span>
              {:else if line.length === 0}<br />
              {:else}{#each line as seg}{#if seg.link}<a class="lnk" href="#top" tabindex="-1">{seg.t}</a>{:else if seg.bold}<b>{seg.t}</b>{:else if seg.italic}<i>{seg.t}</i>{:else}{seg.t}{/if}{/each}{/if}
            </span>
          </div>
        {/each}
      {/if}
    {/each}
    {/key}
  </div>

  <!-- the status bar is Claude Code's TUI, i.e. terminal content, so it only
       exists in the scenes where an agent is running -->
  {#if status}
    <div class="statusbar">
      {#each statusLeft as s}<span class="sb-{s.cls}">{s.t}</span>{/each}
      <span class="sb-spacer"></span>
      <span class="sb-{statusBarRight.cls}">{statusBarRight.t}</span>
    </div>
  {/if}
</div>

<style>
  /* Measured: text col at x=31, gutter glyphs at x=8, first line top ≈ 77.5
     (titlebar 51 + 26 padding). Cell 9.96×19. */
  .term {
    position: relative;   /* the cell probe is absolutely positioned in here */
    display: flex;
    flex-direction: column;
    min-width: 0;
    flex: 1;
    background: var(--w-terminal-bg);
    color: var(--w-term-text);
    font-family: var(--w-mono);
    font-size: var(--w-term-size);
    line-height: var(--w-term-line);
    font-variant-ligatures: none;
    /* min-height: 0 is load-bearing. As a flex item .term's automatic minimum
       is its CONTENT height, so a transcript taller than the window pushed the
       terminal out through the bottom of the app instead of being clipped by
       it: at 1520x800 the window is 720px tall and the terminal was 760. */
    min-height: 0;
  }

  .cellprobe {
    position: absolute;
    top: 0;
    left: 0;
    visibility: hidden;
    pointer-events: none;
    white-space: pre;
  }

  .scroll {
    flex: 1;
    min-height: 0;
    overflow: hidden;
    padding: 25px 0 0 0;
    display: flex;
    flex-direction: column;
  }
  /* Anchor the output to the BOTTOM, which is what a terminal does: the newest
     line sits above the prompt and older ones scroll off the top. It also means
     overflow can only ever clip scrollback, never the prompt, so the window can
     be any height and still look right. */
  .scroll.filled { justify-content: flex-end; }
  .scroll.filled > :global(:last-child) { margin-bottom: 9px; }

  /* ---- the output arriving -------------------------------------------------
     A staggered reveal, in CSS rather than JS on purpose: the island is
     server-rendered, so a JS counter would paint the whole transcript, then
     blank it on hydration, then type it back. Every line is authored visible
     and starts at opacity 0 under an animation that lands it, so the first
     paint is already mid-stream and nothing flashes. Direct children only, so
     a user block fades as one card rather than line by line. */
  .scroll.streaming > .row,
  .scroll.streaming > .ublock {
    opacity: 0;
    transform: translateY(3px);
    animation: term-in 0.28s cubic-bezier(0.2, 0.8, 0.3, 1) forwards;
    /* capped, so a long scene still finishes arriving promptly */
    animation-delay: calc(min(var(--i, 0), 24) * 45ms + 120ms);
  }
  @keyframes term-in {
    to { opacity: 1; transform: none; }
  }

  .row {
    display: grid;
    grid-template-columns: 23px 1fr;
    padding-left: 8px;
    min-height: 19px;
  }
  .g { color: var(--w-term-text); white-space: pre; }
  .g.dim { color: var(--w-term-dim); }
  .g.active { color: var(--w-term-active); }
  .row.dim .t { color: var(--w-term-dim); }
  .row.active .t { color: var(--w-term-active); }
  /* Lines arrive pre-wrapped from wrapSegments, so the browser must not wrap
     them a second time in a different place. */
  .t { white-space: pre; overflow: hidden; min-width: 0; }
  .t.ind { padding-left: calc(2 * var(--w-term-cell)); }

  b { font-weight: 700; }
  i { font-style: italic; }
  .lnk { color: var(--w-term-link); text-decoration: none; }
  .lnk:hover { text-decoration: underline; }

  /* the gutter glyph may overflow its 23px column on purpose, like the app */
  .g { overflow: visible; z-index: 1; }

  .ublock {
    background: var(--w-user-block-bg);
    color: var(--w-user-block-text);
    border-radius: 6px;
    /* negative margins calibrate the ref's tighter spacing around the block */
    margin: -8.5px 12px -4px 4px;
    padding: 6px 0;
  }
  .ublock .row { padding-left: 4px; }
  .ublock .g { color: var(--w-user-block-text); }

  .caret {
    display: inline-block;
    width: 10px;
    height: 19px;
    vertical-align: top;
    background: var(--w-caret);
    /* Waits out the reveal so it starts blinking when the prompt lands, not
       while the output above it is still arriving. */
    animation: caret-blink 1.06s steps(1, end) infinite;
    animation-delay: 1.5s;
  }
  @keyframes caret-blink {
    0%, 55% { opacity: 1; }
    56%, 100% { opacity: 0; }
  }

  /* Nothing here is information, so under reduced motion it all simply is. */
  @media (prefers-reduced-motion: reduce) {
    .scroll.streaming > .row,
    .scroll.streaming > .ublock { opacity: 1; transform: none; animation: none; }
    .caret { animation: none; }
  }

  /* Measured: hairline at y=749, text at 761 → 48 tall, 12px top padding */
  .statusbar {
    flex-shrink: 0;
    height: 48px;
    display: flex;
    align-items: flex-start;
    padding: 11px 16px 0;
    border-top: 1px solid var(--w-hairline);
    white-space: pre;
    overflow: hidden;
  }
  .sb-amber { color: var(--w-sb-amber); }
  .sb-teal { color: var(--w-sb-teal); }
  .sb-dim { color: var(--w-sb-dim); }
  .sb-rc { color: var(--w-sb-rc); }
  .sb-spacer { flex: 1; }
</style>
