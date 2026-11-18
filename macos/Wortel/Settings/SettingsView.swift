import SwiftUI

// The Settings window's two panes: the system's grouped form, with the
// system's own switches, under the toolbar of icon tabs every Mac user knows
// as "a settings window" (`SettingsWindowController`). Nothing in them is
// Wortel's chrome, on purpose.
//
// Every row is a name and one short grey line saying what it does, so nothing
// here needs the docs to be understood, and the whole of that text is the
// switch's to click: a target the width of the row, not the 38 points of the
// switch itself.

/// The width of both panes. The window keeps it and changes only its height
/// between them.
enum SettingsPane {
    static let width: CGFloat = 480
}

/// General: what a new session starts, and what the window shows.
struct GeneralSettingsPane: View {
    @Bindable var settings: AppSettings
    /// The agents this Mac has, asked of the login shell once the pane is up
    /// (`AgentDiscovery`). Empty until it answers: the field works without
    /// the list.
    @State private var agentsFound: [String] = []
    /// What is wrong with the command as typed, said under the row's name.
    @State private var commandProblem: NewSessionCommand.Problem?
    @State private var focusCommand = 0

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    SettingLabel(title: "New sessions start with", note: commandNote,
                                 isProblem: commandProblem != nil)
                        // The name of a field puts the cursor in it.
                        .onTapGesture { focusCommand += 1 }
                    CommandComboBox(command: $settings.newSessionCommand, suggestions: agentsFound,
                                    problem: $commandProblem, focusRequest: focusCommand)
                }
            }
            Section {
                SwitchRow(title: "Commit box", note: "The message field in Source Control.",
                          isOn: $settings.showsCommitBox)
                SwitchRow(title: "Open servers in your browser",
                          note: "Instead of a tab beside the terminal.",
                          isOn: $settings.opensServersInDefaultBrowser)
            }
        }
        .formStyle(.grouped)
        .task { agentsFound = await AgentDiscovery.find() }
    }

    /// The grey line under the command's name: what it does, or why what is
    /// in the field can't be used.
    private var commandNote: String {
        switch commandProblem {
        case .controlCharacter: return "A tab or a line break can't be typed into a shell."
        case .tooLong: return "Too long. A shell takes 1,024 bytes at once."
        case nil:
            return settings.startsSessionsWithCommand
                ? "Typed into each new session. New Terminal (⌃⌘N) starts one without it."
                : "A command typed into each new session. Empty starts a plain terminal."
        }
    }
}

/// Updates: keeping the app current, and what it reports.
///
/// **A row that cannot do anything is absent, not greyed** (DESIGN.md). A
/// development build doesn't update and doesn't report, so it has neither
/// row. The tab stays, with one line saying so, since a window whose tabs
/// come and go with the build is a different window to test.
struct UpdatesSettingsPane: View {
    let updater: Updater
    /// `TelemetrySettings` is static `UserDefaults`, which SwiftUI can't
    /// watch, and the sidebar's ⓘ flips the same preference. Read when the
    /// view is made and again whenever a window becomes key.
    @State private var sharesUsageData = TelemetrySettings.isEnabledByUser

    var body: some View {
        Form {
            Section {
                if updater.isAvailable {
                    SwitchRow(title: "Update automatically", note: "New versions install when you quit.",
                              isOn: Binding(get: { updater.updatesAutomatically },
                                            set: { updater.setUpdatesAutomatically($0) }))
                }
                if TelemetrySettings.isSwitchable {
                    SwitchRow(title: "Share anonymous usage data",
                              note: "Which features are used, never your work.",
                              isOn: Binding(get: { sharesUsageData },
                                            set: {
                                                sharesUsageData = $0
                                                Telemetry.setReporting($0)
                                            }))
                }
                if !updater.isAvailable, !TelemetrySettings.isSwitchable {
                    SettingLabel(title: "Nothing to set in this build",
                                 note: "A development build doesn't update itself and reports nothing.")
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            sharesUsageData = TelemetrySettings.isEnabledByUser
        }
    }
}

/// A row's name and the one grey line under it, as the system's settings
/// rows are set: the name in the body size, the line a size smaller in the
/// secondary colour. Fills the row's width so all of it can be clicked.
private struct SettingLabel: View {
    let title: String
    let note: String
    var isProblem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(note)
                .font(.subheadline)
                .foregroundStyle(isProblem ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A switch with its name and line, where a click on either flips it. The
/// gesture is on the label alone: the switch takes its own clicks, and one
/// on the whole row would flip it twice.
private struct SwitchRow: View {
    let title: String
    let note: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingLabel(title: title, note: note)
                .onTapGesture { isOn.toggle() }
        }
        .toggleStyle(.switch)
    }
}
