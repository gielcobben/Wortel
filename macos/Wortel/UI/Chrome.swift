import AppKit

// The chrome's vocabulary: the palette, the metrics every control shares, how
// things move, and the small views the titlebar rows and tab strips are built
// from. Kept apart from the rows themselves (TitleBars.swift), which know about
// sessions, git and running jobs; these know about nothing but drawing, which
// is also what lets the tab strip be tested on its own (TabStripTests).

@MainActor
enum Chrome {
    /// How tall the titlebar row is. Measured from the real window at launch
    /// (see AppDelegate), because it is the system's number, not ours: it is
    /// what centres the traffic lights, and our rows have to match it.
    static var titlebarHeight: CGFloat = 40
    /// Room kept clear at the window's leading edge for the traffic lights.
    static let trafficLightInset: CGFloat = 78

    // One set of numbers for every control in the rows, so a tab and a button
    // beside it are the same height, the same roundness and the same glyph:
    // the difference between a row that looks designed and one that looks
    // assembled is mostly that nothing in it is two points off anything else.

    /// The height of a tab, and the size of every glyph button beside one.
    static let controlSize: CGFloat = 28
    /// The corner radius of a tab, and of a button's hover and selected fill.
    static let controlRadius: CGFloat = 8
    /// Every glyph in the rows: tab icons and buttons alike.
    static let glyph = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)

    /// The titlebar band: the frame the pages sit in. Clear, so the window's
    /// vibrancy shows through it (see `BackdropController`).
    static let band = NSColor.clear
    /// The session list: the same vibrancy, washed a step lighter in light mode
    /// so the list reads as its own surface under the band, as ChatGPT's does.
    static let sidebar = NSColor(name: nil) { appearance in
        isDark(appearance) ? .white.withAlphaComponent(0.02) : .white.withAlphaComponent(0.35)
    }
    /// The pages: the terminal, and the side column's tabs.
    static let content = dynamic(light: 0xFFFFFF, dark: 0x1F1F1F)
    /// The tab in front: the page's own colour in light mode, lifted in dark,
    /// where "the same colour as the page" disappears into it.
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x2E2E2E)
    static let hairline = NSColor(name: nil) { appearance in
        isDark(appearance) ? .white.withAlphaComponent(0.08) : .black.withAlphaComponent(0.07)
    }
    static let hairlineStrong = NSColor(name: nil) { appearance in
        isDark(appearance) ? .white.withAlphaComponent(0.12) : .black.withAlphaComponent(0.10)
    }
    /// The bottom strip's tab row: a faint band on the page, so the tab in
    /// front can be raised off it.
    static let stripBand = NSColor(name: nil) { appearance in
        isDark(appearance) ? .white.withAlphaComponent(0.04) : .black.withAlphaComponent(0.03)
    }
    static let hoverFill = NSColor(name: nil) { appearance in
        isDark(appearance) ? .white.withAlphaComponent(0.07) : .black.withAlphaComponent(0.05)
    }
    static let selectedFill = NSColor(name: nil) { appearance in
        isDark(appearance) ? .white.withAlphaComponent(0.11) : .black.withAlphaComponent(0.07)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = isDark(appearance) ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }
}

// MARK: - Motion

/// How panes move: one curve and two durations for everything that slides.
///
/// The curve is the ChatGPT app's (`cubic-bezier(.23, 1, .32, 1)`, a quick
/// ease-out): most of the distance early, then a long gentle settle, which
/// reads as responsive rather than as something you wait for. Opening takes a
/// little longer than closing, as in ChatGPT, where closing is instant: putting
/// something away shouldn't make you watch it go.
@MainActor
enum Motion {
    static let opening: TimeInterval = 0.26
    static let closing: TimeInterval = 0.18
    static let tabs: TimeInterval = 0.18
    static let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
}

// MARK: - Building blocks

/// A view filled with one (dynamic) colour, resolved against its own appearance
/// so it follows light and dark.
class FilledView: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}

/// A borderless glyph button that fills lightly under the pointer, and stays
/// filled while it stands for something that's on (`isSelected`).
@MainActor
class HoverFillButton: NSButton {
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        refusesFirstResponder = true
    }
    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A glyph button for a titlebar row.
    static func glyph(_ symbol: String, _ description: String) -> HoverFillButton {
        let button = HoverFillButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(Chrome.glyph)
        button.toolTip = description
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Chrome.controlSize),
            button.heightAnchor.constraint(equalToConstant: Chrome.controlSize),
        ])
        return button
    }

    /// None. A borderless NSButton reports insets around its content, and Auto
    /// Layout sizes the rect *inside* them: a button constrained to 28pt came
    /// out 32pt tall, its fill four points taller than the tab beside it.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor? = isHighlighted ? Chrome.selectedFill
            : isSelected ? Chrome.selectedFill
            : hovering ? Chrome.hoverFill : nil
        if let fill {
            fill.setFill()
            // A full-size button rounds like a tab; a small one (a tab's ×)
            // is a circle.
            let radius = bounds.height >= Chrome.controlSize ? Chrome.controlRadius : bounds.height / 2
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        super.draw(dirtyRect)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// A label that takes no clicks, so a press on the session's name falls
/// through to the row and moves the window, as a title does.
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The hairline between groups of titlebar controls, as ChatGPT sets its panel
/// toggle apart from the conversation's own buttons.
@MainActor
final class ToolbarDivider: FilledView {
    init() {
        super.init(color: Chrome.hairlineStrong)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

