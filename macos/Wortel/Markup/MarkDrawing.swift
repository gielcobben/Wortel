import AppKit
import CoreText

/// How a mark is drawn into a picture: its ink or its outline, and its
/// numbered badge. The layer on screen draws the same shapes with layers
/// (`MarkupOverlayView`); the sizes they share are here.
///
/// Every function draws into a context counted from the bottom-left, as
/// CoreGraphics counts, and takes points counted from the top-left with the
/// height to turn them over by. So a number in a badge is drawn upright
/// without a flipped text matrix to get wrong.
enum MarkDrawing {
    /// The outline around a picked element.
    static let outline: CGFloat = 2
    static let outlineRadius: CGFloat = 4
    /// The badge with the mark's number.
    /// 20, up from 16: at 16 the number was too small to read at a glance
    /// across a page, which is the one thing a badge is for.
    static let badge: CGFloat = 20

    static func color(_ colour: MarkColour) -> NSColor {
        switch colour {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .teal: return .systemTeal
        }
    }

    /// A mark's colour as it is in this appearance, to draw with off the
    /// main thread, where a dynamic colour has no appearance to ask.
    @MainActor
    static func resolved(_ colour: MarkColour, in appearance: NSAppearance) -> CGColor {
        var resolved = NSColor.systemRed.cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = color(colour).usingColorSpace(.sRGB)?.cgColor ?? color(colour).cgColor
        }
        return resolved
    }

    /// The colours of a mark's chip in the note.
    struct Chip {
        var fill: NSColor
        var number: NSColor
        var name: NSColor
    }

    /// How a chip is coloured. At rest, a tint of its mark's colour with the
    /// number in that colour. Selected, solid in it with its words on top,
    /// as a token in Mail or an `NSTokenField` is selected: the system's
    /// selection behind a chip was a block taller and wider than the
    /// capsule, with the capsule floating in it (the owner, 2026-11-25).
    /// Selected in a window that is not key, or with the keyboard elsewhere,
    /// the fill is at 40% and the words are the label's colour, as the
    /// system dims a selection it is not acting on. 40 and not half: at
    /// half, white words on orange, green and teal in the dark were under
    /// 4.5:1 over the bar.
    static func chip(_ colour: MarkColour, selected: Bool, emphasised: Bool) -> Chip {
        let ink = color(colour)
        guard selected else { return Chip(fill: ink.withAlphaComponent(0.15), number: ink, name: .labelColor) }
        guard emphasised else {
            return Chip(fill: ink.withAlphaComponent(0.4), number: .labelColor, name: .labelColor)
        }
        let words = onSolid(colour)
        return Chip(fill: ink, number: words, name: words)
    }

    /// The least contrast white has to have on a solid chip to be used:
    /// 3:1, WCAG's floor for bold or large text and for a control. No mark
    /// colour reaches the 4.5 of body text with white (measured on macOS
    /// 27): red, blue, purple and pink are 3.2 to 4.2 light and dark, and
    /// get white; orange, green and teal are 1.9 to 2.3, and get black,
    /// which is over 9 on them.
    static let leastContrast: CGFloat = 3

    /// The words on a solid chip: white where white can be read on the
    /// mark's colour, black where it cannot. Worked out for the appearance
    /// it is drawn in, since the system's colours are lighter in the dark.
    static func onSolid(_ colour: MarkColour) -> NSColor {
        NSColor(name: nil) { appearance in
            var fill = CGColor(gray: 0, alpha: 1)
            appearance.performAsCurrentDrawingAppearance {
                fill = color(colour).usingColorSpace(.sRGB)?.cgColor ?? fill
            }
            return contrast(CGColor(gray: 1, alpha: 1), fill) >= leastContrast
                ? .white : NSColor.black.withAlphaComponent(0.85)
        }
    }

    /// The contrast of two opaque colours, as WCAG measures it: 1 to 21.
    static func contrast(_ one: CGColor, _ other: CGColor) -> CGFloat {
        func luminance(_ colour: CGColor) -> CGFloat {
            let srgb = colour.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent,
                                        options: nil) ?? colour
            let parts = srgb.components ?? [0, 0, 0]
            let (r, g, b) = parts.count >= 3 ? (parts[0], parts[1], parts[2]) : (parts[0], parts[0], parts[0])
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let a = luminance(one), b = luminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Draw one mark. `placement` is where it is, in units counted from the
    /// top-left of something `height` units tall; `unit` is how many of
    /// those one drawn point should be, so a picture shrunk to fit keeps a
    /// line that can be seen.
    static func draw(_ mark: Mark, at placement: MarkPlacement, colour: CGColor,
                     in context: CGContext, height: CGFloat, unit: CGFloat = 1, badge: Bool,
                     within bounds: CGRect? = nil) {
        func turned(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: height - point.y) }
        let box = placement.box(of: mark.shape)
        context.saveGState()
        context.setStrokeColor(colour)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch mark.shape {
        case .thing:
            let rect = CGRect(x: box.minX, y: height - box.maxY, width: box.width, height: box.height)
                .insetBy(dx: -outline * unit / 2, dy: -outline * unit / 2)
            context.setLineWidth(outline * unit)
            context.addPath(CGPath(roundedRect: rect,
                                   cornerWidth: min(outlineRadius * unit, rect.width / 2),
                                   cornerHeight: min(outlineRadius * unit, rect.height / 2), transform: nil))
            context.strokePath()
        case .area(_, let ink):
            context.setLineWidth(mark.pen.width * unit)
            context.setAlpha(mark.pen.opacity)
            // A marker's ends are cut square.
            if mark.pen == .highlighter { context.setLineCap(.butt) }
            context.addPath(MarkStroke.path(for: mark.pen, through: ink.map { turned(placement.point($0)) },
                                            unit: unit))
            context.strokePath()
        }
        context.restoreGState()
        if badge {
            var centre = placement.badge(of: mark.shape)
            // Whole, also on a mark at the picture's very edge.
            if let bounds {
                let half = Self.badge * unit / 2
                centre.x = min(max(centre.x, bounds.minX + half), max(bounds.maxX - half, bounds.minX + half))
                centre.y = min(max(centre.y, bounds.minY + half), max(bounds.maxY - half, bounds.minY + half))
            }
            self.badge(mark.number, centre: turned(centre),
                       diameter: Self.badge * unit, colour: colour, in: context)
        }
    }

    /// A filled circle in the mark's colour with its number in white.
    static func badge(_ number: Int, centre: CGPoint, diameter: CGFloat, colour: CGColor, in context: CGContext) {
        context.saveGState()
        context.setFillColor(colour)
        context.fillEllipse(in: CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2,
                                       width: diameter, height: diameter))
        // Two digits still fit the circle.
        let size = diameter * (number > 9 ? 0.5 : 0.62)
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let text = NSAttributedString(string: String(number), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: centre.x - bounds.midX, y: centre.y - bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// The pictures a note is copied with.
enum MarkupPicture {
    /// The widest a picture of the whole is, in pixels, and the tallest. A
    /// long page shrunk to fit a screen would make its marks specks, and an
    /// agent pays for every pixel it reads.
    static let widest: CGFloat = 1600
    static let tallest: CGFloat = 16_000
    /// Past this many screens tall, the picture is the stretch that holds
    /// the marks, with a screen above and below, and says so.
    static let screens: CGFloat = 12
    /// And that stretch is this many screens at most, from its top: marks
    /// at both ends of a 9,000-line file are not one picture.
    static let longest: CGFloat = 24

    /// The part of the whole to picture: all of it, or for something very
    /// tall the stretch from a screen above the first mark to a screen
    /// below the last.
    static func part(of size: CGSize, screen: CGFloat, marks: [CGRect]) -> (rect: CGRect, isPart: Bool) {
        let all = CGRect(origin: .zero, size: size)
        guard screen >= 1, size.height > screens * screen, let first = marks.first else { return (all, false) }
        let around = marks.dropFirst().reduce(first) { $0.union($1) }
        let top = max(0, around.minY - screen)
        let bottom = min(size.height, around.maxY + screen, top + longest * screen)
        guard bottom > top else { return (all, false) }
        return (CGRect(x: 0, y: top, width: size.width, height: bottom - top).integral.intersection(all), true)
    }

    /// How many pixels a unit of the part gets: two, as a Retina screen
    /// shows it, or fewer when that would be wider or taller than allowed.
    static func density(for part: CGSize) -> CGFloat {
        guard part.width >= 1, part.height >= 1 else { return 1 }
        return min(2, widest / part.width, tallest / part.height)
    }

    /// The whole with every mark drawn on it. Called off the main thread.
    static func whole(_ whole: MarkupWhole, marks: [Mark], colours: [Int: CGColor])
        -> (image: CGImage, kind: MarkupNote.Whole.Kind, missing: [Int])? {
        let placed = marks.compactMap { mark in whole.placements[mark.number].map { (mark, $0) } }
        let canvas: MarkupCanvas
        switch whole.source {
        case .canvas(let made):
            canvas = made
        case .draw(let draw):
            let (part, isPart) = Self.part(of: whole.size, screen: whole.visible.height,
                                           marks: placed.map { $0.1.box(of: $0.0.shape) })
            guard let made = MarkupCanvas(part: part, isPart: isPart, wholeHeight: whole.size.height,
                                          background: whole.background) else { return nil }
            made.context.saveGState()
            draw(made.context)
            made.context.restoreGState()
            canvas = made
        }
        // A line stays two pixels wide at least, however far it is shrunk.
        let unit = max(1, 1.5 / canvas.density)
        // A mark with no place, or outside what is pictured, is not in the
        // picture, and the note says which.
        var drawn: Set<Int> = []
        for (mark, placement) in placed where placement.box(of: mark.shape).intersects(canvas.part) {
            drawn.insert(mark.number)
            guard let colour = colours[mark.number] else { continue }
            MarkDrawing.draw(mark, at: placement, colour: colour, in: canvas.context,
                             height: whole.size.height, unit: unit, badge: true, within: canvas.part)
        }
        let kind: MarkupNote.Whole.Kind = canvas.isView ? .view : canvas.isPart ? .part : .all
        let missing = marks.map(\.number).filter { !drawn.contains($0) }
        return canvas.context.makeImage().map { ($0, kind, missing) }
    }

    /// A picture of a drawn area with its ink on it. `rect` is the part of
    /// the view the picture shows; the mark's placement is in the same view.
    static func inked(_ image: CGImage, showing rect: CGRect, mark: Mark, at placement: MarkPlacement,
                      colour: CGColor) -> CGImage {
        guard rect.width >= 1, rect.height >= 1,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.scaleBy(x: CGFloat(image.width) / rect.width, y: CGFloat(image.height) / rect.height)
        var moved = placement
        moved.origin.x -= rect.minX
        moved.origin.y -= rect.minY
        MarkDrawing.draw(mark, at: moved, colour: colour, in: context, height: rect.height, badge: false)
        return context.makeImage() ?? image
    }
}
