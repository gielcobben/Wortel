<script>
  import { PaneGroup, Pane, PaneResizer } from 'paneforge';
  import Plus from '@lucide/svelte/icons/plus';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import Check from '@lucide/svelte/icons/check';
  import Cloud from '@lucide/svelte/icons/cloud';
  import ArrowUp from '@lucide/svelte/icons/arrow-up';
  import { changes, commits, commitFiles } from './data.js';
  import Diff from './Diff.svelte';

  // tab + visibility live in WortelApp (the toolbar is window chrome there,
  // so it survives this panel collapsing — behavior ported from the app)
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

  // history rail geometry: rows are 22px, dots centered per row
  const ROW = 22;
  const cy = (i) => i * ROW + ROW / 2;

  // measured defaults → pane percentages (panel is 797 tall; the history
  // resizer is the 26px expand bar, leaving 771 for its two panes)
  const CH_UPPER = (292 / 797) * 100;
  const HI_UPPER = (354 / 771) * 100;
</script>

<!-- Full-height panel (spans the titlebar zone — no hairline on this side).
     The toolbar floats top-right; upper regions scroll BENEATH it with a fade.
     Both modes are vertical PaneGroups so the regions are user-resizable; in
     History, the expand bar itself is the drag handle. -->
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
            <svg class="rail" width="30" height={commits.length * ROW} aria-hidden="true">
              <line x1="14.5" y1="0" x2="14.5" y2={commits.length * ROW} stroke="var(--w-rail)" stroke-width="2" />
              <path d="M 14.5 {cy(9)} C 14.5 {cy(9)+11}, 22.5 {cy(9)+11}, 22.5 {cy(10)} L 22.5 {cy(11)} C 22.5 {cy(11)+11}, 14.5 {cy(11)+11}, 14.5 {cy(12)}"
                fill="none" stroke="var(--w-rail-branch)" stroke-width="2" />
              {#each commits as c, i}
                {#if c.side}
                  <circle cx="22.5" cy={cy(i)} r="3.5" fill="var(--w-rail-branch)" stroke="var(--w-panel-bg)" stroke-width="2" />
                {:else if c.merge}
                  <circle cx="14.5" cy={cy(i)} r="4" fill="var(--w-panel-bg)" stroke="var(--w-rail)" stroke-width="2.5" />
                {:else}
                  <circle cx="14.5" cy={cy(i)} r="3.5" fill="var(--w-rail)" stroke="var(--w-panel-bg)" stroke-width="2" />
                {/if}
              {/each}
            </svg>
            {#each commits as c, i}
              <button class="crow" class:sel={i === selCommit} type="button" onclick={() => (selCommit = i)}>
                <span class="railpad"></span>
                <span class="msg">
                  {#if c.refs}
                    {#each c.refs as r}
                      <span class="chipref" class:branch={r.branch}>
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
  /* full-height panel; width comes from its Pane */
  .panel {
    position: relative;
    width: 100%;
    height: 100%;
    background: var(--w-panel-bg);
    border-left: 1px solid var(--w-hairline);
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
  .letter { font-family: var(--w-mono); font-size: 11.8px; font-weight: 700; width: 13px; flex-shrink: 0; }
  .letter.m { color: var(--w-status-m); }
  .letter.a, .letter.q { color: var(--w-status-a); }
  .letter.d { color: var(--w-status-d); }
  .name { font-size: 13px; font-weight: 600; white-space: nowrap; }
  .path { font-size: 11px; color: var(--w-chrome-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ca { color: var(--w-count-add); font-weight: 600; }
  .cd { color: var(--w-count-del); font-weight: 600; }

  /* ---- Changes ---- */
  .upper { height: 100%; }
  .head {
    height: 26px;
    margin-top: 51px;
    display: flex; justify-content: space-between; align-items: center;
    padding: 8px 10px 0 12.5px;
    font-size: 11px; font-weight: 600; color: var(--w-chrome-sub);
  }
  .plus { display: grid; place-items: center; }
  .frow {
    display: flex; align-items: center;
    width: calc(100% - 8px); height: 22px; margin: 0 4px;
    border: 0; background: transparent; color: inherit; font: inherit;
    text-align: left; padding: 0 4px 0 11px; border-radius: 5px; cursor: pointer;
  }
  .frow .name { margin-right: 7px; }
  .frow:hover { background: color-mix(in srgb, var(--w-chrome-text) 6%, transparent); }
  .frow.sel { background: var(--w-accent); }
  .frow.sel .letter, .frow.sel .name { color: var(--w-accent-text); }
  .frow.sel .path { color: color-mix(in srgb, var(--w-accent-text) 65%, transparent); }

  .lower { height: 100%; display: flex; flex-direction: column; }
  .diffarea { flex: 1; min-height: 0; }
  .boxzone { position: relative; height: 132px; flex-shrink: 0; }

  .msgbox {
    position: absolute; left: 12px; right: 13px; bottom: 12px; height: 69px;
    background: var(--w-box-bg);
    border: 1px solid var(--w-box-border);
    border-radius: 10px;
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

  /* ---- History ---- */
  .hlist { height: 100%; }
  .railwrap { position: relative; padding-top: 56px; }
  .rail { position: absolute; top: 56px; left: 0; pointer-events: none; z-index: 1; }
  .crow {
    position: relative;
    display: flex; align-items: center;
    width: 100%; height: 22px;
    border: 0; background: transparent; color: inherit; font: inherit;
    text-align: left; padding: 0 16.5px 0 0; cursor: pointer;
  }
  .crow:hover { background: color-mix(in srgb, var(--w-chrome-text) 5%, transparent); }
  .crow.sel { background: var(--w-accent); color: var(--w-accent-text); }
  .crow.sel .author, .crow.sel .sha, .crow.sel .when { color: var(--w-accent-text); opacity: 0.9; }
  .railpad { width: 30px; flex-shrink: 0; }
  .msg { flex: 1; min-width: 0; display: flex; align-items: center; gap: 5px; overflow: hidden; font-size: 13px; white-space: nowrap; letter-spacing: -0.14px; }
  .msg b { font-weight: 600; }
  .subj { overflow: hidden; text-overflow: ellipsis; }
  .chipref {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    gap: 2px;
    font-size: 10.5px; font-weight: 600;
    height: 16px;
    padding: 0 6px; border-radius: 4px;
    border: 1px solid var(--w-chip-border);
    color: var(--w-chip-text); background: var(--w-chip-bg);
  }
  .crow.sel .chipref {
    background: var(--w-chip-on-sel); color: #fff;
    border-color: color-mix(in srgb, #fff 45%, transparent);
  }
  /* measured right block: [Giel 1168–1187][3][sha 1190–1236][2][1h …1249.5] */
  .author { font-size: 11px; color: var(--w-chrome-sub); padding: 0 3px 0 12px; }
  .sha { font-family: var(--w-mono); font-size: 11px; color: var(--w-chrome-sub); margin-right: 2px; }
  .when { font-size: 11px; color: var(--w-chrome-sub); }

  .expandbar {
    height: 26px;
    display: flex; justify-content: space-between; align-items: center;
    padding: 0 10px;
    background: var(--w-expand-bar-bg);
    border-top: 1px solid var(--w-hairline-strong);
    border-bottom: 1px solid var(--w-hairline-strong);
    font-size: 11px; color: var(--w-chrome-sub);
  }
  .totals { font-size: 11px; }

  .acc { height: 100%; }
  /* file headers stick while their diff scrolls (stacked replace) */
  .afile {
    position: sticky;
    top: 0;
    z-index: 2;
    background: var(--w-panel-bg);
    display: flex; align-items: center;
    width: 100%; height: 22px;
    border: 0; color: inherit; font: inherit;
    text-align: left; padding: 0 10px 0 12px; cursor: pointer;
  }
  .afile:hover { background: color-mix(in srgb, var(--w-chrome-text) 5%, var(--w-panel-bg)); }
  .chevron { width: 14px; color: var(--w-chrome-sub); display: grid; place-items: center; justify-content: start; }
  .afile .name { margin-right: 7px; }
  .counts { margin-left: auto; font-size: 11px; }
</style>
