import AppKit
import Observation
import UserNotifications

/// What macOS lets Wortel do, as far as Wortel can tell, and the way to change
/// it. The model behind the sidebar's permissions icon and its popover.
///
/// And one thing that is not a permission but is missing in the same way on
/// a new Mac: git, which comes with Apple's command line tools
/// (`DeveloperTools`). It is listed only while it is missing.
///
/// And an agent, which Wortel is made to work beside and does not come with.
/// That question is only asked until it has been answered yes once
/// (`agentSeen`): a Mac that has an agent has one for good as far as this is
/// concerned, and nothing is looked for again.
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
    /// Whether git can run: `granted` or `denied`, never asked of macOS.
    private(set) var developerTools: State = .unknown
    /// Whether this Mac has a coding agent: `granted` once one was found or
    /// started, `denied` while none has been.
    private(set) var agent: State = .unknown

    /// Type this agent's installer into a terminal, set by the app delegate,
    /// which is who has the sessions.
    @ObservationIgnored var installAgent: ((AgentInstall.Agent) -> Void)?

    /// The sidebar icon is out although nothing needs attention, because its
    /// popover was opened from the Wortel menu and has to hang off something.
    var revealed = false

    /// Something Wortel works worse without. Full Disk Access is optional and
    /// never counts: missing it is how most terminals are run.
    var needsAttention: Bool {
        notifications == .denied || notifications == .notAsked || developerTools == .denied
            || (agent == .denied && !agentNoticeSeen)
    }

    /// Something a new Mac lacks that is not a permission, which gets the
    /// popover a section of its own.
    var needsSetup: Bool { developerTools == .denied || agent == .denied }

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        }
    }

    func refresh() {
        fullDiskAccess = Self.readFullDiskAccess()
        developerTools = DeveloperTools.current.canRun ? .granted : .denied
        // The cheap half of the agent question, for the moment after an
        // installer finished: a few folders, never a shell.
        if agent == .denied, !AgentDiscovery.scan(names: AgentCommands.offered).isEmpty { noteAgent() }
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

    // ---- an agent ---------------------------------------------------------------

    private static let agentSeenKey = "setup.agentSeen"
    private static let agentNoticeSeenKey = "setup.agentNoticeSeen"

    /// An agent was found on this Mac or started in a session, once. Kept, so
    /// the question costs nothing from then on: no folder is read and no
    /// shell is asked at any later launch.
    private var agentSeen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.agentSeenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.agentSeenKey) }
    }

    /// The popover was opened while it said no agent was found. After that
    /// the missing agent stops raising the icon: someone who uses Wortel as
    /// a plain terminal has been told once, and a dot that never goes out
    /// is furniture. The row stays in the popover (Wortel ▸ Permissions…).
    private(set) var agentNoticeSeen: Bool {
        get {
            access(keyPath: \.agentNoticeSeen)
            return UserDefaults.standard.bool(forKey: Self.agentNoticeSeenKey)
        }
        set {
            withMutation(keyPath: \.agentNoticeSeen) {
                UserDefaults.standard.set(newValue, forKey: Self.agentNoticeSeenKey)
            }
        }
    }

    /// The popover is on screen. Marked when it closes, not now, or the icon
    /// it hangs off would go while it is being read.
    func popoverClosed() {
        if agent == .denied, !agentNoticeSeen { agentNoticeSeen = true }
    }

    /// An agent is here: found on disk, answered for by the shell, or
    /// started in a session (`SessionManager`, for any agent, known or not).
    func noteAgent() {
        if !agentSeen { agentSeen = true }
        if agent != .granted { agent = .granted }
    }

    /// Look for an agent, at launch and when the popover opens, until one
    /// has been seen. The usual folders first; only when those hold none is
    /// the person's login shell asked (`AgentDiscovery`), which also knows
    /// about an alias, a function and a version manager's folder. Off the
    /// main thread, and never again once the answer was yes.
    func lookForAgent() {
        guard !agentSeen else {
            if agent != .granted { agent = .granted }
            return
        }
        guard AgentDiscovery.scan(names: AgentCommands.offered).isEmpty else {
            noteAgent()
            return
        }
        Task { @MainActor in
            if await AgentDiscovery.find().isEmpty {
                if !self.agentSeen, self.agent != .denied { self.agent = .denied }
            } else {
                self.noteAgent()
            }
        }
    }

    // ---- developer tools ----------------------------------------------------

    /// Apple's installer. It runs for minutes in an app of its own, so the
    /// answer is read again when Wortel is next in front, as the others are.
    func fixDeveloperTools() {
        DeveloperTools.install()
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
