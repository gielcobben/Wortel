import Foundation
import Observation

/// The few things that differ per person, and so have a row in the Settings
/// window (⌘,).
///
/// **The rule for what may live here.** Something decided once that truly
/// differs from one person to the next. What is flipped while working stays in
/// the View menu (Sort Unread First, which side the column is on). What the
/// app can know for itself gets no switch at all. Fonts, colours, keys and
/// scrollback are still decided once, in `wortel.conf`, and that file still
/// cannot grow keys. A new row here needs the same argument the first ones
/// had (`docs/decisions.md`, 2026-11-18).
///
/// Only what is plain `UserDefaults` is held here. Automatic updates are
/// Sparkle's own preference (`Updater.updatesAutomatically`) and usage data
/// is `TelemetrySettings`: each has one owner already, and a second copy
/// would be a second thing to keep in step.
///
/// Foundation only, so it can be tested without the app.
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    /// The commit message box under the changes in Source Control: the
    /// message, the button that drafts one, and Commit. Off for someone whose
    /// agent does the committing, who then reads the pane as a list of what
    /// changed. On unless turned off.
    var showsCommitBox: Bool {
        didSet { defaults.set(showsCommitBox, forKey: Self.commitBoxKey) }
    }

    /// Servers picked from the running-jobs popover open in the Mac's default
    /// browser instead of a tab. The same choice as the checkmark on a
    /// server's right-click menu. App-wide, because which browser you test in
    /// is a habit, not a property of a session. "+" and ⇧⌘L still make a tab;
    /// asking for one is asking for one.
    var opensServersInDefaultBrowser: Bool {
        didSet { defaults.set(opensServersInDefaultBrowser, forKey: Self.serversKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    static let commitBoxKey = "git.showsCommitBox"
    /// The key the View menu's checkmark wrote before there was a window, so
    /// the choice made there carries over.
    static let serversKey = "browser.opensServersInDefaultBrowser"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent means on: `bool(forKey:)` would read a key nobody has
        // written as off.
        showsCommitBox = defaults.object(forKey: Self.commitBoxKey) as? Bool ?? true
        opensServersInDefaultBrowser = defaults.bool(forKey: Self.serversKey)
    }
}
