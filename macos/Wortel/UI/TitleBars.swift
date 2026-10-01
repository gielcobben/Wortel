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

    init(child: NSViewController) {
        self.child = child
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

/// Over the sidebar: the traffic lights and, right beside them, the one
/// control this row has, the sidebar toggle, where ChatGPT keeps its own. A new
/// session is ⌘N or the sidebar's own "+".
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
        let toggle = HoverFillButton.glyph("sidebar.left", "Hide Sidebar (⌘B)")
        toggle.action = #selector(AppDelegate.toggleSessionSidebar(_:))
        addSubview(toggle)
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.trafficLightInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Over the main area, laid out like the ChatGPT app's conversation header: the
/// session's name as a plain title, and at the trailing end its "…" menu and
/// what it's running. Only once something else has been put in the main area's
/// row does the title become that row's tabs. The column's toggle sits at the
/// far end while the column is hidden, as ChatGPT's pane toggle does; with the
/// sidebar collapsed the row also makes room for the traffic lights and the way
/// back to the sidebar.
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
    private let sidebarToggle = HoverFillButton.glyph("sidebar.left", "Show Sidebar (⌘B)")
    private var leading: NSLayoutConstraint!

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
        sidebarToggle.action = #selector(AppDelegate.toggleSessionSidebar(_:))

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
        let row = NSStackView(views: [sidebarToggle, title, strip, trailing])
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
        setSidebarCollapsed(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setSidebarCollapsed(_ collapsed: Bool) {
        sidebarToggle.isHidden = !collapsed
        leading.constant = collapsed ? Chrome.trafficLightInset : (strip.isHidden ? 16 : 8)
    }

    /// The title, or the row's tabs once there's more than the terminal in it.
    func setShowsTabs(_ shows: Bool) {
        guard strip.isHidden == shows else { return }
        strip.isHidden = !shows
        title.isHidden = shows
        setSidebarCollapsed(!sidebarToggle.isHidden)
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
    /// Shown when this row is the leftmost with the sidebar collapsed: the
    /// way back to the sidebar, where the main area's row would carry it.
    let sidebarToggle = HoverFillButton.glyph("sidebar.left", "Show Sidebar (⌘B)")
    private var stripLeading: NSLayoutConstraint!

    override init() {
        super.init()
        toggle.isSelected = true
        sidebarToggle.action = #selector(AppDelegate.toggleSessionSidebar(_:))
        sidebarToggle.isHidden = true
        sidebarToggle.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.trailingAccessory = add
        addSubview(sidebarToggle)
        addSubview(strip)
        addSubview(toggle)
        stripLeading = strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            sidebarToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.trafficLightInset),
            sidebarToggle.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    func setSidebarCollapsed(_ collapsed: Bool) {
        sidebarToggle.isHidden = !collapsed
        stripLeading.constant = collapsed ? Chrome.trafficLightInset + 34 : 8
    }
}

// MARK: - Running jobs

/// What the session on screen is still running: a plain glyph, like the
/// ChatGPT app's Outputs button, with a small dot while something runs (green
/// when it's serving a port). Always there, so the row never shifts when a
/// server starts; the list it opens says when nothing is. The count is in the
/// tooltip.
@MainActor
final class RunningButton: HoverFillButton {
    private let dot = CALayer()
    private var dotColor: NSColor?

    /// The badge, as SF Symbols draw theirs (`app.badge`): a dot on the
    /// glyph's top-right corner with a ring of the glyph cut away around it,
    /// so it reads as a badge and not as a blot on the lines. There is no
    /// `list.bullet.badge` to use instead.
    private static let dotSize: CGFloat = 6
    private static let gap: CGFloat = 1.5

    private let plain = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Running")?
        .withSymbolConfiguration(Chrome.glyph)
    private lazy var badged: NSImage? = plain.map(Self.cutOut)

    convenience init() {
        self.init(frame: .zero)
        image = plain
        toolTip = "Running in this session"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Chrome.controlSize),
            heightAnchor.constraint(equalToConstant: Chrome.controlSize),
        ])
        wantsLayer = true
        dot.cornerRadius = Self.dotSize / 2
        dot.isHidden = true
        layer?.addSublayer(dot)
    }

    func show(_ snapshot: RunningJobsSnapshot) {
        let status = snapshot.status
        let count = snapshot.work.count + snapshot.orphans.count
        dotColor = snapshot.hasWork ? (status.isServing ? .systemGreen : .secondaryLabelColor) : nil
        dot.isHidden = dotColor == nil
        // The glyph with its gap only while there's a dot to sit in it.
        let wanted = dotColor == nil ? plain : badged
        if image !== wanted { image = wanted }
        needsLayout = true
        needsDisplay = true
        toolTip = count == 0 ? "Nothing running in this session"
            : "\(count) \(count == 1 ? "job" : "jobs") running: \(([status.title] + status.ports).joined(separator: " "))"
        setAccessibilityLabel(toolTip)
    }

    /// Where the dot's centre sits on a glyph of `size`, in the glyph's own
    /// (unflipped) coordinates: on its top-right corner, half out of it, as
    /// `app.badge` sits.
    private static func dotCenter(in size: NSSize) -> NSPoint {
        NSPoint(x: size.width - 1.5, y: size.height - 1.5)
    }

    /// The glyph with a ring cut out where the dot goes. Still a template, so
    /// it takes the button's tint in light and dark like any other glyph.
    private static func cutOut(_ glyph: NSImage) -> NSImage {
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

    override func layout() {
        super.layout()
        guard let image = badged else { return }
        // Where the button actually draws its image, so the dot lands in the
        // gap however the cell centres it.
        let imageRect = cell?.imageRect(forBounds: bounds)
            ?? NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                      width: image.size.width, height: image.size.height)
        let center = Self.dotCenter(in: image.size)
        let x = imageRect.minX + center.x
        let y = isFlipped ? imageRect.minY + (image.size.height - center.y) : imageRect.minY + center.y
        let half = Self.dotSize / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = backingAlignedRect(NSRect(x: x - half, y: y - half, width: Self.dotSize, height: Self.dotSize),
                                       options: .alignAllEdgesNearest)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let dotColor else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = dotColor.cgColor
        }
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

    private let manager: SessionManager
    private let git: GitPanelModel
    private let processes: ProcessMonitor
    private var runningPopover: NSPopover?

    init(manager: SessionManager, git: GitPanelModel, processes: ProcessMonitor) {
        self.manager = manager
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
        sideBar.strip.preview = { [weak self] tab in Self.preview(for: tab, in: self?.manager.selected) }
        // The main area's row.
        mainBar.strip.onSelect = { [weak self] tab in self?.git.selectMain(tab) }
        mainBar.strip.onClose = { [weak self] tab in self?.git.requestClose(tab) }
        mainBar.strip.onCloseOthers = { [weak self] keep in self?.git.closeOthers(keeping: keep) }
        mainBar.strip.onMove = { [weak self] tab, region in self?.git.move(tab, to: region, at: .max) }
        mainBar.strip.preview = { [weak self] tab in Self.preview(for: tab, in: self?.manager.selected) }
    }

    func start() {
        observeColumn()
        observeProcesses()
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
        mainBar.title.stringValue = manager.selected?.name ?? "Wortel"
        // A plain title until the row holds more than the session's terminal.
        mainBar.setShowsTabs(git.mainTabs.count > 1)
        let session = manager.selected
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
                         detail: (path as NSString).abbreviatingWithTildeInPath)
        case .browser(let id):
            // The page's title once it has one, where it is until then.
            let page = BrowserTabs.shared.existingPage(for: id)
            let address = page?.location ?? session?.browserAddresses[id].flatMap(URL.init(string:))
            let title = page?.tabTitle ?? address.map(BrowserAddress.short) ?? "New Tab"
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
    /// width, and inside a session's own menu "Fork…" needs no more words to
    /// say it forks this session onto a branch. Below its own three items it
    /// is the sidebar row's menu (SessionActions), so the two always agree.
    @objc private func presentSessionMenu(_ sender: NSView) {
        guard let session = manager.selected else { return }
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
        guard let id = manager.selectedID else { return .empty }
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
        guard runningPopover == nil, let session = manager.selectedID else { return }
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
                self?.git.showInBrowser(url, inMain: NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
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
        // you're in, which from the column's menu is the column; the strip's
        // own is ⇧⌘D.
        let terminal = ClosureMenuItem(title: "New Terminal") {
            git.open(.terminal(UUID()), in: region)
        }
        terminal.setGlyph("apple.terminal")
        if region == .bottom {
            terminal.keyEquivalent = "d"
            terminal.keyEquivalentModifierMask = [.command, .shift]
        } else {
            terminal.keyEquivalent = "t"
            terminal.keyEquivalentModifierMask = [.command]
        }
        menu.addItem(terminal)

        let browser = ClosureMenuItem(title: "New Browser") {
            git.openBrowser(at: nil, in: region)
        }
        browser.setGlyph("globe")
        browser.keyEquivalent = "l"
        browser.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(browser)

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
