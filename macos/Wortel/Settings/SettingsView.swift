import SwiftUI

/// The Settings window's one pane: the system's grouped form, with the
/// system's own switches. Nothing in it is Wortel's chrome, on purpose: a
/// settings window is the one place a Mac user expects to look exactly like
/// every other app's.
///
/// **A row that cannot do anything is absent, not greyed** (DESIGN.md). A
/// development build doesn't update and doesn't report, so it shows neither
/// row; the sidebar's ⓘ still says why nothing is reported there.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let updater: Updater
    /// `TelemetrySettings` is static `UserDefaults`, which SwiftUI can't
    /// watch, and the sidebar's ⓘ flips the same preference. Read when the
    /// view is made and again whenever a window becomes key.
    @State private var sharesUsageData = TelemetrySettings.isEnabledByUser

    var body: some View {
        Form {
            Section {
                Toggle("Commit box in Source Control", isOn: $settings.showsCommitBox)
                Toggle("Open servers in default browser", isOn: $settings.opensServersInDefaultBrowser)
            }
            if updater.isAvailable || TelemetrySettings.isSwitchable {
                Section {
                    if updater.isAvailable {
                        Toggle("Update automatically", isOn: Binding(
                            get: { updater.updatesAutomatically },
                            set: { updater.setUpdatesAutomatically($0) }))
                    }
                    if TelemetrySettings.isSwitchable {
                        Toggle("Share anonymous usage data", isOn: Binding(
                            get: { sharesUsageData },
                            set: {
                                sharesUsageData = $0
                                Telemetry.setReporting($0)
                            }))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            sharesUsageData = TelemetrySettings.isEnabledByUser
        }
    }
}
