# Contributing to Wortel

Thanks for looking. This file says how to build and test Wortel, which rules a
change is held to, and how to send one. It is for people; coding agents read
[`AGENTS.md`](AGENTS.md), which says the same things in more detail, and you
can point yours at it.

## Before you start

- **A bug fix:** go ahead. An issue first helps when the cause is unclear.
- **A feature:** open an issue first. Wortel is small on purpose, and
  [`docs/product.md`](docs/product.md) lists what it will not do and the
  questions a new feature is held to. Most of what looks missing was decided,
  and [`docs/decisions.md`](docs/decisions.md) says why, often with what was
  tried and taken out.
- **A security problem:** not in an issue. See [`SECURITY.md`](SECURITY.md).

## Build and test

The [README](README.md#building-from-source) has the steps: Xcode 26 or
later, XcodeGen, Zig at the pinned version, then `scripts/build-ghostty.sh`,
`xcodegen generate` and an `xcodebuild`. The details are in
[`macos/docs/building.md`](macos/docs/building.md).

**Your Debug build is its own app.** It uses
`~/Library/Application Support/Wortel Dev` and the bundle id
`com.gielcobben.Wortel.dev`, so it never touches the Wortel you have
installed, its sessions or the process that keeps their shells. Run both side
by side as much as you like. A Release build is the real app; give it
`WORTEL_DATA_DIR=/tmp/wortel-try` if you run one.

Before you send a change, run everything that CI runs:

```sh
./scripts/check.sh            # all three: the Swift tests, the Worker's tests, the site's build
./scripts/check.sh macos      # or one of: macos, updates, web
```

Nothing in it signs, deploys or publishes. The Swift tests take about a
minute and a half once Ghostty is built.

**Tests and `project.yml`.** The test target is not hosted by the app: it
compiles the sources it tests straight into the bundle, so it never starts a
terminal to test a pure function. Everything under `macos/Wortel/` is in the
app by itself, but a source you test must also be listed under `WortelTests`'
sources in [`macos/project.yml`](macos/project.yml), and under `WortelCLI` or
`WortelKeeper` if those use it too. A new test file in `macos/WortelTests/` is
picked up by itself. Run `xcodegen generate` after changing `project.yml`.

There is no UI test. For a change you can see, build it, use it, and say in
the pull request what you looked at.

## Rules a change is held to

These are the ones contributors trip on. The rest are in
[`AGENTS.md`](AGENTS.md).

- **Nothing about your work leaves the machine.** Telemetry is a closed list
  of events in `macos/Wortel/Telemetry/TelemetryEvent.swift`, and no event
  takes a `String`. That is what lets the compiler answer "could this leak a
  repository name". A change that adds one will not land.
- **Next to nothing to configure.** No new keys in `wortel.conf`, no user
  config file, and no new row in Settings without a decision recorded in
  `docs/decisions.md` that argues for it. When something seems to need a
  preference, the right answer usually removes the need.
- **No em-dash in anything a person reads:** UI strings, notifications, the
  site, release notes. Use a comma, a colon, brackets or two sentences. Code
  comments and commit messages are exempt. [`docs/voice.md`](docs/voice.md)
  has the rest of how Wortel writes: British spelling, no exclamation marks,
  no "we".
- **Cost tracks the window on screen**, not the size of the repository or the
  number of sessions. A change that does work for something out of sight needs
  a measurement behind it.
- **Nothing destructive without the person choosing it.** Archive rather than
  delete, Trash rather than `rm`.
- **Keep the docs true.** When behaviour changes, change its doc in the same
  commit. A decision gets a line in `docs/decisions.md`.

## Where things are written down

| Where | What |
| --- | --- |
| [`docs/`](docs/) | Product, brand, voice, decisions, incidents, glossary: what holds across the whole repository |
| [`macos/docs/architecture/`](macos/docs/architecture/) | The app, one file per area. [`macos/AGENTS.md`](macos/AGENTS.md) says which to read before touching what |
| [`macos/docs/`](macos/docs/) | Building, debugging, and a design record per feature |
| [`DESIGN.md`](DESIGN.md) | Every colour, size and animation, for anything that is drawn |
| [`AGENTS.md`](AGENTS.md) | The instructions coding agents work from, in this repository and in each app |

## Commits and pull requests

A commit's subject is an area, a colon, and a present-tense statement of the
new behaviour, about 60 characters:

```
Sidebar: a collapsed folder says what it's hiding
Git panel: pull, fast-forward only
```

The body says what was seen, the cause you measured, what changed, and how
you checked it. Keep a pull request to one change; small ones get read
sooner.

## What you can ignore

Some tools here are the maintainer's, and nothing in a contribution depends on
them:

- `macos/scripts/release.sh` and the `release` and `release-note` skills.
  Releasing needs the signing identity, the update key and the Cloudflare
  account. Don't run `release.sh`: it quits Wortel and replaces
  `/Applications/Wortel.app`.
- `npm run deploy` in `web/` and `updates/`.
- The `sync-visuals` skill and anything about the design canvas.

## Licence

Wortel is licensed under the GNU General Public License, version 3 or (at
your option) any later version. See [`LICENSE`](LICENSE). By sending a
contribution you agree that it is under the same licence. There is no
contributor licence agreement.
