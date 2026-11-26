import AppKit

/// What every split's row is: a bar with a strip of tabs, that can make room
/// at its leading end for the sidebar's controls laid over the titlebar.
@MainActor
protocol LeafBar: ChromeBarView {
    var strip: SideTabStrip { get }
    var leadingClearance: CGFloat { get set }
    var trailingClearance: CGFloat { get set }
    /// Shown only while this row's split is zoomed (`ZoomedButton`).
    var unzoom: ZoomedButton { get }
}

/// One leaf of the window's tree of splits: its row on top and its page under
/// it. Every leaf is one of these, the main row's, the side split's and the
/// strip's included, which is what makes them the same thing on screen.
///
/// The row has two dresses, by where the tree has put the leaf:
///
/// - **Along the top of the window** it is a titlebar row: the titlebar's
///   height, see-through to the window's vibrancy, a hairline where the page
///   starts, the tab in front raised off the band, and its empty part moves
///   the window. Terminal on the left and Changes on the right, each with its
///   tabs in the titlebar, is what Wortel has always looked like.
/// - **Anywhere lower** it is the strip's kind of row: 36pt on a faint band
///   over the page, the tab in front raised with the page's own colour, and
///   a double-click on its empty part zooms the split.
///
/// The page is opaque under the body, and under the row too when the row is
/// not in the titlebar.
@MainActor
final class SplitLeafView: NSView {
    static let rowHeight: CGFloat = 36

    let bar: any LeafBar
    let body: NSView
    private let page = FilledView(color: Chrome.content)
    private let rowBand = FilledView(color: Chrome.stripBand)
    private var barHeight: NSLayoutConstraint!
    private var pageUnderRow: NSLayoutConstraint!
    private var pageUnderBar: NSLayoutConstraint!

    /// Whether the leaf touches the top of the window. Set by whoever lays
    /// the tree out, after each layout.
    var isAtTop = true {
        didSet { if isAtTop != oldValue { dress() } }
    }

    init(bar: any LeafBar, body: NSView) {
        self.bar = bar
        self.body = body
        super.init(frame: .zero)
        // The page first, so when it runs up behind the row it's under it.
        for view in [page, rowBand, bar, body] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        barHeight = bar.heightAnchor.constraint(equalToConstant: Chrome.titlebarHeight)
        pageUnderRow = page.topAnchor.constraint(equalTo: topAnchor)
        pageUnderBar = page.topAnchor.constraint(equalTo: bar.bottomAnchor)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            barHeight,
            rowBand.topAnchor.constraint(equalTo: bar.topAnchor),
            rowBand.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            rowBand.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowBand.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        dress()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func dress() {
        barHeight.constant = isAtTop ? Chrome.titlebarHeight : Self.rowHeight
        // One at a time: both active for a moment is a conflict.
        if isAtTop {
            pageUnderRow.isActive = false
            pageUnderBar.isActive = true
        } else {
            pageUnderBar.isActive = false
            pageUnderRow.isActive = true
        }
        rowBand.isHidden = isAtTop
        bar.isTitlebar = isAtTop
        bar.strip.isOnPage = !isAtTop
        if !isAtTop {
            if bar.leadingClearance != 0 { bar.leadingClearance = 0 }
            if bar.trailingClearance != 0 { bar.trailingClearance = 0 }
        }
    }
}
