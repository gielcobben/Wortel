import SwiftUI

// The Settings window's page, in Wortel's own drawing: the app's 13pt type,
// its hairlines, its 28pt controls with 8pt corners, in boxes on an opaque
// page under a titlebar row (`SettingsWindowController`). The system's
// preferences window came before it (37b52e6) and was used for an afternoon;
// this is the one that stayed.
//
// Every row is a name and one short grey line saying what it does, and the
// whole of that text is the switch's to click.

/// The two tabs of the titlebar row.
enum SettingsTab: String, CaseIterable {
    case general = "General"
    case updates = "Updates"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// What the window is showing, shared by the titlebar row and the page under
/// it: which tab is in front, the command as it stands in its field, and the
/// agents found on this Mac.
///
/// The command being typed lives here and not in the field's own view,
/// because the field goes away with its tab: typed and not yet saved, it was
/// lost by a click on Updates, and by closing the window. Whoever takes the
/// field away saves it first (`commitCommand`).
@Observable
@MainActor
final class SettingsTabState {
    var tab: SettingsTab = .general
    /// The field's text. Saved when you are done with it, never per
    /// keystroke: ⌘N pressed while it still says `cla` must start what was
    /// last saved, not half a word.
    var commandDraft: String
    /// Asked of the login shell once, when the window opens
    /// (`AgentDiscovery`). Empty until it answers: the field works without.
    var agentsFound: [String] = []

    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        commandDraft = settings.newSessionCommand
    }

    /// What is wrong with the text in the field, if anything.
    var commandProblem: NewSessionCommand.Problem? {
        if case .failure(let problem) = NewSessionCommand.check(commandDraft) { return problem }
        return nil
    }

    /// Save the field: on Return, on leaving it, on leaving its tab, on the
    /// window closing. A line that can't be typed into a shell is never
    /// saved; the field keeps it and the grey line says why.
    func commitCommand() {
        guard commandProblem == nil else { return }
        let trimmed = commandDraft.trimmingCharacters(in: .whitespaces)
        if settings.newSessionCommand != trimmed { settings.newSessionCommand = trimmed }
    }

    /// Picked from the field's menu.
    func pickCommand(_ value: String) {
        commandDraft = value
        settings.newSessionCommand = value
    }

    func show(_ tab: SettingsTab) {
        commitCommand()
        self.tab = tab
    }
}

enum SettingsMetrics {
    /// The window's one width. It changes only its height between tabs. As
    /// narrow as the longest line under a row allows without wrapping.
    static let width: CGFloat = 380
    /// The page's inset from the window's edges, and the gap between boxes.
    static let inset: CGFloat = 16
    static let boxGap: CGFloat = 12
}

/// The page under the titlebar row: the rows of the tab in front, held to
/// the top of the page and clipped to it.
///
/// The rows are laid over the page, not laid out in it, so the page is
/// whatever size the window gives it and the rows keep their own. While the
/// window's height is still on its way to a taller tab's, the rows are simply
/// cut off at the bottom. Sized by the window instead, rows taller than the
/// page were centred on it, and their top ran up over the titlebar row for
/// the length of the animation.
struct SettingsPage: View {
    let state: SettingsTabState
    @Bindable var settings: AppSettings
    let updater: Updater
    /// The rows' height, whenever it changes: the window follows it.
    let onHeight: (CGFloat) -> Void

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                SettingsRows(state: state, settings: settings, updater: updater)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { onHeight($0) })
            }
            .clipped()
    }
}

/// The rows themselves, at the window's width and their own height: what the
/// window is measured from before it is first shown.
struct SettingsRows: View {
    let state: SettingsTabState
    @Bindable var settings: AppSettings
    let updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.boxGap) {
            switch state.tab {
            case .general: GeneralRows(state: state, settings: settings)
            case .updates: UpdatesRows(updater: updater)
            }
        }
        .padding(SettingsMetrics.inset)
        .frame(width: SettingsMetrics.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The titlebar row's tabs, drawn as every tab in the app is
/// (`SideTabStrip`): 28pt high with 8pt corners, a glyph and the name, the
/// one in front on the band's own selection fill with a hairline, the other
/// quiet until the pointer is over it. No close button, so the name has the
/// same 10pt after it as before the glyph.
struct SettingsTabStrip: View {
    @Bindable var state: SettingsTabState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                SettingsTabButton(tab: tab, isActive: state.tab == tab) { state.show(tab) }
            }
        }
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isActive: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14))
                    .frame(width: 16, height: 16)
                Text(tab.rawValue)
                    .font(.system(size: 13))
            }
            .foregroundStyle(Color(nsColor: isActive ? .labelColor : .secondaryLabelColor))
            .padding(.horizontal, 10)
            .frame(height: Chrome.controlSize)
            .background {
                let shape = RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
                if isActive {
                    shape.fill(Color(nsColor: Chrome.raisedOnBand))
                        .overlay(shape.strokeBorder(Color(nsColor: Chrome.hairlineStrong), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                } else if hovering {
                    shape.fill(Color(nsColor: Chrome.hoverFill))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// General: what a new session starts, and what the window shows.
private struct GeneralRows: View {
    let state: SettingsTabState
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsBox {
            CommandRow(state: state, command: settings.newSessionCommand)
        }
        SettingsBox {
            SwitchRow(title: "Commit box", note: "The message field in Source Control.",
                      isOn: $settings.showsCommitBox)
            Hairline()
            SwitchRow(title: "Open servers in your browser", note: "Instead of a tab beside the terminal.",
                      isOn: $settings.opensServersInDefaultBrowser)
        }
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

    private var showsBetaRow: Bool {
        updater.isAvailable && (Updater.isBetaBuild || updater.getsBetaUpdates)
    }

    var body: some View {
        SettingsBox {
            if updater.isAvailable {
                SwitchRow(title: "Update automatically", note: "New versions install when you quit.",
                          isOn: Binding(get: { updater.updatesAutomatically },
                                        set: { updater.setUpdatesAutomatically($0) }))
            }
            // Only where betas reach: a Mac running a beta or on the channel.
            // Nobody else has a beta to turn on, so for them it's absent.
            if showsBetaRow {
                Hairline()
                SwitchRow(title: "Beta updates", note: "New versions a few days before everyone else.",
                          isOn: Binding(get: { updater.getsBetaUpdates },
                                        set: { updater.setGetsBetaUpdates($0) }))
            }
            if updater.isAvailable, TelemetrySettings.isSwitchable { Hairline() }
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

/// A group of rows in a box: a faint band on the page with rounded corners,
/// as the system's own settings group theirs, in the app's tokens (the
/// bottom strip's band, which is the page's quietest fill). Rows that belong
/// together share one, with a hairline between them.
private struct SettingsBox<Rows: View>: View {
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { rows }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: Chrome.stripBand)))
    }
}

/// The hairline between two rows of a box.
private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: Chrome.hairline))
            .frame(height: 1)
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
/// The text and its saving are `SettingsTabState`'s, which outlives this
/// view. This is the field's drawing, and the two moments it can see for
/// itself: Return, and the keyboard leaving it.
private struct CommandRow: View {
    @Bindable var state: SettingsTabState
    /// The saved command (`AppSettings.newSessionCommand`).
    let command: String

    @FocusState private var editing: Bool
    @State private var menuAnchor = MenuAnchor()

    /// It is any command, not a choice of agent, and the line has to say so:
    /// the menu only holds the agents found.
    private var note: String {
        switch state.commandProblem {
        case .controlCharacter: return "A tab or a line break can't be typed into a shell."
        case .tooLong: return "Too long. A shell takes 1,024 bytes at once."
        case nil:
            // Short enough for one line at the window's width.
            return command.isEmpty
                ? "Any command, like claude. Empty is a terminal."
                : "Any command. ⌃⌘N starts a session without it."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RowLabel(title: "New sessions start with", note: note, isProblem: state.commandProblem != nil)
                // The name of a field puts the cursor in it.
                .onTapGesture { editing = true }
            HStack(spacing: 0) {
                TextField("New sessions start with", text: $state.commandDraft, prompt: Text("Command"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    // Something typed into a shell, so in the font of one.
                    .font(.system(size: 12, design: .monospaced))
                    .focused($editing)
                    .onSubmit { state.commitCommand() }
                    .padding(.leading, 10)
                // Only once there is something to offer: absent, not greyed.
                if !state.agentsFound.isEmpty {
                    Button(action: showAgents) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .frame(width: Chrome.controlSize, height: Chrome.controlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Agents found on this Mac")
                }
            }
            .frame(height: Chrome.controlSize)
            .background(RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor)))
            // The field itself, for the menu to hang from.
            .background(MenuAnchorView(anchor: menuAnchor))
            // The commit box's outline: a field's line, and the accent while
            // it has the keyboard.
            .overlay(RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
                .strokeBorder(editing ? Color.accentColor.opacity(0.5) : Color(nsColor: Chrome.hairlineStrong)))
        }
        .padding(.vertical, SettingRow.padding)
        // Leaving the field is being done with it.
        .onChange(of: editing) { _, now in if !now { state.commitCommand() } }
    }

    /// The agents found, and Terminal, as a menu under the field and as wide
    /// as it: the list of a field, not a menu that happens to open beside
    /// its arrow. (SwiftUI's own `Menu` hung from the arrow at the field's
    /// end and stuck out past the window.)
    private func showAgents() {
        let state = self.state
        let menu = NSMenu()
        for agent in state.agentsFound {
            let item = ClosureMenuItem(title: agent) { state.pickCommand(agent) }
            item.state = command == agent ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let terminal = ClosureMenuItem(title: "Terminal") { state.pickCommand("") }
        terminal.state = command.isEmpty ? .on : .off
        menu.addItem(terminal)
        menuAnchor.pop(menu)
    }
}

/// Where a menu hangs from: a view the size of whatever it is the background
/// of, kept so a button elsewhere in the row can open a menu under it.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?

    /// Open `menu` just under the anchor, from its leading edge and at least
    /// as wide as it.
    func pop(_ menu: NSMenu) {
        guard let view else { return }
        menu.minimumWidth = view.bounds.width
        // The point is the menu's top left. The view isn't flipped, so its
        // bottom edge is zero and "under it" is below that.
        let under = view.isFlipped ? view.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: under), in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
