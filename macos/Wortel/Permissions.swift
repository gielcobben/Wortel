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

    /// Apple's tools are on the disk and macOS is pointed at a developer
    /// directory that is gone (`DeveloperTools.Git.misdirected`): nothing
    /// to install, one command to run.
    private(set) var gitNeedsReset = false

    /// Put a command on a prompt for the person to read and run, set by the
    /// app delegate, which is who has the sessions. An agent's installer
    /// (`AgentInstall`), and the reset above. Wortel runs neither.
    @ObservationIgnored var offerCommand: ((String) -> Void)?

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
        // Only what changed is written: each of these is read by a view (the
        // git panes read `developerTools`), and this runs every time Wortel
        // comes to the front.
        let disk = Self.readFullDiskAccess()
        if fullDiskAccess != disk { fullDiskAccess = disk }
        let git = DeveloperTools.current
        let tools: State = git.canRun ? .granted : .denied
        if developerTools != tools { developerTools = tools }
        if gitNeedsReset != (git == .misdirected) { gitNeedsReset = git == .misdirected }
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
            DispatchQueue.main.async {
                if Permissions.shared.notifications != state { Permissions.shared.notifications = state }
            }
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
    /// reporting what it is doing in a session (`SessionManager`). A marker
    /// in a session is not one: it only has the shell asked again.
    func noteAgent() {
        if !agentSeen { agentSeen = true }
        if agent != .granted { agent = .granted }
    }

    /// Look for an agent, at launch and when the popover opens, until one
    /// has been seen. The usual folders first; only when those hold none is
    /// the person's login shell asked (`AgentDiscovery`), which also knows
    /// about an alias, a function and a version manager's folder. Off the
    /// main thread, and never again once the answer was yes.
    ///
    /// **Only the shell's own "none" is a no.** When it gave no answer (too
    /// slow, a shell Wortel can't ask, another question still out) the
    /// folders are all that was read, and they miss an agent under nvm or
    /// mise and every alias: saying "no agent" on that would put a dot and
    /// an Install row in front of someone who has had one for a year. So
    /// that stays unknown, shown as nothing, and is asked again next time.
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
            guard let answer = await AgentDiscovery.ask() else { return }
            if !answer.isEmpty {
                self.noteAgent()
            } else if !self.agentSeen, self.agent != .denied {
                self.agent = .denied
            }
        }
    }

    // ---- developer tools ----------------------------------------------------

    /// Apple's installer. It runs for minutes in an app of its own, so the
    /// answer is read again when Wortel is next in front, as the others are.
    ///
    /// Unless the tools are there and macOS is looking elsewhere: then the
    /// installer only says "already installed", and what helps is a command
    /// that needs an administrator's password, so it is typed for the
    /// person to run.
    func fixDeveloperTools() {
        if gitNeedsReset {
            offerCommand?(DeveloperTools.resetLine)
            watchForReset()
        } else {
            DeveloperTools.install()
        }
    }

    /// The reset was typed on a prompt (`gitNeedsReset`), and the panes now
    /// say so instead of offering it again.
    private(set) var resetOffered = false

    /// The reset is run inside Wortel, so Wortel never comes to the front
    /// again to notice it worked (`refresh` is on activation): the panes
    /// would go on saying git can't run with git running. So for a few
    /// minutes after the line was typed the disk is asked every two seconds,
    /// a few `stat`s, until git is back.
    private func watchForReset() {
        guard !resetOffered else { return }
        resetOffered = true
        Task { @MainActor in
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(2))
                if DeveloperTools.current.canRun { break }
            }
            self.resetOffered = false
            self.refresh()
        }
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
