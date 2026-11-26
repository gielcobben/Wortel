import AppKit
import Combine
import Foundation
import Observation
import Sparkle
import UserNotifications

/// Sparkle, set up for an app nobody quits.
///
/// Sparkle's quiet path downloads an update and installs it "when the app
/// quits", and its other path is a window in the middle of your work. Wortel is
/// left open for weeks, so the first never comes and the second gets
/// dismissed. What makes a better path possible is that a restart costs
/// nothing here: the shells live in the keeper, so Wortel quits and comes back
/// in a second or two with every session, agent and layout as it was.
///
/// So: check every few hours and download in the background (Info.plist's
/// `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`,
/// `SUScheduledCheckInterval`); when an update is downloaded, take it over from
/// Sparkle (`willInstallUpdateOnQuit` returning true) and say so quietly: a
/// blue download icon in the sidebar's bottom bar, whose popover offers
/// Restart Now (`UpdateIndicator`), and an item in the Wortel menu, until you
/// choose the moment. One click installs and relaunches. And if an update has
/// waited a day, one notification, once.
///
/// Sparkle's own window still answers "Check for Updates…" when nothing is
/// waiting: asked for, it's not an interruption. While an update waits, Sparkle
/// holds its session open for the icon and runs no other check (so that item
/// is greyed, with "Restart to Update" right under it); the restart's launch
/// checks again soon after, so a release that came out meanwhile follows in
/// minutes rather than at the next interval.
@MainActor
@Observable
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private(set) var canCheckForUpdates = false
    /// Settings ▸ Update automatically: checking and downloading together,
    /// because one without the other is a window again. On only while both
    /// are (Sparkle's own dialog can turn downloading off by itself). A
    /// mirror of Sparkle's two preferences, kept by observing them, so the
    /// Settings row follows a change made anywhere. False on a development
    /// build, which has no updater.
    private(set) var updatesAutomatically = false
    /// Settings ▸ Beta updates: also take the versions published to the beta
    /// channel (`release.sh --publish --beta`), which everyone else is never
    /// offered. Regular releases still come either way. See `joinBetaOnce`
    /// for how a Mac gets here without a setting.
    private(set) var getsBetaUpdates = UserDefaults.standard.bool(forKey: Updater.betaKey)
    /// Whether this Mac has ever been on the beta channel. Settings keeps the
    /// row while it is, so turning betas off doesn't take away the switch
    /// that turns them back on.
    private(set) var hasBetaChoice = UserDefaults.standard.object(forKey: Updater.betaKey) != nil
    /// The waiting update is a beta. Its note isn't on wortel.sh/updates, so
    /// the update popover has no What's New for it.
    private(set) var readyIsBeta = false
    /// A downloaded update waiting for a restart, by its version.
    private(set) var readyVersion: String? {
        didSet { if readyVersion != oldValue { onReadyVersionChange?(readyVersion) } }
    }
    /// Set by the menu, so its Restart to Update item follows this without
    /// being re-read on every keypress (a menu delegate would be).
    @ObservationIgnored var onReadyVersionChange: ((String?) -> Void)?

    /// nil on a development build (see `isDevelopmentBuild`).
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var cancellable: AnyCancellable?
    @ObservationIgnored private var automaticCancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var installNow: (() -> Void)?
    /// The one nudge: when the waiting began, by the wall clock, and a timer
    /// that looks every half hour. Not a timer for the whole day: a run-loop
    /// timer's clock stops while the Mac sleeps, and a laptop asleep two
    /// thirds of the day would have it fire days late. In memory, not stored:
    /// any quit installs the update, so a wait never spans launches.
    @ObservationIgnored private var readySince: Date?
    @ObservationIgnored private var nudgeTimer: Timer?

    /// The reminder notification's identifier, which AppDelegate answers.
    static let notificationID = "WortelUpdateReady"

    private static let migratedKey = "WortelAutomaticUpdatesOn1"
    private static let lastRunVersionKey = "WortelLastRunVersion"
    /// Absent until a beta build first runs here; then true, and false only
    /// when it's turned off in Settings.
    private static let betaKey = "WortelBetaUpdates"
    /// The Sparkle channel a beta is published on.
    private static let betaChannel = "beta"
    /// How long an update may wait before the one notification.
    private static let nudgeAfter: TimeInterval = 24 * 60 * 60

    /// A Debug build is version 0.0.0, so every release reads as newer: left
    /// running, Sparkle would download one and offer to replace the build
    /// you're developing. It shares the release's preferences too (one bundle
    /// id), so it mustn't touch those either. So on a development build the
    /// updater stays off. The same rule telemetry uses, from the same place.
    static var isDevelopmentBuild: Bool { TelemetrySettings.isDevelopmentBuild }

    private override init() {
        super.init()
        assert(Self.sparkleCallbacks.allSatisfy { responds(to: $0) },
               "Updater doesn't implement the Sparkle callbacks it relies on")
        guard !Self.isDevelopmentBuild else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        turnOnAutomaticUpdatesOnce()
        joinBetaOnce()
        controller.startUpdater()
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        // Both are documented as KVO compliant (SPUUpdater.h).
        let updater = controller.updater
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .combineLatest(updater.publisher(for: \.automaticallyDownloadsUpdates))
            .receive(on: RunLoop.main)
            .sink { [weak self] checks, downloads in self?.updatesAutomatically = checks && downloads }
            .store(in: &automaticCancellables)
        updatesAutomatically = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        noteVersionChange()
    }

    /// Manual check — shows progress and (if found) the update prompt. Activate
    /// first so Sparkle's window comes to the front even when Wortel isn't the
    /// active app.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.updater.checkForUpdates()
    }

    /// Install the downloaded update and relaunch. Sparkle quits Wortel, which
    /// saves everything on the way out as any quit does; the keeper holds the
    /// shells across it.
    ///
    /// Sparkle's quit is a request from its helper process, and on 2026-11-20
    /// a click on Restart Now did nothing on a laptop whose update had waited
    /// 2.5 hours: the installer had the click (⌘Q later installed *and*
    /// reopened, which only a click asks for) but Wortel was never asked to
    /// quit. It did not reproduce in a test copy (straight away, after 35
    /// minutes, after a Sparkle relaunch), so the cause is not known. So
    /// Restart does not rely on that request: if Wortel is still here a few
    /// seconds after the click, it quits itself, which is the ⌘Q that finished
    /// the update by hand. `quitFallback` is well past the second or so the
    /// request takes when it works.
    ///
    /// A run-loop timer, never a `Task` or `DispatchQueue.main` block: quitting
    /// defers (`terminateLater`) and is answered from the main queue, which
    /// cannot run while the quit was started from inside one of its blocks.
    /// Measured: started from a `Task`, the quit hung for good and every later
    /// quit request was ignored as "already terminating".
    func restartToUpdate() {
        guard let installNow else { return }
        installNow()
        Timer.scheduledTimer(withTimeInterval: Self.quitFallback, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard !AppDelegate.isQuitting else { return }
                NSApp.terminate(nil)
            }
        }
    }

    private static let quitFallback: TimeInterval = 3

    /// Whether this build updates itself at all (a development build doesn't).
    var isAvailable: Bool { controller != nil }

    /// Turn automatic updates on or off. Sparkle keeps the preference itself
    /// (in the app's defaults), so there is no second copy of it here.
    func setUpdatesAutomatically(_ on: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = on
        updater.automaticallyDownloadsUpdates = on
        updatesAutomatically = on
    }

    /// Whether this build was published as a beta (Info.plist's
    /// `WortelUpdateChannel`, stamped by release.sh). Settings shows the beta
    /// row for it, so someone handed a beta can always find the way out.
    static var isBetaBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "WortelUpdateChannel") as? String == betaChannel
    }

    /// Turn beta updates on or off. Off takes effect from the next check: no
    /// beta is offered after it. It moves nothing back: Sparkle never offers
    /// an older version, so a Mac on a beta stays on it until the next
    /// regular release passes it, which is days, not weeks. And a beta
    /// already downloaded and waiting still installs at the next restart,
    /// because that session is Sparkle's and is not torn down from here.
    func setGetsBetaUpdates(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.betaKey)
        getsBetaUpdates = on
        hasBetaChoice = true
        // Turned on: look now, rather than at the next check hours away.
        guard on, let updater = controller?.updater,
              updater.automaticallyChecksForUpdates, updater.canCheckForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }

    // MARK: - Sparkle

    /// Both delegate methods below are optional Objective-C requirements, and
    /// a Swift name that misses one by a word compiles fine and is simply never
    /// called: the update would wait for a quit that never comes, silently.
    /// So each name is pinned twice, both at compile time: `#selector` on the
    /// protocol fails the build if Sparkle has no such method, and
    /// `checkCallbacksAreOurs` fails it if this class doesn't implement that
    /// exact name. (The assert in init says the same at runtime, in Debug.)
    private static let sparkleCallbacks: [Selector] = [
        #selector(SPUUpdaterDelegate.updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)),
        #selector(SPUUpdaterDelegate.updater(_:didFinishUpdateCycleFor:error:)),
        #selector(SPUUpdaterDelegate.allowedChannels(for:)),
    ]

    /// Never called: it compiles only while this class implements the
    /// callbacks under Sparkle's own names.
    private func checkCallbacksAreOurs() {
        _ = updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)
        _ = updater(_:didFinishUpdateCycleFor:error:)
        _ = allowedChannels(for:)
    }

    /// The channels this Mac is offered besides the default one, whose items
    /// carry no channel and are offered to everyone. A beta is an appcast item
    /// tagged `<sparkle:channel>beta</sparkle:channel>`: every Sparkle Wortel
    /// has shipped (2.9 and later) leaves it out unless it is named here.
    /// Read from the defaults on each check, so a change in Settings counts
    /// at the next one.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Self.betaKey) ? [Self.betaChannel] : []
    }

    /// An update is downloaded and would install on quit. Take it over, so it
    /// can install on a click instead of waiting for a quit that never comes.
    /// (Sparkle still installs it on quit if you get there first.)
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        let isBeta = item.channel != nil
        MainActor.assumeIsolated {
            self.installNow = immediateInstallHandler
            self.readyIsBeta = isBeta
            self.readyVersion = version
            self.startNudgeClock()
        }
        return true
    }

    /// The session behind the icon ended without installing (an error in the
    /// installer, say). Sparkle schedules a fresh check on its own; until then
    /// there's nothing to restart into, and an icon that does nothing on a click
    /// is worse than none. While the session waits, Sparkle starts no other
    /// (a manual check is refused), so this is the only way it goes stale.
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: (any Error)?) {
        MainActor.assumeIsolated {
            guard self.installNow != nil else { return }
            self.installNow = nil
            self.readyIsBeta = false
            self.readyVersion = nil
            self.nudgeTimer?.invalidate()
            self.readySince = nil
        }
    }

    // MARK: - Once

    /// Both Macs this was written on had answered Sparkle's one-time "check
    /// automatically?" prompt with "Don't Check", most likely without meaning
    /// to: it's a dialog on the second launch of a terminal you're about to
    /// type in. Info.plist now answers it, so it's never asked; this turns it
    /// on once for anyone who answered before. The menu item turns it off.
    private func turnOnAutomaticUpdatesOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        defaults.set(true, forKey: Self.migratedKey)
        setUpdatesAutomatically(true)
    }

    /// The first launch of a beta build puts this Mac on the beta channel, so
    /// handing someone a beta DMG is the whole invitation: no setting to find.
    /// Once only: the key is set from then on, so a Mac that turned betas off
    /// stays off through every later beta it is on, and a regular release
    /// replacing the beta doesn't take it off the channel either.
    private func joinBetaOnce() {
        let defaults = UserDefaults.standard
        guard Self.isBetaBuild, defaults.object(forKey: Self.betaKey) == nil else { return }
        defaults.set(true, forKey: Self.betaKey)
        getsBetaUpdates = true
        hasBetaChoice = true
    }

    /// The first launch of a new version checks again soon.
    private func noteVersionChange() {
        let defaults = UserDefaults.standard
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let last = defaults.string(forKey: Self.lastRunVersionKey)
        defaults.set(current, forKey: Self.lastRunVersionKey)
        // An update moves the version forward; a debug build next to a
        // release, or the first launch ever, doesn't count.
        guard let current, let last, current != last,
              current.compare(last, options: .numeric) == .orderedDescending else { return }
        // While the last one waited, Sparkle checked for nothing newer: look
        // now rather than at the next interval, so a release that came out in
        // the meantime follows in minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let updater = self?.controller?.updater,
                  updater.automaticallyChecksForUpdates, updater.canCheckForUpdates else { return }
            updater.checkForUpdatesInBackground()
        }
    }

    // MARK: - The one nudge

    private func startNudgeClock() {
        readySince = Date()
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.nudgeIfWaitedLong() }
        }
    }

    /// One notification per waiting update, a day in by the clock on the wall.
    /// Never more: the icon is the reminder, and this only catches an icon
    /// nobody looked at.
    private func nudgeIfWaitedLong() {
        guard let version = readyVersion, let readySince,
              Date().timeIntervalSince(readySince) >= Self.nudgeAfter else { return }
        nudgeTimer?.invalidate()
        nudgeTimer = nil
        let content = UNMutableNotificationContent()
        content.title = "Wortel \(version) is ready"
        content.body = "Restart when it suits you. Your sessions come back as they were."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }
}
