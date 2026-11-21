# Building, running and testing

Paths and commands are relative to `macos/`; run them from that directory.

The `.xcodeproj` is **gitignored and generated** — `project.yml` (XcodeGen) is
the source of truth. After a fresh checkout or any change to `project.yml`:

```sh
scripts/build-ghostty.sh   # Ghostty from source, once per pinned commit (cached)
xcodegen generate          # regenerate Wortel.xcodeproj from project.yml
xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug build
open "$(xcodebuild -project Wortel.xcodeproj -scheme Wortel -configuration Debug \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/Wortel.app"
```

Resolve `BUILT_PRODUCTS_DIR` rather than globbing DerivedData: there is a
`Wortel-<hash>` folder per checkout path, most of them stale, and `open` opens
every one a glob matches.

- Release build (used by benchmarks): `-configuration Release`.
- **A Debug build is its own app, unless this Mac says otherwise.** Out of a
  fresh clone it uses `~/Library/Application Support/Wortel Dev` and the
  bundle id `com.gielcobben.Wortel.dev`: its own sessions, keeper, `wortel`
  socket and UserDefaults, so it never meets an installed Wortel. Without
  that, a Debug build either brought the installed app forward and quit, or
  adopted its sessions, and a keeper speaking another protocol was replaced,
  which ends every shell in it (`docs/architecture/keeper.md`).

  The maintainer's daily Wortel is a Debug build, from whichever worktree was
  built last, so the opt-in is per Mac rather than per checkout. On that Mac,
  once:

  ```sh
  touch ~/Library/Application\ Support/Wortel/debug-builds-share-this-folder
  ```

  With that file there, a Debug build uses the usual folder
  (`DataDirectory`, read by the app, the keeper and the `wortel` command
  alike) and gets the bundle id `com.gielcobben.Wortel`
  (`scripts/debug-bundle-id.sh`, the app's last build phase, before signing).
  Build again after adding or removing it: a build keeps the bundle id it was
  made with. `WORTEL_DATA_DIR` beats both rules. A Release build is never
  isolated: it is the real app, on the usual folder, unless it is given
  `WORTEL_DATA_DIR`.
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
  UserDefaults (sidebar width, folder roots) are still shared, by bundle ID;
  the `test-copy` skill gives a copy its own.
- **Proper signed release (maintainer only):** `./scripts/release.sh` builds Release, signs it
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
  Its install step quits the running Wortel and replaces
  `/Applications/Wortel.app`, the bundle your installed app's keeper runs
  from, so it is not a contributor's tool. A change to notifications can't be
  seen in a Debug build: say so in the pull request, and it is checked in a
  signed build before it ships.
- **Ghostty is built here, from source** (`scripts/build-ghostty.sh`, into
  `GhosttyKit/Frameworks/`, gitignored). The inputs are tracked in
  `GhosttyKit/`: `ghostty.ref` (the Ghostty commit), `spm.ref` (the
  libghostty-spm commit whose build scripts and patch stack are used),
  `zig.version`, and `Patches/` (Wortel's own, applied after libghostty-spm's;
  `0100` adds the snapshot restore). Two libraries come out of the one patched
  tree: GhosttyKit for the app, libghostty-vt for the keeper and the tests, and
  they must, since the snapshots they pass are only defined within one commit.
  Never link both into one binary: they share C dependencies. A build is
  cached by a hash of its inputs in `~/Library/Caches/sh.wortel.ghostty`,
  shared by every checkout, so a second worktree costs a copy. A full build is
  about five minutes and needs Zig at exactly the version in `zig.version`
  (the script refuses any other) and Xcode's Metal toolchain
  (`xcodebuild -downloadComponent MetalToolchain`). `brew install zig` gives
  whatever Homebrew has today, which is the pinned version only until Zig
  moves on; otherwise take that exact release from
  <https://ziglang.org/download/>, unpack it, and put its folder first on your
  `PATH`. `check.sh` and `release.sh` run it first. To move Ghostty:
  change the two refs, run it, fix what the patches no longer apply to (they
  fail loudly on a changed anchor), and run `check-terminals.sh`.
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
`Resources/wortel.conf` and rebuild — do **not** read user config files, and
do not add a row to the Settings window for them
(`docs/architecture/settings.md` says what a row is for).

## Editing `wortel.conf`

Ghostty config has **no trailing/inline comments**: a `#` after a value is
swallowed into the value. Keep every comment on its own line. Config keys are
those of the Ghostty in `GhosttyKit/ghostty.ref` (https://ghostty.org/docs/config/reference).
