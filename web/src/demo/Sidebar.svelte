<script>
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import Loader from '@lucide/svelte/icons/loader';
  import Plus from '@lucide/svelte/icons/plus';
  import { groups, agentGroups } from './data.js';
  // `ongrab` starts a width drag; the grip lives here so it slides in and out
  // with the card it sizes.
  let { open = false, force = false, dragging = false, ongrab = undefined, agents = false } = $props();
  // The worktree sessions, once the story has opened them. Same rows, same
  // pitch, two more of them: nothing here is measured differently.
  const list = $derived(agents ? agentGroups : groups);
</script>

<!-- Floating inset sidebar, measured from the refs: a rounded card at
     x 8→227.5, y 8→788 (radius ~16, 1px rim, drop shadow) that OVERLAYS the
     content pane and slides in/out with translateX. The traffic lights and the
     toggle are WINDOW chrome (owned by WortelApp, layered above this card) —
     the card reserves 51px of headroom for them. Positions are card-relative
     (card origin = window 8,8). -->
<div class="overlay" class:open class:force class:dragging>
  <div class="card">
    {#each list as group, gi}
      <div class="group" class:first={gi === 0}>
        <div class="ghead">
          <span class="chev"><ChevronDown size={13} strokeWidth={1.8} absoluteStrokeWidth aria-hidden="true" /></span>
          {group.name}
        </div>
        {#each group.sessions as s}
          <button class="row" class:active={s.active} type="button">
            <span class="nm">{s.name}</span>
            {#if s.dot}
              <span class="dot"></span>
            {:else if s.spinner}
              <span class="spin"><Loader size={13} strokeWidth={1.5} absoluteStrokeWidth aria-hidden="true" /></span>
            {/if}
          </button>
        {/each}
      </div>
    {/each}

    <button class="add" type="button" aria-label="New session">
      <Plus size={20} strokeWidth={1.5} absoluteStrokeWidth aria-hidden="true" />
    </button>
  </div>

  <!-- the split divider: a mouse-only drag handle in a decorative demo, not a
       real ARIA widget. Below the titlebar, so the window's drag strip stays
       a drag strip. -->
  <div class="grip" onpointerdown={ongrab} aria-hidden="true"></div>
</div>

<style>
  /* overlay layer: no background of its own — the content pane shows through
     around the card. Slides with translateX (compositor-friendly). */
  .overlay {
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    /* 228 measured; the grip below can drag it 180…400, like the real split */
    width: var(--sb-shown-w, 228px);
    transform: translateX(calc(-100% - 32px)); /* clear of the card's shadow */
    transition: transform 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
    font-family: var(--w-sans);
    color: var(--w-chrome-text);
    z-index: 3;
    pointer-events: none;
  }
  .overlay.open { transform: translateX(0); pointer-events: auto; }
  .overlay.dragging { transition: none; }

  /* auto-hide: the .wortel-app ancestor is a named query container ('wortelapp');
     below 900 of its OWN width, slide the card back out even when .open —
     UNLESS the user forced it open (.force) to squeeze past the auto-decision */
  @container wortelapp (max-width: 899px) {
    .overlay.open:not(.force) { transform: translateX(calc(-100% - 32px)); pointer-events: none; }
  }

  /* the floating card: x 8→227.5, y 8→788 */
  .card {
    position: absolute;
    left: 8px;
    top: 8px;
    right: 8.5px;
    bottom: 9px;
    background: var(--w-sb-card);
    border: 1px solid var(--w-sb-rim);
    border-radius: 16px;
    box-shadow: var(--w-sb-shadow);
    overflow: hidden;
    padding-top: 51px;  /* headroom for the window-chrome lights + toggle */
  }

  .group { margin-top: 10px; }
  .group.first { margin-top: 0; }

  /* chevron ink at card-rel x15.5 (13px icon box has ~3px inner padding) */
  .ghead {
    display: flex;
    align-items: center;
    gap: 3px;
    height: 18px;
    padding-left: 12.5px;
    margin-bottom: 9px;
    font-size: 11.5px;
    font-weight: 600;
    color: var(--w-chrome-sub);
  }
  .chev { color: var(--w-chrome-sub); display: grid; place-items: center; }

  /* selection pill: card-rel x 10→209.5 (symmetric 10px margins), h26 */
  .row {
    display: flex;
    align-items: center;
    width: calc(100% - 20px);
    height: 26px;
    margin: 0 0 4px 10px;
    border: 0;
    background: transparent;
    color: var(--w-chrome-text);
    font: inherit;
    font-size: 13px;
    font-weight: 500;
    text-align: left;
    padding: 0 14px 0 20px;    /* text at card-rel x30 (abs 38) */
    border-radius: 9px;
    cursor: pointer;
  }
  .row:hover { background: color-mix(in srgb, var(--w-chrome-text) 6%, transparent); }
  .row.active { background: var(--w-accent); color: var(--w-accent-text); }

  .nm { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .dot {
    margin-left: auto;
    width: 6.5px; height: 6.5px;
    border-radius: 50%;
    background: var(--w-session-dot);
    flex-shrink: 0;
  }
  .spin {
    margin-left: auto;
    margin-right: -3px;
    color: var(--w-chrome-sub);
    flex-shrink: 0;
    display: grid;
    place-items: center;
  }

  /* Same control, same fix as the macOS 27 sidebar: the app used to pad this
     button 10 horizontal / 6 vertical, which left the glyph nearer the bottom
     edge than the left. ContentView.swift pads it 12 on all four sides now, so
     the glyph's centre sits 24 off each of the CARD's edges here. padding: 0
     because a button's UA padding would otherwise leave a 28px box 16px of
     content and push the 20px glyph off centre. */
  .add {
    position: absolute;
    left: 8.5px;
    bottom: 8.5px;
    width: 28px; height: 28px;
    border: 0;
    padding: 0;
    background: transparent;
    color: var(--w-chrome-sub);
    display: grid;
    place-items: center;
    border-radius: 6px;
    cursor: pointer;
  }
  .add:hover { background: color-mix(in srgb, var(--w-chrome-text) 7%, transparent); }

  .grip {
    position: absolute;
    right: -3px;
    top: 51px;
    bottom: 0;
    width: 8px;
    cursor: col-resize;
    z-index: 4;
  }
</style>
