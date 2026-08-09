import XCTest

/// The file tree's git decoration: which rows are coloured, and which collapsed
/// directories get a dot for work hidden inside them.
///
/// Worth pinning because every failure mode here is silent. A directory that
/// fails to roll up simply looks clean — you'd only notice by expanding it and
/// being surprised. A directory that rolls up something it doesn't contain looks
/// *dirty*, sending the reader hunting for a change that isn't there. Neither
/// throws, and the panel has no other test coverage.
final class FileTreeDecorationsTests: XCTestCase {
    private func change(_ path: String, _ code: Character,
                        staged: Bool = false, untracked: Bool = false) -> GitFileChange {
        GitFileChange(path: path, originalPath: nil, statusCode: code,
                      staged: staged, untracked: untracked)
    }

    // MARK: - Ancestors

    /// The reason this type exists. `src/foo` and `src/foobar` share a string
    /// prefix but not a path component, so a `hasPrefix` roll-up would decorate
    /// a sibling directory that contains nothing changed at all.
    func testSiblingSharingAStringPrefixIsNotAnAncestor() {
        let decorations = FileTreeDecorations(changes: [change("src/foo/app.swift", "M")])
        XCTAssertEqual(decorations.code(forRelativePath: "src/foo", isDirectory: true), "M")
        XCTAssertNil(decorations.code(forRelativePath: "src/foobar", isDirectory: true),
                     "a shared string prefix is not containment")
    }

    func testEveryAncestorRollsUp() {
        let decorations = FileTreeDecorations(changes: [change("macos/Wortel/Git/DiffView.swift", "M")])
        for directory in ["macos", "macos/Wortel", "macos/Wortel/Git"] {
            XCTAssertEqual(decorations.code(forRelativePath: directory, isDirectory: true), "M", directory)
        }
    }

    /// A file at the repo root has no ancestor to decorate — and in particular
    /// must not invent an empty-string directory, which would be a row that
    /// exists in the dictionary and nowhere in the tree.
    func testRootLevelFileHasNoAncestors() {
        XCTAssertEqual(FileTreeDecorations.ancestors(of: "README.md"), [])
        let decorations = FileTreeDecorations(changes: [change("README.md", "?")])
        XCTAssertEqual(decorations.code(forRelativePath: "README.md", isDirectory: false), "?")
        XCTAssertNil(decorations.code(forRelativePath: "", isDirectory: true))
    }

    func testAncestorsAreInnermostFirst() {
        XCTAssertEqual(FileTreeDecorations.ancestors(of: "a/b/c/d.txt"), ["a/b/c", "a/b", "a"])
    }

    // MARK: - Repo-relative paths

    /// The other half of containment, and the input to everything above: a row
    /// in the tree knows its filesystem path, and every git question about it is
    /// asked in repo-relative terms.
    func testPathInsideTheRootIsRelativeToIt() {
        XCTAssertEqual(
            FileTreeDecorations.relativePath(of: "/Users/x/wortel/macos/Wortel", in: "/Users/x/wortel"),
            "macos/Wortel")
    }

    /// The root is the project. It has a path — the empty one — and the panel
    /// relies on that being distinguishable from "not in this repo", because the
    /// first is a row it draws undecorated and the second is a row it can't
    /// answer for at all.
    func testTheRootItselfIsTheEmptyPath() {
        XCTAssertEqual(FileTreeDecorations.relativePath(of: "/Users/x/wortel", in: "/Users/x/wortel"), "")
    }

    /// The same trap as `ancestors`, one level down. A sibling checkout is a
    /// different project, and answering with *something* would send
    /// `check-ignore` and the decoration lookup at whatever happens to sit at
    /// that path inside this repo.
    func testSiblingSharingAStringPrefixIsNotInsideTheRoot() {
        XCTAssertNil(FileTreeDecorations.relativePath(of: "/Users/x/wortel-old/README.md",
                                                      in: "/Users/x/wortel"))
        XCTAssertNil(FileTreeDecorations.relativePath(of: "/Users/x/other", in: "/Users/x/wortel"))
    }

    /// A root with a trailing slash is what you get from a path built by
    /// appending, and it must not eat the first character of every answer.
    func testTrailingSlashOnTheRootIsTolerated() {
        XCTAssertEqual(FileTreeDecorations.relativePath(of: "/Users/x/wortel/web", in: "/Users/x/wortel/"),
                       "web")
    }

    // MARK: - Significance

    /// A file can be in the changes list twice — staged one way, modified
    /// another. The row is one row, so the more significant code has to win
    /// regardless of which order they arrive in, or the colour depends on how
    /// git happened to print them.
    func testStagedAndUnstagedPairResolvesToTheMoreSignificantCode() {
        let forwards = FileTreeDecorations(changes: [
            change("app.swift", "A", staged: true),
            change("app.swift", "M"),
        ])
        let backwards = FileTreeDecorations(changes: [
            change("app.swift", "M"),
            change("app.swift", "A", staged: true),
        ])
        XCTAssertEqual(forwards.code(forRelativePath: "app.swift", isDirectory: false), "M")
        XCTAssertEqual(backwards.code(forRelativePath: "app.swift", isDirectory: false), "M")
    }

    /// A directory's dot stands for everything under it, so it reports the most
    /// significant thing there — a deletion isn't masked by an untracked file
    /// that happens to sort first.
    func testDirectoryReportsItsMostSignificantDescendant() {
        let decorations = FileTreeDecorations(changes: [
            change("src/new.swift", "?", untracked: true),
            change("src/gone.swift", "D"),
            change("src/edited.swift", "M"),
        ])
        XCTAssertEqual(decorations.code(forRelativePath: "src", isDirectory: true), "D")
    }

    // MARK: - Files vs directories

    /// The two maps are deliberately separate: a *file* is coloured for its own
    /// status only. Answering a file lookup from the directory roll-up would
    /// colour every file in a dirty folder.
    func testUnchangedFileInAChangedDirectoryIsNotDecorated() {
        let decorations = FileTreeDecorations(changes: [change("src/edited.swift", "M")])
        XCTAssertNil(decorations.code(forRelativePath: "src/untouched.swift", isDirectory: false))
        XCTAssertEqual(decorations.code(forRelativePath: "src", isDirectory: true), "M")
    }

    func testEmptyStatusDecoratesNothing() {
        let decorations = FileTreeDecorations(changes: [])
        XCTAssertNil(decorations.code(forRelativePath: "src", isDirectory: true))
        XCTAssertNil(decorations.code(forRelativePath: "src/app.swift", isDirectory: false))
    }
}
