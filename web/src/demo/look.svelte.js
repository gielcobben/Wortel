// Which macOS look the demo window wears.
//
// The app is native, so macOS 27 restyled it: flush sidebar, glass toggle,
// taller toolbar pills, tighter window corners, a new accent. Visitors still on
// macOS 26 should see the window they actually have, so both looks ship and the
// browser decides. WortelApp.svelte is 26, WortelApp27.svelte is 27.
//
// Browsers do not volunteer the macOS version:
//   · Chromium freezes it in the UA string but tells the truth through
//     User-Agent Client Hints — which is async, hence detect() below.
//   · Safari freezes the UA at 10_15_7, but its OWN version tracks the OS from
//     Safari 26 on, so the `Version/<n> Safari` token is a decent proxy.
//   · Firefox says nothing usable at all.
// Anything we can't place gets the NEW look: that is where the platform is
// going, and it is the window a new visitor is most likely to end up with.

const NEW = 27;
const OLD = 26;

let current = $state(NEW);

/** The look to draw: 27 (default) or 26. */
export function look() {
  return current;
}

function fromQuery() {
  try {
    const q = new URLSearchParams(location.search).get('look');
    if (q === '26' || q === '27') return Number(q);
  } catch {
    // no location (SSR) or a malformed query: fall through to sniffing
  }
  return null;
}

function fromUserAgent() {
  const ua = navigator.userAgent || '';
  const isMac = /Mac OS X|Macintosh/.test(ua) || navigator.userAgentData?.platform === 'macOS';
  if (!isMac) return NEW;
  // Safari only: Chromium carries "Safari/537.36" but no "Version/x.y" token.
  const m = ua.match(/Version\/(\d+)[\d._]*\s+Safari/);
  if (m) return Number(m[1]) >= NEW ? NEW : OLD;
  return NEW;
}

/**
 * Sort this visitor into a look. Called from an effect after hydration, never
 * during render: the HTML shipped from the build carries the NEW look, and
 * flipping it during hydration would mean patching markup the server just sent.
 */
export function detect() {
  if (typeof navigator === 'undefined') return;

  const forced = fromQuery();
  if (forced) {
    current = forced;
    return;
  }

  current = fromUserAgent();

  // Chromium: ask for the real macOS version and correct ourselves. Resolves in
  // a microtask, i.e. long before anyone has read a word of the page.
  navigator.userAgentData
    ?.getHighEntropyValues(['platformVersion'])
    .then((hints) => {
      if (navigator.userAgentData.platform !== 'macOS') return;
      const major = parseInt(hints.platformVersion, 10);
      // Big Sur through Sequoia report 11–15; only 26+ are in the new scheme,
      // and a Chromium that reports the frozen 10.15.7 tells us nothing.
      if (Number.isFinite(major) && major >= 11) current = major >= NEW ? NEW : OLD;
    })
    .catch(() => {
      // hints refused (permissions policy, private mode): keep the UA guess
    });
}
