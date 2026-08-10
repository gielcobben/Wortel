import XCTest

/// The activity tracker decides when Wortel makes a sound at you, and every one
/// of its failure modes is timing-shaped: a `wentQuiet` emitted twice restarts
/// the settle timer and the notification never arrives; one emitted too early
/// cries wolf while the agent is still thinking. None of that shows up by
/// running the app for a minute, so it's pinned here against a fake clock.
final class AgentActivityTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func after(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    func testFirstSampleIsBaselineNotWork() {
        var tracker = AgentActivityTracker(now: t0)
        XCTAssertNil(tracker.sample(digest: 1, now: t0))
    }

    func testChangeDuringGraceDoesNotCountAsWork() {
        var tracker = AgentActivityTracker(now: t0, grace: 2)
        XCTAssertNil(tracker.sample(digest: 1, now: t0))
        // An agent painting its startup banner is not doing your work.
        XCTAssertNil(tracker.sample(digest: 2, now: after(0.5)))
        XCTAssertNil(tracker.sample(digest: 3, now: after(1.5)))
    }

    func testWorkAfterGraceIsReportedOnce() {
        var tracker = AgentActivityTracker(now: t0, grace: 2)
        _ = tracker.sample(digest: 1, now: t0)
        // One changed frame is not work yet — see testLoneRepaintIsNotWork.
        XCTAssertNil(tracker.sample(digest: 2, now: after(3)))
        XCTAssertEqual(tracker.sample(digest: 3, now: after(4)), .startedWorking)
        // Still working is not news; only transitions are reported.
        XCTAssertNil(tracker.sample(digest: 4, now: after(5)))
        XCTAssertNil(tracker.sample(digest: 5, now: after(6)))
    }

    /// The bug this tier is most dangerous for: a session whose agent has been
    /// idle for days, repainted once because the window resized or the app took
    /// focus, and announced a turn nobody took. One frame of difference on a
    /// frozen screen must produce nothing at all — not work, and so never a
    /// quiesce, a dot, or a notification.
    func testLoneRepaintIsNotWork() {
        var tracker = AgentActivityTracker(now: t0, grace: 0)
        _ = tracker.sample(digest: 1, now: t0)
        XCTAssertNil(tracker.sample(digest: 2, now: after(1)))
        for tick in 2...30 {
            XCTAssertNil(tracker.sample(digest: 2, now: after(Double(tick))))
        }
    }

    /// And two lone repaints far apart are still two lone repaints: the second
    /// opens a fresh evidence window rather than joining the first.
    func testRepaintsOutsideTheEvidenceWindowDoNotAddUp() {
        var tracker = AgentActivityTracker(now: t0, grace: 0)
        _ = tracker.sample(digest: 1, now: t0)
        XCTAssertNil(tracker.sample(digest: 2, now: after(1)))
        XCTAssertNil(tracker.sample(digest: 2, now: after(60)))
        XCTAssertNil(tracker.sample(digest: 3, now: after(120)))
        XCTAssertNil(tracker.sample(digest: 3, now: after(180)))
    }

    func testGoingQuietIsReportedExactlyOnce() {
        var tracker = AgentActivityTracker(now: t0, grace: 0)
        _ = tracker.sample(digest: 1, now: t0)
        XCTAssertNil(tracker.sample(digest: 2, now: after(1)))
        XCTAssertEqual(tracker.sample(digest: 3, now: after(2)), .startedWorking)

        // Screen holds still. Nothing until the quiet window has fully elapsed.
        XCTAssertNil(tracker.sample(digest: 3, now: after(3)))
        XCTAssertNil(tracker.sample(digest: 3, now: after(4)))
        XCTAssertEqual(tracker.sample(digest: 3, now: after(5)), .wentQuiet)

        // The critical one: a repeat would restart the settle timer downstream
        // and the notification would never fire.
        XCTAssertNil(tracker.sample(digest: 3, now: after(6)))
        XCTAssertNil(tracker.sample(digest: 3, now: after(30)))
    }

    func testQuietNeedsSustainedStillness() {
        var tracker = AgentActivityTracker(now: t0, grace: 0)
        _ = tracker.sample(digest: 1, now: t0)
        XCTAssertNil(tracker.sample(digest: 2, now: after(1)))
        XCTAssertEqual(tracker.sample(digest: 3, now: after(2)), .startedWorking)
        XCTAssertNil(tracker.sample(digest: 3, now: after(4)))
        // One more frame resets the clock — an agent that pauses mid-render
        // must not read as finished.
        XCTAssertNil(tracker.sample(digest: 4, now: after(4.5)))
        XCTAssertNil(tracker.sample(digest: 4, now: after(7)))
        XCTAssertEqual(tracker.sample(digest: 4, now: after(7.6)), .wentQuiet)
    }

    func testWorkResumesAfterQuiet() {
        var tracker = AgentActivityTracker(now: t0, grace: 0)
        _ = tracker.sample(digest: 1, now: t0)
        XCTAssertNil(tracker.sample(digest: 2, now: after(1)))
        XCTAssertEqual(tracker.sample(digest: 3, now: after(2)), .startedWorking)
        XCTAssertEqual(tracker.sample(digest: 3, now: after(5.5)), .wentQuiet)
        // You reply, the agent starts a second turn: that is news again, and it
        // has to clear the same two-frame bar as the first.
        XCTAssertNil(tracker.sample(digest: 4, now: after(6)))
        XCTAssertEqual(tracker.sample(digest: 5, now: after(7)), .startedWorking)
        XCTAssertEqual(tracker.sample(digest: 5, now: after(10.5)), .wentQuiet)
    }

    func testStillScreenNeverSeenWorkingStaysSilent() {
        // Switching away from an agent that was already idle must not announce
        // a turn that ended while you were watching it.
        var tracker = AgentActivityTracker(now: t0, grace: 0)
        _ = tracker.sample(digest: 7, now: t0)
        for tick in 1...20 {
            XCTAssertNil(tracker.sample(digest: 7, now: after(Double(tick))))
        }
    }
}

final class AgentScreenDigestTests: XCTestCase {
    private func digest(_ string: String) -> UInt64 {
        let copy = Array(string.utf8)
        return copy.withUnsafeBytes { agentScreenDigest($0) }
    }

    func testDigestIsStableAndSensitive() {
        XCTAssertEqual(digest("● Working…"), digest("● Working…"))
        XCTAssertNotEqual(digest("● Working…"), digest("● Working……"))
        // A spinner advancing one frame has to register, or an agent whose only
        // motion is its spinner would read as idle the whole time it works.
        XCTAssertNotEqual(digest("⠋ thinking"), digest("⠙ thinking"))
    }

    func testEmptyScreenHashesWithoutCrashing() {
        XCTAssertEqual(digest(""), digest(""))
    }
}

final class AgentPromptTests: XCTestCase {
    func testRecognisesBlockingPrompts() {
        // Shapes taken from what agent CLIs actually put on screen while they
        // wait: the affordance line, not the question.
        for tail in [
            "Do you want to proceed?\n❯ 1. Yes  2. No",
            "  esc to cancel · enter to select",
            "Allow edit to src/main.swift? (y/n)",
            "Waiting for your approval…",
            "↑/↓ to navigate · enter to confirm",
            "Grant permission to run tests?",
        ] {
            XCTAssertTrue(AgentPrompt.looksBlocked(tail), "should read as blocked: \(tail)")
        }
    }

    func testOrdinaryOutputIsNotBlocked() {
        for tail in [
            "✓ 151 tests passed in 9.4s",
            "Updated src/main.swift and 3 other files.",
            "$ ",
            "",
            "Compiling wortel v0.1.0\n   Finished in 2.3s",
        ] {
            XCTAssertFalse(AgentPrompt.looksBlocked(tail), "should not read as blocked: \(tail)")
        }
    }

    /// A working agent offers you Esc too, and saying so is not asking you
    /// anything. Reading these as prompts is what made a false turn-end arrive
    /// as the loudest kind Wortel has.
    func testWorkingScreensAreNotBlocked() {
        for tail in [
            "✻ Reticulating splines… (esc to interrupt)",
            "· Running tests (12s · esc to interrupt · ctrl+t for details)",
            // Even alongside words that would otherwise read as a prompt: the
            // agent is plainly still going.
            "Do you want me to continue? — working… (esc to interrupt)",
        ] {
            XCTAssertFalse(AgentPrompt.looksBlocked(tail), "should not read as blocked: \(tail)")
        }
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(AgentPrompt.looksBlocked("PRESS ENTER TO CONTINUE"))
    }
}
