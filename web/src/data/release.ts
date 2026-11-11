// The newest release, read from the Sparkle feed at build time.
//
// The feed lives at updates.wortel.sh; the newest signed zip is always mirrored
// to Wortel-latest.zip, so a single stable download URL works forever. The
// version shown beside the button is read from that same feed when the site is
// built, so it only refreshes on redeploy. If the feed is unreachable the line
// is dropped rather than failing the build or showing a stale number.
import { SITE } from './site';

export type Release = { version: string; min?: string; size: string | null; date: string | null };

let cached: Promise<Release | null> | null = null;

export function latestRelease(): Promise<Release | null> {
  cached ??= (async () => {
    try {
      const res = await fetch(SITE.appcast);
      if (!res.ok) return null;
      const xml = await res.text();
      const version = xml.match(/<sparkle:shortVersionString>([^<]+)</)?.[1];
      if (!version) return null;
      const min = xml.match(/<sparkle:minimumSystemVersion>([^<]+)</)?.[1]?.replace(/\.0$/, '');
      const bytes = Number(xml.match(/<enclosure[^>]*\slength="(\d+)"/)?.[1]);
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
