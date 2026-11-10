import XCTest

/// The rollup rule a collapsed folder shows on behalf of what it hides.
///
/// Its failure mode is silence, which is the worst kind here: a folder that
/// reports something calmer than the agent blocked inside it is a session
/// waiting on you that the sidebar never mentions.
final class AttentionKindTests: XCTestCase {
    /// The whole rule: maximum, never latest. A folder holding one blocked
    /// agent and three that merely finished is *blocked*.
    func testLoudestWins() {
        XCTAssertEqual(
            AttentionKind.loudest(of: [.finished, .needsInput, .turnDone, .finished]),
            .needsInput)
        XCTAssertEqual(AttentionKind.loudest(of: [.finished, .turnDone]), .turnDone)
        XCTAssertEqual(AttentionKind.loudest(of: [.finished, .failed]), .failed)
    }

    /// Order must not matter — a calmer signal arriving later cannot displace a
    /// louder one, which is exactly what "latest wins" would do.
    func testOrderDoesNotMatter() {
        let kinds: [AttentionKind] = [.needsInput, .failed, .turnDone, .finished]
        XCTAssertEqual(AttentionKind.loudest(of: kinds), .needsInput)
        XCTAssertEqual(AttentionKind.loudest(of: kinds.reversed()), .needsInput)
    }

    /// Sessions with nothing to say are holes in the sequence, not zeros.
    func testNilsAreIgnored() {
        XCTAssertEqual(AttentionKind.loudest(of: [nil, .turnDone, nil]), .turnDone)
    }

    /// A quiet folder shows nothing at all — not a dot in the lowest colour.
    func testNothingToReport() {
        XCTAssertNil(AttentionKind.loudest(of: []))
        XCTAssertNil(AttentionKind.loudest(of: [nil, nil]))
    }

    /// The priority order the rollup depends on, pinned here so a reordering
    /// has to be deliberate: blocked beats failed beats turn-done beats
    /// finished.
    func testPriorityOrder() {
        let ordered: [AttentionKind] = [.finished, .turnDone, .failed, .needsInput]
        XCTAssertEqual(ordered.map(\.priority), [1, 2, 3, 4])
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(lower.priority, higher.priority)
        }
    }

    // MARK: - AttentionRaise

    private func decide(
        _ kind: AttentionKind, title: String = "t", body: String = "b",
        current: AttentionKind? = nil, standing: AttentionRaise.Standing? = nil,
        viewing: Bool = false, onScreen: Bool = false
    ) -> AttentionRaise {
        AttentionRaise.decide(kind: kind, title: title, body: body, current: current,
                              standing: standing, activelyViewing: viewing, onScreen: onScreen)
    }

    /// Someone is looking at the session, so nothing is raised, whatever else is true.
    func testActivelyViewingIgnores() {
        XCTAssertEqual(decide(.needsInput, viewing: true, onScreen: true), .ignore)
        XCTAssertEqual(decide(.finished, current: .finished, viewing: true), .ignore)
    }

    /// A first signal for a session nobody is looking at is a fresh episode with a sound.
    func testFreshEpisodeAlerts() {
        XCTAssertEqual(decide(.turnDone),
                       .raise(alert: true, startsEpisode: true, whileAway: false))
    }

    /// On screen but the user is away from the Mac: remembered as raised while away.
    func testOnScreenButAwayIsRaisedWhileAway() {
        XCTAssertEqual(decide(.turnDone, onScreen: true),
                       .raise(alert: true, startsEpisode: true, whileAway: true))
    }

    /// A quieter signal never replaces a louder one that is showing.
    func testQuieterKindIsIgnored() {
        XCTAssertEqual(decide(.turnDone, current: .needsInput), .ignore)
    }

    /// The same kind with new text updates the banner silently, no sound.
    func testSameKindNewTextIsSilent() {
        let standing = AttentionRaise.Standing(kind: .turnDone, title: "t", body: "old")
        XCTAssertEqual(decide(.turnDone, body: "new", current: .turnDone, standing: standing),
                       .raise(alert: false, startsEpisode: false, whileAway: false))
    }

    /// A louder kind than what is showing escalates: a sound, but not a new episode.
    func testLouderKindAlertsWithoutNewEpisode() {
        XCTAssertEqual(decide(.needsInput, current: .turnDone),
                       .raise(alert: true, startsEpisode: false, whileAway: false))
    }

    /// Exactly what is already showing is silent and changes nothing.
    func testIdenticalToStandingIsIgnored() {
        let standing = AttentionRaise.Standing(kind: .failed, title: "t", body: "b")
        XCTAssertEqual(decide(.failed, current: .failed, standing: standing), .ignore)
    }

    /// Identical content is ignored even when no kind is showing, pinning the order of checks.
    func testIdenticalToStandingIgnoredWithoutCurrent() {
        let standing = AttentionRaise.Standing(kind: .failed, title: "t", body: "b")
        XCTAssertEqual(decide(.failed, current: nil, standing: standing), .ignore)
    }

    /// Equal priority is not an escalation, so a re-emitted kind with a new body is silent.
    func testEqualPriorityIsNotAnEscalation() {
        XCTAssertEqual(decide(.failed, body: "other", current: .failed),
                       .raise(alert: false, startsEpisode: false, whileAway: false))
    }
}

/// Whether a turn's end was already read before anything announced it.
///
/// Reported 2026-11-10 from a Codex user: read the answer to the end in
/// Wortel, ⌘-tab away, and a banner with that same answer arrives anyway. The
/// screen tier only calls a turn over once the screen holds still, and the
/// scrolling that reading takes kept restarting that wait until she left.
final class SeenLedgerTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// The report: the turn ended while she was on it, she read for a while
    /// and left; the announcement that comes after is about something seen.
    func testATurnThatEndedWhileYouReadWasSeen() {
        var ledger = SeenLedger()
        ledger.show(a, at: at(0), present: true)
        ledger.show(nil, at: at(60), present: true) // ⌘-tab away
        XCTAssertTrue(ledger.saw(a, writtenAt: at(30), now: at(64)))
    }

    /// A turn that finished after you left was not on screen with you.
    func testATurnThatEndedAfterYouLeftWasNot() {
        var ledger = SeenLedger()
        ledger.show(a, at: at(0), present: true)
        ledger.show(nil, at: at(60), present: true)
        XCTAssertFalse(ledger.saw(a, writtenAt: at(61), now: at(65)))
    }

    /// Ending a moment before you left is a glimpse, not a read.
    func testLessThanTheDwellIsNotARead() {
        var ledger = SeenLedger()
        ledger.show(a, at: at(0), present: true)
        ledger.show(nil, at: at(60), present: true)
        XCTAssertFalse(ledger.saw(a, writtenAt: at(59.5), now: at(65)))
        XCTAssertTrue(ledger.saw(a, writtenAt: at(59), now: at(65)))
    }

    /// Clicking through a session on the way to another isn't reading it,
    /// even when what it shows is old.
    func testFlickingPastIsNotARead() {
        var ledger = SeenLedger()
        ledger.show(a, at: at(10), present: true)
        ledger.show(b, at: at(10.3), present: true)
        XCTAssertFalse(ledger.saw(a, writtenAt: at(0), now: at(20)))
    }

    /// Only the session on screen is read; the one beside it in the sidebar
    /// finishing meanwhile was not.
    func testOnlyTheSessionOnScreenIsRead() {
        var ledger = SeenLedger()
        ledger.show(a, at: at(0), present: true)
        ledger.show(nil, at: at(60), present: true)
        XCTAssertFalse(ledger.saw(b, writtenAt: at(30), now: at(64)))
    }

    /// A window left on screen for an empty room showed nobody anything.
    func testAStretchThatEndedWithNobodyThereCountsForNothing() {
        var ledger = SeenLedger()
        ledger.show(a, at: at(0), present: true)
        ledger.show(nil, at: at(600), present: false)
        XCTAssertFalse(ledger.saw(a, writtenAt: at(30), now: at(700)))
    }

    /// Still on it: it counts once it has been there for the dwell.
    func testTheSessionOnScreenNow() {
        var ledger = SeenLedger()
        ledger.show(a, at: at(0), present: true)
        XCTAssertTrue(ledger.saw(a, writtenAt: at(30), now: at(31)))
        XCTAssertFalse(ledger.saw(a, writtenAt: at(30), now: at(30.5)))
    }

    /// An earlier read still counts after a later glimpse: coming back for a
    /// moment doesn't unread what you read before.
    func testAnEarlierReadSurvivesALaterGlimpse() {
        var ledger = SeenLedger()
        ledger.show(a, at: at(0), present: true)
        ledger.show(b, at: at(60), present: true)
        ledger.show(a, at: at(70), present: true)
        ledger.show(nil, at: at(70.2), present: true)
        XCTAssertTrue(ledger.saw(a, writtenAt: at(30), now: at(80)))
    }

    /// Showing the same session again (a redundant activate) doesn't restart
    /// the stretch.
    func testShowingTheSameSessionAgainKeepsTheStretch() {
        var ledger = SeenLedger()
        ledger.show(a, at: at(0), present: true)
        ledger.show(a, at: at(59.9), present: true)
        ledger.show(nil, at: at(60), present: true)
        XCTAssertTrue(ledger.saw(a, writtenAt: at(30), now: at(64)))
    }
}
