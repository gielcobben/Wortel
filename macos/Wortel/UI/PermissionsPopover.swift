import AppKit
import SwiftUI

/// The sidebar's word about permissions, beside +, ⓘ and the update icon and
/// drawn like them. There only while something Wortel depends on is off (an
/// orange dot on a raised hand, Privacy's own symbol in System Settings), and
/// while its popover is open from the Wortel menu, so it has something to hang
/// off. Everything granted, it is gone: a permanent icon for a state that is
/// fine would be furniture.
struct PermissionsIndicator: View {
    private var permissions: Permissions { .shared }

    var body: some View {
        if permissions.needsAttention || permissions.revealed {
            PermissionsButton(attention: permissions.needsAttention)
                .frame(width: 24, height: 24)
        }
    }
}

/// AppKit, as the ⓘ and the update icon are, so the popover can hang off the
/// real button.
struct PermissionsButton: NSViewRepresentable {
    let attention: Bool

    func makeNSView(context: Context) -> BadgedGlyphButton {
        let button = BadgedGlyphButton()
        button.setGlyph(NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Permissions")?
            .withSymbolConfiguration(SidebarBarButton.glyph))
        button.setAccessibilityLabel("Permissions")
        button.toolTip = "Permissions"
        button.target = PermissionsNotice.shared
        button.action = #selector(PermissionsNotice.clicked(_:))
        PermissionsNotice.shared.register(anchor: button)
        return button
    }

    func updateNSView(_ button: BadgedGlyphButton, context: Context) {
        button.dotColor = attention ? .systemOrange : nil
    }
}

/// The popover the permissions icon opens, from a click on it or from
/// Wortel ▸ Permissions…. Transient, as the update popover is: it's only ever
/// opened on purpose, so it can close on a click elsewhere like any popover.
@MainActor
final class PermissionsNotice: NSObject, NSPopoverDelegate {
    static let shared = PermissionsNotice()
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

    /// From the menu: bring the icon out if everything is fine and it's
    /// hidden, then open on it once SwiftUI has laid it out.
    func showFromMenu() {
        if let popover, popover.isShown { return }
        Permissions.shared.revealed = true
        Permissions.shared.refresh()
        showWhenAnchored(retries: 5)
    }

    private func showWhenAnchored(retries: Int) {
        if let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor, !anchor.visibleRect.isEmpty {
            show()
            return
        }
        guard retries > 0 else {
            // The sidebar is collapsed: nowhere to point from.
            Permissions.shared.revealed = false
            NSSound.beep()
            return
        }
        DispatchQueue.main.async { self.showWhenAnchored(retries: retries - 1) }
    }

    private func show() {
        guard let anchor else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PermissionsView())
        self.popover = popover
        responder = anchor.window?.firstResponder
        Permissions.shared.refresh()
        Permissions.shared.lookForAgent()
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
        Permissions.shared.revealed = false
        Permissions.shared.popoverClosed()
    }

    /// Put away before something is typed into a terminal: the keyboard goes
    /// back to it in `popoverDidClose`, and the typing comes after.
    func close() {
        // At once, not after the fade: what is typed next must find the
        // keyboard already back with the terminal.
        popover?.animates = false
        popover?.close()
    }
}

private struct PermissionsView: View {
    private var permissions: Permissions { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // What a new Mac lacks that is not a permission, each only while
            // it is missing: on a Mac that has both, this section is not here.
            if permissions.needsSetup {
                Text("Setup")
                    .font(.system(size: 13, weight: .semibold))
                if permissions.agent == .denied {
                    PermissionRow(
                        symbol: "terminal",
                        title: "An agent",
                        detail: "Pick one and its install command is typed for you to run.",
                        optional: false,
                        state: permissions.agent,
                        action: "Install",
                        choices: AgentInstall.offered.map { agent in
                            PermissionRow.Choice(title: agent.name) {
                                PermissionsNotice.shared.close()
                                // After the popover has handed the keyboard back.
                                DispatchQueue.main.async { permissions.offerCommand?(agent.line) }
                            }
                        },
                        fix: {})
                }
                if permissions.developerTools == .denied {
                    PermissionRow(
                        symbol: "arrow.triangle.branch",
                        title: "Git",
                        detail: permissions.gitNeedsReset
                            ? "macOS points at developer tools that are gone. The fix is typed for you."
                            : "For worktrees, Changes and History. Part of Apple\u{2019}s command line tools.",
                        optional: false,
                        state: permissions.developerTools,
                        action: permissions.gitNeedsReset ? "Fix" : "Install\u{2026}",
                        fix: {
                            guard permissions.gitNeedsReset else { return permissions.fixDeveloperTools() }
                            PermissionsNotice.shared.close()
                            // After the popover has handed the keyboard back.
                            DispatchQueue.main.async { permissions.fixDeveloperTools() }
                        })
                }
                Divider()
            }
            Text("Permissions")
                .font(.system(size: 13, weight: .semibold))
            PermissionRow(
                symbol: "bell.badge",
                title: "Notifications",
                detail: "Tells you when an agent needs you, with a banner, a sound and the Dock badge.",
                optional: false,
                state: permissions.notifications,
                fix: { permissions.fixNotifications() })
            PermissionRow(
                symbol: "internaldrive",
                title: "Full Disk Access",
                detail: "Lets what you run read any folder, like Mail\u{2019}s, without asking each time.",
                optional: true,
                state: permissions.fullDiskAccess,
                fix: { permissions.fixFullDiskAccess() })
            Divider()
            Text("Anything else, like the camera or the microphone, is asked for by the program that needs it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let optional: Bool
    let state: Permissions.State
    var action = "Grant"
    /// More than one way to fix it: the button becomes a pull-down of these.
    var choices: [Choice] = []
    let fix: () -> Void

    struct Choice: Identifiable {
        let title: String
        let pick: () -> Void
        var id: String { title }
    }

    private var granted: Bool { state == .granted }

    /// Green once it's on; orange while something Wortel depends on is off;
    /// grey for an optional one that's off, which is a choice, not a problem.
    private var tint: Color {
        if granted { return .green }
        if state == .unknown { return .secondary }
        return optional ? .secondary : .orange
    }

    var body: some View {
        // One line that says what it is and holds its button, then what it
        // is for under it, across the whole width.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    // From the same left edge as the line under it.
                    .frame(width: 22, alignment: .leading)
                Text(title)
                    .font(.system(size: 13))
                if optional {
                    Text("Optional")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer(minLength: 8)
                trailing
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // Stops short of the buttons' column, the same in every row
                // whatever its button's width: the text has one right edge
                // and each button has air under it. The details are written
                // to fit two lines at this width.
                .padding(.trailing, Self.buttonColumn)
        }
    }

    /// The widest button (the agent menu) and the gap before it.
    private static let buttonColumn: CGFloat = 80

    @ViewBuilder private var trailing: some View {
        if granted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white, .green)
                .accessibilityLabel("Granted")
        } else if !choices.isEmpty {
            Menu(action) {
                ForEach(choices) { choice in
                    Button(choice.title, action: choice.pick)
                }
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)
            .fixedSize()
        } else if state != .unknown || optional {
            Button(action, action: fix)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}
