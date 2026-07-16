import XCTest

final class DiffParserTests: XCTestCase {
    func testParsesKindsAndLineNumbers() {
        let patch = """
        diff --git a/f.txt b/f.txt
        index 1234567..89abcde 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -10,3 +10,4 @@ func something() {
         context line
        -removed line
        +added line
        +another added
        """
        let result = DiffParser.parse(patch)
        XCTAssertFalse(result.isBinary)
        XCTAssertFalse(result.truncated)

        // Headers are dropped; the hunk header is kept as its own kind.
        XCTAssertEqual(result.lines.map(\.kind),
                       [.hunkHeader, .context, .deletion, .addition, .addition])
        XCTAssertEqual(result.lines[1].text, "context line")
        XCTAssertEqual(result.lines[2].text, "removed line")
        XCTAssertEqual(result.lines[3].text, "added line")

        // Counters start at the hunk header and advance per side.
        XCTAssertEqual(result.lines[1].oldLine, 10)
        XCTAssertEqual(result.lines[1].newLine, 10)
        XCTAssertEqual(result.lines[2].oldLine, 11)
        XCTAssertNil(result.lines[2].newLine, "a deletion has no new-side number")
        XCTAssertNil(result.lines[3].oldLine, "an addition has no old-side number")
        XCTAssertEqual(result.lines[3].newLine, 11)
    }

    func testDropsEveryFileHeaderKind() {
        let patch = """
        diff --git a/old.txt b/new.txt
        similarity index 95%
        rename from old.txt
        rename to new.txt
        old mode 100644
        new mode 100755
        new file mode 100644
        deleted file mode 100644
        index abc..def
        --- a/old.txt
        +++ b/new.txt
        @@ -1 +1 @@
        +only real line
        \\ No newline at end of file
        """
        let result = DiffParser.parse(patch)
        XCTAssertEqual(result.lines.map(\.kind), [.hunkHeader, .addition])
        XCTAssertEqual(result.lines[1].text, "only real line")
    }

    func testTagsLinesWithTheirFilePath() {
        let patch = """
        diff --git a/web/src/app.ts b/web/src/app.ts
        index 1234567..89abcde 100644
        --- a/web/src/app.ts
        +++ b/web/src/app.ts
        @@ -1,2 +1,2 @@
         const x = 1
        +const y = 2
        """
        let result = DiffParser.parse(patch)
        // Hunk header and every content line carry the post-image path.
        XCTAssertEqual(result.lines.map(\.path), Array(repeating: "web/src/app.ts", count: result.lines.count))
    }

    func testMultiFileCommitDiffTagsEachFile() {
        // A whole-commit diff (History pane) concatenates files; the path must
        // switch at each file boundary so highlighting can pick a grammar.
        let patch = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1 @@
        +let a = 1
        diff --git a/b/style.css b/b/style.css
        --- a/b/style.css
        +++ b/b/style.css
        @@ -1 +1 @@
        +.x { color: red }
        """
        let result = DiffParser.parse(patch)
        let swift = result.lines.filter { $0.text.contains("let a") }
        let css = result.lines.filter { $0.text.contains("color: red") }
        XCTAssertEqual(swift.first?.path, "a.swift")
        XCTAssertEqual(css.first?.path, "b/style.css")
    }

    func testDeletionTakesPathFromGitHeader() {
        // The new-side marker is /dev/null, so the path comes from `diff --git`.
        let patch = """
        diff --git a/gone.py b/gone.py
        deleted file mode 100644
        --- a/gone.py
        +++ /dev/null
        @@ -1 +0,0 @@
        -x = 1
        """
        let result = DiffParser.parse(patch)
        XCTAssertEqual(result.lines.last?.path, "gone.py")
    }

    func testBinaryPatch() {
        let result = DiffParser.parse("""
        diff --git a/img.png b/img.png
        Binary files a/img.png and b/img.png differ
        """)
        XCTAssertTrue(result.isBinary)
    }

    /// Regression: a regenerated lock file produced a 51MB / 600k-line patch that
    /// took 1.2s to parse — on the main actor, freezing the terminal too.
    func testHugePatchIsCappedAndFlagged() {
        var patch = "diff --git a/yarn.lock b/yarn.lock\n@@ -1,1 +1,1 @@\n"
        // Comfortably over the byte ceiling.
        for i in 0..<60_000 {
            patch += "+  resolved-package-\(i) \"https://registry.example.com/pkg\(i)/-/pkg\(i)-1.0.0.tgz\"\n"
        }
        XCTAssertGreaterThan(patch.utf8.count, DiffParser.maxBytes, "fixture must exceed the cap")

        let result = DiffParser.parse(patch)
        XCTAssertTrue(result.truncated, "an oversized patch must say it was cut")
        XCTAssertLessThanOrEqual(result.lines.count, DiffParser.maxLines)
        XCTAssertFalse(result.lines.isEmpty, "the head of the patch is still shown")
    }

    /// The byte ceiling is the one that matters for speed — splitting the string
    /// costs the same whether or not the lines are kept, so it has to bite before
    /// the split. A minified bundle is exactly this: enormous lines, few of them,
    /// sailing under the line cap. Without the byte cap this patch parses in full.
    func testFewEnormousLinesHitTheByteCap() {
        var patch = "@@ -1,1 +1,1 @@\n"
        let long = String(repeating: "x", count: 30_000)
        for i in 0..<120 { patch += "+\(i)\(long)\n" }

        XCTAssertGreaterThan(patch.utf8.count, DiffParser.maxBytes, "fixture must exceed the byte cap")
        XCTAssertLessThan(121, DiffParser.maxLines, "and must stay well under the line cap")

        let result = DiffParser.parse(patch)
        XCTAssertTrue(result.truncated, "the byte ceiling must catch few-but-huge lines")
        XCTAssertLessThan(result.lines.count, 121, "the tail must actually be dropped")
    }

    /// The line ceiling catches a patch of many short lines that never trips the
    /// byte ceiling.
    func testManyShortLinesHitTheLineCap() {
        var patch = "@@ -1,1 +1,1 @@\n"
        for i in 0..<(DiffParser.maxLines + 5_000) { patch += "+x\(i)\n" }
        XCTAssertLessThan(patch.utf8.count, DiffParser.maxBytes, "fixture must stay under the byte cap")

        let result = DiffParser.parse(patch)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.lines.count, DiffParser.maxLines)
    }

    /// The cap must be invisible to real diffs — a limit that mangles ordinary
    /// patches would be a worse bug than the freeze it prevents.
    func testOrdinaryPatchIsUntouched() {
        var patch = "diff --git a/a.swift b/a.swift\n@@ -1,4 +1,4 @@\n"
        for i in 0..<400 { patch += (i % 3 == 0 ? "+" : " ") + "line \(i)\n" }

        let result = DiffParser.parse(patch)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.lines.count, 401, "hunk header plus every content line")
    }

    func testEmptyAndNoTrailingPhantomLine() {
        XCTAssertTrue(DiffParser.parse("").lines.isEmpty)
        // A trailing newline must not produce an extra blank context row.
        let result = DiffParser.parse("@@ -1 +1 @@\n+only\n")
        XCTAssertEqual(result.lines.count, 2)
    }
}
