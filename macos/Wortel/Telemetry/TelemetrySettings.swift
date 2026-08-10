import Foundation

/// Whether Wortel reports anything, and the one identifier it has.
///
/// **Opt-out, disclosed once, off in one click.** On by default, because the
/// alternative in practice is no data: opt-in analytics on a developer tool is
/// answered by a small and unrepresentative slice, and a number you cannot
/// trust is worse than none. The bargain that makes that defensible is the rest
/// of this directory: the events are a closed list you can read in one screen
/// (`TelemetryEvent`), there is nothing in them that describes you or your work,
/// the app says so on first launch without blocking the terminal, and turning it
/// off is one menu item with no settings window to find.
///
/// **Four ways it stays quiet**, and the last two matter most to whoever is
/// reading this in the repository:
///
/// - the user turned it off
/// - `DO_NOT_TRACK` is set (see `noticeDoNotTrack`), which is the convention
///   command line tools already honour and this is one
/// - `#if DEBUG`, so a build from Xcode never reports
/// - the marketing version is `0.0.0`, which is `project.yml`'s dev-build
///   placeholder. Release builds are stamped with a real CalVer by
///   `scripts/release.sh`, so this is what keeps a locally built Release out of
///   the numbers without anyone remembering to check.
enum TelemetrySettings {

    // ---- the switch -------------------------------------------------------

    private static let enabledKey = "TelemetryEnabled"
    private static let installIDKey = "TelemetryInstallID"
    private static let noticeShownKey = "TelemetryNoticeShown"

    /// Whether the user has said no. Absent means they have not said anything,
    /// which is the opt-out default.
    static var isEnabledByUser: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The one question the rest of the app asks.
    static var isEnabled: Bool {
        #if DEBUG
        return false
        #else
        guard !doNotTrack else { return false }
        guard !isDevelopmentBuild else { return false }
        return isEnabledByUser
        #endif
    }

    /// Whether a switch over this preference would mean anything. It cannot
    /// change while the app runs — all three conditions are fixed by the build
    /// and the environment — which is why the menu item is *added* on this
    /// rather than hidden by `validateMenuItem`: `isHidden` set during
    /// validation is not reliably applied, and the first thing that showed was
    /// a live-looking, permanently unchecked switch on a dev build.
    static var isSwitchable: Bool {
        #if DEBUG
        return false
        #else
        return !isDevelopmentBuild && !doNotTrack
        #endif
    }

    /// True when this build carries `project.yml`'s placeholder version, i.e.
    /// it was built by hand rather than by `scripts/release.sh --publish`.
    static var isDevelopmentBuild: Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version == nil || version == "0.0.0"
    }

    // ---- DO_NOT_TRACK -----------------------------------------------------

    /// Captured before `InheritedEnvironment.apply()` runs, for exactly the
    /// reason `PtyHost.readEnableFlag()` is: the scrub can drop a variable
    /// whose value points into the temp directory, and a flag read afterwards
    /// is a flag that silently never fires. `main.swift` calls this first.
    ///
    /// Any value except the ones that plainly mean "no" counts as set, matching
    /// how consolidated.dev describes the convention and how other tools read
    /// it: someone who exports `DO_NOT_TRACK` at all has expressed a preference.
    private(set) static var doNotTrack = false

    static func readDoNotTrack(from environment: [String: String] = ProcessInfo.processInfo.environment) {
        doNotTrack = interpretDoNotTrack(environment["DO_NOT_TRACK"])
    }

    /// Split out so it can be tested without touching the test runner's own
    /// environment. `nil` and the explicit falsehoods are the only "off".
    static func interpretDoNotTrack(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        if value.isEmpty { return false }
        return !["0", "false", "no", "off"].contains(value)
    }

    // ---- identity ---------------------------------------------------------

    /// A random UUID, made once and kept. It is not derived from anything: not
    /// the hardware id, not the serial, not the user name, so it says nothing
    /// about the machine and cannot be recomputed by anyone who has one.
    ///
    /// In `UserDefaults` and deliberately **not** the Keychain, which is the
    /// tempting place to put an install id. A Keychain item survives dragging
    /// the app to the Trash, so an uninstall would not be an uninstall, and
    /// reading one at launch can prompt. Losing the id when preferences are
    /// cleared is the correct behaviour, not a bug to fix.
    static var installID: String {
        if let existing = UserDefaults.standard.string(forKey: installIDKey) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: installIDKey)
        return fresh
    }

    // ---- the first-run notice ---------------------------------------------

    /// Whether the one-time notice still has to be shown. False forever after.
    static var needsNotice: Bool {
        guard isEnabled else { return false }
        return !UserDefaults.standard.bool(forKey: noticeShownKey)
    }

    static func markNoticeShown() {
        UserDefaults.standard.set(true, forKey: noticeShownKey)
    }
}
