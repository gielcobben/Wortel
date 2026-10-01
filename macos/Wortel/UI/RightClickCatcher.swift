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
/// A view that shows it's the one a context menu is about while the menu is
/// open (a sidebar row keeps its highlight, as Finder's and Mail's do).
@MainActor
protocol ContextMenuHost: AnyObject {
    func contextMenu(isOpen: Bool)
}

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
            let host = sequence(first: self as NSView, next: { $0.superview })
                .lazy.compactMap { $0 as? ContextMenuHost }.first
            host?.contextMenu(isOpen: true)
            NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
            host?.contextMenu(isOpen: false)
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
    /// A row's file drag, as it goes: so the window can offer the same landing
    /// spots a dragged tab gets (TabDragController.handleFileDrag) on top of
    /// everything that takes a file anyway (a terminal types its path).
    enum FileDragPhase {
        case began
        case moved
        /// `accepted`: something took the drop itself (a terminal, the Finder,
        /// another app), so it isn't a tab row's.
        case ended(accepted: Bool)
    }

    /// Set by the window's split view, which owns the tab drag controller.
    /// Points are in the dragging row's window.
    @MainActor static var onFileDrag: ((FileDragPhase, [URL], NSWindow, NSPoint) -> Void)?

    /// Called with the click's modifiers, because a list selection is a different
    /// gesture with ⌘ or ⇧ held and only the view that owns the click can tell.
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    /// Dragged out when the row is dragged — the terminal accepts `.fileURL`s and
    /// inserts the shell-escaped paths, space-separated. A closure rather than a
    /// value because a multi-row selection drags all of it, and what that is has
    /// to be read when the drag starts rather than when the row was last drawn.
    let urls: () -> [URL]

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        configure(view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { configure(view) }

    private func configure(_ view: CatcherView) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.urls = urls
    }

    final class CatcherView: NSView, NSDraggingSource {
        var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
        var onDoubleClick: () -> Void = {}
        var urls: () -> [URL] = { [] }
        private var mouseDownEvent: NSEvent?
        /// What this drag carries, for its later phases.
        private var draggedURLs: [URL] = []

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
            onClick(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            if event.clickCount == 2 { onDoubleClick() }
        }

        /// Past a few points of movement this is a drag, not a click.
        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent else { return }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy > 9 else { return }
            mouseDownEvent = nil

            let dragged = urls()
            guard !dragged.isEmpty else { return }

            // A small icon under the pointer, not the row's whole width — a
            // 32pt icon stretched across a 300pt frame is what you get for
            // passing `bounds` here. Several files stack on that same spot,
            // which is what the Finder does with a multi-file drag.
            let size = NSSize(width: 32, height: 32)
            let origin = convert(down.locationInWindow, from: nil)
            let frame = NSRect(x: origin.x - size.width / 2, y: origin.y - size.height / 2,
                               width: size.width, height: size.height)
            let items = dragged.map { url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                item.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            draggedURLs = dragged
            let session = beginDraggingSession(with: items, event: down, source: self)
            // Dropped on a tab row or a pane, nothing *accepts* it (the window
            // opens it, see `onFileDrag`), and the icon flying back to the row
            // would say the opposite of what just happened.
            session.animatesToStartingPositionsOnCancelOrFail = false
        }

        override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            report(.began, at: screenPoint)
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            report(.moved, at: screenPoint)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            report(.ended(accepted: operation != []), at: screenPoint)
            draggedURLs = []
        }

        private func report(_ phase: FileDragPhase, at screenPoint: NSPoint) {
            guard let window, !draggedURLs.isEmpty else { return }
            RowClickCatcher.onFileDrag?(phase, draggedURLs, window, window.convertPoint(fromScreen: screenPoint))
        }
    }
}
