import AppKit
import WebKit

/// Mark-up over a page: where its elements are, what is under the pointer,
/// and pictures of it.
///
/// WebKit scrolls a page in another process and tells the app after, so the
/// marks follow what the page's script reports (`WebMarkupScript`), not the
/// scroll itself. Measured 2026-11-25 (macOS 27.0.1, 120 Hz, a clear window,
/// scroll events sent to the web view): a report reached the app a median
/// 0.6 ms after its scroll event on an idle page (5.4 ms at most), and
/// 14.6 ms (41 ms at most) on a page whose main thread was busy 40 of every
/// 50 ms. So a mark lands in the same frame or the next, and trails by as
/// long as the page stalls. The layer shows that as it is: marks that are
/// waiting for a report are drawn faint (`MarkupOverlayView`).
///
/// Pictures are WebKit's own: `takeSnapshot` for an area, whose rect is in
/// the view's points from the top-left and exact at 2x and under page zoom,
/// and `createPDF` for the whole page, which holds what is below the fold
/// without scrolling (a 6,000pt page in 8 ms). A snapshot has nothing past
/// the view's edge (it comes back white), so a mark's picture is the part
/// of it that was showing.
@MainActor
final class WebMarkupSurface: NSObject, MarkupSurface, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private var moved: (() -> Void)?
    private var latest = WebMarkReport()
    private var isActive = false

    /// One probe at a time: a pointer moves faster than a page answers, and
    /// only the newest place is worth asking about.
    private var probing = false
    private var nextProbe: (CGPoint, (CGRect?) -> Void)?

    /// A world of Wortel's own. The page's scripts cannot see what runs in
    /// it, nor post to its message handler.
    static let world = WKContentWorld.world(name: "wortel.markup")

    init(webView: WKWebView) {
        self.webView = webView
    }

    var view: NSView? { webView }
    var picksThings: Bool { true }
    var scrollsInside: Bool { false }
    var readingColumn: CGRect? { nil }

    /// The view's points per CSS pixel.
    private var zoom: CGFloat { max(webView?.pageZoom ?? 1, 0.01) }

    // MARK: - On and off

    /// The layer has the web view's own frame (`MarkupOverlayView.follow`),
    /// so the two share coordinates and there is nothing to convert.
    func attach(to layer: NSView) {}

    func activate(moved: @escaping () -> Void) {
        self.moved = moved
        guard let webView, !isActive else { return }
        isActive = true
        // What the page last said is from before mark-up was turned off,
        // and the page has scrolled since. Nothing is known, and no mark
        // is drawn, until it says where they are now: on a page whose main
        // thread was busy the marks otherwise stood a scroll away from
        // their content for a frame or more (measured 2026-11-25: 40pt off
        // at 17 ms, right at 42 ms).
        latest = WebMarkReport()
        webView.configuration.userContentController
            .add(self, contentWorld: Self.world, name: WebMarkupScript.handler)
        call("\(WebMarkupScript.source); window.__wortelMarkup.start(); return window.__wortelMarkup.report()") {
            [weak self] body in self?.take(body)
        }
    }

    func deactivate(forgetting: Bool) {
        moved = nil
        nextProbe = nil
        guard let webView, isActive else {
            // Off already, with a note that is now gone: the script still
            // holds which elements it was on.
            if forgetting {
                latest = WebMarkReport()
                ask("destroy()")
            }
            return
        }
        isActive = false
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: WebMarkupScript.handler, contentWorld: Self.world)
        // With a note to come back to, the script keeps which elements its
        // marks are on and nothing else: no listener, no observer. With
        // none, it takes itself out of the page.
        ask(forgetting ? "destroy()" : "stop()")
        if forgetting { latest = WebMarkReport() }
    }

    /// The page went elsewhere: its script and its elements went with it.
    func pageLeft() {
        latest = WebMarkReport()
    }

    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { take(message.body) }
    }

    private func take(_ body: Any?) {
        guard isActive, let body, let report = WebMarkReport(body) else { return }
        latest = report
        moved?()
    }

    // MARK: - Asking the page

    private func call(_ body: String, arguments: [String: Any] = [:], reply: @escaping (Any?) -> Void) {
        guard let webView else { return reply(nil) }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Self.world) { result in
            MainActor.assumeIsolated { reply(try? result.get()) }
        }
    }

    /// Call one of the script's functions, where the script is in the page.
    /// Nil where it is not: the page went elsewhere, or mark-up was never
    /// on here.
    private func ask(_ function: String, arguments: [String: Any] = [:], reply: @escaping (Any?) -> Void = { _ in }) {
        call("return window.__wortelMarkup ? window.__wortelMarkup.\(function) : null",
             arguments: arguments, reply: reply)
    }

    private static func rect(_ body: Any?) -> CGRect? {
        guard let values = body as? [Double], values.count == 4,
              values.allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else { return nil }
        return CGRect(x: values[0], y: values[1], width: max(values[2], 0), height: max(values[3], 0))
    }

    /// A string the page gave, cut to a length and with nothing in it that
    /// a terminal would act on or that does not show (`MarkText`): the
    /// page's author chose it.
    private static func text(_ value: Any?, most: Int, lines: Bool = false) -> String? {
        MarkText.fromPage(value, most: most, lines: lines)
    }

    /// A selector the page gave: as it was, or none (`MarkText`).
    private static func selector(_ value: Any?) -> String? {
        MarkText.selectorFromPage(value)
    }

    // MARK: - Marks

    func probe(at point: CGPoint, reply: @escaping (CGRect?) -> Void) {
        guard isActive else { return reply(nil) }
        if probing {
            nextProbe = (point, reply)
            return
        }
        probing = true
        let zoom = zoom
        ask("probe(x, y)", arguments: ["x": point.x / zoom, "y": point.y / zoom]) { [weak self] body in
            guard let self else { return }
            self.probing = false
            reply(Self.rect(body).map { $0.applying(CGAffineTransform(scaleX: zoom, y: zoom)) })
            if let (point, reply) = self.nextProbe {
                self.nextProbe = nil
                self.probe(at: point, reply: reply)
            }
        }
    }

    func pick(_ number: Int, at point: CGPoint, unless picked: [Int], reply: @escaping (MarkPick?) -> Void) {
        let zoom = zoom
        ask("pick(n, x, y, picked)",
            arguments: ["n": number, "x": point.x / zoom, "y": point.y / zoom, "picked": picked]) { [weak self] body in
            // Only a number that was asked about: the page's answer is read
            // with the same suspicion as a report.
            if let already = (body as? [String: Any])?["already"] as? Int {
                return reply(picked.contains(already) ? .already(already) : nil)
            }
            reply(self?.tie(number, from: body).map(MarkPick.tied))
        }
    }

    func tie(_ number: Int, to box: CGRect, reply: @escaping (MarkTie?) -> Void) {
        let zoom = zoom
        ask("tie(n, l, t, w, h)",
            arguments: ["n": number, "l": box.minX / zoom, "t": box.minY / zoom,
                        "w": box.width / zoom, "h": box.height / zoom]) { [weak self] body in
            reply(self?.tie(number, from: body))
        }
    }

    /// The page's answer to a pick or a tie, read with the same suspicion as
    /// a report.
    private func tie(_ number: Int, from body: Any?) -> MarkTie? {
        guard let answer = body as? [String: Any],
              let rect = Self.rect(answer["rect"]), let clip = Self.rect(answer["clip"]) else { return nil }
        let fixed = answer["fixed"] as? Bool ?? false
        // Placed at once, from the answer: the next report may be a scroll away.
        latest.marks[number] = .init(rect: rect, clip: clip, lost: false, fixed: fixed)
        if let scroll = answer["scroll"] as? [Double], scroll.count == 2 {
            latest.scroll = CGPoint(x: scroll[0], y: scroll[1])
        }
        guard let placement = latest.placement(of: number, zoom: zoom) else { return nil }

        let raw = answer["details"] as? [String: Any] ?? [:]
        var details = MarkDetails()
        details.tag = Self.text(raw["tag"], most: 40)
        details.role = Self.text(raw["role"], most: 40)
        details.text = Self.text(raw["text"], most: 220)
        details.selector = Self.selector(raw["selector"])
        details.frame = Self.selector(raw["frame"])
        details.html = Self.text(raw["html"], most: 2100, lines: true)
        if let styles = raw["styles"] as? [String: Any] {
            var kept: [String: String] = [:]
            for (key, value) in styles.prefix(20) {
                if let key = Self.text(key, most: 40), let value = Self.text(value, most: 200) { kept[key] = value }
            }
            details.styles = kept.isEmpty ? nil : kept
        }
        if let elements = raw["elements"] as? [[String: Any]], !elements.isEmpty {
            details.elements = elements.prefix(20).compactMap { element in
                guard let name = Self.text(element["name"], most: 120) else { return nil }
                return .init(name: name, selector: Self.selector(element["selector"]),
                             text: Self.text(element["text"], most: 100))
            }
        }
        return MarkTie(placement: placement, name: Self.text(raw["name"], most: 120), details: details)
    }

    func placement(of number: Int) -> MarkPlacement? {
        latest.placement(of: number, zoom: zoom)
    }

    func forget(_ number: Int) {
        latest.marks[number] = nil
        ask("forget(n)", arguments: ["n": number])
    }

    // MARK: - Scrolling

    /// Measured by the page itself, at the moment it scrolls: the last
    /// report may be a resize or a scroll behind.
    func reveal(_ mark: Mark, coveredBelow covered: CGFloat) {
        // A drawn area's box is in CSS pixels from its element's corner.
        var part: Any = NSNull()
        if case .area(let box, _) = mark.shape {
            part = [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)]
        }
        ask("reveal(n, part, below, smooth)",
            arguments: ["n": mark.number, "part": part, "below": Double(covered / zoom),
                        "smooth": !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion])
    }

    /// Not at the page's end that way, by its last report.
    func expectsMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        latest.wouldScroll(deltaX: deltaX, deltaY: deltaY)
    }

    // MARK: - Pictures

    func capture(_ rect: CGRect, reply: @escaping (MarkCapture?) -> Void) {
        guard let webView else { return reply(nil) }
        // Whole points, and no further than the view: past its edge a
        // snapshot is white.
        let wanted = rect.intersection(webView.bounds).integral.intersection(webView.bounds)
        guard !wanted.isNull, wanted.width >= 1, wanted.height >= 1 else { return reply(nil) }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = wanted
        // What is on screen now, which is what was pointed at.
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated {
                var proposed = CGRect(origin: .zero, size: image?.size ?? .zero)
                reply(image?.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
                    .map { MarkCapture(image: $0, showing: wanted) })
            }
        }
    }

    func whole(_ marks: [Mark], reply: @escaping (MarkupWhole?) -> Void) {
        guard let webView else { return reply(nil) }
        // The PDF's points per CSS pixel: the page zoom, as in the view
        // (`zoom`). Not the PDF's width over the page's: the page's width
        // is the wider of the root's and the body's, and `createPDF` lays
        // out the root's alone. On a page that hides what is wider than the
        // view (`html, body { overflow-x: hidden }` and a 1,200px row in an
        // 800pt view), that put every mark and every `bounds` two thirds of
        // the way to the top-left (found in review, 2026-11-27). Measured
        // then: the PDF is the laid-out width times the zoom, at zoom 1 and
        // 1.5, with and without the rule, in standards and quirks mode.
        let perPixel = zoom
        // Where the marks are first, then the page: asked in this order so
        // the two describe the same moment as nearly as two calls can.
        ask("report()") { body in
            guard let body, let report = WebMarkReport(body) else { return reply(nil) }
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                MainActor.assumeIsolated {
                    guard let data = try? result.get(),
                          let provider = CGDataProvider(data: data as CFData),
                          let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
                        return reply(nil)
                    }
                    let box = page.getBoxRect(.mediaBox)
                    guard box.width >= 1, box.height >= 1 else { return reply(nil) }
                    let held = PDFPage(page: page, box: box)
                    reply(MarkupWhole(
                        draw: { context in
                            context.translateBy(x: -held.box.minX, y: -held.box.minY)
                            context.drawPDFPage(held.page)
                        },
                        size: box.size,
                        visible: report.visibleInPicture(perPixel: perPixel),
                        placements: report.placementsInPicture(perPixel: perPixel, size: box.size)))
                }
            }
        }
    }

    /// A PDF page, to draw on another thread. Drawing one is all that is
    /// done with it there.
    private struct PDFPage: @unchecked Sendable {
        let page: CGPDFPage
        let box: CGRect
    }
}
