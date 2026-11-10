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
