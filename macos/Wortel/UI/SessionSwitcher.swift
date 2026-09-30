import AppKit
import SwiftUI

/// ⌘P: go to a session by typing a few letters of its name, its folder, its
/// branch or its directory. VS Code's, Cursor's and Zed's quick open; ⌘K, the
/// ChatGPT app's, is "clear screen" in a terminal.
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
    /// Where the card's top sits, in screen coordinates: what stays put as
    /// its height changes.
    private var top: CGFloat = 0

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
            pick: { [weak self] id in
                self?.close()
                self?.manager.selectedID = id
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

/// The field, the matches, and a line of keys.
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
    let pick: (UUID) -> Void
    let cancel: () -> Void
    let resize: (CGFloat) -> Void

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
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Go to session", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onSubmit { if matches.indices.contains(highlighted) { pick(matches[highlighted].id) } }
                    .onExitCommand(perform: cancel)
                    .onKeyPress(.downArrow) { move(1, in: matches.count) }
                    .onKeyPress(.upArrow) { move(-1, in: matches.count) }
            }
            .padding(.horizontal, 18)
            .frame(height: Self.fieldHeight)

            if !matches.isEmpty {
                Divider().opacity(0.6)
                if query.isEmpty {
                    Text("Recent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .frame(height: Self.headerHeight, alignment: .bottom)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                                SwitcherRow(candidate: match,
                                            session: manager.sessions.first { $0.id == match.id },
                                            isHighlighted: index == highlighted,
                                            isCurrent: match.id == manager.selectedID)
                                    .id(index)
                                    .onTapGesture { pick(match.id) }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(Self.listPadding)
                    }
                    .scrollIndicators(.never)
                    .frame(height: CGFloat(min(matches.count, Self.visibleRows)) * Self.rowHeight
                           + Self.listPadding * 2)
                    .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
                }
                SwitcherFooter()
                    .frame(height: Self.footerHeight)
            } else if !query.isEmpty {
                Divider().opacity(0.6)
                Text("No session matches \u{201c}\(query)\u{201d}")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.emptyHeight)
            }
        }
        .frame(width: Self.width)
        // Its own height, whatever the window's, measured once laid out and
        // handed to the window: the window follows the card, never the other
        // way round. (Worked out from row counts, the two disagreed, and the
        // card's top was cut off above a gap under it.)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resize($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func move(_ offset: Int, in count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = (highlighted + offset + count) % count
        return .handled
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
                if let kind = session?.attention {
                    AttentionDot(color: SessionStatusIndicator.attentionColor(kind),
                                 motion: kind == .needsInput ? .pulse : .still)
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
