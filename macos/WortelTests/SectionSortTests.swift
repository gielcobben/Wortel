import XCTest

/// How one sidebar section orders itself. Every way it's wrong is a row in
/// the wrong place, which nothing reports.
final class SectionSortTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000 + seconds) }

    private func facts(created: Date? = nil, sent: Date? = nil, name: String = "") -> SectionSort.Facts {
        .init(created: created, sent: sent, name: name)
    }

    func testManualIsTheStoredOrder() {
        let order = SectionSort.order([c, a, b], mode: .manual,
                                      facts: [a: facts(created: at(3)), b: facts(created: at(2)), c: facts(created: at(1))])
        XCTAssertEqual(order, [c, a, b])
    }

    func testRecentIsTheLastReturnNewestFirst() {
        let order = SectionSort.order([a, b, c], mode: .recent, facts: [
            a: facts(created: at(0), sent: at(10)),
            b: facts(created: at(5), sent: at(30)),
            c: facts(created: at(9), sent: at(20)),
        ])
        XCTAssertEqual(order, [b, c, a])
    }

    func testRecentCountsBeingMadeUntilTheFirstReturn() {
        let order = SectionSort.order([a, b], mode: .recent, facts: [
            a: facts(created: at(0), sent: at(10)),
            b: facts(created: at(20)),
        ])
        XCTAssertEqual(order, [b, a], "a new session is on top until another is sent to")
    }

    func testCreatedIgnoresReturns() {
        let order = SectionSort.order([a, b, c], mode: .created, facts: [
            a: facts(created: at(2), sent: at(100)),
            b: facts(created: at(3)),
            c: facts(created: at(1), sent: at(50)),
        ])
        XCTAssertEqual(order, [b, a, c])
    }

    /// Sessions saved before the times were kept have none: they go after
    /// those that do, in the order they had, not scattered among them.
    func testNoTimeGoesLastInStoredOrder() {
        let order = SectionSort.order([a, b, c, d], mode: .created, facts: [
            a: facts(), b: facts(created: at(1)), c: facts(), d: facts(created: at(2)),
        ])
        XCTAssertEqual(order, [d, b, a, c])
        XCTAssertEqual(SectionSort.order([a, b], mode: .recent, facts: [:]), [a, b], "no facts at all")
    }

    func testEqualTimesKeepStoredOrder() {
        let order = SectionSort.order([c, a, b], mode: .recent, facts: [
            a: facts(sent: at(5)), b: facts(sent: at(5)), c: facts(sent: at(5)),
        ])
        XCTAssertEqual(order, [c, a, b])
    }

    func testNameIsAToZAsFinderSortsIt() {
        let order = SectionSort.order([a, b, c, d], mode: .name, facts: [
            a: facts(name: "session 10"), b: facts(name: "Session 2"),
            c: facts(name: "alpha"), d: facts(name: "Écrire"),
        ])
        XCTAssertEqual(order, [c, d, b, a], "case and accents don't split it, and 2 comes before 10")
    }

    func testEqualNamesKeepStoredOrder() {
        let order = SectionSort.order([b, a], mode: .name, facts: [a: facts(name: "x"), b: facts(name: "x")])
        XCTAssertEqual(order, [b, a])
    }

    func testEveryChoiceHasATitleWithoutADash() {
        for mode in SectionSort.Mode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.title.contains("\u{2014}") || mode.title.contains("\u{2013}"))
        }
    }
}
