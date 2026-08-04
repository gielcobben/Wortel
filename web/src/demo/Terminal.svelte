<script>
  import { transcript, statusBar, statusBarRight } from './data.js';
  import { parseInline } from './util.js';

  // Which transcript to draw. Defaults to the full session: a terminal is the
  // one part of this replica that looks broken when it's empty, and the tour
  // needs a window with something in it at every stop.
  let { rows = transcript } = $props();

  // an empty terminal is just the prompt at the top; a filled one pins the
  // prompt to the bottom and shows the status bar
  const filled = $derived(rows.length > 1);
</script>

<div class="term">
  <div class="scroll" class:filled>
    {#each rows as row, i}
      {#if row.block}
        <!-- user message block: bg wraps gutter + lines -->
        <div class="ublock" style="--i:{i}">
          <div class="row">
            <span class="g">{row.g}</span>
            <span class="t">{row.lines[0]}</span>
          </div>
          {#each row.lines.slice(1) as line}
            <div class="row"><span class="g"></span><span class="t">{line}</span></div>
          {/each}
        </div>
      {:else}
        <div class="row {row.cls ?? ''}" class:right={row.right} class:flow={row.flow} style="--i:{i}">
          {#if !row.flow}<span class="g {row.gcls ?? ''}">{row.g ?? ''}</span>{/if}
          <span class="t" class:ind={row.ind}>
            {#if row.caret}<span class="caret"></span>
            {:else if row.t === ''}<br />
            {:else}
              {#each parseInline(row.t) as seg}
                {#if seg.link}<a class="lnk" href="#top" tabindex="-1">{seg.t}</a>
                {:else if seg.bold}<b>{seg.t}</b>
                {:else if seg.italic}<i>{seg.t}</i>
                {:else}{seg.t}{/if}
              {/each}
            {/if}
          </span>
        </div>
      {/if}
    {/each}
  </div>

  <!-- the status bar is Claude Code's TUI, i.e. terminal content — hidden
       while the terminal is empty -->
  {#if filled}
    <div class="statusbar">
      {#each statusBar as s}<span class="sb-{s.cls}">{s.t}</span>{/each}
      <span class="sb-spacer"></span>
      <span class="sb-{statusBarRight.cls}">{statusBarRight.t}</span>
    </div>
  {/if}
</div>

<style>
  /* Measured: text col at x=31, gutter glyphs at x=8, first line top ≈ 77.5
     (titlebar 51 + 26 padding). Cell 9.96×19. */
  .term {
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
  }
  /* min-height: 0 is load-bearing. As a flex item .term's automatic minimum is
     its CONTENT height, so a transcript taller than the window pushed the
     terminal out through the bottom of the app instead of being clipped by it:
     at a 1520x800 viewport the window is 720px tall and the terminal was 760,
     spilling 41px past the rounded corner with a hard edge. Only visible once
     the terminal had content in it and the viewport was short enough. */
  .term { min-height: 0; }

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
     blank it on hydration, then type it back. Every row is authored visible and
     starts at opacity 0 under an animation that lands it, so the first paint is
     already mid-stream and nothing flashes. */
  .row, .ublock {
    opacity: 0;
    transform: translateY(3px);
    animation: term-in 0.28s cubic-bezier(0.2, 0.8, 0.3, 1) forwards;
    animation-delay: calc(var(--i, 0) * 85ms + 250ms);
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
  .row.flow { grid-template-columns: 1fr; } /* "[image] …" runs as one line */
  .row.right .t { text-align: right; padding-right: 20px; }
  .g { color: var(--w-term-text); white-space: pre; }
  .g.dim { color: var(--w-term-dim); }
  .g.active { color: var(--w-term-active); }
  .row.dim .t { color: var(--w-term-dim); }
  .row.active .t { color: var(--w-term-active); }
  /* line breaks are hard-coded from the reference — never re-wrap */
  .t { white-space: pre; overflow: hidden; min-width: 0; }
  .t.ind { padding-left: calc(2 * var(--w-term-cell)); }

  b { font-weight: 700; }
  i { font-style: italic; }
  .lnk { color: var(--w-term-link); text-decoration: none; }
  .lnk:hover { text-decoration: underline; }

  /* [image] gutter overflows its 23px column on purpose, like the app */
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
    animation-delay: 2.4s;
  }
  @keyframes caret-blink {
    0%, 55% { opacity: 1; }
    56%, 100% { opacity: 0; }
  }

  /* Nothing here is information, so under reduced motion it all simply is. */
  @media (prefers-reduced-motion: reduce) {
    .row, .ublock { opacity: 1; transform: none; animation: none; }
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
