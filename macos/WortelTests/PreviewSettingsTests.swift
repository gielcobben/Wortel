import XCTest

/// The reading size ⌘+/⌘− move. Small surface, but the clamp is a `didSet` that
/// assigns to its own property — correct as written, and one careless edit away
/// from unbounded recursion or a size that walks past its own bounds.
@MainActor
final class PreviewSettingsTests: XCTestCase {
    private static let key = "preview.fontSize"
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: Self.key)
        saved = nil
        super.tearDown()
    }

    func testStartsAtTheDefault() {
        XCTAssertEqual(PreviewSettings().fontSize, PreviewSettings.defaultFontSize)
    }

    func testStepsByOnePoint() {
        let settings = PreviewSettings()
        settings.increase()
        XCTAssertEqual(settings.fontSize, PreviewSettings.defaultFontSize + 1)
        settings.decrease()
        XCTAssertEqual(settings.fontSize, PreviewSettings.defaultFontSize)
    }

    func testHoldingTheShortcutStopsAtTheBounds() {
        let settings = PreviewSettings()
        for _ in 0..<50 { settings.increase() }
        XCTAssertEqual(settings.fontSize, PreviewSettings.range.upperBound)
        for _ in 0..<50 { settings.decrease() }
        XCTAssertEqual(settings.fontSize, PreviewSettings.range.lowerBound)
    }

    func testAssigningOutOfRangeClampsRatherThanRecurses() {
        let settings = PreviewSettings()
        settings.fontSize = 999
        XCTAssertEqual(settings.fontSize, PreviewSettings.range.upperBound)
        settings.fontSize = -10
        XCTAssertEqual(settings.fontSize, PreviewSettings.range.lowerBound)
    }

    func testResetReturnsToTheDefault() {
        let settings = PreviewSettings()
        settings.increase()
        settings.increase()
        settings.reset()
        XCTAssertEqual(settings.fontSize, PreviewSettings.defaultFontSize)
    }

    /// One reading size for every preview, remembered across launches — the
    /// point of persisting it at all.
    func testSizeSurvivesANewInstance() {
        let settings = PreviewSettings()
        settings.increase()
        settings.increase()
        XCTAssertEqual(PreviewSettings().fontSize, PreviewSettings.defaultFontSize + 2)
    }

    /// A stored value from an older build with a different range must not come
    /// back as an unreadable window.
    func testStoredValueOutsideTheRangeFallsBackToTheDefault() {
        UserDefaults.standard.set(400.0, forKey: Self.key)
        XCTAssertEqual(PreviewSettings().fontSize, PreviewSettings.defaultFontSize)
    }

    func testNoStoredValueIsNotReadAsZero() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        XCTAssertEqual(PreviewSettings().fontSize, PreviewSettings.defaultFontSize,
                       "UserDefaults.double returns 0 for a missing key")
    }
}
