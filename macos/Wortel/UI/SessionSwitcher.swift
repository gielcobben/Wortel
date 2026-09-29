import AppKit
import SwiftUI

/// ⌘P: go to a session by typing a few letters of its name, its folder, its
/// branch or its directory. VS Code's, Cursor's and Zed's quick open; ⌘K, the
/// ChatGPT app's, is "clear screen" in a terminal.
///
/// A panel over the top of the window, as Xcode's Open Quickly and Spotlight
/// are: a field, the matches under it (SessionSwitcherMatch), arrows and
/// Return, Escape or a click elsewhere to put it away.
@MainActor
final class SessionSwitcher {
    private let manager: SessionManager
    private var panel: SwitcherPanel?

    init(manager: SessionManager) {
        self.manager = manager
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle(over window: NSWindow) {
        if isShown { close() } else { show(over: window) }
    }

    func show(over window: NSWindow) {
        close()
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: SwitcherView.width, height: 360),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow: the panel is taller than the card,
        // and a window shadow would outline the clear part too.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.onResign = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: SwitcherView(manager: manager, pick: { [weak self] id in
            self?.close()
            self?.manager.selectedID = id
        }, cancel: { [weak self] in self?.close() }))
        // A fixed height, the card pinned to its top: the panel never has to
        // resize as the list shortens, and its top stays put. (Sized from the
        // view's fitting size instead, it opened at no height at all: there,
        // with the keyboard, and invisible.)
        host.sizingOptions = []
        panel.contentView = host
        // A little below the top of the window, centred on it.
        let frame = window.frame
        let height = SwitcherView.maximumHeight
        panel.setFrame(NSRect(x: frame.midX - SwitcherView.width / 2,
                              y: frame.maxY - 90 - height,
                              width: SwitcherView.width, height: height), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.onResign = nil
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Back to the window it was opened over, and its terminal.
        parent?.makeKey()
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

/// The field and the matches.
private struct SwitcherView: View {
    static let width: CGFloat = 520
    private static let visibleRows = 8
    private static let rowHeight: CGFloat = 44
    private static let fieldHeight: CGFloat = 50
    /// The card at its tallest: the field and eight rows.
    static var maximumHeight: CGFloat { fieldHeight + 1 + CGFloat(visibleRows) * rowHeight + 12 + 24 }

    let manager: SessionManager
    let pick: (UUID) -> Void
    let cancel: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var matches: [SessionSwitcherMatch.Candidate] {
        let candidates = manager.sessions.map { session in
            SessionSwitcherMatch.Candidate(
                id: session.id, name: session.leafName, folder: session.folderPath,
                branch: session.worktreeLabel, path: session.abbreviatedPath)
        }
        return SessionSwitcherMatch.rank(query, candidates, recent: manager.recentSessionIDs,
                                         current: manager.selectedID)
    }

    var body: some View {
        let matches = self.matches
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                TextField("Go to session", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { if matches.indices.contains(highlighted) { pick(matches[highlighted].id) } }
                    .onExitCommand(perform: cancel)
                    .onKeyPress(.downArrow) { move(1, in: matches.count) }
                    .onKeyPress(.upArrow) { move(-1, in: matches.count) }
            }
            .padding(.horizontal, 16)
            .frame(height: Self.fieldHeight)
            if !matches.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                                SwitcherRow(candidate: match, session: manager.sessions.first { $0.id == match.id },
                                            isHighlighted: index == highlighted,
                                            isCurrent: match.id == manager.selectedID)
                                    .id(index)
                                    .onTapGesture { pick(match.id) }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(matches.count), CGFloat(Self.visibleRows)) * Self.rowHeight + 12)
                    .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
                }
            } else if !query.isEmpty {
                Divider()
                Text("No session matches \u{201c}\(query)\u{201d}")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color(nsColor: Chrome.hairlineStrong), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        // Top of a panel that's as tall as the card can get; the rest is clear.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func move(_ offset: Int, in count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = (highlighted + offset + count) % count
        return .handled
    }
}

/// One session: its status, its name, and where it is.
private struct SwitcherRow: View {
    let candidate: SessionSwitcherMatch.Candidate
    let session: Session?
    let isHighlighted: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let kind = session?.attention {
                    AttentionDot(color: SessionStatusIndicator.attentionColor(kind),
                                 motion: kind == .needsInput ? .pulse : .still)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(where_)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Text("Current")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isHighlighted ? Color.accentColor.opacity(0.18) : .clear))
    }

    /// "Wortel · ~/Developer/wortel", "networth · worktree/pre-post".
    private var where_: String {
        [candidate.folder, candidate.branch ?? candidate.path].compactMap { $0 }.joined(separator: " · ")
    }
}
