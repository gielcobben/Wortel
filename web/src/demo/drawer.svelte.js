// A "drawer" is a collapsible edge panel — the left sidebar OR the right
// inspector. Both share ONE state model and ONE set of open/close/override
// rules so they behave 1:1:
//
//   wanted — the wide-tier intent (is it open when there's room?)
//   force  — the narrow-tier override ("keep it open even though it doesn't
//            fit — squeeze the window further")
//
// Width tiers are decided in pure CSS: container queries stamp a `--fits-<name>`
// flag onto a hidden probe element. JS reads that flag synchronously (via
// getComputedStyle — which, unlike a transition, is not frozen in background
// tabs) so a toggle always does the right thing across the auto-collapse:
//
//   • roomy  → the toggle flips the wide-tier intent (wanted)
//   • cramped→ the toggle flips the narrow-tier override (force)
//
// Effective visibility is `wanted && (fits || force)`; the components render it
// with `.open:not(.force-*)` / `.git-closed` selectors under the same
// @container, so the rendering matches the rules with no ResizeObserver.
export function createDrawer(initialOpen, fitsVar, getProbe) {
  let wanted = $state(initialOpen);
  let force = $state(false);

  function fits() {
    const el = getProbe();
    if (!el) return true;
    return getComputedStyle(el).getPropertyValue(fitsVar).trim() !== '0';
  }

  function shownNow() {
    return wanted && (fits() || force);
  }

  function set(show) {
    const roomy = fits();
    if (show) {
      wanted = true;
      force = !roomy; // force it in only when it wouldn't otherwise fit
    } else if (roomy) {
      wanted = false; // roomy: drop the wide intent
    } else {
      force = false;  // cramped: just drop the override → back to auto-collapsed
    }
  }

  return {
    get wanted() { return wanted; },
    get force() { return force; },
    fits,
    shownNow,
    open: () => set(true),
    close: () => set(false),
    toggle: () => set(!shownNow()),
  };
}
