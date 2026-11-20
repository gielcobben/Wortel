import XCTest
import os

/// The listener on a terminal's output. It only listens: the question Claude
/// Code and Pi ask first is answered by the keeper, in order with its other
/// answers (`KeeperTerminalTests`, `KeeperTerminalProtocolTests`).
final class ProgramStatusWatchTests: XCTestCase {

    /// Collects what a watch delivers, on the main thread as it arrives.
    private final class Heard {
        var heard: [(signal: ProgramSignal, replayed: Bool)] = []
        /// The status reports among it.
        var reports: [(report: ProgramStatusReport, replayed: Bool)] {
            heard.compactMap { item in
                if case .status(let report) = item.signal { return (report, item.replayed) }
                return nil
            }
        }
        var notifications: [TerminalNotification] {
            heard.compactMap { item in
                if case .notification(let said) = item.signal { return said }
                return nil
            }
        }
    }

    private func watch() -> (ProgramStatusWatch, Heard) {
        let watch = ProgramStatusWatch()
        let heard = Heard()
        watch.onHeard = { signal, replayed in heard.heard.append((signal, replayed)) }
        return (watch, heard)
    }

    /// Run the main loop until `done` says so, since reports are delivered there.
    private func wait(_ seconds: TimeInterval = 10, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func feed(_ watch: ProgramStatusWatch, _ text: String) {
        Array(text.utf8).withUnsafeBufferPointer { raw in
            watch.output(raw.baseAddress!, count: raw.count)
        }
    }

    // MARK: - Live output

    /// The question itself is not passed on: it is the keeper's to answer,
    /// not news about the program.
    func testAQueryIsNotDelivered() {
        let (watch, heard) = watch()
        feed(watch, "\u{1B}]7501;?\u{1B}\\\u{1B}]7501;state=idle:app=pi\u{1B}\\")
        wait { !heard.reports.isEmpty }
        XCTAssertEqual(heard.reports.map(\.report), [.status(ProgramStatus(state: .idle, app: "pi"))])
    }

    func testReportsArriveInOrderAcrossReads() {
        let (watch, heard) = watch()
        feed(watch, "text \u{1B}]7501;state=work")
        feed(watch, "ing\u{1B}\\ more \u{1B}]7501;state=done\u{07}")
        wait { heard.reports.count == 2 }
        XCTAssertEqual(heard.reports.map(\.report),
                       [.status(ProgramStatus(state: .working)), .status(ProgramStatus(state: .done))])
    }

    // MARK: - A replay

    /// Of what was written while nobody was attached, only what still stands
    /// is passed on, and it is marked as old. A question in there is not
    /// passed on either.
    func testAReplayIsFoldedToWhatStands() {
        let (watch, heard) = watch()
        let replay = "\u{1B}]7501;?\u{1B}\\"
            + "\u{1B}]7501;state=working:app=codex\u{1B}\\"
            + "\u{1B}]7501;state=blocked:kind=permission:app=codex\u{1B}\\"
            + "\u{1B}]7501;state=working:app=codex\u{1B}\\"
            + "\u{1B}]7501;state=working:id=bash_1\u{1B}\\"
            + "\u{1B}]7501;state=working:id=bash_2\u{1B}\\"
            + "\u{1B}]7501;state=clear:id=bash_1\u{1B}\\"
            + "\u{1B}]7501;state=done:app=codex\u{1B}\\"
        watch.replay(Data(replay.utf8))
        wait { heard.reports.count == 2 }
        XCTAssertEqual(heard.reports.map(\.report), [
            .status(ProgramStatus(state: .done, app: "codex")),
            .status(ProgramStatus(state: .working, id: "bash_2")),
        ])
        XCTAssertTrue(heard.reports.allSatisfy(\.replayed))
    }

    /// The program left while nobody was attached: that is what stands.
    func testAReplayThatEndsInClear() {
        let (watch, heard) = watch()
        watch.replay(Data("\u{1B}]7501;state=done:app=codex\u{1B}\\\u{1B}]7501;state=clear\u{1B}\\".utf8))
        wait { !heard.reports.isEmpty }
        XCTAssertEqual(heard.reports.map(\.report), [.clear])
    }

    /// And one that left and was started again.
    func testAReplayWithAClearInTheMiddle() {
        let (watch, heard) = watch()
        watch.replay(Data(("\u{1B}]7501;state=blocked:app=codex\u{1B}\\\u{1B}]7501;state=clear\u{1B}\\"
            + "\u{1B}]7501;state=idle:app=codex\u{1B}\\").utf8))
        wait { heard.reports.count == 2 }
        XCTAssertEqual(heard.reports.map(\.report), [.clear, .status(ProgramStatus(state: .idle, app: "codex"))])
    }

    /// Of the notifications in a replay, the last is the latest thing the
    /// program wanted to tell anyone. It is passed on, as old news.
    func testAReplayKeepsItsLastNotification() {
        let (watch, heard) = watch()
        watch.replay(Data("\u{1B}]9;First\u{07}text\u{1B}]9;Approval requested: ls\u{07}".utf8))
        wait { !heard.heard.isEmpty }
        XCTAssertEqual(heard.notifications, [TerminalNotification(title: "", body: "Approval requested: ls")])
        XCTAssertTrue(heard.heard.allSatisfy(\.replayed))
    }

    func testLiveNotificationsAreAllDelivered() {
        let (watch, heard) = watch()
        feed(watch, "\u{1B}]9;One\u{07}\u{1B}]9;One\u{07}\u{1B}]777;notify;Two;body\u{07}")
        wait { heard.heard.count == 3 }
        XCTAssertEqual(heard.notifications.map(\.body), ["One", "One", "body"])
        XCTAssertFalse(heard.heard.contains { $0.replayed })
    }

    func testAReplayWithNothingInItDeliversNothing() {
        let (watch, heard) = watch()
        watch.replay(Data("plain output \u{1B}[31m\u{1B}]0;title\u{07}".utf8))
        wait(0.2) { !heard.reports.isEmpty }
        XCTAssertTrue(heard.reports.isEmpty)
    }
}
