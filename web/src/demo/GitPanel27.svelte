<script>
  import { PaneGroup, Pane, PaneResizer } from 'paneforge';
  import Plus from '@lucide/svelte/icons/plus';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import Check from '@lucide/svelte/icons/check';
  import Cloud from '@lucide/svelte/icons/cloud';
  import ArrowUp from '@lucide/svelte/icons/arrow-up';
  import { changes, commits, commitFiles, branch } from './data.js';
  import Diff from './Diff.svelte';

  // tab + visibility live in WortelApp27 (the toolbar is window chrome there,
  // so it survives this panel collapsing — behaviour ported from the app)
  let { tab = 'changes' } = $props();

  let selChange = $state(0);
  let selCommit = $state(0);
  let open = $state({ BUILD: false, 'appcast.xml': true });

  const selected = $derived(changes[selChange]);

  // "Git History: harden…" → bold "Git History:" prefix, like the app
  function splitSubject(s) {
    const i = s.indexOf(': ');
    return i > 0 ? [s.slice(0, i + 1), s.slice(i + 1)] : [null, s];
  }

  // macOS 27's app colours a ref chip by WHICH branch it names: the checked-out
  // branch is a filled chip, its remote an outline in the same hue, and every
  // other ref stays blue (measured on the light/dark history refs).
  function chipKind(r) {
    if (r.icon === 'check') return 'k-head';
    if (r.icon === 'cloud' && r.label.endsWith('/' + branch)) return 'k-rem';
    return 'k-other';
  }

  // history rail geometry: rows are 22px, dots centered per row, lanes at 15
  // and 27 (panel-relative), text from 38.5
  const ROW = 22;
  const cy = (i) => i * ROW + ROW / 2;
  // The app indents a row by the graph beside it: rows the side branch runs
  // past clear TWO lanes, the rest clear one. Measured on the light history
  // ref: single-lane rows start their text at panel+31, two-lane rows at +43,
  // and the selection begins 4.5 to the left of the text either way.
  const twoLanes = (i) => i >= 9 && i <= 12;
  const rowIndent = (i) => (twoLanes(i) ? 38.5 : 26.5);

  // measured defaults → pane percentages (the history resizer is the 26px
  // expand bar, leaving the rest for its two panes)
  // measured on the refs: in Changes the file list gives way at y340 of 807; in
  // History the expand bar (the 27px resizer) sits at 354, leaving 780 to split.
  const CH_UPPER = (340 / 807) * 100;
  const HI_UPPER = (354 / 780) * 100;
</script>

<!-- Full-height panel, the same material as the sidebar and with no divider
     rule between it and the terminal (macOS 27 dropped the hairline). The
     toolbar floats above it; upper regions scroll BENEATH it with a fade. -->
<div class="panel">
  {#if tab === 'changes'}
    <PaneGroup direction="vertical" class="vgroup">
      <!-- upper region: header + file list, scrolls under the toolbar -->
      <Pane defaultSize={CH_UPPER} minSize={12}>
        <div class="scroll upper">
          <div class="head"><span>Changes ({changes.length})</span><span class="plus"><Plus size={17} strokeWidth={1.5} absoluteStrokeWidth aria-hidden="true" /></span></div>
          {#each changes as f, i}
            <button class="frow" class:sel={i === selChange} type="button" onclick={() => (selChange = i)}>
              <span class="letter {f.kind}">{f.status}</span>
              <span class="name">{f.name}</span>
              <span class="path">{f.path}</span>
            </button>
          {/each}
        </div>
      </Pane>
      <PaneResizer class="vresizer" />
      <Pane defaultSize={100 - CH_UPPER} minSize={25}>
        <div class="lower">
          <div class="scroll diffarea">
            {#if selected?.hunks.length}
              <Diff hunks={selected.hunks} lang={selected.lang} />
            {/if}
          </div>
          <div class="boxzone">
            <div class="msgbox">
              <span class="ph">Message (⌘↵ to commit)</span>
              <span class="send"><ArrowUp size={13} strokeWidth={1.8} absoluteStrokeWidth aria-hidden="true" /></span>
            </div>
          </div>
        </div>
      </Pane>
    </PaneGroup>
  {:else}
    <PaneGroup direction="vertical" class="vgroup">
      <!-- commit log: scrolls under the toolbar; the rail scrolls with it -->
      <Pane defaultSize={HI_UPPER} minSize={15}>
        <div class="scroll hlist">
          <div class="railwrap">
            <svg class="rail" width="38.5" height={commits.length * ROW} aria-hidden="true">
              <line x1="15" y1="0" x2="15" y2={commits.length * ROW} stroke="var(--w-rail)" stroke-width="1.5" />
              <path d="M 15 {cy(9)} C 15 {cy(9)+11}, 27 {cy(9)+11}, 27 {cy(10)} L 27 {cy(11)} C 27 {cy(11)+11}, 15 {cy(11)+11}, 15 {cy(12)}"
                fill="none" stroke="var(--w-rail-branch)" stroke-width="1.5" />
              {#each commits as c, i}
                {#if c.side}
                  <circle cx="27" cy={cy(i)} r="2" fill="var(--w-rail-branch)" />
                {:else if c.merge}
                  <circle cx="15" cy={cy(i)} r="2.5" fill="var(--w-panel-bg)" stroke="var(--w-rail)" stroke-width="1.5" />
                {:else}
                  <circle cx="15" cy={cy(i)} r="2" fill="var(--w-rail)" />
                {/if}
              {/each}
            </svg>
            {#each commits as c, i}
              <button class="crow" class:sel={i === selCommit} type="button"
                style="--indent: {rowIndent(i)}px" onclick={() => (selCommit = i)}>
                <span class="msg">
                  {#if c.refs}
                    {#each c.refs as r}
                      <span class="chipref {chipKind(r)}">
                        {#if r.icon === 'check'}<Check size={10} strokeWidth={2} absoluteStrokeWidth aria-hidden="true" />
                        {:else if r.icon === 'cloud'}<Cloud size={10} strokeWidth={1.8} absoluteStrokeWidth aria-hidden="true" />{/if}
                        {r.label}
                      </span>
                    {/each}
                  {/if}
                  {#if splitSubject(c.subject)[0]}<b>{splitSubject(c.subject)[0]}</b>{/if}
                  <span class="subj">{splitSubject(c.subject)[1]}</span>
                </span>
                <span class="author">{c.author}</span>
                <span class="sha">{c.sha}</span>
                <span class="when">{c.when}</span>
              </button>
            {/each}
          </div>
        </div>
      </Pane>
      <!-- the expand bar IS the resize handle between log and accordion -->
      <PaneResizer class="expandresizer">
        <div class="expandbar">
          <span>Expand All</span>
          <span class="totals">2 files <b class="ca">+9</b> <b class="cd">−9</b></span>
        </div>
      </PaneResizer>
      <Pane defaultSize={100 - HI_UPPER} minSize={15}>
        <div class="scroll acc">
          {#each commitFiles as f}
            <button class="afile" type="button" onclick={() => (open[f.name] = !open[f.name])}>
              <span class="chevron">
                {#if open[f.name]}<ChevronDown size={12} strokeWidth={1.6} absoluteStrokeWidth aria-hidden="true" />
                {:else}<ChevronRight size={12} strokeWidth={1.6} absoluteStrokeWidth aria-hidden="true" />{/if}
              </span>
              <span class="letter {f.kind}">{f.status}</span>
              <span class="name">{f.name}</span>
              <span class="path">{f.path}</span>
              <span class="counts"><b class="ca">+{f.add}</b> <b class="cd">−{f.del}</b></span>
            </button>
            {#if open[f.name]}
              <Diff hunks={f.hunks} lang={f.lang} />
            {/if}
          {/each}
        </div>
      </Pane>
    </PaneGroup>
  {/if}
</div>

<style>
  .panel {
    position: relative;
    width: 100%;
    height: 100%;
    /* the material darkens over the last ~25px, the same edge the sidebar has */
    background:
      linear-gradient(to top, color-mix(in srgb, #000 3%, var(--w-panel-bg)) 0, var(--w-panel-bg) 26px);
    font-family: var(--w-sans);
    color: var(--w-chrome-text);
    overflow: hidden;
  }
  .panel :global(.vgroup) { height: 100%; }

  /* invisible horizontal grab strip between the vertical panes */
  .panel :global(.vresizer) {
    position: relative;
    height: 0;
    z-index: 5;
  }
  .panel :global(.vresizer)::after {
    content: '';
    position: absolute;
    left: 0; right: 0;
    top: -4px;
    height: 9px;
    cursor: row-resize;
  }
  .panel :global(.expandresizer) { z-index: 5; cursor: row-resize; }

  /* scroll areas hide their bars (macOS overlay style) */
  .scroll { overflow-y: auto; scrollbar-width: none; }
  .scroll::-webkit-scrollbar { display: none; }

  /* content fades as it slides under the floating toolbar (window chrome) */
  .upper, .hlist {
    mask-image: linear-gradient(to bottom, rgba(0, 0, 0, 0.2) 30px, #000 62px);
    -webkit-mask-image: linear-gradient(to bottom, rgba(0, 0, 0, 0.2) 30px, #000 62px);
  }

  /* shared bits */
  .letter { font-family: var(--w-mono); font-size: 12px; font-weight: 700; width: 18px; flex-shrink: 0; }
  .letter.m { color: var(--w-status-m); }
  .letter.a, .letter.q { color: var(--w-status-a); }
  .letter.d { color: var(--w-status-d); }
  .name { font-size: 13px; font-weight: 500; white-space: nowrap; }
  .path { font-size: 11px; color: var(--w-chrome-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ca { color: var(--w-count-add); font-weight: 600; }
  .cd { color: var(--w-count-del); font-weight: 600; }

  /* ---- Changes ----
     measured: header text at panel+12.5 with its baseline at 72; rows 22 tall;
     the selection is inset 4.5 on BOTH sides and rounded. */
  .upper { height: 100%; }
  .head {
    height: 26px;
    margin-top: 52px;
    display: flex; justify-content: space-between; align-items: center;
    padding: 8px 10px 0 12.5px;
    font-size: 10.5px; font-weight: 600; color: var(--w-chrome-sub);
  }
  .plus { display: grid; place-items: center; }
  .frow {
    display: flex; align-items: center;
    width: calc(100% - 9px); height: 22px; margin: 0 4.5px;
    border: 0; background: transparent; color: inherit; font: inherit;
    text-align: left; padding: 0 4px 0 10.5px; border-radius: 6px; cursor: pointer;
  }
  .frow .name { margin-right: 7px; }
  .frow:hover { background: color-mix(in srgb, var(--w-chrome-text) 6%, transparent); }
  .frow.sel { background: var(--w-accent); }
  .frow.sel .letter, .frow.sel .name { color: var(--w-accent-text); }
  .frow.sel .path { color: color-mix(in srgb, var(--w-accent-text) 65%, transparent); }

  .lower { height: 100%; display: flex; flex-direction: column; background: var(--w-code-bg); }
  .diffarea { flex: 1; min-height: 0; }
  /* measured: the rule above the commit box at y714, the box 727.5→794.5 in an
     807-tall window — so the zone is 93 tall with the box inset 13.5/12.5 */
  .boxzone {
    position: relative; height: 93px; flex-shrink: 0;
    background: var(--w-panel-bg);
    border-top: 0.5px solid var(--w-hairline-strong);
  }

  .msgbox {
    position: absolute; left: 12px; right: 12.5px; bottom: 11.5px; height: 67px;
    background: var(--w-box-bg);
    border: 0.5px solid var(--w-box-border);
    border-radius: 11px;
    padding: 10px 12px;
  }
  .ph { font-size: 13px; color: var(--w-box-placeholder); }
  .send {
    position: absolute; right: 8px; bottom: 8px;
    width: 22px; height: 22px; border-radius: 50%;
    display: grid; place-items: center;
    background: var(--w-box-send-bg); color: var(--w-box-send-fg);
    font-size: 12px;
  }

  /* ---- History ----
     measured: rail lanes at 15 and 27, row text from 38.5, and the selection
     inset 38.5 on the left (it starts where the graph ends) and 11.5 right. */
  .hlist { height: 100%; }
  .railwrap { position: relative; padding-top: 56px; }
  .rail { position: absolute; top: 56px; left: 0; pointer-events: none; z-index: 1; }
  .crow {
    position: relative;
    display: flex; align-items: center;
    /* A button is shrink-to-fit even as a flex container, so the width has to
       be spelled out or the right-hand columns ride up against the subject. */
    margin-left: var(--indent);
    margin-right: 11.5px;
    width: calc(100% - var(--indent) - 11.5px);
    height: 22px;
    border: 0; background: transparent; color: inherit; font: inherit;
    text-align: left; padding: 0 0 0 4.5px; border-radius: 5px; cursor: pointer;
  }
  .crow:hover { background: color-mix(in srgb, var(--w-chrome-text) 5%, transparent); }
  .crow.sel { background: var(--w-accent); color: var(--w-accent-text); }
  .crow.sel .author, .crow.sel .sha, .crow.sel .when { color: var(--w-accent-text); opacity: 0.9; }
  .msg { flex: 1; min-width: 0; display: flex; align-items: center; gap: 5px; overflow: hidden; font-size: 12px; white-space: nowrap; letter-spacing: -0.14px; }
  .msg b { font-weight: 600; }
  .subj { overflow: hidden; text-overflow: ellipsis; }

  /* ref chips: filled for the checked-out branch, outlined for its remote,
     blue for everything else */
  .chipref {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    gap: 2px;
    font-size: 10.5px; font-weight: 600;
    height: 15px;
    padding: 0 5.5px; border-radius: 4px;
    border: 1px solid var(--w-chip-border);
    color: var(--w-chip-text); background: var(--w-chip-bg);
  }
  .chipref.k-head {
    border-color: var(--w-chip-head-border);
    color: var(--w-chip-head-text); background: var(--w-chip-head-bg);
  }
  .chipref.k-rem {
    border-color: var(--w-chip-rem-border);
    color: var(--w-chip-rem-text); background: var(--w-chip-rem-bg);
  }
  .crow.sel .chipref {
    background: var(--w-chip-on-sel); color: #fff;
    border-color: color-mix(in srgb, #fff 45%, transparent);
  }
  /* Fixed columns, measured across every row of the light history ref: the
     author's text ends 136.5 before the row's right edge, the sha (7 mono
     characters, 50px) ends 36.5 before it, and the time is right-aligned with
     4.5 to spare. */
  .author { font-size: 11.5px; color: var(--w-chrome-sub); padding-right: 48.5px; }
  .sha {
    font-family: var(--w-mono);
    font-size: calc(7.14px / var(--w-mono-advance));
    color: var(--w-chrome-sub);
    width: 50px; text-align: right; flex-shrink: 0;
  }
  .when {
    font-size: 11.5px; color: var(--w-chrome-sub);
    width: 36.5px; text-align: right; padding-right: 4.5px; flex-shrink: 0;
  }

  /* measured: rules at 354 and 380.5, bar fill #fbfbfb (the code surface) */
  .expandbar {
    height: 25px;
    display: flex; justify-content: space-between; align-items: center;
    padding: 0 10px;
    background: var(--w-expand-bar-bg);
    border-top: 0.5px solid var(--w-hairline-strong);
    border-bottom: 0.5px solid var(--w-hairline-strong);
    font-size: 11px; color: var(--w-chrome-sub);
  }
  .totals { font-size: 11px; }

  /* the accordion sits on the code surface, not the panel material */
  .acc { height: 100%; background: var(--w-code-bg); }
  /* file headers stick while their diff scrolls (stacked replace) */
  .afile {
    position: sticky;
    top: 0;
    z-index: 2;
    background: var(--w-code-bg);
    display: flex; align-items: center;
    width: 100%; height: 22px;
    border: 0; color: inherit; font: inherit;
    text-align: left; padding: 0 10px 0 12px; cursor: pointer;
  }
  .afile:hover { background: color-mix(in srgb, var(--w-chrome-text) 5%, var(--w-code-bg)); }
  .chevron { width: 14px; color: var(--w-chrome-sub); display: grid; place-items: center; justify-content: start; }
  .afile .name { margin-right: 7px; }
  .counts { margin-left: auto; font-size: 11px; }
</style>
