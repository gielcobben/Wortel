import AppKit

/// A glimpse of what's in a tab, for its hover card.
enum TabPreview {
    /// Lines of text: a terminal's screen, the top of a file.
    case text(String)
    /// A picture: a web page, as it last looked.
    case image(NSImage)
}

/// What resting on a tab shows: a preview of what's in it (a terminal's last
/// lines, a page, the top of a file), its whole title, and where it is. A tab
/// row shrinks long titles to fit and shows only one tab of each row, and
/// this is where you see the rest without switching.
///
/// A card under the tab rather than a tooltip: a tooltip takes a second and a
/// half, shows one line, and starts over for every tab. This one comes after
/// half a second, and once it's up, moving along the row moves it with you
/// at once, as Safari's tab previews do. A click on the tab, or leaving it,
/// puts it away. What it shows is read when it opens, never ahead of time.
@MainActor
final class TabHoverCard {
    static let shared = TabHoverCard()

    private static let delay: TimeInterval = 0.5
    /// How long after one card goes the next comes at once: long enough to
    /// cross the gap between two tabs.
    private static let grace: TimeInterval = 0.4
    private static let maxWidth: CGFloat = 360
    /// A card with a preview is this wide, whatever its title.
    private static let previewWidth: CGFloat = 300
    private static let previewMaxHeight: CGFloat = 170
    private static let inset: CGFloat = 10

    struct Content {
        let title: String
        let detail: String?
        let preview: () -> TabPreview?
    }

    private var panel: NSPanel?
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let previewBox = NSView()
    private let previewText = NSTextField(labelWithString: "")
    private let previewImage = NSImageView()
    private weak var anchor: NSView?
    /// A tab that was clicked: no card for it until the pointer leaves it.
    private weak var suppressed: NSView?
    private var timer: Timer?
    private var hiddenAt: Date = .distantPast

    private var isShown: Bool { panel?.isVisible ?? false }

    /// The pointer came to rest on a tab.
    func enter(_ view: NSView, _ content: Content) {
        guard view !== suppressed else { return }
        anchor = view
        timer?.invalidate()
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
        if let panel, isShown {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        hiddenAt = .distantPast
    }

    private func hide() {
        guard let panel, isShown else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        hiddenAt = Date()
    }

    private func show(_ content: Content, under view: NSView) {
        guard let window = view.window, view.superview != nil else { return }
        let preview = content.preview()
        // Nothing the tab doesn't already say: no card.
        guard preview != nil || content.detail != nil || content.title != visibleTitle(of: view) else {
            hide()
            return
        }
        let panel = self.panel ?? makePanel()
        titleLabel.stringValue = content.title
        detailLabel.stringValue = content.detail ?? ""
        detailLabel.isHidden = content.detail == nil

        let inset = Self.inset
        let textWidth: CGFloat
        if preview != nil {
            textWidth = Self.previewWidth - inset * 2
        } else {
            textWidth = min(Self.maxWidth, max(titleLabel.measure(width: Self.maxWidth),
                                               content.detail == nil ? 0 : detailLabel.measure(width: Self.maxWidth)))
        }
        let titleHeight = titleLabel.measure(width: textWidth, height: true)
        let detailHeight = content.detail == nil ? 0 : detailLabel.measure(width: textWidth, height: true)
        let previewHeight = layoutPreview(preview, width: textWidth)
        let previewGap: CGFloat = preview == nil ? 0 : 8
        let detailGap: CGFloat = content.detail == nil ? 0 : 1
        let size = NSSize(width: ceil(textWidth) + inset * 2,
                          height: ceil(8 + previewHeight + previewGap + titleHeight + detailGap + detailHeight + 8))

        // Top down: the preview, then the title and where it is.
        var y = size.height - 8
        previewBox.isHidden = preview == nil
        if preview != nil {
            y -= previewHeight
            previewBox.frame = NSRect(x: inset, y: y, width: textWidth, height: previewHeight)
            y -= previewGap
        }
        y -= titleHeight
        titleLabel.frame = NSRect(x: inset, y: y, width: textWidth, height: titleHeight)
        y -= detailGap + detailHeight
        detailLabel.frame = NSRect(x: inset, y: y, width: textWidth, height: detailHeight)

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

    /// Fill the preview box and say how tall it is at `width`.
    private func layoutPreview(_ preview: TabPreview?, width: CGFloat) -> CGFloat {
        switch preview {
        case nil:
            return 0
        case .text(let text)?:
            previewImage.isHidden = true
            previewText.isHidden = false
            previewText.stringValue = text
            let lines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
            let lineHeight = ceil((previewText.font?.boundingRectForFont.height ?? 11))
            let height = min(Self.previewMaxHeight, CGFloat(lines) * lineHeight + 12)
            previewText.frame = NSRect(x: 8, y: 6, width: width - 16, height: height - 12)
            return height
        case .image(let image)?:
            previewText.isHidden = true
            previewImage.isHidden = false
            previewImage.image = image
            let aspect = image.size.width > 0 ? image.size.height / image.size.width : 0.6
            let height = min(Self.previewMaxHeight, max(60, (width * aspect).rounded()))
            previewImage.frame = NSRect(x: 0, y: 0, width: width, height: height)
            return height
        }
    }

    /// The title as the tab shows it, to tell whether it was cut short.
    private func visibleTitle(of view: NSView) -> String? {
        (view as? TabTitleProviding)?.isTitleTruncated == true ? nil : (view as? TabTitleProviding)?.title
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
        background.layer?.cornerRadius = 10
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        panel.contentView = background

        // The preview sits on the page's own colour, as a thumbnail of it.
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 6
        previewBox.layer?.cornerCurve = .continuous
        previewBox.layer?.masksToBounds = true
        previewBox.layer?.borderWidth = 0.5
        previewBox.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        previewBox.layer?.backgroundColor = Chrome.content.cgColor
        previewText.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        previewText.textColor = .secondaryLabelColor
        previewText.lineBreakMode = .byClipping
        previewText.maximumNumberOfLines = 0
        previewText.cell?.wraps = false
        previewText.isSelectable = false
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.imageAlignment = .alignTop
        previewBox.addSubview(previewText)
        previewBox.addSubview(previewImage)
        background.addSubview(previewBox)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingMiddle
        for label in [titleLabel, detailLabel] {
            label.isSelectable = false
            background.addSubview(label)
        }
        self.panel = panel
        return panel
    }
}

/// What the card asks a tab about its title.
@MainActor
protocol TabTitleProviding: AnyObject {
    var title: String { get }
    var isTitleTruncated: Bool { get }
}

private extension NSTextField {
    /// The width this label wants on one line, up to `width`; or, with
    /// `height`, how tall it is at `width`.
    func measure(width: CGFloat, height: Bool = false) -> CGFloat {
        let size = cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)) ?? .zero
        return height ? ceil(size.height) : ceil(size.width)
    }
}

extension TabPreview {
    /// The last lines of a terminal's screen, trailing blank lines dropped.
    static func terminal(_ screen: String?, lines: Int = 14) -> TabPreview? {
        guard let screen else { return nil }
        var rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        guard !rows.isEmpty else { return nil }
        return .text(rows.suffix(lines).joined(separator: "\n"))
    }

    /// The top of a text file; nil for a binary one or one that can't be read.
    static func file(at path: String, lines: Int = 14) -> TabPreview? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192), !data.isEmpty,
              !data.contains(0) else { return nil }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\t", with: "  ")
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lines)
        return .text(rows.joined(separator: "\n"))
    }
}
