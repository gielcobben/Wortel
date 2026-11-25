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

    /// How a chip and the copied text refer to it. An element has a name of
    /// its own; an area only has its number.
    var reference: String {
        if case .area = shape { return "area \(number)" }
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

/// What the details file says about a mark. Everything optional is left out
/// of the file when a kind of preview has nothing to say there.
struct MarkDetails: Codable, Equatable {
    var number = 0
    var colour = ""
    /// "element" or "area".
    var kind = ""
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

/// What was marked up: the first lines of the details file, and the line
/// under the sentence in what is copied.
enum MarkupSubject: Equatable {
    case page(String)
    /// A file and the view of it: "Source", "Diff", "Rendered".
    case file(path: String, view: String?)

    var line: String {
        switch self {
        case .page(let address): return "Page: \(address)"
        case .file(let path, let view): return view.map { "File: \(path) (\($0))" } ?? "File: \(path)"
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
