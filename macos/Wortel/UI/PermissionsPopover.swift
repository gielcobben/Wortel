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
    }
}

private struct PermissionsView: View {
    private var permissions: Permissions { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                detail: "Lets what you run in a session read any folder, like Mail's and Safari's, without asking for each one.",
                optional: true,
                state: permissions.fullDiskAccess,
                fix: { permissions.fixFullDiskAccess() })
            Divider()
            Text("Anything else, like the camera or the microphone, is asked for by the program that needs it, when it needs it.")
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
    let fix: () -> Void

    private var granted: Bool { state == .granted }

    /// Green once it's on; orange while something Wortel depends on is off;
    /// grey for an optional one that's off, which is a choice, not a problem.
    private var tint: Color {
        if granted { return .green }
        if state == .unknown { return .secondary }
        return optional ? .secondary : .orange
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
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
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        if granted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.white, .green)
                .accessibilityLabel("Granted")
        } else if state != .unknown || optional {
            Button("Grant", action: fix)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}
