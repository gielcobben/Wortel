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

    /// Servers picked from the running-jobs popover, and a ⌘-clicked address
    /// on this Mac in a terminal (`localhost:3000`), open in the Mac's default
    /// browser instead of a tab. The same choice as the checkmark on a
    /// server's right-click menu. App-wide, because which browser you test in
    /// is a habit, not a property of a session. "+" and ⇧⌘L still make a tab;
    /// asking for one is asking for one.
    var opensServersInDefaultBrowser: Bool {
        didSet { defaults.set(opensServersInDefaultBrowser, forKey: Self.serversKey) }
    }

    /// What a new session's shell is given to run, as written in Settings
    /// (New sessions start with): `claude`, `claude --model opus`, any
    /// command. Empty for a plain terminal, which is how it starts out. Kept
    /// trimmed; what can't be typed is never stored (`NewSessionCommand`).
    var newSessionCommand: String {
        didSet {
            let trimmed = newSessionCommand.trimmingCharacters(in: .whitespaces)
            if trimmed != newSessionCommand {
                newSessionCommand = trimmed
                return
            }
            // Against what was last saved, not `oldValue`: the trim above
            // comes through here a second time, with the untrimmed text as
            // its old value.
            guard newSessionCommand != savedCommand else { return }
            savedCommand = newSessionCommand
            defaults.set(newSessionCommand, forKey: Self.newSessionCommandKey)
            onNewSessionCommandChange?()
        }
    }

    /// Whether new sessions start with a command at all, which is when New
    /// Terminal exists.
    var startsSessionsWithCommand: Bool { NewSessionCommand.line(for: newSessionCommand) != nil }

    /// Set by the menu, so its New Terminal item comes and goes with the
    /// command without being asked about on every keypress.
    @ObservationIgnored var onNewSessionCommandChange: (() -> Void)?
    @ObservationIgnored private var savedCommand = ""

    @ObservationIgnored private let defaults: UserDefaults

    static let commitBoxKey = "git.showsCommitBox"
    /// The key the View menu's checkmark wrote before there was a window, so
    /// the choice made there carries over.
    static let serversKey = "browser.opensServersInDefaultBrowser"
    static let newSessionCommandKey = "sessions.newSessionCommand"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent means on: `bool(forKey:)` would read a key nobody has
        // written as off.
        showsCommitBox = defaults.object(forKey: Self.commitBoxKey) as? Bool ?? true
        opensServersInDefaultBrowser = defaults.bool(forKey: Self.serversKey)
        let command = (defaults.string(forKey: Self.newSessionCommandKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        savedCommand = command
        newSessionCommand = command
    }
}
