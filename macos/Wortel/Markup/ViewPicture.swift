import AppKit

/// Pictures of views the app draws itself, for mark-up over a file.
@MainActor
enum ViewPicture {
    /// The page's own colour, as this view shows it. A file's views draw no
    /// background of their own (the page behind them does), so a picture of
    /// one alone would be dark text on nothing.
    static func background(of view: NSView) -> CGColor {
        var colour = CGColor(gray: 1, alpha: 1)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            colour = Chrome.content.usingColorSpace(.sRGB)?.cgColor ?? Chrome.content.cgColor
        }
        return colour
    }

    /// What `view` shows in `rect` (its own coordinates), on the page's
    /// colour. The mark-up layer is never in it: it is no part of `view`.
    static func capture(_ view: NSView, rect: CGRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        guard let shot = rep.cgImage else { return nil }
        return onBackground(shot, background(of: view))
    }

    /// What a scroll view of the app's own shows in `rect` of the layer over
    /// it, and the part of `rect` that is: there is nothing to picture past
    /// the clip view's edge.
    static func capture(_ rect: CGRect, of scroll: NSScrollView, under layer: NSView) -> MarkCapture? {
        let clip = scroll.contentView
        let shown = scroll.clip(in: layer).intersection(rect).integral
        guard !shown.isNull, let image = capture(clip, rect: clip.convert(shown, from: layer)) else { return nil }
        return MarkCapture(image: image, showing: shown)
    }

    /// The most pixels a side of a mark's picture has. What a file says its
    /// size is, is the file's to say: an SVG can declare any width, and a
    /// mark across it must not ask for a bitmap that large.
    static let mostPixels = 4096

    /// `image` on a colour, made smaller when a side is over `mostPixels`.
    static func onBackground(_ image: CGImage, _ background: CGColor) -> CGImage? {
        let shrink = min(1, CGFloat(mostPixels) / CGFloat(max(image.width, 1)),
                         CGFloat(mostPixels) / CGFloat(max(image.height, 1)))
        let width = max(Int((CGFloat(image.width) * shrink).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * shrink).rounded()), 1)
        guard let context = CGContext.picture(width: width, height: height) else { return nil }
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(background)
        context.fill(all)
        context.draw(image, in: all)
        return context.makeImage()
    }

    /// Draw a stretch of what a scroll view scrolls into a canvas, a
    /// screen at a time: scroll, let the views lay out, take a picture,
    /// and put the scroll back where it was.
    ///
    /// All in one turn of the run loop, so nothing on screen moves: the
    /// window is only drawn again after the scroll is back. `top` and
    /// `bottom` are in the document view's coordinates; `place` says where
    /// a stretch of the document belongs in the canvas's whole.
    static func tiles(of scroll: NSScrollView, from top: CGFloat, to bottom: CGFloat,
                      into canvas: MarkupCanvas, place: (CGRect) -> CGRect) {
        let clip = scroll.contentView
        let start = clip.bounds.origin
        defer {
            clip.scroll(to: start)
            scroll.reflectScrolledClipView(clip)
            scroll.layoutSubtreeIfNeeded()
        }
        var y = top
        for _ in 0..<64 where y < bottom {
            let wanted = NSRect(x: start.x, y: y, width: clip.bounds.width, height: clip.bounds.height)
            clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
            scroll.reflectScrolledClipView(clip)
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            let shown = scroll.documentVisibleRect
            if let image = capture(clip, rect: clip.bounds) {
                canvas.draw(image, at: place(shown))
            }
            // At the document's end the scroll stops short of what was asked.
            guard shown.maxY > y + 1 else { break }
            y = shown.maxY
        }
    }
}
