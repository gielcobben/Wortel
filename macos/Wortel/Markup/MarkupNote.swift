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

    /// The picture of the whole, as the copied text names it.
    struct Whole: Equatable {
        enum Kind: Equatable {
            /// All of what was marked up.
            case all
            /// The stretch that holds the marks, of something very tall.
            case part
            /// What was in view at Return: rendered Markdown, which cannot
            /// be pictured further than it is built.
            case view
        }

        var path: String
        var kind = Kind.all
        /// The marks that are not in it: out of view, or on something
        /// that is gone. Said, because a reader told "all marks" looks
        /// for all of them (the first note read by an agent, 2026-11-25,
        /// had one mark of two in its picture and a line that said
        /// "the part with the marks").
        var missing: [Int] = []
    }

    /// What Return puts on the clipboard.
    ///
    /// The sentence first, then what was marked up, the picture of the
    /// whole and the details file, each on a line of its own with a word
    /// saying what it is. A note of chips alone still gives each mark its
    /// reference and its picture.
    static func copied(pieces: [Piece], marks: [Int: Reference], subject: MarkupSubject,
                       whole: Whole?, details: String?) -> String {
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
                // Whatever named the mark, it is one word of one sentence.
                let name = MarkText.clean(mark.text)
                sentence += mark.picture.map { "\(name) (\($0))" } ?? name
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
            let names = whole.missing.compactMap { marks[$0].map { MarkText.clean($0.text) } }
            var label: String
            switch whole.kind {
            case .all: label = names.isEmpty ? "All marks" : "The whole"
            case .part: label = "The part with the marks"
            case .view: label = "What was in view"
            }
            if !names.isEmpty {
                let listed = names.count == 1 ? names[0]
                    : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
                label += " (\(listed) \(names.count == 1 ? "is" : "are") not in it)"
            }
            lines.append("\(label): \(whole.path)")
        }
        if let details { lines.append("Details: \(details)") }
        return lines.joined(separator: "\n")
    }
}
