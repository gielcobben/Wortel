import AppKit
import Observation
import SwiftUI

/// Wortel's own titlebar: a flat band that each pane draws the top of, split
/// by the same hairlines as the panes below it.
///
/// This replaces the system toolbar, and the reason is the ChatGPT app, which is
/// what this is modelled on (measured from its bundle and its screen): a grey
/// band, white pages under it, hairlines between them, plain glyphs that fill
/// on hover, and the side column's tabs sitting in the band itself. The system
/// toolbar can't be that on macOS 26 and later: every item it holds, custom
/// views included, is set on a Liquid Glass capsule, and AppKit has no switch to
/// turn that off (SwiftUI's `sharedBackgroundVisibility` has no AppKit twin). So
/// the window keeps an *empty* toolbar, only for the height it gives the
/// titlebar and the centred traffic lights, makes the titlebar transparent so
/// clicks reach the views under it, and every pane draws its own row.
///
/// The rows are AppKit rather than SwiftUI for the same reasons the tab strip
/// is: they are mostly empty space that has to drag the window, and double-click
/// has to zoom it, which needs real events.
// The palette, metrics, motion and small building blocks the rows are made
// of live in Chrome.swift.

// MARK: - Pane motion

extension Motion {
    /// A pane opening or closing, with every terminal's resizing held until it
    /// lands (SurfaceView.holdResizes): one resize at the end instead of one a
    /// frame. `completion` runs as it lands, before the terminals resize, so a
    /// width it sets is the width they get.
    static func pane(opening: Bool, _ changes: () -> Void,
                     completion: @escaping @MainActor @Sendable () -> Void = {}) {
        SurfaceView.holdResizes()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = opening ? Self.opening : Self.closing
            context.timingFunction = curve
            context.allowsImplicitAnimation = true
            changes()
        } completionHandler: {
            MainActor.assumeIsolated {
                completion()
                DispatchQueue.main.async { SurfaceView.releaseResizes() }
            }
        }
    }
}

/// One pane's titlebar row: the band colour, a hairline along its bottom where
/// the page starts, and titlebar behaviour for whatever of it is empty: drag
/// moves the window, double-click does what the Mac is set to do.
@MainActor
class ChromeBarView: FilledView {
    private let bottomLine = FilledView(color: Chrome.hairline)

    init() {
        super.init(color: Chrome.band)
        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomLine)
        NSLayoutConstraint.activate([
            bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Whether the hairline along the bottom shows. Faded rather than cut,
    /// since the sidebar's comes and goes as its list scrolls.
    var showsBottomLine = true {
        didSet {
            guard showsBottomLine != oldValue else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                bottomLine.animator().alphaValue = showsBottomLine ? 1 : 0
            }
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Moving the window

    /// The window server's own titlebar dragging is off (WindowMovability), so
    /// a press on empty row moves the window from here.
    ///
    /// Handled here rather than left to `mouseDownCanMoveWindow`, because a
    /// window-server drag never delivers the second click of a double-click.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

/// A pane of the main split: its titlebar row on top and its content below.
/// The row is see-through to the window's vibrancy; the content sits on
/// `bodyColor`, which is opaque for a page (the terminal, the side column) and a
/// light wash for the sidebar.
@MainActor
final class ChromePaneController: NSViewController {
    let bar: NSView
    let content: NSViewController
    private let bodyColor: NSColor
    /// The body's colour runs up behind the titlebar row too, so the pane is
    /// one surface to the top of the window (the sidebar, as ChatGPT's is).
    private let colorsUnderBar: Bool

    init(bar: NSView, content: NSViewController, bodyColor: NSColor, colorsUnderBar: Bool = false) {
        self.bar = bar
        self.content = content
        self.bodyColor = bodyColor
        self.colorsUnderBar = colorsUnderBar
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(content)
        let page = FilledView(color: bodyColor)
        let body = content.view
        // The page first, so when it runs up behind the row it's under it.
        for view in [page, bar, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Chrome.titlebarHeight),
            page.topAnchor.constraint(equalTo: colorsUnderBar ? root.topAnchor : bar.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        view = root
    }
}

/// The window's vibrancy: one behind-window material under everything, so the
/// band and the sidebar are translucent to the desktop and only the pages are
/// solid. That is the ChatGPT app's arrangement too (its window is a `menu`
/// vibrancy with opaque pages on top).
///
/// Cheap where it matters: the blur is the window server's, over a region that
/// only changes when what's *behind the window* does. The terminal is an
/// opaque page in front of it, so its redraws never touch the blur, which is
/// the compositor cost `background-blur` in wortel.conf would have paid on
/// every frame.
@MainActor
final class BackdropController: NSViewController {
    private let child: NSViewController
    /// Laid over the top of the window, the titlebar's height: the sidebar's
    /// controls, which belong to no one pane.
    private let overlay: NSView?

    init(child: NSViewController, overlay: NSView? = nil) {
        self.child = child
        self.overlay = overlay
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        addChild(child)
        let content = child.view
        content.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: backdrop.topAnchor),
            content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        if let overlay {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(overlay, positioned: .above, relativeTo: content)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: backdrop.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                overlay.heightAnchor.constraint(equalToConstant: Chrome.titlebarHeight),
            ])
        }
        view = backdrop
    }
}

/// The split view, with hairline dividers in the chrome's own colour, running
/// the full height of the window, through the titlebar band as well.
final class ChromeSplitView: NSSplitView {
    override var dividerColor: NSColor { Chrome.hairline }
    override var dividerThickness: CGFloat { 1 }
}

// MARK: - The three rows

/// Over the sidebar: the traffic lights, and under the sidebar toggle and
/// Back and Forward, which are not this row's but `SidebarControls`', laid
/// over every row. A new session is ⌘N or the sidebar's own "+".
@MainActor
final class SidebarBar: ChromeBarView {
    /// Posted by the sidebar's list as it scrolls, with the window as its
    /// object and whether any of the list is under the row.
    static let scrolledNotification = Notification.Name("WortelSidebarScrolled")

    override init() {
        super.init()
        // No line under the row while the list sits at the top: the sidebar
        // reads as one surface up to the traffic lights. It comes back once
        // rows slide under the row, so they don't vanish at an invisible edge.
        showsBottomLine = false
        NotificationCenter.default.addObserver(
            forName: Self.scrolledNotification, object: nil, queue: .main
        ) { [weak self] note in
            let scrolled = note.userInfo?["scrolled"] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self, note.object as AnyObject? === self.window else { return }
                self.showsBottomLine = scrolled
            }
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// The sidebar toggle and Back and Forward: one set, laid over the whole
/// titlebar rather than a copy in each row, so opening and closing the sidebar
/// moves them instead of swapping them.
///
/// There used to be three sets (the sidebar's row, and the main area's or the
/// column's once the sidebar was collapsed), shown and hidden by `isHidden`.
/// So the sidebar slid shut with its arrows clipped by its own edge, then the
/// next row's set popped in at the end. Now the toggle never moves, beside the
/// traffic lights in both states, and the arrows ride the sidebar's edge,
/// against the main area they change as a browser keeps its arrows by the page,
/// until the edge reaches the toggle and they stop beside it. The rows to the
/// right make room by `leadingClearance`, so the title is pushed along with
/// them rather than jumping.
///
/// Placed by MainSplitViewController on every layout pass and every resize of
/// the split, which a collapse animation makes every frame, so it moves in
/// step with the sidebar.
@MainActor
final class SidebarControls: NSView {
    let toggle = HoverFillButton.glyph("sidebar.left", "Hide Sidebar (⌘B)")
    let history = HistoryButtons()
    private var historyLeading: NSLayoutConstraint!

    /// Where the arrows start when the sidebar is shut: past the toggle.
    private static let restingX = Chrome.trafficLightInset + Chrome.controlSize + 8

    init() {
        super.init(frame: .zero)
        toggle.action = #selector(AppDelegate.toggleSessionSidebar(_:))
        history.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toggle)
        addSubview(history)
        historyLeading = history.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.restingX)
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.trafficLightInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            historyLeading,
            history.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Follow the sidebar's right edge, `edge` points from this view's leading
    /// edge (0 when it's shut). Returns where the arrows end, in the same
    /// coordinates, for the rows to clear.
    @discardableResult
    func place(sidebarEdge edge: CGFloat, collapsed: Bool) -> CGFloat {
        // Measured, not restated: whatever HistoryButtons holds and spaces.
        let width = history.fittingSize.width
        let x = max(Self.restingX, edge - 8 - width)
        if abs(historyLeading.constant - x) > 0.01 { historyLeading.constant = x }
        let label = collapsed ? "Show Sidebar (⌘B)" : "Hide Sidebar (⌘B)"
        if toggle.toolTip != label {
            toggle.toolTip = label
            toggle.setAccessibilityLabel(label)
        }
        return x + width
    }

    /// Only the buttons take clicks: the rest is the rows' under it, which
    /// move the window and zoom it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// Over the main area, laid out like the ChatGPT app's conversation header: the
/// session's name as a plain title, and at the trailing end its "…" menu and
/// what it's running. Only once something else has been put in the main area's
/// row does the title become that row's tabs. The column's toggle sits at the
/// far end while the column is hidden, as ChatGPT's pane toggle does; with the
/// sidebar collapsed the row also makes room for the traffic lights and the
/// sidebar's controls (`leadingClearance`).
///
/// Everything else (a new terminal here, the bottom strip) is in the "…" menu
/// and on the keyboard, not on the row: a titlebar full of glyphs is a titlebar
/// nobody can read.
@MainActor
final class MainBar: ChromeBarView {
    let title = PassthroughLabel(labelWithString: "")
    let strip = SideTabStrip()
    let more = HoverFillButton.glyph("ellipsis", "Session")
    let running = RunningButton()
    let sideToggle = HoverFillButton.glyph("sidebar.right", "Show Side Column (⌥⌘B)")
    private let sideDivider = ToolbarDivider()
    private var leading: NSLayoutConstraint!
    /// How far from the row's leading edge its content has to start to clear
    /// the sidebar's controls laid over it: 0 while they're over the sidebar.
    var leadingClearance: CGFloat = 0 {
        didSet { if leadingClearance != oldValue { updateLeading() } }
    }

    /// While the row shows the title rather than tabs: the row, as a place to
    /// drop a tab, and where the marker goes, just after the title's text (the
    /// session's tab it will sit beside), in window coordinates.
    func dropSlot() -> (area: NSRect, markerX: CGFloat)? {
        guard window != nil, strip.isHidden, !isHiddenOrHasHiddenAncestor else { return nil }
        let textWidth = min(title.intrinsicContentSize.width, title.bounds.width)
        let end = title.convert(NSPoint(x: textWidth + 6, y: 0), to: nil).x
        return (convert(bounds, to: nil), end)
    }

    override init() {
        super.init()

        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.init(1), for: .horizontal)

        strip.region = .main
        strip.isHidden = true
        strip.setContentHuggingPriority(.init(1), for: .horizontal)
        strip.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let trailing = NSStackView(views: [more, running, sideDivider, sideToggle])
        trailing.spacing = 4
        let row = NSStackView(views: [title, strip, trailing])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        leading = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        NSLayoutConstraint.activate([
            // The full row, as the other two rows' strips: a strip of a fixed
            // height centred in a row whose height is measured at launch sat
            // half a point off whenever the two differed by an odd amount.
            // Here, not where the strip is set up: a constraint between views
            // that don't share a superview yet throws, and at launch that
            // left the app with no window.
            strip.heightAnchor.constraint(equalTo: heightAnchor),
            leading,
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func updateLeading() {
        let own: CGFloat = strip.isHidden ? 16 : 8
        let constant = max(own, leadingClearance)
        if abs(leading.constant - constant) > 0.01 { leading.constant = constant }
    }

    /// The title, or the row's tabs once there's more than the terminal in it.
    func setShowsTabs(_ shows: Bool) {
        guard strip.isHidden == shows else { return }
        strip.isHidden = !shows
        title.isHidden = shows
        updateLeading()
    }

    /// The column's toggle, here only while the column is hidden.
    func setShowsSideToggle(_ shows: Bool) {
        sideToggle.isHidden = !shows
        sideDivider.isHidden = !shows
    }
}

/// Over the side column: its tabs with "+" right after the last one, as in
/// ChatGPT's right pane, and the column's toggle at the far end.
@MainActor
final class SideColumnBar: ChromeBarView {
    let strip = SideTabStrip()
    let add = HoverFillButton.glyph("plus", "New Tab")
    let toggle = HoverFillButton.glyph("sidebar.right", "Hide Side Column (⌥⌘B)")
    private var stripLeading: NSLayoutConstraint!
    /// As the main area's row: room for the sidebar's controls when this row
    /// is the leftmost with the sidebar collapsed.
    var leadingClearance: CGFloat = 0 {
        didSet {
            let constant = max(8, leadingClearance)
            if abs(stripLeading.constant - constant) > 0.01 { stripLeading.constant = constant }
        }
    }

    override init() {
        super.init()
        toggle.isSelected = true
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.trailingAccessory = add
        addSubview(strip)
        addSubview(toggle)
        stripLeading = strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            stripLeading,
            // The full row, like the buttons' centre: a tab centred on a strip
            // that stopped short of the hairline sat half a point low.
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Back and Forward

/// The two arrows that step through the places you've been: a session and
/// the tab you had in front in it. Part of `SidebarControls`.
@MainActor
final class HistoryButtons: NSStackView {
    let back = HoverFillButton.glyph("chevron.left", "Back (⌃⌘[)")
    let forward = HoverFillButton.glyph("chevron.right", "Forward (⌃⌘])")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        back.action = #selector(AppDelegate.goBackSession(_:))
        forward.action = #selector(AppDelegate.goForwardSession(_:))
        addArrangedSubview(back)
        addArrangedSubview(forward)
        update(canGoBack: false, canGoForward: false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Disabled arrows are drawn faint by hand: a set `contentTintColor` is
    /// used as is, enabled or not.
    func update(canGoBack: Bool, canGoForward: Bool) {
        for (button, enabled) in [(back, canGoBack), (forward, canGoForward)] {
            button.isEnabled = enabled
            button.contentTintColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - A badge on a glyph

/// A dot on a glyph's top-right corner, as SF Symbols draw their own badges
/// (`app.badge`): half out of the corner, with a ring of the glyph cut away
/// around it so it reads as a badge and not as a blot on the lines. Used where
/// no `.badge` variant of the symbol exists: the running list, the update icon.
enum GlyphBadge {
    static let dotSize: CGFloat = 6
    static let gap: CGFloat = 1.5

    /// Where the dot's centre sits on a glyph of `size`, in the glyph's own
    /// (unflipped) coordinates.
    static func dotCenter(in size: NSSize) -> NSPoint {
        NSPoint(x: size.width - 1.5, y: size.height - 1.5)
    }

    /// The glyph with a ring cut out where the dot goes. Still a template, so
    /// it takes the button's tint in light and dark like any other glyph.
    static func cutOut(_ glyph: NSImage) -> NSImage {
        let size = glyph.size
        let image = NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: rect)
            let center = dotCenter(in: size)
            let radius = dotSize / 2 + gap
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The dot's frame in `button`, where the button actually draws `image`,
    /// so it lands in the gap however the cell centres it, flipped or not.
    @MainActor
    static func dotFrame(in button: NSButton, image: NSImage) -> NSRect {
        let bounds = button.bounds
        let imageRect = button.cell?.imageRect(forBounds: bounds)
            ?? NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                      width: image.size.width, height: image.size.height)
        let center = dotCenter(in: image.size)
        let x = imageRect.minX + center.x
        let y = button.isFlipped ? imageRect.minY + (image.size.height - center.y) : imageRect.minY + center.y
        let half = dotSize / 2
        return button.backingAlignedRect(NSRect(x: x - half, y: y - half, width: dotSize, height: dotSize),
                                         options: .alignAllEdgesNearest)
    }
}

/// A hover glyph button with an optional `GlyphBadge` dot: the glyph swaps to
/// its cut-out version while there's a dot to sit in the gap. One place for the
/// running list's dot and the update icon's.
@MainActor
class BadgedGlyphButton: HoverFillButton {
    private let dot = CALayer()
    private var plainGlyph: NSImage?
    private var badgedGlyph: NSImage?

    /// The dot's colour; nil for no dot (and the plain glyph).
    var dotColor: NSColor? {
        didSet { if dotColor != oldValue { applyBadge() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        dot.cornerRadius = GlyphBadge.dotSize / 2
        dot.isHidden = true
        layer?.addSublayer(dot)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The glyph; its cut-out twin is made once, here, not on every redraw.
    func setGlyph(_ glyph: NSImage?) {
        plainGlyph = glyph
        badgedGlyph = glyph.map(GlyphBadge.cutOut)
        applyBadge()
    }

    private func applyBadge() {
        let wanted = dotColor == nil ? plainGlyph : badgedGlyph
        if image !== wanted { image = wanted }
        dot.isHidden = dotColor == nil
        needsLayout = true
        applyDotColor()
    }

    override func layout() {
        super.layout()
        guard dotColor != nil, let badgedGlyph else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = GlyphBadge.dotFrame(in: self, image: badgedGlyph)
        CATransaction.commit()
    }

    /// A layer holds a fixed CGColor: resolve it for this view's appearance,
    /// and again whenever that changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDotColor()
    }

    private func applyDotColor() {
        guard let dotColor else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = dotColor.cgColor
        }
        CATransaction.commit()
    }
}

// MARK: - Running jobs

/// What the session on screen is still running: a plain glyph, like the
/// ChatGPT app's Outputs button, with a small dot while something runs (green
/// when it's serving a port). Always there, so the row never shifts when a
/// server starts; the list it opens says when nothing is. The count is in the
/// tooltip.
@MainActor
final class RunningButton: BadgedGlyphButton {
    convenience init() {
        self.init(frame: .zero)
        // The badge (`GlyphBadge`): there is no `list.bullet.badge` to use.
        setGlyph(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Running")?
            .withSymbolConfiguration(Chrome.glyph))
        toolTip = "Running in this session"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Chrome.controlSize),
            heightAnchor.constraint(equalToConstant: Chrome.controlSize),
        ])
    }

    func show(_ snapshot: RunningJobsSnapshot) {
        let status = snapshot.status
        let count = snapshot.work.count + snapshot.orphans.count
        dotColor = snapshot.hasWork ? (status.isServing ? .systemGreen : .secondaryLabelColor) : nil
        toolTip = count == 0 ? "Nothing running in this session"
            : "\(count) \(count == 1 ? "job" : "jobs") running: \(([status.title] + status.ports).joined(separator: " "))"
        setAccessibilityLabel(toolTip)
    }
}

// MARK: - Keeping the rows current

/// Keeps the three rows in step with the models: the session's name, the side
/// column's tabs, what the session is running. The rows only draw; this is
/// where they learn what to draw and what their clicks mean.
@MainActor
final class TitleBarController: NSObject, NSPopoverDelegate {
    let sidebarBar = SidebarBar()
    let mainBar = MainBar()
    let sideBar = SideColumnBar()
    /// The sidebar toggle and the arrows, over all three rows.
    let sidebarControls = SidebarControls()

    private let manager: SessionManager
    /// The window these rows are in: its session's name, tabs and jobs.
    private let home: SessionWindow
    private let git: GitPanelModel
    private let processes: ProcessMonitor
    private var runningPopover: NSPopover?

    init(manager: SessionManager, home: SessionWindow, git: GitPanelModel, processes: ProcessMonitor) {
        self.manager = manager
        self.home = home
        self.git = git
        self.processes = processes
        super.init()

        mainBar.sideToggle.target = self
        mainBar.sideToggle.action = #selector(toggleSideColumn)
        sideBar.toggle.target = self
        sideBar.toggle.action = #selector(toggleSideColumn)
        sideBar.add.target = self
        sideBar.add.action = #selector(presentNewTabMenu(_:))
        mainBar.running.target = self
        mainBar.running.action = #selector(openRunningJobs(_:))
        mainBar.more.target = self
        mainBar.more.action = #selector(presentSessionMenu(_:))

        // The column's tab row.
        sideBar.strip.onSelect = { [weak self] tab in self?.git.select(tab) }
        sideBar.strip.onClose = { [weak self] tab in self?.git.requestClose(tab) }
        sideBar.strip.onCloseOthers = { [weak self] keep in self?.git.closeOthers(keeping: keep) }
        sideBar.strip.onMove = { [weak self] tab, region in self?.git.move(tab, to: region, at: .max) }
        sideBar.strip.onKeep = { [weak self] tab in self?.git.keep(tab) }
        sideBar.strip.onSplit = { [weak self] tab, edge in self?.git.split(.side, on: edge, with: tab) }
        sideBar.strip.preview = { [weak self] tab in Self.preview(for: tab, in: self?.home.selected) }
        // The main area's row.
        mainBar.strip.onSelect = { [weak self] tab in self?.git.selectMain(tab) }
        mainBar.strip.onClose = { [weak self] tab in self?.git.requestClose(tab) }
        mainBar.strip.onCloseOthers = { [weak self] keep in self?.git.closeOthers(keeping: keep) }
        mainBar.strip.onMove = { [weak self] tab, region in self?.git.move(tab, to: region, at: .max) }
        mainBar.strip.onKeep = { [weak self] tab in self?.git.keep(tab) }
        mainBar.strip.onSplit = { [weak self] tab, edge in self?.git.split(.main, on: edge, with: tab) }
        mainBar.strip.preview = { [weak self] tab in Self.preview(for: tab, in: self?.home.selected) }
    }

    func start() {
        observeColumn()
        observeProcesses()
        observeHistory()
    }

    // MARK: Back and Forward

    private func observeHistory() {
        withObservationTracking {
            let back = manager.canGoBack, forward = manager.canGoForward
            sidebarControls.history.update(canGoBack: back, canGoForward: forward)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHistory() }
        }
    }

    // MARK: Side column

    private func observeColumn() {
        withObservationTracking {
            syncColumn()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeColumn() }
        }
    }

    private func syncColumn() {
        mainBar.setShowsSideToggle(!git.isVisible)
        mainBar.title.stringValue = home.selected?.name ?? "Wortel"
        // A plain title until the row holds more than the session's terminal,
        // and again once the main area is split: every pane then has a row of
        // its own under the titlebar, the main row's included (`PaneBar`).
        // TODO(unify): `hasPanes`, not `isSplit`: the column and the strip are
        // leaves of the tree now and have rows of their own already.
        mainBar.setShowsTabs(git.mainTabs.count > 1 && !git.splitLayout.hasPanes)
        let session = home.selected
        func item(_ tab: SideTab) -> SideTabStrip.Item { Self.stripItem(for: tab, in: session) }
        sideBar.strip.update(items: git.tabs.map(item), active: git.activeTab)
        mainBar.strip.update(items: git.mainTabs.map(item), active: git.activeMainTab ?? .session)
    }

    /// A tab as a row shows it: its title and glyph.
    static func stripItem(for tab: SideTab, in session: Session?) -> SideTabStrip.Item {
        switch tab {
        case .pane(let pane):
            return .init(tab: tab, title: pane.title, symbol: pane.symbol)
        case .terminal(let id):
            let raw = session?.sideTerminalTitles[id]
            return .init(tab: tab, title: terminalTitle(raw), symbol: "apple.terminal",
                         detail: terminalDetail(raw))
        case .file(let path):
            let url = URL(fileURLWithPath: path)
            let symbol = ["md", "markdown"].contains(url.pathExtension.lowercased())
                ? "doc.richtext" : "doc.text"
            return .init(tab: tab, title: url.lastPathComponent, symbol: symbol,
                         detail: (path as NSString).abbreviatingWithTildeInPath,
                         isPreview: session?.peekTab == tab)
        case .browser(let id):
            // The page's title once it has one, where it is until then.
            let page = BrowserTabs.shared.existingPage(for: id)
            let address = page?.location ?? session?.browserAddresses[id].flatMap(URL.init(string:))
            // A page not made yet (a restored tab never shown): a file by
            // its name, as its page will call it.
            let title = page?.tabTitle
                ?? address.map { $0.isFileURL ? $0.lastPathComponent : BrowserAddress.short($0) }
                ?? "New Tab"
            return .init(tab: tab, title: title, symbol: "globe",
                         detail: address?.absoluteString)
        case .session:
            // The session's own terminal, by the session's name.
            let name = session.map { SessionName.leaf(of: $0.name) } ?? "Terminal"
            return .init(tab: tab, title: name, symbol: "terminal", pinned: true,
                         detail: session?.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath })
        }
    }

    /// What a tab's hover card shows of it: a terminal's last lines, the top of
    /// a file, a page as it last looked. Read now, when the card opens.
    static func preview(for tab: SideTab, in session: Session?) -> TabPreview? {
        switch tab {
        case .terminal(let id):
            return .terminal(session?.sideSurfaces[id]?.activeScreenTail(maxBytes: 4096))
        case .session:
            return .terminal(session?.surfaceView?.activeScreenTail(maxBytes: 4096))
        case .file(let path):
            return .file(at: path)
        case .browser(let id):
            return BrowserTabs.shared.existingPage(for: id)?.previewSnapshot().map(TabPreview.image)
        case .pane:
            return nil
        }
    }

    /// What a hover card says about a terminal: its folder in full, or the
    /// program it's running, when that's what the tab shortened.
    static func terminalDetail(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let colon = raw.lastIndex(of: ":"), raw[..<colon].contains("@") {
            return String(raw[raw.index(after: colon)...])
        }
        return raw == terminalTitle(raw) ? nil : raw
    }

    /// What a shell titled itself, trimmed to what fits on a tab. Shells title a
    /// terminal `user@host:path`, and the path's last component is the part
    /// that tells two terminals apart.
    static func terminalTitle(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return "Terminal"
        }
        if let colon = raw.lastIndex(of: ":"), raw[..<colon].contains("@") {
            let path = String(raw[raw.index(after: colon)...])
            let leaf = (path as NSString).lastPathComponent
            return leaf.isEmpty ? path : leaf
        }
        return raw
    }

    @objc private func toggleSideColumn() {
        git.toggle()
    }

    /// The column's "+": NewTabMenu, opening into the column.
    @objc private func presentNewTabMenu(_ sender: NSView) {
        // "+" is the column's; the main area's tabs come from the "…" menu.
        NewTabMenu.popUp(from: sender, git: git, region: .side)
    }

    /// The session's "…": its own actions, as ChatGPT's menu is the
    /// conversation's. Native, small, glyphs that show, shortcuts on the right.
    /// The titles are short on purpose: the longest title decides the menu's
    /// width, and inside a session's own menu "Hide Strip" needs no more words to say
    /// it's about this session. Below its own three items it
    /// is the sidebar row's menu (SessionActions), so the two always agree.
    @objc private func presentSessionMenu(_ sender: NSView) {
        guard let session = home.selected else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        // What used to be glyphs on the row: a terminal in the main area, and
        // the strip under it.
        let terminal = ClosureMenuItem(title: "New Terminal") { [weak self] in
            self?.git.openMainTerminal()
        }
        Self.setGlyph("apple.terminal", on: terminal)
        terminal.keyEquivalent = "t"
        terminal.keyEquivalentModifierMask = [.command]
        menu.addItem(terminal)
        let browser = ClosureMenuItem(title: "New Browser") { [weak self] in
            self?.git.openBrowser(at: nil, in: .main)
        }
        Self.setGlyph("globe", on: browser)
        browser.keyEquivalent = "l"
        browser.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(browser)
        // A terminal in a split of its own, beside the main row or under it.
        let splitRight = ClosureMenuItem(title: "Split Right") { [weak self] in
            self?.git.split(.main, on: .right)
        }
        Self.setGlyph("rectangle.split.2x1", on: splitRight)
        splitRight.keyEquivalent = "d"
        splitRight.keyEquivalentModifierMask = [.command]
        menu.addItem(splitRight)
        let splitDown = ClosureMenuItem(title: "Split Down") { [weak self] in
            self?.git.split(.main, on: .down)
        }
        Self.setGlyph("rectangle.split.1x2", on: splitDown)
        splitDown.keyEquivalent = "d"
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(splitDown)
        let strip = ClosureMenuItem(title: git.bottomVisible ? "Hide Strip" : "Show Strip") { [weak self] in
            self?.git.toggleBottom()
        }
        Self.setGlyph("rectangle.bottomthird.inset.filled", on: strip)
        strip.keyEquivalent = "j"
        strip.keyEquivalentModifierMask = [.command]
        menu.addItem(strip)
        menu.addItem(.separator())

        // The rest is the session's own menu, the one its sidebar row has.
        let actions = SessionActions.menu(for: session, manager: manager)
        for item in actions.items {
            actions.removeItem(item)
            menu.addItem(item)
        }

        let x = sender.bounds.width - menu.size.width
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: sender.bounds.height + 4), in: sender)
    }

    private static func setGlyph(_ symbol: String, on item: NSMenuItem) {
        item.setGlyph(symbol)
    }

    // MARK: Running jobs

    /// What the selected session is running, and anything it started that has
    /// already left. Leftovers nobody owns are not in it: they would put the
    /// pill in every session, which is the thing this scoping exists to stop.
    private var runningSnapshot: RunningJobsSnapshot {
        guard let id = home.selectedID else { return .empty }
        return processes.snapshot.scoped(to: id)
    }

    private func observeProcesses() {
        withObservationTracking {
            mainBar.running.show(runningSnapshot)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.processes.updateActivityAssertion()
                self.observeProcesses()
            }
        }
    }

    @objc private func openRunningJobs(_ sender: NSButton) {
        guard runningPopover == nil, let session = home.selectedID else { return }
        // Scan before showing, not after: NSPopover sizes itself to the content
        // it is handed at presentation.
        processes.refresh()
        Telemetry.capture(.processesShown(
            jobs: CountBucket(processes.snapshot.work.count),
            orphans: CountBucket(processes.snapshot.orphans.count)))
        let popover = NSPopover()
        popover.behavior = .transient
        let list = RunningJobsList(
            monitor: processes, session: session,
            openInTab: { [weak self] url in
                self?.git.showInBrowser(url, elsewhere: NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
            },
            dismiss: { [weak self] in self?.runningPopover?.performClose(nil) })
        let host = NSHostingController(rootView: list)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.delegate = self
        runningPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.runningPopover = nil
            self.mainBar.running.show(self.runningSnapshot)
        }
    }
}

/// What "+" offers in a tab row. The column's and the bottom strip's are the
/// same menu, built here once so the two can't drift apart again (the strip's
/// used to open a terminal straight away), and what it opens goes into the row
/// whose "+" was clicked.
///
/// Native and small, like the ChatGPT app's own menus: a terminal first,
/// because a new one is what "+" usually means, a browser, then the panes, the
/// groups set apart by separators rather than labels. What's serving is offered
/// by a new browser's address field instead. No checkmarks on the panes that
/// are already open, since choosing one does the useful thing either way: it
/// brings that tab to the front.
@MainActor
enum NewTabMenu {
    static func popUp(from sender: NSView, git: GitPanelModel, region: TabRegion) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // The shortcut that opens a terminal *there*: ⌘T opens one in the area
        // you're in, which from a row's own menu is that row.
        let terminal = ClosureMenuItem(title: "New Terminal") {
            git.open(.terminal(UUID()), in: region)
        }
        terminal.setGlyph("apple.terminal")
        terminal.keyEquivalent = "t"
        terminal.keyEquivalentModifierMask = [.command]
        menu.addItem(terminal)

        let browser = ClosureMenuItem(title: "New Browser") {
            git.openBrowser(at: nil, in: region)
        }
        browser.setGlyph("globe")
        browser.keyEquivalent = "l"
        browser.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(browser)

        // A terminal in a split of its own: beside this one, when the row is
        // a part of the main area, and beside the main row from the column
        // or the strip.
        menu.addItem(.separator())
        let splitRight = ClosureMenuItem(title: "Split Right") { git.split(region, on: .right) }
        splitRight.setGlyph("rectangle.split.2x1")
        splitRight.keyEquivalent = "d"
        splitRight.keyEquivalentModifierMask = [.command]
        menu.addItem(splitRight)
        let splitDown = ClosureMenuItem(title: "Split Down") { git.split(region, on: .down) }
        splitDown.setGlyph("rectangle.split.1x2")
        splitDown.keyEquivalent = "d"
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(splitDown)

        menu.addItem(.separator())
        for pane in InspectorPane.allCases {
            let item = ClosureMenuItem(title: pane.title) {
                git.open(.pane(pane), in: region)
            }
            item.setGlyph(pane.symbol)
            // How much is waiting in Changes, as a native count badge.
            if pane == .changes, let count = git.repo?.status.changes.count, count > 0 {
                item.badge = NSMenuItemBadge(count: count)
            }
            menu.addItem(item)
        }

        // Hung from the button the native way, its leading edge under the
        // button's, as a toolbar's pull-down opens. (It used to open leftward,
        // its trailing edge on the "+", back over the tabs.)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}
