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
    /// The agents this Mac has, asked of the login shell once the window is
    /// up (`AgentDiscovery`). Empty until it answers: the field works
    /// without the list.
    @State private var agentsFound: [String] = []
    /// What is wrong with the command as typed, shown under the field.
    @State private var commandProblem: NewSessionCommand.Problem?

    var body: some View {
        Form {
            Section {
                // An HStack, not LabeledContent: that lines its two sides up on
                // their first baselines, and an AppKit control hosted here has
                // none to offer, so the label sat a few points high.
                HStack {
                    Text("New sessions start with")
                    Spacer()
                    CommandComboBox(command: $settings.newSessionCommand, suggestions: agentsFound,
                                    problem: $commandProblem)
                        .frame(width: 200)
                }
            } footer: {
                Text(commandNote)
                    .foregroundStyle(commandProblem == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        .task { agentsFound = await AgentDiscovery.find() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            sharesUsageData = TelemetrySettings.isEnabledByUser
        }
    }

    /// The line under the command field: why it can't be used, or what it
    /// does.
    private var commandNote: String {
        switch commandProblem {
        case .controlCharacter:
            return "A tab or another control character can't be typed into a shell."
        case .tooLong:
            return "Too long. A shell takes at most 1,024 bytes typed at once."
        case nil:
            return settings.startsSessionsWithCommand
                ? "Typed into each new session. New Terminal (⌃⌘N) starts one without it."
                : "Empty starts a terminal."
        }
    }
}
