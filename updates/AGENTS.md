# updates/: updates.wortel.sh

For coding agents working on the updates Worker. The repo-wide rules in the
root `AGENTS.md` still apply. Paths and commands here are relative to
`updates/`. `README.md` is the full record; read it before changing anything.

The Worker in front of the `wortel-updates` R2 bucket. It serves the appcast,
the signed zips (Sparkle's) and the DMGs (the website's), and it is the only
place downloads are counted. Every
installed copy of Wortel asks it for updates, so it changes almost never, and
carefully.

## Commands

```sh
npm install
npm test             # the pure logic: classification, conditionals, ranges
npm run typecheck
npm run dev          # local, with a bucket you seed yourself (see README.md)
```

`npm run deploy` publishes to updates.wortel.sh. Only when asked.

## Rules

- **Counting can never affect serving.** Events go out inside
  `ctx.waitUntil()`, after the response is built, in a `try/catch` that
  swallows. Nothing about analytics may delay a download or fail an update
  check.
- **It only reads.** Publishing is `macos/scripts/release.sh`, straight to R2.
- **Conditional and range requests are answered by the book** (304, 412, 416,
  206). Resumed downloads depend on it. These fail silently, so they are the
  parts with tests: add a test with any change to them.
- **`wrangler dev --remote` does not work here**, and `README.md` says why.
  Seed a local bucket.
- **It stays separate from `web/`.** The update channel must not be able to go
  down with a bad site build.
- What is counted is disclosed on wortel.sh/privacy. A change to what is
  counted changes that page in the same commit.
