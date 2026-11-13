# Building, running and testing

Paths and commands are relative to `macos/`; run them from that directory.

The `.xcodeproj` is **gitignored and generated** — `project.yml` (XcodeGen) is
the source of truth. After a fresh checkout or any change to `project.yml`:

```sh
xcodegen generate          # regenerate Wortel.xcodeproj from project.yml
xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Wortel-*/Build/Products/Debug/Wortel.app
```

- Release build (used by benchmarks): `-configuration Release`.
- **One Wortel per data folder.** A second copy launched while one is running
  (any build, any worktree) brings the running one forward and exits
  (`InstanceLock`), because two copies sharing `~/Library/Application
  Support/Wortel` each write their stale view of it back on quit: that is how
  agents lost their light/dark subscription. To try a build *beside* the one
  you're working in, give it a folder of its own; it gets its own sessions,
  keeper and `wortel` socket and never touches the real ones:

  ```sh
  open -n --env WORTEL_DATA_DIR=/tmp/wortel-try path/to/Wortel.app
  ```

  Keep the path short (sockets live in it; 104-byte limit). Its keeper keeps
  its shells after it quits, like the real one; stop it by pid when done.
  UserDefaults (sidebar width, folder roots) are still shared, by bundle ID.
- **Proper signed release:** `./scripts/release.sh` builds Release, signs it
  with your Developer ID (auto-detected), installs to `/Applications`, and
  launches it. This is required for anything that needs a real, registered app
  rather than an ad-hoc Debug build — notably **macOS notifications**: an
  ad-hoc-signed build in DerivedData is *not* registered with the notification
  daemon (`usernoted`), so `UNUserNotificationCenter` reports `granted` and
  accepts posts with no error, but nothing is ever displayed. `--notarize` adds
  hardened runtime + notarization + a `.dmg` for distributing to other Macs
  (needs a `notarytool` keychain profile — see the script footer).
  `--publish` refuses uncommitted changes and runs `WortelTests` and the
  `updates/` tests before it builds (`--allow-dirty`, `--no-tests` to
  override); it uploads with the wrangler pinned in `updates/`.
- **Package versions are pinned in `macos/Package.resolved`** (tracked; the
  project's own copy is generated and ignored). `release.sh` copies it into the
  generated project and builds with `-onlyUsePackageVersionsFromResolvedFile`,
  so a release never picks up whatever is newest that day. Local Debug builds
  are not forced onto it. To take a newer version of a package: change
  `project.yml` if needed (the two branch-only grammars are pinned by
  `revision:`), run `xcodegen generate`, resolve in Xcode or with
  `-resolvePackageDependencies`, check the build and the diff highlighting by
  hand, then copy `Wortel.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  back over `macos/Package.resolved` and commit it.
- There is no linter config. For the app itself, "verify" still means building
  and running it — the UI has no test coverage.
- The one test target is `WortelTests`, covering the git panel's logic and the
  persisted-session format:

  ```sh
  xcodebuild -project Wortel.xcodeproj -scheme WortelTests test
  ```

  It is **not** hosted by the app — hosting would launch libghostty, Metal and a
  real shell to test pure functions. Instead `project.yml` lists the individual
  sources it exercises (`Wortel/Git/*`, plus `SessionStore.swift` and
  `SessionName.swift`) and compiles them straight into the bundle, so adding a
  file needs it listed in both targets. The bar for a source being here is that
  it's testable *without* the app shell — which is also a reason to keep
  migration decisions out of types that would drag AppKit in, and why the
  Folder/Leaf name split lives in `SessionName` rather than on `Session`.
  Most of these tests use **git itself as the oracle**: they build a repo with
  `GitFixture` and compare against
  `git log --topo-order` / `git log --graph`, because reproducing those cheaply
  is the whole point of the code under test. See `WortelTests/GitFixture.swift`
  on why its branches are long-lived — a tamer fixture passes against known bugs.
  `PersistedSessionTests` pins the other testable-in-isolation thing: the
  decoder's `decodeIfPresent` defaults, which *are* the sessions.json migrations
  and otherwise only ever run on the one launch that reads an old file.
  `SessionNameTests` pins the Folder/Leaf split for the same reason — a session's
  folder is just the part of its name before the last slash, so a wrong split
  doesn't throw, it silently moves the session.
- **`./scripts/verify-running-jobs.py`** checks the running-processes feature
  against a real machine: real servers in a real `/usr/bin/login` pty session,
  in all 44 shapes agents and people start them in, scanned by the shipping
  code. Fixtures cannot catch a shape nobody thought of, and that is what every
  bug in that feature has been. Run it before releasing a change to
  `Wortel/Processes/`.
- **`./scripts/try-git.sh`** builds a throwaway repo with every git situation
  the panel handles (branches busy in other folders, agent worktrees with and
  without changes, something running in one, ahead and behind, a branch in
  the way of a local edit) and opens a session in it, with a checklist to
  look over before a release touching `Wortel/Git/`. `--clean` removes it.
- Performance checks live in `bench/`: `./bench/measure.sh` (cold-launch time +
  memory, Release only), `./bench/gen.sh` (throughput fixtures). Most latency /
  render checks are manual side-by-side vs Ghostty.app — see `bench/BENCHMARKS.md`.

To change terminal behavior, fonts, theme, or keybinds, edit
`Resources/wortel.conf` and rebuild — do **not** add a settings UI or read user
config files.

## Editing `wortel.conf`

Ghostty config has **no trailing/inline comments**: a `#` after a value is
swallowed into the value. Keep every comment on its own line. Config keys are
pinned to Ghostty v1.3.1 (https://ghostty.org/docs/config/reference).
