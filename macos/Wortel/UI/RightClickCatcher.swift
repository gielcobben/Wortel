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

// MARK: - Native press

/// The same trick again, for a control that should act the instant you press it
/// rather than when you let go — a disclosure triangle, which is what every
/// outline view on the platform does (including Wortel's own sidebar headers,
/// see `SidebarOutline.headerPressed`).
///
/// A SwiftUI `Button` fires on mouse-*up*, and only if the up lands back inside
/// the target. On a 12pt-wide chevron that is a coin flip with a trackpad: press,
/// drift two points, release — nothing happened, and the row underneath doesn't
/// even select, because the button swallowed the click. That reads as "I have to
/// click these twice". Claiming the press directly removes both halves of the
/// problem: it acts immediately, and there is no release to miss.
struct PressCatcher: NSViewRepresentable {
    let onPress: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onPress = onPress
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onPress = onPress
    }

    final class CatcherView: NSView {
        var onPress: () -> Void = {}

        override func mouseDown(with event: NSEvent) { onPress() }

        /// Claims the first click of a press and nothing else — hover, drags,
        /// right-clicks and the second click of a double all fall through to the
        /// row beneath, which owns them.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let event = NSApp.currentEvent
            guard event?.type == .leftMouseDown, event?.clickCount == 1,
                  let local = superview.map({ convert(point, from: $0) }),
                  bounds.contains(local)
            else { return nil }
            return self
        }
    }
}

// MARK: - Native row clicks (select, double-click, drag)

/// One AppKit view that owns everything the left mouse does to a row: selecting,
/// double-clicking to open, and dragging the row's file out.
///
/// It exists because those three cannot be split between SwiftUI and AppKit on
/// the same row. `.onDrag` starts tracking the mouse on the first click and
/// **swallows the second**, so a double-click never reaches either a tap gesture
/// or an overlay that decides by reading `NSApp.currentEvent.clickCount` —
/// measured, the click counts a row sees go 1, 1, 1, 3, 4, never 2, which is why
/// double-clicking did nothing and four fast clicks worked. Owning the whole
/// gesture is the only way the second click survives.
///
/// The same conclusion the sidebar reached for its own rows, where a native
/// `doubleAction` replaced `.onTapGesture(count: 2)`.
struct RowClickCatcher: NSViewRepresentable {
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    /// Dragged out when the row is dragged — the terminal accepts a `.fileURL`
    /// and inserts the shell-escaped path.
    let url: URL

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        configure(view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { configure(view) }

    private func configure(_ view: CatcherView) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.url = url
    }

    final class CatcherView: NSView, NSDraggingSource {
        var onClick: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        var url = URL(fileURLWithPath: "/")
        private var mouseDownEvent: NSEvent?

        /// Claims the left button and nothing else: right-clicks and hover fall
        /// through to the row beneath, which still owns those.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .leftMouseDown,
                  let local = superview.map({ convert(point, from: $0) }),
                  bounds.contains(local)
            else { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            // Act on the way down, like every outline view on the platform. The
            // select fires for both clicks of a double, which is what makes the
            // row highlight before the window appears.
            onClick()
            if event.clickCount == 2 { onDoubleClick() }
        }

        /// Past a few points of movement this is a drag, not a click.
        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy > 9 else { return }
            mouseDownEvent = nil

            // A small icon under the pointer, not the row's whole width — a
            // 32pt icon stretched across a 300pt frame is what you get for
            // passing `bounds` here.
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let size = NSSize(width: 32, height: 32)
            let origin = convert(down.locationInWindow, from: nil)
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(
                NSRect(x: origin.x - size.width / 2, y: origin.y - size.height / 2,
                       width: size.width, height: size.height),
                contents: icon)
            beginDraggingSession(with: [item], event: down, source: self)
        }

        override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}
