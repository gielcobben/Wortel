import AppKit
import SwiftUI

// MARK: - Native right-click

/// A transparent AppKit overlay that owns a row's right-click: it runs a side
/// effect (e.g. select the row) and pops a freshly-built menu. It's invisible to
/// every other event — `hitTest` only claims right-mouse events, so SwiftUI
/// keeps left-clicks and hover. This avoids SwiftUI's `.contextMenu`, which
/// presents on a press-hold rather than instantly and rebuilds its content
/// closure on every render — the reason it feels laggy inside a hosted cell.
///
/// Shared by the git panel's changed-file rows and the sidebar's session/folder
/// rows.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
        view.makeMenu = makeMenu
    }

    final class CatcherView: NSView {
        var onRightClick: () -> Void = {}
        var makeMenu: () -> NSMenu = { NSMenu() }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick()
            NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
        }

        // Participate only in right-clicks; let clicks and hover fall through to
        // the SwiftUI content beneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? self : nil
        }
    }
}

/// An `NSMenuItem` that runs a closure when chosen, so a menu can be built
/// inline without a separate target/selector object.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
