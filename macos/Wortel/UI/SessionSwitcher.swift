import AppKit
import SwiftUI

/// ⌘P: go to a session by typing a few letters of its name, its folder, its
/// branch or its directory, or run any command in the menus. VS Code's,
/// Cursor's and Zed's quick open with cmdk's commands mixed in; ⌘K, the
/// ChatGPT app's, is "clear screen" in a terminal. ⇧⌘P: commands only, as
/// VS Code's command palette.
///
/// A card over the top of the window, as Spotlight and Xcode's Open Quickly
/// are: a field, the matches under it (SessionSwitcherMatch), arrows and
/// Return, Escape or a click elsewhere to put it away.
///
/// The card is the window: a vibrant material with rounded corners, and the
/// system's own shadow following its shape. The window is exactly as tall as
/// the card, sized from the rows it shows rather than measured, and grows
/// and shrinks from its top edge as the list does.
@MainActor
final class SessionSwitcher {
    private let manager: SessionManager
    private var panel: SwitcherPanel?
    /// Which palette is open, until it closes and is counted
    /// (`Telemetry` palette_used): nil once reported.
    private var openMode: PaletteMode?
    /// Where the card's top sits, in screen coordinates: what stays put as
    /// its height changes.
    private var top: CGFloat = 0

    init(manager: SessionManager) {
        self.manager = manager
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle(over window: NSWindow, commandsOnly: Bool = false) {
        if isShown { close() } else { show(over: window, commandsOnly: commandsOnly) }
    }

    /// ⇧⌘O: Open Branch (`OpenTarget`) for the repository at `directory`.
    func showBranches(over window: NSWindow, from directory: String?) {
        let model = OpenBranchModel(inputs: manager.openBranchInputs(from: directory), from: directory)
        show(over: window, branches: model)
        manager.loadBranches(into: { [weak model] in model?.inputs = $0 }, from: directory)
    }

    /// `commandsOnly`: ⇧⌘P, the menus' commands and no sessions.
    func show(over window: NSWindow, commandsOnly: Bool = false, branches: OpenBranchModel? = nil) {
        close()
        // Read now, while the window is key: validated for it, not the panel.
        let commands = PaletteCommands.all()
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: SwitcherView.width, height: SwitcherView.fieldHeight),
            // Borderless and nothing else: with `.fullSizeContentView` the
            // hosted card was given a titlebar's worth of safe area it
            // doesn't have, and sat 28pt too high, its field clipped.
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.onResign = { [weak self] in self?.close() }

        // The material is the card: behind-window vibrancy, so the window and
        // the desktop show softly through, masked to the card's corners (which
        // is also the shape the window's shadow takes).
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: SwitcherView.cornerRadius)
        let host = NSHostingView(rootView: SwitcherView(
            manager: manager,
            commands: branches == nil ? commands : [],
            commandsOnly: commandsOnly,
            branches: branches,
            open: { [weak self] action, alternate in
                self?.report(.session)
                self?.close()
                guard let self else { return }
                // ⌥↩ on Create: the same branch, from a base you pick.
                if alternate, case .create(let branch) = action {
                    newSessionOnBranch(self.manager, name: branch, from: branches?.from)
                } else {
                    self.manager.perform(action, from: branches?.from)
                }
            },
            pick: { [weak self] id in
                self?.report(.session)
                self?.close()
                self?.manager.selectedID = id
            },
            run: { [weak self] command in
                self?.report(.command)
                self?.close()
                // Once the window has the keyboard back: commands act on the
                // key window's responder chain, as from the menu.
                DispatchQueue.main.async { command.perform() }
            },
            cancel: { [weak self] in self?.close() },
            resize: { [weak self] height in self?.resize(to: height) }))
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = background
        // Resized with the window, not pinned by constraints: pinned, the
        // views kept an older, taller height when the window shrank, and the
        // window showed their bottom part, the card's top cut off above a gap.
        // (Reproduced and checked offscreen: host and card now match the window.)
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)

        // A little below the top of the window, centred on it.
        let frame = window.frame
        top = frame.maxY - 84
        panel.setFrame(NSRect(x: frame.midX - SwitcherView.width / 2, y: top - SwitcherView.fieldHeight,
                              width: SwitcherView.width, height: SwitcherView.fieldHeight), display: false)
        // Before it's shown: showing it lays the card out, and the card's first
        // report of its height arrives then. With the panel not yet set that
        // report was dropped, and never repeated, since the height didn't
        // change again: the window stayed at the field's height, the card cut
        // off inside it.
        self.panel = panel
        openMode = branches != nil ? .branches : commandsOnly ? .commands : .sessions
        window.addChildWindow(panel, ordered: .above)

        // In with a quick fade, as Spotlight comes in.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = Motion.curve
            panel.animator().alphaValue = 1
        }
        if let height = pendingHeight { resize(to: height) }
    }

    /// A height reported before there was a panel to give it to.
    private var pendingHeight: CGFloat?

    /// The card's height changed with the list: grow or shrink from the top.
    private func resize(to height: CGFloat) {
        pendingHeight = height
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height,
                              width: panel.frame.width, height: height), display: true)
        panel.invalidateShadow()
    }

    /// How this palette ended, counted once. A close with nothing picked is a
    /// dismissal, whatever closed it.
    private func report(_ result: PaletteResult) {
        guard let mode = openMode else { return }
        openMode = nil
        Telemetry.capture(.paletteUsed(mode: mode, result: result))
    }

    func close() {
        report(.dismissed)
        guard let panel else { return }
        self.panel = nil
        panel.onResign = nil
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Back to the window it was opened over, and its terminal.
        parent?.makeKey()
    }

    /// A stretchable rounded rectangle: the card's shape at any height.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// What Open Branch lists, filled in as the branches arrive.
@Observable
@MainActor
final class OpenBranchModel {
    var inputs: OpenTarget.Inputs
    let from: String?
    init(inputs: OpenTarget.Inputs, from: String?) {
        self.inputs = inputs
        self.from = from
    }
}

/// A borderless panel that can take the keyboard, and goes away when it
/// loses it.
private final class SwitcherPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// The field, the matches (sessions, then commands), and a line of keys.
private struct SwitcherView: View {
    static let width: CGFloat = 560
    static let cornerRadius: CGFloat = 16
    static let fieldHeight: CGFloat = 56
    private static let visibleRows = 8
    private static let rowHeight: CGFloat = 44
    private static let listPadding: CGFloat = 6
    private static let headerHeight: CGFloat = 26
    private static let footerHeight: CGFloat = 32
    private static let emptyHeight: CGFloat = 64

    let manager: SessionManager
    let commands: [PaletteCommand]
    let commandsOnly: Bool
    /// Open Branch: its rows instead of sessions and commands.
    let branches: OpenBranchModel?
    /// A row of Open Branch chosen, and whether with ⌥.
    let open: (OpenTarget.Action, Bool) -> Void
    let pick: (UUID) -> Void
    let run: (PaletteCommand) -> Void
    let cancel: () -> Void
    let resize: (CGFloat) -> Void

    @State private var query = ""
    @State private var highlighted = 0
    /// The highlighted row by id, so rows arriving above it (Open Branch's
    /// branches, then the remote ones after the fetch, seconds later) leave
    /// it on the row you chose: Return does what it said when you looked.
    @State private var highlightedID: String?

    enum Row: Identifiable {
        case session(SessionSwitcherMatch.Candidate)
        case command(PaletteCommand)
        case target(OpenTarget.Choice)
        var id: String {
            switch self {
            case .session(let c): return c.id.uuidString
            case .command(let c): return c.id.uuidString
            case .target(let c): return c.id
            }
        }
    }

    private var targetRows: [Row] {
        guard let branches else { return [] }
        return OpenTarget.choices(for: query, in: branches.inputs).map(Row.target)
    }

    private var sessionRows: [Row] {
        guard !commandsOnly, branches == nil else { return [] }
        let candidates = manager.sessions.map { session in
            SessionSwitcherMatch.Candidate(
                id: session.id, name: session.leafName, folder: session.folderPath,
                branch: session.worktreeLabel, path: session.abbreviatedPath)
        }
        return SessionSwitcherMatch.rank(query, candidates, recent: manager.recentSessionIDs,
                                         current: manager.selectedID).map(Row.session)
    }

    /// Commands ranked by the same rules as sessions: the title as the name,
    /// its menus as the folder ("session move" finds Session › Move To).
    private var commandRows: [Row] {
        let byID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        let candidates = commands.map {
            SessionSwitcherMatch.Candidate(id: $0.id, name: $0.title, folder: $0.path.joined(separator: " "),
                                           branch: nil, path: "")
        }
        return SessionSwitcherMatch.rank(query, candidates, recent: [], current: nil)
            .compactMap { byID[$0.id] }.map(Row.command)
    }

    var body: some View {
        let targets = targetRows
        let sessions = sessionRows
        let commands = commandRows
        let rows = targets + sessions + commands
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: branches != nil ? "arrow.triangle.branch" : commandsOnly ? "command" : "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                PaletteField(text: $query,
                             placeholder: branches != nil ? "Go to a branch, a worktree or a pull request"
                                : commandsOnly ? "Run a command" : "Go to a session or run a command",
                             submit: { activate(rows) },
                             cancel: cancel,
                             move: { move($0, in: rows.count) == .handled })
                    .frame(height: 28)
            }
            .padding(.horizontal, 18)
            .frame(height: Self.fieldHeight)

            if !rows.isEmpty {
                Divider().opacity(0.6)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(targetGroups(targets), id: \.offset) { group in
                                section(group.title, rows: group.rows, offset: group.offset)
                            }
                            section(sessions.isEmpty ? nil : (query.isEmpty ? "Recent" : "Sessions"),
                                    rows: sessions, offset: targets.count)
                            section(commands.isEmpty || commandsOnly ? nil : "Commands",
                                    rows: commands, offset: targets.count + sessions.count)
                        }
                        .padding(Self.listPadding)
                    }
                    .scrollIndicators(.never)
                    .frame(height: listHeight(sessions: sessions.count, commands: commands.count,
                                              targetHeaders: targetGroups(targets).filter { $0.title != nil }.count,
                                              targets: targets.count))
                    .onChange(of: highlighted) { _, index in
                        highlightedID = rows[safe: index]?.id
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(rows[safe: index]?.id) }
                    }
                    .onChange(of: rows.map(\.id)) { _, ids in
                        if let id = highlightedID, let index = ids.firstIndex(of: id), index != highlighted {
                            highlighted = index
                        }
                    }
                }
                SwitcherFooter()
                    .frame(height: Self.footerHeight)
            } else if !query.isEmpty || branches != nil {
                Divider().opacity(0.6)
                Text(query.isEmpty ? "No worktrees yet. Type a branch, or a pull request\u{2019}s number."
                     : branches?.inputs.hasRepository == false
                        ? "Not in a repository: nothing here has branches."
                        : "Nothing matches \u{201c}\(query)\u{201d}")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.emptyHeight)
            }
        }
        .frame(width: Self.width)
        // Its own height, whatever the window's, measured once laid out and
        // handed to the window: the window follows the card, never the other
        // way round.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resize($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .onChange(of: query) { _, _ in
            highlighted = 0
            highlightedID = nil
        }
    }

    /// A titled group of rows; `offset` is where its rows start in the one
    /// list the keys walk.
    @ViewBuilder
    private func section(_ title: String?, rows: [Row], offset: Int) -> some View {
        if let title {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: Self.headerHeight, alignment: .bottom)
                .padding(.bottom, 2)
        }
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            let position = offset + index
            Group {
                switch row {
                case .session(let candidate):
                    SwitcherRow(candidate: candidate,
                                session: manager.sessions.first { $0.id == candidate.id },
                                isHighlighted: position == highlighted,
                                isCurrent: candidate.id == manager.selectedID)
                case .command(let command):
                    CommandRow(command: command, isHighlighted: position == highlighted)
                case .target(let choice):
                    TargetRow(choice: choice, isHighlighted: position == highlighted)
                }
            }
            .id(row.id)
            .onTapGesture { activateRow(row) }
            .onHover { if $0 { highlighted = position } }
        }
    }

    /// Open Branch's rows in their groups, each with where it starts.
    private func targetGroups(_ rows: [Row]) -> [(title: String?, rows: [Row], offset: Int)] {
        var groups: [(title: String?, rows: [Row], offset: Int)] = []
        var last: OpenTarget.Group?
        for (index, row) in rows.enumerated() {
            guard case .target(let choice) = row else { continue }
            if choice.group != last {
                groups.append((choice.group.title, [], index))
                last = choice.group
            }
            groups[groups.count - 1].rows.append(row)
        }
        return groups
    }

    /// Room for up to eight rows, and the section titles among them.
    private func listHeight(sessions: Int, commands: Int, targetHeaders: Int = 0, targets: Int = 0) -> CGFloat {
        let headers = (sessions > 0 ? 1 : 0) + (commands > 0 && !commandsOnly ? 1 : 0) + targetHeaders
        let rows = min(sessions + commands + targets, Self.visibleRows)
        return CGFloat(rows) * Self.rowHeight + CGFloat(headers) * (Self.headerHeight + 2) + Self.listPadding * 2
    }

    private func activate(_ rows: [Row]) {
        guard let row = rows[safe: highlighted] else { return }
        activateRow(row)
    }

    private func activateRow(_ row: Row) {
        switch row {
        case .session(let candidate): pick(candidate.id)
        case .command(let command): run(command)
        case .target(let choice):
            open(choice.action, NSApp.currentEvent?.modifierFlags.contains(.option) == true)
        }
    }

    private func move(_ offset: Int, in count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = (highlighted + offset + count) % count
        return .handled
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One command: its menu's icon, its title and the menus it's in, and its
/// shortcut, so the palette teaches the keys as it's used.
private struct CommandRow: View {
    let command: PaletteCommand
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Color.white.opacity(0.22) : Color.primary.opacity(0.07))
                Group {
                    if let image = command.image {
                        Image(nsImage: image).renderingMode(.template)
                    } else {
                        Image(systemName: "command")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(command.path.joined(separator: " \u{203A} "))
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHighlighted ? Color.accentColor : .clear))
    }
}

/// One session: a tile with its status, its name, and where it is. The one
/// the keys are on takes the accent, with white text, as Spotlight's does.
private struct SwitcherRow: View {
    let candidate: SessionSwitcherMatch.Candidate
    let session: Session?
    let isHighlighted: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Color.white.opacity(0.22) : Color.primary.opacity(0.07))
                // The sidebar's own vocabulary, so a session reads the same in
                // both places: the kinds that pulse there pulse here, and a
                // working one shows the working dots.
                if let kind = session?.attention {
                    AttentionDot(color: SessionStatusIndicator.attentionColor(kind),
                                 motion: kind.pulses ? .pulse : .still)
                } else if session?.isBusy == true {
                    WorkingIndicator()
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Text("Current")
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHighlighted ? Color.accentColor : .clear))
    }

    /// "Wortel · ~/Developer/wortel", "networth · worktree/pre-post".
    private var location: String {
        [candidate.folder, candidate.branch ?? candidate.path].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One row of Open Branch: what it is, and what Return does.
private struct TargetRow: View {
    let choice: OpenTarget.Choice
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Color.white.opacity(0.22) : Color.primary.opacity(0.07))
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text([choice.branch, choice.status].compactMap { $0 }.joined(separator: " \u{00b7} "))
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if case .create = choice.action, isHighlighted {
                Text("\u{2325}\u{21a9} from\u{2026}")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .help("Option-Return: pick the branch it starts from")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHighlighted ? Color.accentColor : .clear))
    }

    private var glyph: String {
        switch choice.action {
        case .goTo: return "terminal"
        case .restore: return "archivebox"
        case .openWorktree, .checkOut: return "arrow.triangle.branch"
        case .mainCheckout: return "folder"
        case .pullRequest: return "arrow.triangle.pull"
        case .create: return "plus"
        }
    }
}

/// The keys, quietly, along the bottom.
private struct SwitcherFooter: View {
    var body: some View {
        HStack(spacing: 16) {
            key("↑↓", "to move")
            key("↩", "to open")
            key("esc", "to close")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    private func key(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(symbol)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(height: 17)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }
}

/// The palette's field: an AppKit text field, for the two things SwiftUI's
/// wouldn't do reliably. It takes the keyboard the moment the palette is on
/// screen (a `@FocusState` set on appear sometimes asked before the panel was
/// key, and typing went nowhere), and its text sits in the same place
/// whether it's being edited or not (SwiftUI's moved a point as editing
/// began, when the field editor took over from the cell's drawing).
private struct PaletteField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let submit: () -> Void
    let cancel: () -> Void
    /// Up or down a row; true if there was somewhere to go.
    let move: (Int) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.cell = CenteredTextFieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.stringValue = text
        Self.focus(field, attemptsLeft: 20)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    /// Into the field as soon as its window can take the keyboard: a few
    /// turns of patience while the panel comes up.
    private static func focus(_ field: NSTextField, attemptsLeft: Int) {
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            if let window = field.window, window.isKeyWindow {
                if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
                return
            }
            guard attemptsLeft > 0 else { return }
            focus(field, attemptsLeft: attemptsLeft - 1)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteField
        init(_ parent: PaletteField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): return parent.move(1)
            case #selector(NSResponder.moveUp(_:)): return parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.cancel()
                return true
            default:
                return false
            }
        }
    }
}

/// A text cell whose text is centred vertically, and in the same place when
/// the field editor takes over for editing: the default draws the idle text
/// and the editor's at slightly different heights, and the text jumps.
///
/// Its editor draws no background either. AppKit's shared field editor paints
/// white while it edits, which on a field over the sidebar's material (the
/// rename) is a white box, and set up here it's clear from the first frame
/// rather than cleared a frame or two in.
final class CenteredTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        editor.drawsBackground = false
        return editor
    }

    /// The clip view AppKit wraps a scrolling field's editor in paints a
    /// background of its own, too.
    private func clearEditorBackground(_ textObj: NSText) {
        textObj.drawsBackground = false
        (textObj.superview as? NSClipView)?.drawsBackground = false
    }

    private func centred(_ rect: NSRect) -> NSRect {
        let height = cellSize(forBounds: rect).height
        guard height < rect.height else { return rect }
        return NSRect(x: rect.minX, y: rect.minY + ((rect.height - height) / 2).rounded(),
                      width: rect.width, height: height)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centred(super.drawingRect(forBounds: rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centred(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
        clearEditorBackground(textObj)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centred(rect), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
        clearEditorBackground(textObj)
    }
}
