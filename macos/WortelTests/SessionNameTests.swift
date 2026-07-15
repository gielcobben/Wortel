import XCTest

/// A session's folder isn't a field — it's the part of the name before the last
/// slash, so `SessionName` *is* the folder feature, and a session moves between
/// folders only by its name changing. That makes these splits worth pinning:
/// getting one wrong doesn't throw, it silently relocates a session.
final class SessionNameTests: XCTestCase {

    // MARK: - The split

    /// Last slash, not first. A name is one folder plus one leaf, so a nested
    /// path is folder "a/b" — not a tree, and not folder "a" with leaf "b/c".
    func testSplitsOnTheLastSlash() {
        XCTAssertEqual(SessionName.folder(of: "Wakker/Worker"), "Wakker")
        XCTAssertEqual(SessionName.leaf(of: "Wakker/Worker"), "Worker")

        XCTAssertEqual(SessionName.folder(of: "a/b/c"), "a/b")
        XCTAssertEqual(SessionName.leaf(of: "a/b/c"), "c")
    }

    func testTopLevelNameHasNoFolder() {
        XCTAssertNil(SessionName.folder(of: "Manager"))
        XCTAssertEqual(SessionName.leaf(of: "Manager"), "Manager")
    }

    /// Both halves are trimmed, so a name typed with spaces around the slash
    /// groups with the same folder as one without.
    func testTrimsAroundTheSlash() {
        XCTAssertEqual(SessionName.folder(of: "Wakker / Worker"), "Wakker")
        XCTAssertEqual(SessionName.leaf(of: "Wakker / Worker"), "Worker")
    }

    /// Names that are all prefix or all leaf have no usable other half. Falling
    /// back to the whole name keeps a row from rendering blank.
    func testDegenerateNamesFallBackToTheWholeName() {
        XCTAssertNil(SessionName.folder(of: "/Worker"), "no prefix is a top-level session")
        XCTAssertEqual(SessionName.leaf(of: "/Worker"), "Worker")

        XCTAssertEqual(SessionName.folder(of: "Wakker/"), "Wakker")
        XCTAssertEqual(SessionName.leaf(of: "Wakker/"), "Wakker/", "no leaf to show, so show the name")
    }

    // MARK: - Rename selection

    /// The bug this exists for: the rename field holds the *full* name, so
    /// opening it with everything selected meant the first keystroke ate the
    /// folder prefix and the session jumped to the top level. Selecting only the
    /// leaf has to leave the prefix — and therefore the folder — intact.
    func testTypingOverTheSelectionKeepsTheFolder() throws {
        let name = "Wakker/Worker"
        let range = try XCTUnwrap(SessionName.leafRange(of: name))

        let renamed = (name as NSString).replacingCharacters(in: range, with: "Boss")
        XCTAssertEqual(renamed, "Wakker/Boss")
        XCTAssertEqual(SessionName.folder(of: renamed), SessionName.folder(of: name),
                       "a rename through the selection must not move the session")
    }

    /// AppKit's text system counts in UTF-16, so a prefix containing anything
    /// outside the BMP (an emoji folder name) would slide the selection off the
    /// leaf if the range were computed in Characters.
    func testSelectionIsUTF16OffsetForEmojiPrefixes() {
        let name = "🚀/Worker"
        guard let range = SessionName.leafRange(of: name) else { return XCTFail("expected a leaf") }

        XCTAssertEqual((name as NSString).substring(with: range), "Worker")
        XCTAssertEqual(range.location, 3, "🚀 is two UTF-16 units, plus the slash")
    }

    /// The selection covers what the row displayed — no leading space picked up
    /// from a name typed with spaces around the slash.
    func testSelectionMatchesTheDisplayedLeaf() {
        for name in ["Wakker/Worker", "Wakker / Worker", "a/b/c", "🚀/Worker"] {
            let range = SessionName.leafRange(of: name)
            let selected = range.map { (name as NSString).substring(with: $0) }
            XCTAssertEqual(selected, SessionName.leaf(of: name), "for \(name)")
        }
    }

    /// nil means "leave the field's default whole-string selection alone": a
    /// top-level session has nothing to narrow to, and an all-prefix name has no
    /// leaf. Both are the pre-existing select-all behaviour, deliberately.
    func testNoLeafToSelect() {
        XCTAssertNil(SessionName.leafRange(of: "Manager"), "no slash, so select all as before")
        XCTAssertNil(SessionName.leafRange(of: "Wakker/"), "nothing after the slash")
        XCTAssertNil(SessionName.leafRange(of: "Wakker/   "), "nothing but spaces after the slash")
    }
}
