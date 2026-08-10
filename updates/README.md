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
| `Wortel-latest.zip` | the download button on wortel.sh |
| `Wortel-<version>.zip` | Sparkle, when it has an update to install |

This Worker only ever reads. Publishing is `release.sh`'s job and goes straight
to R2.

## What it counts

Nothing counted the downloads before this existed, which is why there is no
number for the period before it. The classification matters more than the
counting: Sparkle checks in about once per install per day, so raw request
counts are dominated by people who already have the app, and "downloads" read
off the total would be a number about your existing users.

| Request | Event |
| --- | --- |
| `Wortel-latest.zip` | `app_downloaded` `{ source: web }` |
| `Wortel-<v>.zip` + Sparkle agent | `app_updated` `{ from_version, to_version }` |
| `Wortel-<v>.zip` + anything else | `app_downloaded` `{ source: direct, version }` |
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

### Taking over the domain

`updates.wortel.sh` is still a **custom domain on the R2 bucket**, and a bucket
custom domain and a Worker route cannot both hold one hostname. So the Worker
currently lives on `wortel-updates.cobbens.workers.dev`, deployed and verified,
serving the real archives out of the real bucket and taking no real traffic.
`routes` is commented out in `wrangler.jsonc` to keep it that way.

This is a handover rather than a swap, because the Worker reads the bucket
through its **R2 binding and not over HTTP**. Once it is in front, the bucket
does not need a public domain at all, and losing it closes a door that
currently goes around the counting.

The hostname itself cannot move. `SUFeedURL` is baked into `Info.plist`, so
every copy of Wortel already installed will check `updates.wortel.sh` forever.
A different domain would only ever see people who install from that day on.

1. Point a scratch build's `SUFeedURL` at the workers.dev URL and run a real
   Sparkle update end to end. Everything else here can be checked with curl,
   and has been; this is the only step that exercises what the Worker is for.
2. Remove the custom domain from the bucket: R2 → wortel-updates → Settings →
   Public access → Custom domains.
3. Uncomment `routes` in `wrangler.jsonc` and `npm run deploy`.
4. Set `workers_dev` to `false` and deploy again, so the archives are not also
   served from a second hostname nobody meant to publish.

Between 2 and 3 the hostname resolves to nothing. Sparkle treats a failed check
as no update available and tries again later, so the cost of that window is a
missed check, not a broken install.

**Rollback** is the same in reverse: delete the Worker route, put the custom
domain back on the bucket, and the channel is exactly what it was before this
directory existed.

## Known tradeoff

A bucket on a custom domain gets Cloudflare's CDN caching for free. A Worker in
front of it does not: every request now reads from R2. At this app's size that
is a few thousand class B operations a month and no egress cost, and it buys
the only download numbers that exist. If download volume ever makes that matter,
the lever is the Cache API around the R2 read, counting either way so a cache
hit is still a download.
