import AppKit
import SwiftUI

/// The sidebar's word about an agent that is out of date, beside +, ⓘ, the
/// update icon and the permissions icon, and drawn like them. There only
/// while an agent that can report what it is doing is running in a version
/// that does not (`Session.silentAgent`): an orange warning triangle, and a
/// click opens a popover that says which agent, which version it needs, and
/// where its release notes are. The agent updated and started again, it is
/// gone.
///
/// It was a grey line under the session's name first. That read as disabled,
/// was cut off at the sidebar's width, and a row's second line is for a branch
/// or a reminder (`DESIGN.md`). This is where Wortel already says "there is an
/// update for you", for itself.
struct AgentUpdateIndicator: View {
    /// The agents to name, by their marker's name (`SessionManager.silentAgents`).
    let agents: [String]

    var body: some View {
        let reporters = agents.compactMap { ReportedStatus.knownReporters[$0] }
        if !reporters.isEmpty {
            AgentUpdateButton(reporters: reporters)
                .frame(width: 24, height: 24)
        }
    }
}

/// AppKit, as the bar's other icons are, so the popover can hang off the real
/// button.
struct AgentUpdateButton: NSViewRepresentable {
    let reporters: [ReportedStatus.Reporter]

    /// A point under the bar's other glyphs (`SidebarBarButton.glyph`, 13pt),
    /// so it is as wide as they are: at 13pt this symbol measures 17 by 15
    /// against the circles' 15 by 15, and at 12pt it is 15 by 14.
    static let glyph = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

    func makeNSView(context: Context) -> BadgedGlyphButton {
        let button = BadgedGlyphButton()
        button.setGlyph(NSImage(systemSymbolName: "exclamationmark.triangle",
                                accessibilityDescription: "Agent out of date")?
            .withSymbolConfiguration(Self.glyph))
        // Orange, the colour for "needs you": the one icon in the bar that
        // is a warning, so it is tinted and not only dotted.
        button.contentTintColor = .systemOrange
        button.target = AgentUpdateNotice.shared
        button.action = #selector(AgentUpdateNotice.clicked(_:))
        AgentUpdateNotice.shared.register(anchor: button)
        return button
    }

    func updateNSView(_ button: BadgedGlyphButton, context: Context) {
        AgentUpdateNotice.shared.reporters = reporters
        // Setting a tooltip registers it again: only when the words change.
        let words = AgentUpdateWords.tooltip(for: reporters)
        if button.toolTip != words {
            button.toolTip = words
            button.setAccessibilityLabel(words)
        }
    }
}

/// The popover the icon opens. Transient, as the update and permissions
/// popovers are: opened only on purpose, closed by a click elsewhere.
@MainActor
final class AgentUpdateNotice: NSObject, NSPopoverDelegate {
    static let shared = AgentUpdateNotice()
    /// What the popover lists: kept current by the button as agents come and go.
    var reporters: [ReportedStatus.Reporter] = []
    private var popover: NSPopover?
    private weak var anchor: HoverFillButton?
    /// Whoever had the keyboard (the terminal), given it back on close.
    private weak var responder: NSResponder?
    /// See `UpdateNotice.closedAt`: the click on the icon that closes the
    /// popover must not open it again.
    private var closedAt = Date.distantPast

    func register(anchor: HoverFillButton) { self.anchor = anchor }

    @objc func clicked(_ sender: NSButton) {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        guard Date().timeIntervalSince(closedAt) > 0.3 else { return }
        show()
    }

    /// From a session's menu ("Update Pi…"): the same popover, on the bar's
    /// icon. With the sidebar hidden there is no icon to hang it off, so the
    /// agent's release notes open instead: the item must not be a dead end
    /// from the titlebar's menu either.
    func showFromMenu(for reporter: ReportedStatus.Reporter) {
        if let popover, popover.isShown { return }
        guard let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor,
              !anchor.visibleRect.isEmpty, !reporters.isEmpty else {
            NSWorkspace.shared.open(reporter.notes)
            return
        }
        show()
    }

    private func show() {
        guard let anchor, !reporters.isEmpty else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: AgentUpdateView(
            reporters: reporters,
            open: { [weak self] url in
                self?.popover?.close()
                NSWorkspace.shared.open(url)
            }))
        self.popover = popover
        responder = anchor.window?.firstResponder
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        anchor.isSelected = true
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        if let window = anchor?.window, let responder {
            window.makeKey()
            window.makeFirstResponder(responder)
        }
        anchor?.isSelected = false
        responder = nil
        popover = nil
    }
}

/// What the icon and its popover say. Apart from the views, so the sentences
/// can be read in one place.
enum AgentUpdateWords {
    /// "Codex", "Codex and Pi", "Codex, Pi and opencode".
    static func names(_ reporters: [ReportedStatus.Reporter]) -> String {
        let names = reporters.map(\.name)
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    static func tooltip(for reporters: [ReportedStatus.Reporter]) -> String {
        "\(names(reporters)) \(reporters.count == 1 ? "is" : "are") out of date"
    }

    static func title(for reporters: [ReportedStatus.Reporter]) -> String {
        "Update \(names(reporters))"
    }

    /// The item in a session's menu, and in the Session menu.
    static func menuItem(for reporter: ReportedStatus.Reporter) -> String {
        "Update \(reporter.name)\u{2026}"
    }

    static let menuGlyph = "exclamationmark.triangle"

    static func explanation(for reporters: [ReportedStatus.Reporter]) -> String {
        reporters.count == 1
            ? "This version doesn't tell Wortel what it is doing, so there is no sign of it working, finishing or waiting for you."
            : "These versions don't tell Wortel what they are doing, so there is no sign of them working, finishing or waiting for you."
    }

    /// What a session's row says about it, on hover.
    static func row(for reporter: ReportedStatus.Reporter) -> String {
        "\(reporter.name) is out of date, so Wortel can't tell what it is doing here."
    }
}

/// One column, one left edge: the title, what it means, then a line per
/// agent with the version it needs and where to read about it. Laid out as
/// the app's own update popover is (`UpdateNoticeView`).
private struct AgentUpdateView: View {
    let reporters: [ReportedStatus.Reporter]
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AgentUpdateWords.title(for: reporters))
                    .font(.system(size: 13, weight: .semibold))
                Text(AgentUpdateWords.explanation(for: reporters))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ForEach(reporters, id: \.name) { reporter in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reporter.name)
                            .font(.system(size: 13))
                        Text("Version \(reporter.since) or later")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    Spacer(minLength: 12)
                    Button("Release Notes") { open(reporter.notes) }
                        .controlSize(.small)
                }
            }
            Divider()
            Text("After updating, quit the agent and start it again.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
    }
}
