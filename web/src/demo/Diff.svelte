<script>
  import { highlight } from './util.js';
  let { hunks = [], lang = 'text' } = $props();
</script>

<div class="diff">
  {#each hunks as hunk}
    <div class="hunk">{hunk.header}</div>
    {#each hunk.lines as ln}
      <div class="row {ln.k}">
        <span class="num">{ln.o ?? ''}</span>
        <span class="num">{ln.n ?? ''}</span>
        <span class="sign">{ln.k === 'add' ? '+' : ln.k === 'del' ? '-' : ''}</span>
        <span class="code">{#each highlight(ln.t, lang) as s}<span class="c-{s.c}">{s.t}</span>{/each}</span>
      </div>
    {/each}
  {/each}
</div>

<style>
  /* Measured: rows 18px, hunk strip 19px, code col at x=71 (panel-relative),
     line numbers right-aligned in two 26px columns, font 12.2px mono. */
  .diff {
    font-family: var(--w-mono);
    font-size: var(--w-diff-size);
    line-height: var(--w-diff-line);
    font-variant-ligatures: none;
  }
  /* measured: hunk text at panel+8.5; num cols right-align at 22/48;
     code text starts at panel+70 */
  .hunk {
    height: 19px;
    line-height: 19px;
    background: var(--w-diff-hunk-bg);
    color: var(--w-diff-hunk-text);
    padding-left: 8.5px;
    white-space: pre;
    overflow: hidden;
  }
  .row {
    display: grid;
    grid-template-columns: 22px 26px 22px 1fr;
    height: 18px;
    white-space: pre;
    overflow: hidden;
  }
  .num {
    text-align: right;
    color: var(--w-diff-linenum);
    user-select: none;
  }
  .sign { text-align: center; }
  .code { overflow: hidden; }
  .row.add { background: var(--w-diff-add-bg); }
  .row.del { background: var(--w-diff-del-bg); }
  .row.add .sign { color: var(--w-count-add); }
  .row.del .sign { color: var(--w-count-del); }

  .c-, .code { color: var(--w-syn-plain); }
  .c-kw { color: var(--w-syn-kw); }
  .c-str { color: var(--w-syn-str); }
  .c-com { color: var(--w-syn-com); }
  .c-attr { color: var(--w-syn-attr); }
</style>
