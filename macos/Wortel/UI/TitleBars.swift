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
@MainActor
enum Chrome {
    /// How tall the titlebar row is. Measured from the real window at launch
    /// (see AppDelegate), because it is the system's number, not ours: it is
    /// what centres the traffic lights, and our rows have to match it.
    static var titlebarHeight: CGFloat = 40
    /// Room kept clear at the window's leading edge for the traffic lights.
    static let trafficLightInset: CGFloat = 78

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

    /// A pane opening or closing, with every terminal's resizing held until it
    /// lands (SurfaceView.holdResizes): one resize at the end instead of one a
    /// frame. `completion` runs as it lands, before the terminals resize, so a
    /// width it sets is the width they get.
    static func pane(opening: Bool, _ changes: () -> Void,
                     completion: @escaping @MainActor () -> Void = {}) {
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
    static func glyph(_ symbol: String, _ description: String, pointSize: CGFloat = 13) -> HoverFillButton {
        let button = HoverFillButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        button.toolTip = description
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
    }

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
            let radius = min(7, bounds.height / 2)
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

    init(bar: NSView, content: NSViewController, bodyColor: NSColor) {
        self.bar = bar
        self.content = content
        self.bodyColor = bodyColor
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(content)
        let page = FilledView(color: bodyColor)
        let body = content.view
        for view in [bar, page, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Chrome.titlebarHeight),
            page.topAnchor.constraint(equalTo: bar.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            body.topAnchor.constraint(equalTo: page.topAnchor),
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

/// Over the sidebar: room for the traffic lights, then the sidebar toggle and
/// a new session, where ChatGPT keeps its own.
@MainActor
final class SidebarBar: ChromeBarView {
    override init() {
        super.init()
        let toggle = HoverFillButton.glyph("sidebar.left", "Hide Sidebar")
        toggle.action = #selector(AppDelegate.toggleSessionSidebar(_:))
        let new = HoverFillButton.glyph("square.and.pencil", "New Session")
        new.action = #selector(AppDelegate.newSession(_:))
        let stack = NSStackView(views: [toggle, new])
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Over the main area: its tab row (the session's own terminal pinned first,
/// by name, then anything dragged or opened here), "+", and at the trailing end
/// what the session is running and the toggles for the strip and the column.
/// With the sidebar collapsed it takes over the sidebar row's job too: room for
/// the traffic lights, and a way to bring the sidebar back.
@MainActor
final class MainBar: ChromeBarView {
    let strip = SideTabStrip()
    let add = HoverFillButton.glyph("plus", "New Tab")
    /// The session's actions, as ChatGPT's "…" is the conversation's.
    let more = HoverFillButton.glyph("ellipsis", "Session")
    let running = RunningButton()
    let sideToggle = HoverFillButton.glyph("sidebar.right", "Show Side Column")
    let bottomToggle = HoverFillButton.glyph("rectangle.bottomthird.inset.filled", "Bottom Strip")
    private let sidebarControls: NSStackView
    private var leading: NSLayoutConstraint!

    override init() {
        let toggle = HoverFillButton.glyph("sidebar.left", "Show Sidebar")
        toggle.action = #selector(AppDelegate.toggleSessionSidebar(_:))
        let new = HoverFillButton.glyph("square.and.pencil", "New Session")
        new.action = #selector(AppDelegate.newSession(_:))
        sidebarControls = NSStackView(views: [toggle, new])
        sidebarControls.spacing = 2
        super.init()

        strip.region = .main
        strip.setContentHuggingPriority(.init(1), for: .horizontal)
        strip.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        strip.heightAnchor.constraint(equalToConstant: 38).isActive = true
        // ChatGPT's order: the row's "+", then the conversation's own controls,
        // a hairline, and the panel toggles at the far end.
        let trailing = NSStackView(views: [add, ToolbarDivider(), more, running,
                                           ToolbarDivider(), bottomToggle, sideToggle])
        trailing.spacing = 4
        let row = NSStackView(views: [sidebarControls, strip, trailing])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        leading = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            leading,
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setSidebarCollapsed(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setSidebarCollapsed(_ collapsed: Bool) {
        sidebarControls.isHidden = !collapsed
        leading.constant = collapsed ? Chrome.trafficLightInset : 8
    }
}

/// Over the side column: its tabs, then "+" and the column's toggle at the
/// trailing end.
@MainActor
final class SideColumnBar: ChromeBarView {
    let strip = SideTabStrip()
    let add = HoverFillButton.glyph("plus", "New Tab")
    let toggle = HoverFillButton.glyph("sidebar.right", "Hide Side Column")
    /// Shown when this row is the leftmost with the sidebar collapsed: the
    /// way back to the sidebar, where the main area's row would carry it.
    let sidebarToggle = HoverFillButton.glyph("sidebar.left", "Show Sidebar")
    private var stripLeading: NSLayoutConstraint!

    override init() {
        super.init()
        toggle.isSelected = true
        sidebarToggle.action = #selector(AppDelegate.toggleSessionSidebar(_:))
        sidebarToggle.isHidden = true
        sidebarToggle.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        let trailing = NSStackView(views: [add, toggle])
        trailing.spacing = 4
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebarToggle)
        addSubview(strip)
        addSubview(trailing)
        stripLeading = strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            sidebarToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.trafficLightInset),
            sidebarToggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            stripLeading,
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            strip.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    convenience init() {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Running")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        toolTip = "Running in this session"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        wantsLayer = true
        dot.cornerRadius = 3
        dot.isHidden = true
        layer?.addSublayer(dot)
    }

    func show(_ snapshot: RunningJobsSnapshot) {
        let status = snapshot.status
        let count = snapshot.work.count + snapshot.orphans.count
        dotColor = snapshot.hasWork ? (status.isServing ? .systemGreen : .secondaryLabelColor) : nil
        dot.isHidden = dotColor == nil
        needsDisplay = true
        toolTip = count == 0 ? "Nothing running in this session"
            : "\(count) \(count == 1 ? "job" : "jobs") running: \(([status.title] + status.ports).joined(separator: " "))"
        setAccessibilityLabel(toolTip)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // On the glyph's shoulder, as a badge sits.
        dot.frame = NSRect(x: bounds.maxX - 10, y: isFlipped ? 5 : bounds.maxY - 11, width: 6, height: 6)
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
        mainBar.bottomToggle.target = self
        mainBar.bottomToggle.action = #selector(toggleBottom)
        sideBar.toggle.target = self
        sideBar.toggle.action = #selector(toggleSideColumn)
        sideBar.add.target = self
        sideBar.add.action = #selector(presentNewTabMenu(_:))
        mainBar.add.target = self
        mainBar.add.action = #selector(presentNewTabMenu(_:))
        mainBar.running.target = self
        mainBar.running.action = #selector(openRunningJobs(_:))
        mainBar.more.target = self
        mainBar.more.action = #selector(presentSessionMenu(_:))

        // The column's tab row.
        sideBar.strip.onSelect = { [weak self] tab in self?.git.select(tab) }
        sideBar.strip.onClose = { [weak self] tab in self?.git.requestClose(tab) }
        sideBar.strip.onCloseOthers = { [weak self] keep in
            guard let self else { return }
            self.git.select(keep)
            for tab in self.git.tabs where tab != keep { self.git.requestClose(tab) }
        }
        sideBar.strip.onMove = { [weak self] tab, region in self?.git.move(tab, to: region, at: .max) }
        // The main area's row.
        mainBar.strip.onSelect = { [weak self] tab in self?.git.selectMain(tab) }
        mainBar.strip.onClose = { [weak self] tab in self?.git.requestClose(tab) }
        mainBar.strip.onCloseOthers = { [weak self] keep in
            guard let self else { return }
            for tab in self.git.mainTabs where tab != keep && tab != .session {
                self.git.requestClose(tab)
            }
        }
        mainBar.strip.onMove = { [weak self] tab, region in self?.git.move(tab, to: region, at: .max) }
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
        mainBar.sideToggle.isHidden = git.isVisible
        mainBar.bottomToggle.isSelected = git.bottomVisible
        mainBar.bottomToggle.toolTip = git.bottomVisible ? "Hide Bottom Strip" : "Show Bottom Strip"
        let titles = manager.selected?.sideTerminalTitles ?? [:]
        func item(_ tab: SideTab) -> SideTabStrip.Item {
            switch tab {
            case .pane(let pane):
                return .init(tab: tab, title: pane.title, symbol: pane.symbol)
            case .terminal(let id):
                return .init(tab: tab, title: Self.terminalTitle(titles[id]), symbol: "apple.terminal")
            case .session:
                // The session's own terminal: pinned first, by the session's name.
                let name = manager.selected.map { SessionName.leaf(of: $0.name) } ?? "Terminal"
                return .init(tab: tab, title: name, symbol: "terminal", pinned: true)
            }
        }
        sideBar.strip.update(items: git.tabs.map(item), active: git.activeTab)
        mainBar.strip.update(items: git.mainTabs.map(item), active: git.activeMainTab ?? .session)
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

    @objc private func toggleBottom() {
        git.toggleBottom()
    }

    /// The "+" menu. Native and small, like the ChatGPT app's own menus: a
    /// terminal first, because a new one is what "+" usually means, then the
    /// panes, then whatever the session is serving, the groups set apart by
    /// separators rather than labels. No
    /// checkmarks on the panes that are already open, since choosing one does the
    /// useful thing either way: it brings that tab to the front.
    ///
    /// Right-aligned under the button, so it opens into the window rather than
    /// off its side.
    @objc private func presentNewTabMenu(_ sender: NSView) {
        // "+" means here: the row whose button it is.
        let region: TabRegion = sender === mainBar.add ? .main : .side
        let menu = NSMenu()
        menu.autoenablesItems = false

        let terminal = ClosureMenuItem(title: "New Terminal") { [weak self] in
            if region == .main { self?.git.openMainTerminal() } else { self?.git.openTerminal() }
        }
        Self.setGlyph("apple.terminal", on: terminal)
        if region == .side {
            terminal.keyEquivalent = "`"
            terminal.keyEquivalentModifierMask = [.control]
        }
        menu.addItem(terminal)

        menu.addItem(.separator())
        for pane in InspectorPane.allCases {
            let item = ClosureMenuItem(title: pane.title) { [weak self] in
                self?.git.open(.pane(pane), in: region)
            }
            Self.setGlyph(pane.symbol, on: item)
            // How much is waiting in Changes, as a native count badge.
            if pane == .changes, let count = git.repo?.status.changes.count, count > 0 {
                item.badge = NSMenuItemBadge(count: count)
            }
            menu.addItem(item)
        }

        // What the session holds a port open for, to open in the browser.
        let servers = (runningSnapshot.work + runningSnapshot.orphans).filter { $0.localURL != nil }
        if !servers.isEmpty {
            menu.addItem(.separator())
            for job in servers {
                guard let url = job.localURL, let address = job.localAddress else { continue }
                let item = ClosureMenuItem(title: address) { NSWorkspace.shared.open(url) }
                Self.setGlyph("globe", on: item)
                item.toolTip = job.label
                menu.addItem(item)
            }
        }

        let x = sender.bounds.width - menu.size.width
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: sender.bounds.height + 4), in: sender)
    }

    /// The session's "…": its own actions, as ChatGPT's menu is the
    /// conversation's. Native, small, glyphs that show, shortcuts on the right.
    @objc private func presentSessionMenu(_ sender: NSView) {
        guard let session = manager.selected else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let rename = ClosureMenuItem(title: "Rename") { [weak self] in
            self?.manager.editingID = session.id
        }
        Self.setGlyph("pencil", on: rename)
        rename.keyEquivalent = "r"
        rename.keyEquivalentModifierMask = [.command]
        menu.addItem(rename)

        let destinations = manager.folderNames.filter { $0 != session.folderPath }
        if session.folderPath != nil || !destinations.isEmpty {
            let submenu = NSMenu()
            if session.folderPath != nil {
                submenu.addItem(ClosureMenuItem(title: "Top Level") { [weak self] in
                    self?.manager.moveSession(id: session.id, toFolder: nil, at: .max)
                })
            }
            for folder in destinations {
                submenu.addItem(ClosureMenuItem(title: folder) { [weak self] in
                    self?.manager.moveSession(id: session.id, toFolder: folder, at: .max)
                })
            }
            let move = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
            Self.setGlyph("folder", on: move)
            move.submenu = submenu
            menu.addItem(move)
        }

        menu.addItem(.separator())
        let branch = ClosureMenuItem(title: "New Session on Branch\u{2026}") { [weak self] in
            guard let self else { return }
            newSessionOnBranch(self.manager, inFolder: session.folderPath)
        }
        Self.setGlyph("arrow.triangle.branch", on: branch)
        menu.addItem(branch)

        if let cwd = session.cwd {
            let reveal = ClosureMenuItem(title: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
            }
            Self.setGlyph("folder.badge.gearshape", on: reveal)
            menu.addItem(reveal)
            let copy = ClosureMenuItem(title: "Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cwd, forType: .string)
            }
            Self.setGlyph("doc.on.doc", on: copy)
            menu.addItem(copy)
        }

        menu.addItem(.separator())
        let close = ClosureMenuItem(title: "Close Session") { [weak self] in
            self?.manager.requestClose(session)
        }
        Self.setGlyph("xmark.square", on: close)
        close.keyEquivalent = "w"
        close.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(close)

        let x = sender.bounds.width - menu.size.width
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: sender.bounds.height + 4), in: sender)
    }

    private static func setGlyph(_ symbol: String, on item: NSMenuItem) {
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
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
