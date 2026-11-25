import Foundation

/// The note, as what is copied.
///
/// Plain text, because it is pasted wherever the person wants it: this
/// session's agent, another one, an issue. A chip becomes what it points at
/// in words a person can read, with the path of its picture beside it, so an
/// agent that can read this disk opens the picture and one that cannot still
/// has the sentence.
enum MarkupNote {
    /// The note in order: what was typed, and the marks dropped into it.
    enum Piece: Equatable {
        case text(String)
        case mark(Int)
    }

    /// A mark as the copied text needs it.
    struct Reference: Equatable {
        let text: String
        /// The picture's path, when it was written.
        let picture: String?
    }

    /// What Return puts on the clipboard.
    ///
    /// The sentence first, then what was marked up, the picture of the
    /// whole and the details file, each on a line of its own with a word
    /// saying what it is. A note of chips alone still gives each mark its
    /// reference and its picture.
    static func copied(pieces: [Piece], marks: [Int: Reference], subject: MarkupSubject,
                       whole: String?, wholeIsPart: Bool, details: String?) -> String {
        var sentence = ""
        // A chip sits in the sentence as a word does: a space each side,
        // unless one is there, it opens the line, or punctuation follows.
        var afterMark = false
        for piece in pieces {
            switch piece {
            case .text(let text):
                guard let first = text.first else { continue }
                if afterMark, !first.isWhitespace, !first.isPunctuation { sentence += " " }
                sentence += text
                afterMark = false
            case .mark(let number):
                guard let mark = marks[number] else { continue }
                if let last = sentence.last, !last.isWhitespace, last != "(" { sentence += " " }
                sentence += mark.picture.map { "\(mark.text) (\($0))" } ?? mark.text
                afterMark = true
            }
        }
        // No space left hanging at either end of a line.
        let tidy = sentence.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lines = [tidy, "", subject.line]
        if let whole {
            lines.append((wholeIsPart ? "The part with the marks: " : "All marks: ") + whole)
        }
        if let details { lines.append("Details: \(details)") }
        return lines.joined(separator: "\n")
    }
}
