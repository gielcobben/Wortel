import AppKit

/// What a file tab turns into once it's dragged out of the window: a small
/// window of its own that follows the pointer, so you can see that letting go
/// makes a window, and where it will be. Safari does the same with a tab.
///
/// A borderless panel rather than a drawing in the drag overlay, because the
/// overlay lives inside the main window and is clipped to it, and the whole
/// point is that the pointer has left it. It takes no clicks and never becomes
/// key: the tab strip's own event loop is still tracking the drag.
///
/// Drawn the way a preview window is: the glass with a row on it (traffic
/// lights at rest, the tab itself where the file's name goes) and the file's
/// page under a hairline. Only the shape, not the file: it's a promise of a
/// window, at a size that doesn't cover where you're aiming.
@MainActor
final class TabTearOffGhost {
    static let size = NSSize(width: 300, height: 196)
    private static let rowHeight: CGFloat = 36
    private static let radius: CGFloat = 12

    private let panel: NSPanel
    /// Where the tab sits in the panel, so the pointer keeps hold of the tab
    /// at the very point it grabbed it.
    private let tabOrigin: NSPoint
    private let tabHeight: CGFloat
    private let grab: NSPoint

    /// `tab` is the tab's picture; `grab` where the pointer holds it, from the
    /// picture's bottom-left.
    init(tab: NSImage?, grab: NSPoint, appearance: NSAppearance?) {
        let size = Self.size
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = appearance
        panel.alphaValue = 0

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .sidebar
        glass.blendingMode = .behindWindow
        glass.state = .active
        // A mask image rather than a layer's corner radius: it's what a
        // borderless window's shadow is cut from, so the shadow rounds too.
        glass.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.radius, yRadius: Self.radius).fill()
            return true
        }

        let page = FilledView(color: Chrome.content)
        page.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - Self.rowHeight)
        glass.addSubview(page)
        let line = FilledView(color: Chrome.hairline)
        line.frame = NSRect(x: 0, y: size.height - Self.rowHeight, width: size.width, height: 1)
        glass.addSubview(line)

        // Traffic lights at rest: the window isn't key yet, and colour here
        // would be the only colour on screen.
        for index in 0..<3 {
            let dot = FilledView(color: Chrome.hairlineStrong)
            dot.frame = NSRect(x: 12 + CGFloat(index) * 18,
                               y: size.height - Self.rowHeight / 2 - 5, width: 10, height: 10)
            dot.layer?.cornerRadius = 5
            glass.addSubview(dot)
        }

        let tabSize = tab?.size ?? NSSize(width: 120, height: Chrome.controlSize)
        let origin = NSPoint(x: 66, y: size.height - Self.rowHeight / 2 - tabSize.height / 2)
        if let tab {
            let picture = NSImageView(frame: NSRect(origin: origin, size: tabSize))
            picture.image = tab
            picture.imageScaling = .scaleNone
            glass.addSubview(picture)
        }
        tabOrigin = origin
        tabHeight = tabSize.height
        self.grab = grab
        panel.contentView = glass
    }

    var isShown: Bool { panel.isVisible && panel.alphaValue > 0 }

    /// The ghost's own window: under the pointer, so looked past when asking
    /// what else is there.
    var window: NSWindow { panel }

    /// Follow the pointer, given in screen coordinates.
    func move(to pointer: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: pointer.x - tabOrigin.x - grab.x,
                                     y: pointer.y - tabOrigin.y - grab.y))
    }

    func show() {
        guard !isShown else { return }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.tabs
            panel.animator().alphaValue = 1
        }
    }

    /// Back over the window: the tab is a tab again. Instant, as closing
    /// things is everywhere else in the chrome.
    func hide() {
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    /// Where the real window's top-left goes so it takes the ghost's place:
    /// its file name where the tab's title was, its row's middle where the
    /// tab's middle was, wherever on the tab the pointer holds it.
    func windowTopLeft(for pointer: NSPoint) -> NSPoint {
        // The window's row: traffic lights, the file button, 8pt, the name
        // (PreviewWindowBar). The tab: 10pt in, a 16pt glyph, 8pt, the title
        // (SideTabView).
        let windowNameX = Chrome.trafficLightInset + Chrome.controlSize + 8
        let tabTitleX: CGFloat = 10 + 16 + 8
        let tabLeft = pointer.x - grab.x
        let tabMiddle = pointer.y - grab.y + tabHeight / 2
        return NSPoint(x: tabLeft + tabTitleX - windowNameX,
                       y: tabMiddle + Chrome.titlebarHeight / 2)
    }
}
