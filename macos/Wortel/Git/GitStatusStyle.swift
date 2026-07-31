import SwiftUI

/// How a git status code is coloured, shared by everything that draws one: the
/// changes list's rows and the file tree's names and roll-up dots.
///
/// It lives apart from both because the two panes are looking at the same fact
/// — this file differs from HEAD — and a reader moving between them reads the
/// colour, not the letter. Two private copies of this switch would drift the
/// first time one of them gained a case.
enum GitStatusStyle {
    /// The colour for a porcelain status code (M/A/D/R/C/?/U/T). Anything
    /// unrecognised is deliberately neutral rather than alarming.
    static func color(for code: Character) -> Color {
        switch code {
        case "M", "T": return .orange
        case "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        case "?": return .green
        case "U": return .red
        default: return .secondary
        }
    }

}
