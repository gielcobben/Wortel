import AppKit

/// What resting on a tab shows: its whole title, and where it is (a file's
/// path, a browser's address, a terminal's folder). A tab row shrinks long
/// titles to fit, and this is where they're read in full.
///
/// A card under the tab rather than a tooltip: a tooltip takes a second and a
/// half, shows one line, and starts over for every tab. This one comes after
/// half a second, and once it's up, moving along the row moves it with you
/// at once, as Safari's tab previews do. A click on the tab, or leaving it,
/// puts it away.
@MainActor
final class TabHoverCard {
    static let shared = TabHoverCard()

    private static let delay: TimeInterval = 0.5
    /// How long after one card goes the next comes at once: long enough to
    /// cross the gap between two tabs.
    private static let grace: TimeInterval = 0.4
    private static let maxWidth: CGFloat = 360

    private var panel: NSPanel?
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private weak var anchor: NSView?
    /// A tab that was clicked: no card for it until the pointer leaves it.
    private weak var suppressed: NSView?
    private var timer: Timer?
    private var hiddenAt: Date = .distantPast

    private var isShown: Bool { panel?.isVisible ?? false }

    /// The pointer came to rest on a tab.
    func enter(_ view: NSView, title: String, detail: String?) {
        guard view !== suppressed else { return }
        anchor = view
        timer?.invalidate()
        let content = (title, detail)
        if isShown || Date().timeIntervalSince(hiddenAt) < Self.grace {
            show(content, under: view)
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, self.anchor === view else { return }
                    self.show(content, under: view)
                }
            }
        }
    }

    /// The pointer left a tab, or the tab went away.
    func exit(_ view: NSView) {
        if suppressed === view { suppressed = nil }
        guard anchor === view else { return }
        anchor = nil
        timer?.invalidate()
        hide()
    }

    /// The tab was clicked or dragged: the card is in the way now.
    func dismiss(_ view: NSView) {
        suppressed = view
        anchor = nil
        timer?.invalidate()
        if isShown { panel?.orderOut(nil) }
        hiddenAt = .distantPast
    }

    private func hide() {
        guard isShown else { return }
        panel?.parent?.removeChildWindow(panel!)
        panel?.orderOut(nil)
        hiddenAt = Date()
    }

    private func show(_ content: (title: String, detail: String?), under view: NSView) {
        guard let window = view.window, view.superview != nil else { return }
        let panel = self.panel ?? makePanel()
        titleLabel.stringValue = content.title
        detailLabel.stringValue = content.detail ?? ""
        detailLabel.isHidden = content.detail == nil

        let inset: CGFloat = 10
        let width = min(Self.maxWidth,
                        max(titleLabel.cellSize(forWidth: Self.maxWidth),
                            content.detail == nil ? 0 : detailLabel.cellSize(forWidth: Self.maxWidth)))
        let titleHeight = titleLabel.cellSize(forWidth: width, height: true)
        let detailHeight = content.detail == nil ? 0 : detailLabel.cellSize(forWidth: width, height: true)
        let spacing: CGFloat = content.detail == nil ? 0 : 2
        let size = NSSize(width: ceil(width) + inset * 2,
                          height: ceil(titleHeight + spacing + detailHeight) + 8 * 2)
        titleLabel.frame = NSRect(x: inset, y: size.height - 8 - titleHeight,
                                  width: ceil(width), height: titleHeight)
        detailLabel.frame = NSRect(x: inset, y: 8, width: ceil(width), height: detailHeight)

        // Under the tab, its left edge, kept on the screen.
        let tab = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: tab.minX, y: tab.minY - 6 - size.height)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        panel.contentView = background

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byCharWrapping
        for label in [titleLabel, detailLabel] {
            label.isSelectable = false
            label.translatesAutoresizingMaskIntoConstraints = true
            background.addSubview(label)
        }
        self.panel = panel
        return panel
    }
}

private extension NSTextField {
    /// The width this label wants on one line, up to `limit`; or, with
    /// `height`, how tall it is at `width`.
    func cellSize(forWidth width: CGFloat, height: Bool = false) -> CGFloat {
        let size = cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)) ?? .zero
        return height ? ceil(size.height) : ceil(size.width)
    }
}
