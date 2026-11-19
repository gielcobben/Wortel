import Foundation

/// Listens to one terminal's output for what its program says: what it is
/// doing (OSC 7501, `ProgramStatus`) and the notifications it asks for. And
/// answers the program when it asks whether anyone is listening.
///
/// It is read here, on the pty's queue, as the bytes go past to the terminal.
/// libghostty ignores a status report; and its own count of notifications is
/// for one terminal, not a window of them (`TerminalNotificationReader`). It
/// hears the output whether or not there is a terminal: a hibernated
/// session's is heard the same way.
///
/// Owned by its `SurfaceView` and created before its surface, so the pty's
/// output handler can hold it.
final class ProgramStatusWatch: @unchecked Sendable {
    /// Fed on the pty queue. Behind the lock all the same: a restarted shell
    /// gets a new pty and a new queue while the old one may still be
    /// delivering its last read.
    private var scanner = ProgramSignalScanner()

    private let lock = NSLock()
    private var handler: ((ProgramSignal, _ replayed: Bool) -> Void)?

    /// Called on the main thread for each thing heard, in order. `replayed`:
    /// it was read from what the program wrote while nobody was attached, so
    /// it says what is true now and not that something just happened.
    var onHeard: ((ProgramSignal, _ replayed: Bool) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    /// A new pty for the same terminal (a restarted shell): nothing half-read
    /// from the last one carries over, so a kitty notification cut off there
    /// is not joined onto the new shell's.
    func reset() {
        lock.withLock { scanner = ProgramSignalScanner() }
    }

    /// Output on its way to the terminal. Called on the pty queue.
    func output(_ bytes: UnsafePointer<UInt8>, count: Int, pty: PtyHost?) {
        let heard = lock.withLock { scanner.scan(UnsafeBufferPointer(start: bytes, count: count)) }
        guard !heard.isEmpty else { return }
        var news: [ProgramSignal] = []
        for signal in heard {
            if signal == .status(.query) {
                // The program is waiting on this, and takes silence as "no"
                // for as long as it runs.
                ProgramStatusReport.reply.withUnsafeBufferPointer { raw in
                    guard let base = raw.baseAddress else { return }
                    pty?.write(base, count: raw.count)
                }
            } else {
                news.append(signal)
            }
        }
        deliver(news, replayed: false)
    }

    /// What the program wrote while nobody was attached, on its way into a
    /// new terminal. Called on the pty queue.
    ///
    /// Old news twice over. A query in there was asked long ago and the
    /// program has stopped waiting: an answer now would be typed into it. And
    /// of the rest only what it leaves standing is still true, so that is
    /// what is passed on, marked as replayed: the status records still
    /// there, and the last notification, which is the latest thing it wanted
    /// to tell anyone.
    func replay(_ data: Data) {
        let heard = lock.withLock {
            data.withUnsafeBytes { raw in scanner.scan(raw.bindMemory(to: UInt8.self)) }
        }
        // Folded, so a child record cleared before the end is not brought
        // back: the last root report, the children still there, in the order
        // they were last written.
        var records = ProgramRecords()
        var cleared = false
        var notification: TerminalNotification?
        for signal in heard {
            switch signal {
            case .status(.query): continue
            case .status(let report):
                if report == .clear { cleared = true }
                records.apply(report)
            case .notification(let said):
                notification = said
            }
        }
        var standing: [ProgramSignal] = cleared ? [.status(.clear)] : []
        if let root = records.root { standing.append(.status(.status(root))) }
        standing += records.childrenInOrder.map { .status(.status($0)) }
        if let notification { standing.append(.notification(notification)) }
        deliver(standing, replayed: true)
    }

    private func deliver(_ heard: [ProgramSignal], replayed: Bool) {
        guard !heard.isEmpty, let handler = onHeard else { return }
        DispatchQueue.main.async {
            for signal in heard { handler(signal, replayed) }
        }
    }
}
