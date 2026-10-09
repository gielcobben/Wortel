import AppKit
import Observation
import UserNotifications

/// What macOS lets Wortel do, as far as Wortel can tell, and the way to change
/// it. The model behind the sidebar's permissions icon and its popover.
///
/// **Two permissions, not a checklist of everything.** A terminal runs other
/// people's programs, and macOS charges what they do to the terminal: a
/// script that wants the camera asks as "Wortel". Those prompts are the
/// program's to raise, at the moment it needs them, and listing them here
/// ahead of time would ask for things nobody has decided to use yet. What is
/// listed is what Wortel itself depends on (notifications) and the one grant
/// that only ever happens by hand, because no prompt for it exists (Full Disk
/// Access).
///
/// **Asked, never cached across a trip to System Settings.** Both are read
/// again whenever Wortel becomes the active app, which is exactly the moment
/// after someone flips a switch there and comes back.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    enum State: Equatable {
        /// Not read yet, or unreadable: shown as neither granted nor missing.
        case unknown
        /// Never asked. Notifications only: Full Disk Access is never asked.
        case notAsked
        case granted
        case denied
    }

    private(set) var notifications: State = .unknown
    private(set) var fullDiskAccess: State = .unknown

    /// The sidebar icon is out although nothing needs attention, because its
    /// popover was opened from the Wortel menu and has to hang off something.
    var revealed = false

    /// Something Wortel works worse without. Full Disk Access is optional and
    /// never counts: missing it is how most terminals are run.
    var needsAttention: Bool {
        notifications == .denied || notifications == .notAsked
    }

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        }
    }

    func refresh() {
        fullDiskAccess = Self.readFullDiskAccess()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: State
            switch settings.authorizationStatus {
            case .notDetermined: state = .notAsked
            case .denied: state = .denied
            // Allowed, but with every way of showing one turned off is the
            // same as not allowed, from where the person is sitting.
            case .authorized, .provisional, .ephemeral:
                state = settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled
                    ? .granted : .denied
            @unknown default: state = .unknown
            }
            DispatchQueue.main.async { Permissions.shared.notifications = state }
        }
    }

    // ---- notifications ------------------------------------------------------

    /// The system prompt while it can still be shown; System Settings once it
    /// has been answered, because macOS asks only once.
    func fixNotifications() {
        if notifications == .notAsked {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                DispatchQueue.main.async { Permissions.shared.refresh() }
            }
        } else {
            openSettings(Self.notificationSettings)
        }
    }

    /// Wortel's own page under Notifications, rather than the list of every app.
    private static var notificationSettings: URL {
        let id = Bundle.main.bundleIdentifier ?? "com.gielcobben.Wortel"
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
    }

    // ---- Full Disk Access -----------------------------------------------------

    /// There is no prompt for this and no API to ask: the list in System
    /// Settings is the only way in, and Wortel is added to it with the + there.
    func fixFullDiskAccess() {
        openSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// Whether a file only Full Disk Access can open does open. Opening one
    /// never raises a prompt (Full Disk Access has none), so this is safe to
    /// ask at any time. The first of these that exists decides; none existing
    /// is `unknown` rather than a guess.
    private static func readFullDiskAccess() -> State {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probes = [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "\(home)/Library/Mail",
        ]
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { return .denied }
        }
        return .unknown
    }

    private func openSettings(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
