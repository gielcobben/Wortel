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

// MARK: - Native double-click

/// The same trick as `RightClickCatcher`, for double-clicks: an invisible
/// overlay that claims an event only when it is the *second* click of a pair,
/// and is transparent to everything else.
///
/// SwiftUI's `.onTapGesture(count: 2)` is the obvious alternative and the wrong
/// one — it has to wait out the double-click interval before it can rule a
/// single click in, so every single click in the row picks up a visible delay.
/// Reading `clickCount` off the current event needs no such wait: a single click
/// falls straight through to the SwiftUI content and selects immediately, and
/// only the second click of a genuine double is intercepted here.
struct DoubleClickCatcher: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onDoubleClick = onDoubleClick
    }

    final class CatcherView: NSView {
        var onDoubleClick: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else { return }
            onDoubleClick()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let event = NSApp.currentEvent
            guard event?.type == .leftMouseDown, event?.clickCount == 2 else { return nil }
            return self
        }
    }
}
