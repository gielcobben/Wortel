# updates.wortel.sh

The Worker in front of the `wortel-updates` R2 bucket. It serves two things and
counts three, and it is the third deployable in this repo alongside `macos/`
and `web/`.

```
worker/index.ts   the whole thing
wrangler.jsonc    bindings, vars, the custom domain
```

## What it serves

Whatever `macos/scripts/release.sh --publish` puts in the bucket:

| Object | Who asks for it |
| --- | --- |
| `appcast.xml` | Sparkle, in every installed copy, on a schedule |
| `Wortel-latest.dmg` | the download button on wortel.sh |
| `Wortel-<version>.zip` | Sparkle, when it has an update to install |
| `Wortel-<version>.dmg` | nobody in particular: each release's DMG, kept |
| `Wortel-latest.zip` | the download button's old link, still kept current |

This Worker only ever reads. Publishing is `release.sh`'s job and goes straight
to R2.

Conditional and range requests are answered by the book: a failed `If-Match` or
`If-Unmodified-Since` is a 412, a failed `If-None-Match` or `If-Modified-Since`
is a 304, and a range the file cannot satisfy is a 416.

## What it counts

Nothing counted the downloads before this existed, which is why there is no
number for the period before it. The classification matters more than the
counting: Sparkle checks in about once per install per day, so raw request
counts are dominated by people who already have the app, and "downloads" read
off the total would be a number about your existing users.

| Request | Event |
| --- | --- |
| `Wortel-latest.dmg` or `.zip` | `app_downloaded` `{ source: web }` |
| `Wortel-<v>.zip` + Sparkle agent | `app_updated` `{ from_version, to_version }` |
| `Wortel-<v>.zip` or `.dmg` + anything else | `app_downloaded` `{ source: direct, version }` |
| `appcast.xml` | `update_checked` `{ app_version }` |

`update_checked` is the useful one. Sparkle puts the running version in its
User-Agent, so it gives you active installs and version distribution across
everyone, including users who turned the app's own reporting off. That is also
why `wortel.sh/privacy` has to disclose it: an opt-out that silently failed to
cover this would not be an opt-out.

Not counted: `HEAD` requests (asking about a file is not taking one), range
requests (a resumed download of something already counted), 304s, and obvious
crawlers. `curl` and `wget` are counted, because someone scripting a download
is a real download.

Nobody is identified. `distinct_id` is a truncated SHA-256 of address, agent
and the date, so it rotates at midnight and cannot be joined across days or
back to a person; no address is stored; every event carries
`$process_person_profile: false` so PostHog builds no profile.

**Counting can never affect serving.** Events are sent inside `ctx.waitUntil()`
after the response is built, in a `try/catch` that swallows. PostHog being
slow, broken or blocked cannot delay a download or fail an update check.

## Test

```sh
npm install
npm test           # the pure logic: classification and Content-Range
npm run typecheck  # tsc; ../scripts/check.sh runs every app
```

Those are the two things that fail silently, so they are the two things with
tests. Everything else about this Worker fails loudly.

```sh
npm run dev        # local, with a bucket you seed yourself
```

Local and not `--remote`, which is worth explaining because the obvious command
does not work here: `wrangler dev --remote` opens its preview session on a
hostname in the zone, and every hostname this Worker cares about is already
claimed (`updates.wortel.sh` by the bucket, `wortel.sh` by the site). It fails
with "Could not create remote preview session". Seed a local bucket instead:

```sh
npx wrangler r2 object put wortel-updates/appcast.xml \
  --file ../macos/releases/appcast.xml --content-type application/xml --local
head -c 3000000 /dev/urandom > /tmp/fake.zip
npx wrangler r2 object put wortel-updates/Wortel-latest.zip \
  --file /tmp/fake.zip --content-type application/zip --local
```

To exercise it against the **real** archives, deploy (below) and test the
workers.dev URL. Comparing it against the live bucket is the check worth
running, because it answers the only question that matters:

```sh
curl -s https://wortel-updates.cobbens.workers.dev/Wortel-latest.zip | shasum -a 256
curl -s https://updates.wortel.sh/Wortel-latest.zip | shasum -a 256   # must match

# ranges, which resumed downloads depend on. Add a unique query string:
# Cloudflare caches 206s and a stale one will hide a fix you just deployed.
for r in 0-99 1000-1499 -500 18421000-; do
  curl -s -r $r -D- -o /dev/null \
    "https://wortel-updates.cobbens.workers.dev/Wortel-latest.zip?n=$RANDOM" \
    | grep -i content-range
done
```

## Deploy

```sh
npm run deploy
npm run tail       # live logs, if something looks wrong
```

### The domain handover, which has already happened

`updates.wortel.sh` was a **custom domain on the R2 bucket** until this Worker
took it over. The two cannot both hold one hostname, which is what gave the
handover an order:

1. Remove the custom domain from the bucket: R2 → wortel-updates → Settings →
   Public access → Custom domains.
2. `npm run deploy`, with `routes` present in `wrangler.jsonc`.
3. Deploy again with `workers_dev` false, so the archives are not also served
   from a second hostname nobody meant to publish.

Between 1 and 2 the hostname serves nothing and returns 530. Sparkle reads a
failed check as no update available and tries again later, so the cost of that
window is a missed check, not a broken install. It lasted about a minute.

It was a handover rather than a swap, because the Worker reads the bucket
through its **R2 binding and not over HTTP**. With it in front, the bucket needs
no public domain at all, and losing that domain closed a door that went around
the counting.

The hostname itself can never move. `SUFeedURL` is baked into `Info.plist`, so
every copy of Wortel already installed will check `updates.wortel.sh` forever. A
different domain would only ever be seen by people who install from that day on,
which is exactly the population `update_checked` is least interested in.

**Rollback** is the reverse: delete the Worker route, put the custom domain back
on the bucket, and the channel is what it was before this directory existed.

## Known tradeoff

A bucket on a custom domain gets Cloudflare's CDN caching for free. A Worker in
front of it does not: every request now reads from R2. At this app's size that
is a few thousand class B operations a month and no egress cost, and it buys
the only download numbers that exist. If download volume ever makes that matter,
the lever is the Cache API around the R2 read, counting either way so a cache
hit is still a download.

## The visitor salt

The unique-visitor id sent to PostHog is a hash of address, user agent, day and
a salt. The salt is a Worker secret named `HASH_SALT`, and it is deliberately
not in `wrangler.jsonc` or anywhere else in the repository: with it public, the
hash could be recomputed from a list of addresses.

Set or rotate it from `updates/` with `npx wrangler secret put HASH_SALT` and
paste a new random value (for example the output of `openssl rand -hex 32`).
Rotating only resets who looks unique, for one day. Without the secret the
Worker serves downloads normally and counts nothing.
