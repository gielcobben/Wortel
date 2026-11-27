// What a request to updates.wortel.sh means, and how long it may be cached.
//
// Split out from index.ts because it is the half that is silently wrong. A
// serving bug is loud: the archive does not arrive and Sparkle says so. A
// classification bug just quietly files an existing user's upgrade under new
// downloads, and the number looks plausible forever. Pure functions over two
// strings, so classify.test.ts can pin them without a bucket or a network.

export type Counted = { event: string; props: Record<string, string> };

/// Sparkle's agent is "Wortel/2026.32.3 Sparkle/2.9.0", so the leading token is
/// the version the app is running *now*: on an appcast fetch that is what is
/// installed, and on a zip fetch it is what is being upgraded from.
///
/// A beta names itself by its shown name and version, "Wortel Beta/2026.48.4
/// beta 1 Sparkle/2.9.4", and is counted under its bundle version, 2026.48.4b1:
/// the spelling its zip is named with, so from_version and to_version agree.
export function appVersion(ua: string): string | null {
  const m = ua.match(/^Wortel(?: Beta)?\/(\S+)(?: beta (\d+))?(?= Sparkle\/|$)/)
    ?? ua.match(/^Wortel(?: Beta)?\/(\S+)/);
  if (!m) return null;
  return m[2] ? `${m[1]}b${m[2]}` : m[1];
}

/// Only the unambiguous ones. curl and wget stay in: someone scripting a
/// download is a real download, and excluding them would undercount exactly
/// the audience this app is for.
const CRAWLER = /bot\b|crawler|spider|slurp|facebookexternalhit|headlesschrome|uptime|pingdom|monitoring/i;

export function isCrawler(ua: string): boolean {
  return CRAWLER.test(ua);
}

export function classify(key: string, ua: string): Counted | null {
  if (key === 'appcast.xml') {
    const version = appVersion(ua);
    return { event: 'update_checked', props: version ? { app_version: version } : {} };
  }

  // The zip is Sparkle's and the DMG is the website's; either one, at the
  // same key shape, means the same thing.
  const match = key.match(/^Wortel-(.+)\.(?:zip|dmg)$/);
  if (!match) return null;
  const version = match[1];

  // The website's stable link, which only ever points at the newest build.
  // Anyone fetching it does not have the app.
  if (version === 'latest') return { event: 'app_downloaded', props: { source: 'web' } };

  // Sparkle names itself, and only ever fetches a versioned archive.
  if (/Sparkle/i.test(ua)) {
    const from = appVersion(ua);
    return {
      event: 'app_updated',
      props: from ? { to_version: version, from_version: from } : { to_version: version },
    };
  }

  return { event: 'app_downloaded', props: { source: 'direct', version } };
}

/// A versioned archive is the same bytes forever and is worth caching hard.
/// The feed and the moving "latest" link are not: a release nobody sees for a
/// day because a stale appcast is cached is the failure this domain exists to
/// avoid.
export function cacheControl(key: string): string {
  if (key === 'appcast.xml' || /^Wortel-latest\.(?:zip|dmg)$/.test(key)) {
    return 'public, max-age=300, must-revalidate';
  }
  if (/^Wortel-.+\.(?:zip|dmg)$/.test(key)) {
    return 'public, max-age=31536000, immutable';
  }
  return 'public, max-age=3600';
}
