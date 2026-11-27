import CoreGraphics
import Foundation

/// What a page's script says about where its marks are, read.
///
/// One flat list of numbers per report: the page's scroll and size, then ten
/// numbers a mark. Numbers only, and checked here, because the list crosses
/// from a web page's process: a page cannot post to the handler (it is in a
/// world of Wortel's own), but what arrives is still read as if it could be
/// anything.
struct WebMarkReport: Equatable {
    /// How far the page is scrolled, and its size and the view's, in CSS
    /// pixels.
    var scroll = CGPoint.zero
    var view = CGSize.zero
    /// The wider and the taller of the root's and the body's scroll size:
    /// for whether a scroll moves anything (`wouldScroll`), not for scale.
    var page = CGSize.zero
    var marks: [Int: Entry] = [:]

    struct Entry: Equatable {
        /// What the mark is tied to, in the view, in CSS pixels.
        var rect: CGRect
        /// The part of the view it may show in.
        var clip: CGRect
        /// The element is gone from the page.
        var lost: Bool
        /// It does not scroll with the page (a fixed header).
        var fixed: Bool
    }

    static let header = 6
    static let perMark = 10
    /// More marks than anyone draws; past it the report is refused whole.
    static let most = 200

    init() {}

    init?(_ body: Any) {
        guard let raw = body as? [Any], raw.count >= Self.header else { return nil }
        var values: [Double] = []
        values.reserveCapacity(raw.count)
        for item in raw {
            guard let number = item as? NSNumber else { return nil }
            let value = number.doubleValue
            guard value.isFinite, abs(value) < 1e7 else { return nil }
            values.append(value)
        }
        let count = (values.count - Self.header) / Self.perMark
        guard (values.count - Self.header) % Self.perMark == 0, count <= Self.most else { return nil }
        scroll = CGPoint(x: values[0], y: values[1])
        view = CGSize(width: values[2], height: values[3])
        page = CGSize(width: values[4], height: values[5])
        for index in 0..<count {
            let at = Self.header + index * Self.perMark
            let number = Int(values[at])
            guard number > 0, Double(number) == values[at] else { return nil }
            let flags = Int(values[at + 9])
            marks[number] = Entry(
                rect: CGRect(x: values[at + 1], y: values[at + 2],
                             width: max(values[at + 3], 0), height: max(values[at + 4], 0)),
                clip: CGRect(x: values[at + 5], y: values[at + 6],
                             width: max(values[at + 7], 0), height: max(values[at + 8], 0)),
                lost: flags & 1 != 0, fixed: flags & 2 != 0)
        }
    }

    /// Where a mark is in the web view, whose points are CSS pixels times
    /// the page's zoom (measured 2026-11-25: an element at CSS 100, 200 is
    /// at 150, 300 in the view at zoom 1.5).
    func placement(of number: Int, zoom: CGFloat) -> MarkPlacement? {
        guard let entry = marks[number], !entry.lost else { return nil }
        return MarkPlacement(
            origin: CGPoint(x: entry.rect.minX * zoom, y: entry.rect.minY * zoom),
            size: CGSize(width: entry.rect.width * zoom, height: entry.rect.height * zoom),
            scale: zoom,
            clip: CGRect(x: entry.clip.minX * zoom, y: entry.clip.minY * zoom,
                         width: entry.clip.width * zoom, height: entry.clip.height * zoom))
    }

    /// Whether a scroll by these deltas would move the page: it is not at
    /// its end that way. A wheel turned at the bottom of a page moves
    /// nothing, and nothing is then owed. A positive delta is a scroll
    /// towards the top or the left, as AppKit counts it.
    func wouldScroll(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        let slack: CGFloat = 0.5
        if deltaY > 0, scroll.y > slack { return true }
        if deltaY < 0, scroll.y + view.height < page.height - slack { return true }
        if deltaX > 0, scroll.x > slack { return true }
        if deltaX < 0, scroll.x + view.width < page.width - slack { return true }
        return false
    }

    /// Where a mark is in the whole page, in CSS pixels: where it is in the
    /// view plus the scroll, except for what does not scroll, which a
    /// picture of the whole page shows at the top.
    func placementInPage(of number: Int) -> MarkPlacement? {
        guard let entry = marks[number], !entry.lost else { return nil }
        let offset = entry.fixed ? CGPoint.zero : scroll
        return MarkPlacement(
            origin: CGPoint(x: entry.rect.minX + offset.x, y: entry.rect.minY + offset.y),
            size: entry.rect.size, scale: 1,
            clip: CGRect(origin: .zero, size: page))
    }

    /// Where each mark is in a picture of the whole page `size` points in
    /// all, at `perPixel` points a CSS pixel. That is the page zoom, never
    /// the picture's width over `page`'s: `page` is as wide as the widest
    /// of what is in it, hidden or not, and the picture is as wide as the
    /// page is laid out (`WebMarkupSurface.whole`).
    func placementsInPicture(perPixel: CGFloat, size: CGSize) -> [Int: MarkPlacement] {
        var placements: [Int: MarkPlacement] = [:]
        for number in marks.keys {
            guard let inPage = placementInPage(of: number) else { continue }
            placements[number] = MarkPlacement(
                origin: CGPoint(x: inPage.origin.x * perPixel, y: inPage.origin.y * perPixel),
                size: CGSize(width: inPage.size.width * perPixel, height: inPage.size.height * perPixel),
                scale: perPixel, clip: CGRect(origin: .zero, size: size))
        }
        return placements
    }

    /// What was in view, in that picture.
    func visibleInPicture(perPixel: CGFloat) -> CGRect {
        CGRect(x: scroll.x * perPixel, y: scroll.y * perPixel,
               width: view.width * perPixel, height: view.height * perPixel)
    }
}
