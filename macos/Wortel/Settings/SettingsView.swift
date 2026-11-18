import SwiftUI

// The Settings window's page, in Wortel's own drawing: the app's 13pt type,
// its hairlines, its 28pt controls with 8pt corners, on an opaque page under
// a titlebar row (`SettingsWindowController`). An experiment beside the
// system's preferences window that came before it (37b52e6), to see which
// one the app should have.
//
// Every row is a name and one short grey line saying what it does, and the
// whole of that text is the switch's to click.

/// The two tabs, as the titlebar row's switch names them.
enum SettingsTab: String, CaseIterable {
    case general = "General"
    case updates = "Updates"
}

/// Which tab is in front: shared by the switch in the titlebar row and the
/// page under it.
@Observable
@MainActor
final class SettingsTabState {
    var tab: SettingsTab = .general
}

enum SettingsMetrics {
    /// The window's one width. It changes only its height between tabs.
    static let width: CGFloat = 440
    /// The page's inset from the window's edges: the terminal page's own
    /// feel, a little roomier, since this is read and not worked in.
    static let inset: CGFloat = 20
}

/// The page under the titlebar row: the rows of the tab in front.
struct SettingsPage: View {
    let state: SettingsTabState
    @Bindable var settings: AppSettings
    let updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state.tab {
            case .general: GeneralRows(settings: settings)
            case .updates: UpdatesRows(updater: updater)
            }
        }
        .padding(.horizontal, SettingsMetrics.inset)
        .padding(.vertical, 8)
        .frame(width: SettingsMetrics.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// General: what a new session starts, and what the window shows.
private struct GeneralRows: View {
    @Bindable var settings: AppSettings
    /// The agents this Mac has, asked of the login shell once the page is up
    /// (`AgentDiscovery`). Empty until it answers: the field works without
    /// the list.
    @State private var agentsFound: [String] = []

    var body: some View {
        CommandRow(command: $settings.newSessionCommand, agents: agentsFound)
            .task { agentsFound = await AgentDiscovery.find() }
        Hairline()
        SwitchRow(title: "Commit box", note: "The message field in Source Control.",
                  isOn: $settings.showsCommitBox)
        SwitchRow(title: "Open servers in your browser", note: "Instead of a tab beside the terminal.",
                  isOn: $settings.opensServersInDefaultBrowser)
    }
}

/// Updates: keeping the app current, and what it reports.
///
/// **A row that cannot do anything is absent, not greyed** (DESIGN.md). A
/// development build doesn't update and doesn't report, so it has neither
/// row. The tab stays, with one line saying so, since a window whose tabs
/// come and go with the build is a different window to test.
private struct UpdatesRows: View {
    let updater: Updater
    /// `TelemetrySettings` is static `UserDefaults`, which SwiftUI can't
    /// watch, and the sidebar's ⓘ flips the same preference. Read when the
    /// view is made and again whenever a window becomes key.
    @State private var sharesUsageData = TelemetrySettings.isEnabledByUser

    var body: some View {
        Group {
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
                RowLabel(title: "Nothing to set in this build",
                         note: "A development build doesn't update itself and reports nothing.")
                    .padding(.vertical, SettingRow.padding)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            sharesUsageData = TelemetrySettings.isEnabledByUser
        }
    }
}

private enum SettingRow {
    /// Above and under each row's two lines.
    static let padding: CGFloat = 10
}

/// A row's name and the one grey line under it: the app's 13pt in the label
/// colour, and 12pt in the secondary one. Fills the row's width so all of it
/// can be clicked.
private struct RowLabel: View {
    let title: String
    let note: String
    var isProblem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .labelColor))
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: isProblem ? .labelColor : .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The hairline between groups of rows.
private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: Chrome.hairline))
            .frame(height: 1)
            .padding(.vertical, 6)
    }
}

/// A small switch with its name and line, where a click on either flips it.
/// The gesture is on the label alone: the switch takes its own clicks, and
/// one on the whole row would flip it twice.
private struct SwitchRow: View {
    let title: String
    let note: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, note: note)
                .onTapGesture { isOn.toggle() }
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, SettingRow.padding)
    }
}

/// New sessions start with: a field for any command, 28pt high with 8pt
/// corners as every control here is, and a menu at its end of the agents
/// found on this Mac.
///
/// **Saved when you are done, never per keystroke**: on Return, on leaving
/// the field, on picking from the menu, and when the window closes (which
/// ends editing). ⌘N pressed while the field still says `cla` must start what
/// was last saved, not half a word. A line that can't be typed into a shell
/// is never saved: the field keeps the text and the grey line says why.
private struct CommandRow: View {
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

    /// It is any command, not a choice of agent, and the line has to say so:
    /// the menu only holds the agents found.
    private var note: String {
        switch problem {
        case .controlCharacter: return "A tab or a line break can't be typed into a shell."
        case .tooLong: return "Too long. A shell takes 1,024 bytes at once."
        case nil:
            return command.isEmpty
                ? "Any command, such as claude. Empty starts a plain terminal."
                : "Any command. New Terminal (⌃⌘N) starts a session without it."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowLabel(title: "New sessions start with", note: note, isProblem: problem != nil)
                // The name of a field puts the cursor in it.
                .onTapGesture { editing = true }
            HStack(spacing: 0) {
                TextField("New sessions start with", text: $draft, prompt: Text("Command"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    // Something typed into a shell, so in the font of one.
                    .font(.system(size: 12, design: .monospaced))
                    .focused($editing)
                    .onSubmit(save)
                    .padding(.leading, 10)
                // Only once there is something to offer: absent, not greyed.
                if !agents.isEmpty {
                    Menu {
                        ForEach(agents, id: \.self) { agent in
                            Toggle(agent, isOn: Binding(get: { command == agent },
                                                        set: { _ in pick(agent) }))
                        }
                        Divider()
                        Toggle("Terminal", isOn: Binding(get: { command.isEmpty },
                                                         set: { _ in pick("") }))
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: Chrome.controlSize, height: Chrome.controlSize)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Agents found on this Mac")
                }
            }
            .frame(height: Chrome.controlSize)
            .background(RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor)))
            // The commit box's outline: a field's line, and the accent while
            // it has the keyboard.
            .overlay(RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
                .strokeBorder(editing ? Color.accentColor.opacity(0.5) : Color(nsColor: Chrome.hairlineStrong)))
        }
        .padding(.vertical, SettingRow.padding)
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
