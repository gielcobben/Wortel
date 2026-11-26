import CoreGraphics
import Foundation

// Mark-up: pointing at what a preview shows and saying something about it,
// for an agent to read (docs/architecture/mark-up.md). This file is the part
// with no view in it: what a mark is, and what is written down about it.

/// The colours marks take, in turn. The system's own, in the Finder's tag
/// order where the Finder has them. Yellow is left out: a 3pt yellow line on
/// a white page can't be read. They repeat after seven, which is why a mark
/// also has a number.
enum MarkColour: Int, CaseIterable {
    case red, orange, green, blue, purple, pink, teal

    static func of(_ number: Int) -> MarkColour {
        allCases[((number - 1) % allCases.count + allCases.count) % allCases.count]
    }

    /// What the details file calls it, for a sentence like "the red one".
    var name: String {
        switch self {
        case .red: return "red"
        case .orange: return "orange"
        case .green: return "green"
        case .blue: return "blue"
        case .purple: return "purple"
        case .pink: return "pink"
        case .teal: return "teal"
        }
    }
}

/// What an area is drawn with. The pen is a hand's own line; the others are
/// for what a hand draws badly: a straight-sided box, an arrow from one
/// thing to another, a wide see-through stroke over text.
enum MarkPen: String, CaseIterable {
    case pen, box, arrow, highlighter

    /// What a mark drawn with it is called, before its number.
    var word: String {
        switch self {
        case .pen: return "area"
        case .box: return "box"
        case .arrow: return "arrow"
        case .highlighter: return "highlight"
        }
    }

    /// How wide its line is, and how much of what is under it shows through.
    var width: CGFloat { self == .highlighter ? 14 : MarkStroke.width }
    var opacity: CGFloat { self == .highlighter ? 0.35 : 1 }
}

/// The tool in hand while marking up: one of the pens, or the one that
/// moves a drawing already made.
enum MarkupTool: Equatable, CaseIterable {
    // The box first: it is what is in hand to begin with. Most marks say
    // "this area", and a box says it exactly, where a hand's loop is rough.
    case box, pen, arrow, highlighter, move

    /// What it draws with, or nil for the one that draws nothing.
    var pen: MarkPen? {
        switch self {
        case .pen: return .pen
        case .box: return .box
        case .arrow: return .arrow
        case .highlighter: return .highlighter
        case .move: return nil
        }
    }

    var name: String {
        switch self {
        case .pen: return "Pen"
        case .box: return "Box"
        case .arrow: return "Arrow"
        case .highlighter: return "Highlighter"
        case .move: return "Move"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "scribble"
        case .box: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .highlighter: return "highlighter"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

/// One thing pointed at: an element that was picked, or an area that was
/// drawn around.
struct Mark: Identifiable, Equatable {
    /// 1, 2, 3 in the order they were made. Never reused while a note
    /// lives: a number on the page and in a sentence has to stay the same
    /// thing when the mark before it is removed.
    let number: Int
    var id: Int { number }
    var colour: MarkColour { .of(number) }

    enum Shape: Equatable {
        /// The whole of what it is tied to: a picked element.
        case thing
        /// A drawn area. The box and the ink are in the units of what the
        /// mark is tied to, measured from its origin, so they move and
        /// scale with it (`MarkPlacement`).
        case area(box: CGRect, ink: [CGPoint])
    }

    let shape: Shape
    /// What it is called without its number: `button "Download"`, or "area".
    let name: String
    /// The picture's file name in the note's folder, once it is written.
    var picture: String?
    var details: MarkDetails
    /// What a drawn area was drawn with. A picked element has no pen.
    var pen = MarkPen.pen

    /// How a chip and the copied text refer to it. An element has a name of
    /// its own; a drawn mark only has what it is and its number.
    var reference: String {
        if case .area = shape { return "\(pen.word) \(number)" }
        return name
    }
}

/// Where a mark is now, in the view the marks lie over: the origin and size
/// of what it is tied to, how many points one of its units is, and the part
/// of the view it may show in (a mark inside a scrolling panel is cut off
/// where the panel is).
struct MarkPlacement: Equatable {
    var origin: CGPoint
    var size: CGSize
    var scale: CGFloat
    var clip: CGRect

    /// The mark's box in the view.
    func box(of shape: Mark.Shape) -> CGRect {
        switch shape {
        case .thing:
            return CGRect(origin: origin, size: size)
        case .area(let box, _):
            return CGRect(x: origin.x + box.minX * scale, y: origin.y + box.minY * scale,
                          width: box.width * scale, height: box.height * scale)
        }
    }

    /// Where a mark's numbered badge goes: on the corner of a picked
    /// element, and where the hand began on a drawn area, so the number
    /// touches the ink it belongs to (on the corner of the area's box it
    /// floated beside a loop, belonging to nothing).
    func badge(of shape: Mark.Shape) -> CGPoint {
        if case .area(_, let ink) = shape, let first = ink.first { return point(first) }
        return box(of: shape).origin
    }

    /// A point of the ink in the view.
    func point(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }
}

/// Where a mark has to go for its chip's click to show it.
///
/// What is brought into view is the mark's own box, never the thing it is
/// tied to: a box drawn on a page is tied to the element around it, which
/// can be the whole of a long article, and centring that put the box 350
/// to 1,300pt off the screen (measured 2026-11-25). And "in view" is the
/// room left uncovered: the note bar floats over the bottom of the preview,
/// and a mark under it counted as shown.
enum MarkReveal {
    /// How far `box` has to move to be shown in `room`, both in one view's
    /// points. Nothing when it is wholly there already: a mark in view
    /// stays where the eye found it. Otherwise, on each side where it is
    /// not inside, to the middle of the room, or where it is larger than
    /// the room, its start to the room's start: a mark's top and left are
    /// where it begins, and its middle could be anything. `moving` says
    /// the view has scrolled up or down for it already (to a block that
    /// was not built): it is placed as one that had to move, even where
    /// that scroll happened to leave it inside.
    static func shift(_ box: CGRect, into room: CGRect, moving: Bool = false) -> CGVector {
        guard !box.isNull, !room.isNull, room.width > 0, room.height > 0 else { return .zero }
        let slack: CGFloat = 0.5
        func along(_ start: CGFloat, _ length: CGFloat, _ roomStart: CGFloat, _ roomLength: CGFloat,
                   settled: Bool) -> CGFloat {
            if settled, start >= roomStart - slack, start + length <= roomStart + roomLength + slack { return 0 }
            if length <= roomLength { return (roomStart + roomLength / 2) - (start + length / 2) }
            return roomStart - start
        }
        return CGVector(dx: along(box.minX, box.width, room.minX, room.width, settled: true),
                        dy: along(box.minY, box.height, room.minY, room.height, settled: !moving))
    }

    /// The part of a view of `size` that the note bar does not cover, when
    /// it covers `covered` points of its bottom.
    static func room(_ size: CGSize, coveredBelow covered: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: size.width, height: max(size.height - max(covered, 0), 0))
    }
}

/// What the details file says about a mark. Everything optional is left out
/// of the file when a kind of preview has nothing to say there.
struct MarkDetails: Codable, Equatable {
    var number = 0
    var colour = ""
    /// "element" or "area".
    var kind = ""
    /// What a drawn area was drawn with: "pen", "box", "arrow", "highlighter".
    var shape: String?
    var name = ""
    var picture: String?
    /// Where it is in the page or file, in its own units: x, y, width, height.
    var bounds: [Double]?

    // A page's element.
    var tag: String?
    var role: String?
    var text: String?
    var selector: String?
    /// The selector of the frame it is in, when it is in one.
    var frame: String?
    var styles: [String: String]?
    var html: String?
    /// For an area in a page: what lies inside it.
    var elements: [Inside]?

    struct Inside: Codable, Equatable {
        var name: String
        var selector: String?
        var text: String?
    }
}

/// Text that came from what was marked up, made safe to put on the
/// clipboard.
///
/// A page names its own elements: an `aria-label`, an id, a class are
/// whatever the page's author wrote. What is copied is pasted into a
/// terminal, where an escape character is an instruction and a line break
/// can end one prompt and start another. So nothing from a preview reaches
/// the note with a control character, a line or paragraph separator, or an
/// invisible formatting character (the ones that reorder text or hide in
/// it) still in it.
enum MarkText {
    /// `text` with those characters gone. On one line, every run of white
    /// space becomes one space; with `lines` kept, a new line and a tab
    /// stay (for HTML in the details file, which is written as JSON).
    static func clean(_ text: String, lines: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        var gap = false
        for scalar in text.unicodeScalars {
            if lines, scalar == "\n" || scalar == "\t" {
                out.append(scalar)
                gap = false
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                // A control character that separated words still does.
                if scalar.properties.isWhitespace || scalar == "\n" || scalar == "\t" { gap = true }
                continue
            case .spaceSeparator:
                if lines { out.append(" ") } else { gap = true }
                continue
            default:
                if gap, !out.isEmpty { out.append(" ") }
                gap = false
                out.append(scalar)
            }
        }
        return String(out)
    }
}

/// What was marked up: the first lines of the details file, and the line
/// under the sentence in what is copied.
enum MarkupSubject: Equatable {
    case page(String)
    /// A file and the view of it: "Source", "Diff", "Rendered".
    case file(path: String, view: String?)

    var line: String {
        switch self {
        // A file's name may hold a line break; the line it is named on may not.
        case .page(let address): return "Page: \(MarkText.clean(address))"
        case .file(let path, let view):
            let path = MarkText.clean(path)
            return view.map { "File: \(path) (\($0))" } ?? "File: \(path)"
        }
    }
}

/// The details file.
struct MarkupDetailsFile: Codable, Equatable {
    var page: String?
    var file: String?
    var view: String?
    /// The picture of the whole, when there is one.
    var whole: String?
    var marks: [MarkDetails]

    init(subject: MarkupSubject, whole: String?, marks: [MarkDetails]) {
        switch subject {
        case .page(let address): page = address
        case .file(let path, let view):
            file = path
            self.view = view
        }
        self.whole = whole
        self.marks = marks
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}
