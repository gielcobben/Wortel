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
    {#each rows as row}
      {#if row.block}
        <!-- user message block: bg wraps gutter + lines -->
        <div class="ublock">
          <div class="row">
            <span class="g">{row.g}</span>
            <span class="t">{row.lines[0]}</span>
          </div>
          {#each row.lines.slice(1) as line}
            <div class="row"><span class="g"></span><span class="t">{line}</span></div>
          {/each}
        </div>
      {:else}
        <div class="row {row.cls ?? ''}" class:right={row.right} class:flow={row.flow}>
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
  .scroll { flex: 1; overflow: hidden; padding: 25px 0 0 0; display: flex; flex-direction: column; }
  /* when filled, the prompt row pins to the bottom, like the real app */
  .scroll.filled > :global(:last-child) { margin-top: auto; margin-bottom: 9px; }

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
