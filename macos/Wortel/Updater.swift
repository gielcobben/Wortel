import AppKit
import Combine
import Foundation
import Observation
import Sparkle

/// Wraps Sparkle's standard updater. `SPUStandardUpdaterController` starts the
/// updater (scheduled background checks against `SUFeedURL` in Info.plist) and
/// provides the default user-facing update UI. We mirror Sparkle's KVO
/// `canCheckForUpdates` flag into observable state so the "Check for Updates…"
/// menu item can disable itself while a check is already in flight.
@MainActor
@Observable
final class Updater {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var cancellable: AnyCancellable?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    /// Manual check — shows progress and (if found) the update prompt. Activate
    /// first so Sparkle's window comes to the front even when Wortel isn't the
    /// active app.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }
}
