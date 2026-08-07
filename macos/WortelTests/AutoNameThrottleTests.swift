import XCTest

/// The gate in front of auto-naming, against a fake clock.
///
/// Every rule here fails invisibly. Too eager and the sidebar relabels itself
/// while you're reading it; too shy and a session keeps a name that stopped
/// being true an hour ago; and a summariser that fails on every turn will retry
/// on every turn forever unless the cooldown counts attempts rather than
/// successes. None of that shows up as a crash or a failed build.
final class AutoNameThrottleTests: XCTestCase {
    private let throttle = AutoNameThrottle()
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// A screen with `count` distinct, substantial lines.
    private func screen(_ count: Int, salt: String = "") -> String {
        (0..<count).map { "line \($0)\(salt) with enough text on it to be worth reading" }
            .joined(separator: "\n")
    }

    private func lines(_ screen: String) -> Set<Int> {
        AutoNameThrottle.fingerprint(screen)
    }

    // MARK: - First look

    func testFirstNamingProceeds() {
        XCTAssertEqual(throttle.decide(screen: screen(20), state: .init(), now: start),
                       .proceed(lines: lines(screen(20))))
    }

    /// A fresh shell, a cleared terminal, a session showing only a prompt —
    /// there is nothing there to name, and naming it anyway produces a title
    /// invented out of a shell prompt.
    func testTooLittleOnScreen() {
        XCTAssertEqual(throttle.decide(screen: "$ ", state: .init(), now: start),
                       .tooLittleOnScreen)
        // Long enough in characters, but only a couple of lines.
        let wide = String(repeating: "x", count: 200) + "\n" + String(repeating: "y", count: 200)
        XCTAssertEqual(throttle.decide(screen: wide, state: .init(), now: start),
                       .tooLittleOnScreen)
    }

    // MARK: - Growth

    /// The rule that matters: a screen that *changed* isn't a screen with
    /// something new to say. A spinner ticking over redraws lines endlessly.
    func testUnchangedScreenDoesNotProceed() {
        let text = screen(20)
        let state = AutoNameThrottle.State(
            lastAttemptAt: start, lastLines: lines(text))
        XCTAssertEqual(
            throttle.decide(screen: text, state: state, now: start.addingTimeInterval(600)),
            .insufficientGrowth)
    }

    func testSmallChangeDoesNotProceed() {
        let before = screen(20)
        let after = before + "\none new line\nand a second"
        let state = AutoNameThrottle.State(lastAttemptAt: start, lastLines: lines(before))
        XCTAssertEqual(
            throttle.decide(screen: after, state: state, now: start.addingTimeInterval(600)),
            .insufficientGrowth)
    }

    func testEnoughNewLinesProceeds() {
        let before = screen(20)
        let after = before + "\n" + screen(8, salt: " fresh")
        let state = AutoNameThrottle.State(lastAttemptAt: start, lastLines: lines(before))
        XCTAssertEqual(
            throttle.decide(screen: after, state: state, now: start.addingTimeInterval(600)),
            .proceed(lines: lines(after)))
    }

    /// A viewport scrolls: old lines leave as new ones arrive. Growth has to be
    /// "lines not seen before", not "more lines than before" — the latter is
    /// zero for a full screen that has scrolled a page.
    func testScrolledScreenCountsAsGrowth() {
        let before = screen(20)
        let after = screen(20, salt: " later")
        let state = AutoNameThrottle.State(lastAttemptAt: start, lastLines: lines(before))
        XCTAssertEqual(
            throttle.decide(screen: after, state: state, now: start.addingTimeInterval(600)),
            .proceed(lines: lines(after)))
    }

    // MARK: - Cooldown

    func testTooSoonAfterAnAttempt() {
        let state = AutoNameThrottle.State(lastAttemptAt: start)
        XCTAssertEqual(
            throttle.decide(screen: screen(30), state: state, now: start.addingTimeInterval(10)),
            .tooSoon)
    }

    /// The cooldown anchors on the last *attempt*, so a session whose
    /// summariser keeps failing — and therefore has no successful naming and no
    /// baseline to measure growth against — still backs off instead of
    /// respawning the model on every turn end.
    func testFailedAttemptStillHoldsTheCooldown() {
        // A failed pass records the attempt but never a baseline.
        let state = AutoNameThrottle.State(lastAttemptAt: start, lastLines: nil)
        XCTAssertEqual(
            throttle.decide(screen: screen(30), state: state, now: start.addingTimeInterval(20)),
            .tooSoon)
        XCTAssertEqual(
            throttle.decide(screen: screen(30), state: state, now: start.addingTimeInterval(60)),
            .proceed(lines: lines(screen(30))),
            "…and once it has waited, a session that never succeeded may try again")
    }

    // MARK: - In flight

    func testASecondTurnDoesNotStartASecondPass() {
        let state = AutoNameThrottle.State(inFlightSince: start)
        XCTAssertEqual(
            throttle.decide(screen: screen(30), state: state, now: start.addingTimeInterval(5)),
            .inFlight)
    }

    /// A pass that never comes back — a cancelled task, a hung model — must not
    /// wedge a session's naming for the lifetime of the app.
    func testAStalePassStopsBlocking() {
        let state = AutoNameThrottle.State(inFlightSince: start)
        XCTAssertEqual(
            throttle.decide(screen: screen(30), state: state, now: start.addingTimeInterval(600)),
            .proceed(lines: lines(screen(30))))
    }

    // MARK: - Fingerprint

    /// Whitespace-only differences are not news: an agent redrawing its frame
    /// one column over would otherwise read as a page of new content.
    func testFingerprintIgnoresBlankAndPaddingDifferences() {
        XCTAssertEqual(AutoNameThrottle.fingerprint("a\n\n  b  \n"),
                       AutoNameThrottle.fingerprint("  a\nb\n\n\n"))
    }
}
