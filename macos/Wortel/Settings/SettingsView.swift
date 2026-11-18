import SwiftUI

/// The Settings window's one pane: the system's grouped form, with the
/// system's own switches. Nothing in it is Wortel's chrome, on purpose: a
/// settings window is the one place a Mac user expects to look exactly like
/// every other app's. One pane and no toolbar of icon tabs, as Notes and
/// Reminders have it: tabs are for an app with several panes, and five rows
/// are one.
///
/// Every row is a name and one short grey line saying what it does, so
/// nothing here needs the docs to be understood.
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

    var body: some View {
        Form {
            Section {
                CommandField(command: $settings.newSessionCommand, agents: agentsFound)
            }
            Section {
                Toggle(isOn: $settings.showsCommitBox) {
                    Text("Commit box")
                    Text("The message field in Source Control.")
                }
                Toggle(isOn: $settings.opensServersInDefaultBrowser) {
                    Text("Open servers in your browser")
                    Text("Instead of a tab beside the terminal.")
                }
            }
            if updater.isAvailable || TelemetrySettings.isSwitchable {
                Section {
                    if updater.isAvailable {
                        Toggle(isOn: Binding(
                            get: { updater.updatesAutomatically },
                            set: { updater.setUpdatesAutomatically($0) })) {
                            Text("Update automatically")
                            Text("New versions install when you quit.")
                        }
                    }
                    if TelemetrySettings.isSwitchable {
                        Toggle(isOn: Binding(
                            get: { sharesUsageData },
                            set: {
                                sharesUsageData = $0
                                Telemetry.setReporting($0)
                            })) {
                            Text("Share anonymous usage data")
                            Text("Which features are used, never your work.")
                        }
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
}

/// New sessions start with: a field for any command, and a menu at its end
/// of the agents found on this Mac.
///
/// **Saved when you are done, never per keystroke**: on Return, on leaving
/// the field, on picking from the menu, and when the window closes (which
/// ends editing). ⌘N pressed while the field still says `cla` must start what
/// was last saved, not half a word. A line that can't be typed into a shell
/// is never saved: the field keeps the text and the grey line says why.
private struct CommandField: View {
    /// The saved command (`AppSettings.newSessionCommand`).
    @Binding var command: String
    let agents: [String]

    /// What the field shows while it is being typed in.
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var problem: NewSessionCommand.Problem? {
        if case .failure(let problem) = NewSessionCommand.check(draft) { return problem }
        return nil
    }

    private var note: String {
        switch problem {
        case .controlCharacter: return "A tab or a line break can't be typed into a shell."
        case .tooLong: return "Too long. A shell takes 1,024 bytes at once."
        case nil:
            // One line, as every row's is. That New Terminal (⌃⌘N) is the
            // way round it is said where it is found: in the Session menu,
            // right under New Session, the moment this is set.
            return command.isEmpty
                ? "Empty starts a plain terminal."
                : "Typed into each new session."
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("New sessions start with", text: $draft, prompt: Text("Nothing"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .focused($editing)
                    .onSubmit(save)
                    .frame(minWidth: 120)
                // Only once there is something to offer: absent, not greyed.
                if !agents.isEmpty {
                    Menu {
                        ForEach(agents, id: \.self) { agent in
                            Toggle(agent, isOn: Binding(
                                get: { command == agent },
                                set: { _ in pick(agent) }))
                        }
                        Divider()
                        Toggle("Terminal", isOn: Binding(
                            get: { command.isEmpty },
                            set: { _ in pick("") }))
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Agents found on this Mac")
                }
            }
        } label: {
            Text("New sessions start with")
            Text(note)
                .foregroundStyle(problem == nil ? .secondary : .primary)
        }
        .onAppear { draft = command }
        // Changed from outside the field: the menu, or another window.
        .onChange(of: command) { _, new in if !editing { draft = new } }
        // Leaving the field is being done with it.
        .onChange(of: editing) { _, now in if !now { save() } }
    }

    private func pick(_ value: String) {
        draft = value
        command = value
    }

    private func save() {
        guard problem == nil else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if command != trimmed { command = trimmed }
    }
}
