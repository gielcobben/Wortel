# Telemetry

What Wortel reports, why it is opt-out, and the rules for changing any of it.

The user-facing version of this is <https://wortel.sh/privacy>. This is the
design record.

## The shape of it

Eight files in `Wortel/Telemetry/`:

| File | What it is |
| --- | --- |
| `TelemetryEvent.swift` | **The allowlist.** Every event and every property. |
| `TelemetryBridging.swift` | App enums to reportable values, exhaustively. |
| `TelemetrySettings.swift` | Whether it reports at all, and the install id. |
| `TelemetryClient.swift` | The actor that batches and sends. |
| `TelemetryNotice.swift` | The disclosure popover, and the switch in it. |
| `ExitMarker.swift` | How the last run ended, from one empty file. |
| `CrashReport.swift` | A macOS crash report reduced to closed sets and offsets. |
| `HangReport.swift` | The same for a hang report: a force quit of an app that stopped answering. |

Call sites are one line and never conditional:

```swift
Telemetry.capture(.sessionCreated(via: .cli, command: false))
```

Every gate lives inside `capture`, so adding an event somewhere never involves
reasoning about whether reporting is on.

## Why it cannot leak

**No case in `TelemetryEvent` takes a `String`.** Every associated value is an
enum, a `Bool` or a bucket. A caller cannot pass a session name, a branch, a
path or a line of terminal output, because there is no parameter that would
accept one. That is the whole design, and it is worth keeping: it turns "did we
remember to sanitise this" into a question the compiler answers.

Counts are buckets rather than numbers for a softer version of the same reason.
"8+ sessions" answers the product question; "37 sessions" is a number that,
combined with two others, starts to describe one particular person's machine.

`WortelTests/TelemetryTests.swift` is the second line: it walks one of every
case and asserts that every property value is a short lowercase token, and that
every key is in the documented set. A path, a name or anything a person typed
would fail it.

## Why opt-out

Opt-in analytics on a developer tool is answered by a small and unrepresentative
slice, and a number you cannot trust is worse than no number. The bargain that
makes opt-out defensible is everything else here: the event list is readable in
one screen, none of it describes you or your work, the app says so on first
launch without blocking the terminal, and turning it off is one switch.

The disclosure is an `NSPopover` off the ⓘ beside the + in the sidebar's bottom
bar — the same popover on first launch and every time after, so the notice comes
from a control you can point at again rather than appearing out of the middle of
the window. It holds the switch itself; the row in Settings is the same preference
through the same funnel (`Telemetry.setReporting`). It never takes the
keyboard: key goes straight back to the terminal, and typing or clicking away
dismisses it.

It reports nothing at all in four cases:

- the user turned it off (the sidebar's ⓘ, or Settings ▸ Share anonymous usage
  data)
- `DO_NOT_TRACK` is set in the environment
- `#if DEBUG`
- the marketing version is `0.0.0`, `project.yml`'s dev-build placeholder

The last is what keeps a locally built Release out of the numbers without anyone
remembering to check. `scripts/release.sh` stamps a real CalVer, so only a
published build reports.

**`DO_NOT_TRACK` is read in `main.swift` before `InheritedEnvironment.apply()`,**
for the same reason `PtyHost.readEnableFlag()` is: the scrub can drop a variable
whose value points into the temp directory, and a flag read afterwards is one
that silently never fires. An opt-out that fails open is the worst kind.

## How a run ended

`app_launched` carries `previous_exit`: `none` (first launch), `clean`,
`unclean`, `crashed` or `hung`. The mechanism is a file named `running` in the data
folder, created by `main.swift` right after `InstanceLock` and removed in
`applicationWillTerminate`. Finding it at launch means the last run never
quit. Nothing runs while the app is dying: no signal handler, no reporter.

It is armed before the first frame on purpose, which is the one exception to
the launch rule below: a crash during launch is the one most worth seeing, and
the cost is a stat and an empty write, with no network and no client.

`crashed` instead of `unclean` means macOS kept a crash report for that run:
the newest `Wortel-*.ips` in `~/Library/Logs/DiagnosticReports` written after
the marker's date, with our bundle id. It is reduced on the launch after, off
the main thread, to `app_crashed`: signal and exception type (closed sets),
the version (rebuilt from integers), the chip, `site` (the hex offset of the
topmost frame inside Wortel's own binary on the faulting thread) and
`signature` (12 hex chars of SHA-256 over the top five such offsets, for
grouping). Symbols, file names, paths, thread names and system frames are
never read into anything sent; `TelemetryTests` feeds it a report full of them.

To read a site, `release.sh --publish` archives each release's dSYMs in
`releases/dsyms/<version>/` (git-ignored, never uploaded), and:

```sh
./scripts/symbolicate.sh 2026.47.1 1a2b3c          # arm64 by default
```

`hung` instead of `unclean` means there was no crash report but macOS kept a
hang report from that run: Wortel stopped answering at some point, and the run
then did not quit. Usually that is one event, a hang that was force quit, but
the report does not prove the hang is what ended the run (if macOS also keeps
reports of hangs that pass, a short one followed by a power cut reads the
same); `lasted` is what tells the two apart. Spindump writes it
as `Wortel_<date>_<host>.hang`, a text report of every process on the Mac,
ten megabytes and more. Both `~/Library/Logs/DiagnosticReports` and
`/Library/Logs/DiagnosticReports` are looked in (which one macOS uses for a
hang was not seen on the Mac this was written on; the system folder is
readable by admin users and skipped otherwise). Of the newest few matches (at
most three, newest first) only the first 512 KB is read: the header and the
hung process's own section, which spindump puts first. A report whose process
`UID` is not this user's is skipped, since the system folder is shared by
everyone on the Mac. It is reduced to `app_hung`: `activity`, which of
a closed set of kinds of code the main thread's heaviest stack was in
(`swiftui`, `appkit`, `wortel`, `waiting`, `io`, `other`, decided by the
frameworks in it); `site` and `signature` from that stack's frames inside
Wortel's binary, read exactly like a crash's; `hung_version` and `hung_arch`;
`lasted`, the hang's length as a duration bucket (`unknown` when the report
does not say); and `memory`, the app's footprint then as one of four ranges
(where it ended up, when it moved while it was sampled). The host name, paths, symbols and other
processes are never read into anything sent; `TelemetryTests` feeds it a
report carrying them. The first hang anyone sent (2026-11-23, by mail) read
`swiftui`, `7ff4`, `<24h`, `8gb+` this way.

A crash of the keeper is not an app crash; it shows as `keeper_lost`.

Archives are worktree sessions only, so `session_archived` and
`session_unarchived` carry nothing, and so does `reminder_set`: when a
reminder is for says something about the person's day. `agent_started` is a run the person
started: the agents alive at launch and the resumes Wortel types itself are
`agents_resumed` instead.

## Launch cost

Nothing runs at launch. The client is not constructed until the first event, and
the first event is dispatched a runloop turn after the window is up (the same
trick as `warmRemainingSurfaces`). Cold launch is a benchmarked number:

```sh
xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Release build
./bench/measure.sh
```

If a change here moves it, the change is wrong.

`measure.sh` runs a throwaway copy of the build on a data folder of its own and
stops only that copy, so it can be run from a session inside Wortel.

## Adding an event

1. Add a case to `TelemetryEvent`, with enum or bucket parameters only.
2. Add its name and properties to the two switches.
3. Add the new closed-set values to `TelemetryTests.buildEveryEvent`, and any
   new key to `testPropertyKeysAreTheDocumentedSet`.
4. **Update `web/src/content/legal/privacy.md` in the same change.** The page
   promises the list there is the whole list.

If a question needs a value that is not a small closed set, the answer is a
bucket or no event.

## Before this ships

The first release carrying this has to do three things, or the privacy page
becomes untrue the day it lands:

- `web/src/content/legal/privacy.md` currently says the app contains no
  analytics and sends nothing. **That is true today and stops being true on the
  release that ships this.** Rewrite that section in the same release.
- Say so in the changelog entry, plainly, near the top.
- Bump the `updated` date on the privacy page.

The site is redeployed by `release.sh --publish`, so the page and the build go
out together if the edit is committed before the release runs.
