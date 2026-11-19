import XCTest

/// A hibernated screen's palette colours come back as palette colours.
///
/// libghostty's dump writes every palette cell as the 24-bit value it had when
/// the dump was taken. Unchanged, a prompt saved in dark keeps the dark
/// theme's colours on a light page for as long as it stays in the scrollback.
final class SnapshotPaletteTests: XCTestCase {
    private func restore(_ text: String) -> String {
        String(decoding: SnapshotPalette.restoringIndices(Data(text.utf8)), as: UTF8.self)
    }

    private func marker(_ prefix: Int, _ index: Int) -> String {
        "\u{1B}[\(prefix);2;\(SnapshotPalette.red);\(SnapshotPalette.green);\(index)m"
    }

    func testAMarkerBecomesItsPaletteIndex() {
        XCTAssertEqual(restore("a\(marker(38, 2))b"), "a\u{1B}[38;5;2mb")
        XCTAssertEqual(restore(marker(48, 0)), "\u{1B}[48;5;0m")
        XCTAssertEqual(restore(marker(58, 255)), "\u{1B}[58;5;255m")
    }

    /// What the formatter really writes for a bold green prompt arrow.
    func testARealLineOfTheDump() {
        let line = "\u{1B}[0m\u{1B}[1m\(marker(38, 2))➜  \u{1B}[0m\u{1B}[1m\(marker(38, 6))tmp\u{1B}[0m ls"
        XCTAssertEqual(restore(line),
                       "\u{1B}[0m\u{1B}[1m\u{1B}[38;5;2m➜  \u{1B}[0m\u{1B}[1m\u{1B}[38;5;6mtmp\u{1B}[0m ls")
    }

    /// A program's own 24-bit colour is the program's, whatever theme is on.
    func testAColourTheProgramChoseIsLeftAlone() {
        for text in [
            "\u{1B}[38;2;63;185;80mx",
            "\u{1B}[48;2;165;91;3mx",
            "\u{1B}[38;2;165;90mx",
            "\u{1B}[38;2;165;90;300mx",
            "\u{1B}[38;2;165;90;1234mx",
            "\u{1B}[38;5;2mx",
            "\u{1B}[1;38;2;165;90;2mx",
            "\u{1B}[68;2;165;90;2mx",
        ] {
            XCTAssertEqual(restore(text), text)
        }
    }

    func testADumpCutShortIsPassedThrough() {
        for text in ["", "\u{1B}", "\u{1B}[38", "\u{1B}[38;2;165;90;", "\u{1B}[38;2;165;90;2", "plain"] {
            XCTAssertEqual(restore(text), text)
        }
    }

    func testEveryIndexHasAMarkerOfItsOwn() {
        let install = String(decoding: SnapshotPalette.install, as: UTF8.self)
        let entries = install.components(separatedBy: "\u{1B}\\").filter { !$0.isEmpty }
        XCTAssertEqual(entries.count, 256)
        XCTAssertEqual(entries[0], "\u{1B}]4;0;rgb:a5/5a/00")
        XCTAssertEqual(entries[10], "\u{1B}]4;10;rgb:a5/5a/0a")
        XCTAssertEqual(entries[255], "\u{1B}]4;255;rgb:a5/5a/ff")
        XCTAssertEqual(Set(entries).count, 256)
    }

    /// A slice of a larger buffer starts at an index that isn't zero.
    func testADumpThatIsASliceOfSomethingLarger() {
        let lead = "\u{1B}]11;rgb:00/00/00\u{1B}\\"
        let whole = Data((lead + marker(38, 4) + "x").utf8)
        let slice = whole.suffix(from: lead.utf8.count)
        XCTAssertEqual(String(decoding: SnapshotPalette.restoringIndices(slice), as: UTF8.self),
                       "\u{1B}[38;5;4mx")
    }
}
