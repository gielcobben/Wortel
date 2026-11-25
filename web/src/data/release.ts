// The newest release, read from the Sparkle feed at build time.
//
// The feed lives at updates.wortel.sh; the newest notarized DMG is always
// mirrored to Wortel-latest.dmg, so a single stable download URL works forever.
// The version shown beside the button is read from that same feed when the site
// is built, so it only refreshes on redeploy. If the feed is unreachable the
// line is dropped rather than failing the build or showing a stale number.
//
// The size is the DMG's, from a HEAD of the download itself (not counted by
// the updates Worker): the feed's enclosure is Sparkle's zip, a different file
// of a different size. No DMG there, no size shown.
import { SITE } from './site';

export type Release = { version: string; min?: string; size: string | null; date: string | null };

let cached: Promise<Release | null> | null = null;

async function downloadSize(): Promise<number> {
  try {
    const res = await fetch(SITE.download, { method: 'HEAD' });
    return res.ok ? Number(res.headers.get('content-length')) : NaN;
  } catch {
    return NaN;
  }
}

export function latestRelease(): Promise<Release | null> {
  cached ??= (async () => {
    try {
      const res = await fetch(SITE.appcast);
      if (!res.ok) return null;
      const xml = await res.text();
      const version = xml.match(/<sparkle:shortVersionString>([^<]+)</)?.[1];
      if (!version) return null;
      const min = xml.match(/<sparkle:minimumSystemVersion>([^<]+)</)?.[1]?.replace(/\.0$/, '');
      const bytes = await downloadSize();
      const date = xml.match(/<pubDate>([^<]+)</)?.[1];
      return {
        version,
        min,
        size: Number.isFinite(bytes) && bytes > 0 ? `${Math.round(bytes / 1e6)} MB` : null,
        date: date ? new Date(date).toISOString().slice(0, 10) : null,
      };
    } catch {
      return null;
    }
  })();
  return cached;
}
