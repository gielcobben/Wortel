<script>
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import Loader from '@lucide/svelte/icons/loader';
  import Plus from '@lucide/svelte/icons/plus';
  import { groups } from './data.js';
  // `ongrab` is the pointerdown that starts a width drag; the grip lives here
  // rather than in WortelApp27 so it slides in and out with the panel it sizes.
  let { open = false, force = false, dragging = false, ongrab = undefined } = $props();
</script>

<!-- macOS 27 sidebar. The floating inset CARD of macOS 26 is gone: this is a
     flush panel, x 0→236, running the full height of the window and carrying
     the window's own rounded corners on its left edge. It is the same material
     the inspector uses on the other side, and it still OVERLAYS the content
     pane and slides in and out with translateX.

     The traffic lights and the toggle are WINDOW chrome (owned by WortelApp27,
     layered above), so the panel reserves 52px of headroom for them.
     Measured (light-history / dark-history refs): panel 0→236; group header
     text x 28.5, baseline 72; selection pill x 10→226, h26, r6, text x 28.5. -->
<div class="overlay" class:open class:force class:dragging>
  <div class="panel">
    {#each groups as group, gi}
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
      <Plus size={15.5} strokeWidth={1.5} absoluteStrokeWidth aria-hidden="true" />
    </button>
  </div>

  <!-- the split divider: a mouse-only drag handle in a decorative demo, not a
       real ARIA widget. It starts below the titlebar so the strip a window is
       dragged by stays a drag handle. -->
  <div class="grip" onpointerdown={ongrab} aria-hidden="true"></div>
</div>

<style>
  /* overlay layer: slides with translateX (compositor-friendly) */
  .overlay {
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    /* 236 measured; the grip below can drag it 180…400, like the real split */
    width: var(--sb-shown-w, 236px);
    transform: translateX(-101%);
    transition: transform 0.28s cubic-bezier(0.3, 0.9, 0.3, 1);
    font-family: var(--w-sans);
    color: var(--w-chrome-text);
    z-index: 3;
    pointer-events: none;
  }
  .overlay.open { transform: translateX(0); pointer-events: auto; }
  .overlay.dragging { transition: none; }

  /* auto-hide: the .wortel-app ancestor is a named query container ('wortelapp');
     below 900 of its OWN width, slide the panel back out even when .open —
     UNLESS the user forced it open (.force) to squeeze past the auto-decision */
  @container wortelapp (max-width: 899px) {
    .overlay.open:not(.force) { transform: translateX(-101%); pointer-events: none; }
  }

  /* the panel itself: flush to the window edge, no rim, no shadow. The tiny
     darkening along the bottom is the material's own edge, measured as
     #ebeced → #e6e7e8 over the last ~25px. */
  .panel {
    position: absolute;
    inset: 0;
    background:
      linear-gradient(to top, color-mix(in srgb, #000 3%, var(--w-glass-sidebar)) 0, var(--w-glass-sidebar) 26px);
    -webkit-backdrop-filter: var(--w-glass-filter);
    backdrop-filter: var(--w-glass-filter);
    overflow: hidden;
    padding-top: 56px;  /* headroom for the window-chrome lights + toggle */
  }

  .group { margin-top: 10px; }
  .group.first { margin-top: 0; }

  /* group header: text at x28.5, baseline 72 → a 22px box starting at 56 */
  .ghead {
    display: flex;
    align-items: center;
    gap: 4.5px;
    height: 22px;
    padding-left: 14px;
    margin-bottom: 6px;
    font-size: 13px;
    font-weight: 600;
    color: var(--w-chrome-text);
  }
  .chev { color: var(--w-chrome-sub); display: grid; place-items: center; }

  /* selection pill: x 10→226 (symmetric 10px margins), h26, r6 */
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
    font-weight: 400;
    text-align: left;
    padding: 0 14px 0 18.5px;    /* text at x28.5 */
    border-radius: 6px;
    cursor: pointer;
  }
  .row:hover { background: color-mix(in srgb, var(--w-chrome-text) 6%, transparent); }
  .row.active { background: var(--w-accent); color: var(--w-accent-text); font-weight: 500; }

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

  /* DELIBERATELY NOT THE REFS. The app had this button on asymmetric padding
     (10 horizontal, 6 vertical), which put the glyph nearer the bottom edge
     than the left and read as crammed into the corner. Fixed in the app
     (ContentView.swift: .padding(12) on all four sides), and mirrored here:
     the glyph's centre sits 24 off the left and 24 off the bottom, so it rests
     on the corner's diagonal. The 24px box is the hit area, centred on it.

     Its padding is zeroed because a button's UA padding is 1px 6px, which
     leaves a 24px box only 12px of content: the 15.5px glyph then overflows to
     the content edge rather than centring. Only this button is small enough to
     hit that; the toolbar's are wide enough to swallow it. */
  .add {
    position: absolute;
    left: 11.5px;
    bottom: 11.5px;
    width: 24px; height: 24px;
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
    top: 52px;
    bottom: 0;
    width: 8px;
    cursor: col-resize;
    z-index: 4;
  }
</style>
