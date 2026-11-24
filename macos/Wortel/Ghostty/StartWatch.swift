import Foundation
import OSLog

/// One session's start, watched until its cover lifts: `StartCover`'s rule
/// with a clock and a timer. Made when the terminal is, gone a few seconds
/// later at the most. Main thread only.
final class StartWatch {
    /// What each start heard and how it ended, with times in milliseconds
    /// since the terminal was made. Debug level, so it costs nothing unless
    /// someone listens:
    ///
    ///     log stream --level debug \
    ///       --predicate 'subsystem == "com.gielcobben.Wortel" && category == "session-start"'
    static let log = Logger(subsystem: "com.gielcobben.Wortel", category: "session-start")

    private var cover: StartCover
    private let began: TimeInterval
    private var timer: DispatchWorkItem?
    private var onEnd: ((StartCover.End) -> Void)?
    private let session: String

    /// `onEnd` is called once, on the main thread.
    init(session: UUID?, onEnd: @escaping (StartCover.End) -> Void) {
        began = ProcessInfo.processInfo.systemUptime
        cover = StartCover(now: began)
        self.onEnd = onEnd
        self.session = session.map { String($0.uuidString.prefix(8)) } ?? "-"
        schedule()
    }

    /// What one read of the output held, and when it was read.
    func heard(_ events: [StartCover.Event], at time: TimeInterval) {
        for event in events {
            guard onEnd != nil else { return }
            if event != .output { trace("\(event)", at: time) }
            if let end = cover.heard(event, at: time) { return finish(end, at: time) }
        }
        schedule()
    }

    /// The session's agent marker appeared.
    func agentKnown() {
        heard([.agentKnown], at: ProcessInfo.processInfo.systemUptime)
    }

    /// The terminal is going, or its shell is another one: lift now.
    func giveUp() {
        guard onEnd != nil else { return }
        finish(.tookTooLong, at: ProcessInfo.processInfo.systemUptime)
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        guard onEnd != nil, let deadline = cover.deadline else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.onEnd != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let end = self.cover.check(at: now) { self.finish(end, at: now) } else { self.schedule() }
        }
        timer = item
        let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    private func finish(_ end: StartCover.End, at time: TimeInterval) {
        timer?.cancel()
        timer = nil
        trace("end \(end)", at: time)
        let onEnd = self.onEnd
        self.onEnd = nil
        onEnd?(end)
    }

    private func trace(_ what: String, at time: TimeInterval) {
        let ms = Int(((time - began) * 1000).rounded())
        Self.log.debug("\(self.session, privacy: .public) +\(ms)ms \(what, privacy: .public)")
    }
}
