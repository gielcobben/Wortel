import Foundation
import os

/// A listener on a pty's input, alive only while a session is waiting for an
/// agent's first prompt. `PtyHost.write` feeds it every byte the terminal sends
/// the program; it reconstructs typed lines (`TypedLineBuilder`) and hands each
/// completed one to `onLine` on the main thread.
///
/// The scoping is the privacy story: the tap exists from the moment an agent
/// launches until a prompt is accepted, the agent exits, or a deadline passes,
/// and `SessionManager` detaches it the instant any of those happen. Nothing is
/// kept but the one line it was created to find, and that line goes to the
/// on-device model and nowhere else.
final class PromptTap: PtyInputListener, @unchecked Sendable {
    private struct State {
        var builder = TypedLineBuilder()
        var bytesSeen = 0
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let onLine: @Sendable (String) -> Void
    /// A prompt is a few hundred bytes. A stream this long without an accepted
    /// line is an agent being *used*, not started, and listening any further
    /// would be recording rather than naming.
    private let byteLimit = 16_384

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    /// Called from the pty write path, on whichever thread libghostty uses.
    func feed(_ bytes: UnsafePointer<UInt8>, count: Int) {
        let lines: [String]? = state.withLock { s -> [String]? in
            guard s.bytesSeen < byteLimit else { return nil }
            s.bytesSeen += count
            return s.builder.feed(UnsafeBufferPointer(start: bytes, count: count))
        }
        guard let lines, !lines.isEmpty else { return }
        let deliver = onLine
        DispatchQueue.main.async { for line in lines { deliver(line) } }
    }
}

/// A listener on a pty's input while a move waits on its session's agent
/// (`wortel cd`): it says whether the user has a draft in the agent's input
/// and when they last typed, and nothing else. Quitting the agent would throw
/// a draft away, and a keystroke means someone is at the keyboard.
///
/// Holds the line being typed only to know whether it's empty; the text is
/// never read out, kept or sent anywhere, and the tap is detached as soon as
/// the move happens or is cancelled.
final class DraftTap: PtyInputListener, @unchecked Sendable {
    private struct State {
        var builder = TypedLineBuilder()
        var lastInput: Date?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// Called from the pty write path, on whichever thread libghostty uses.
    func feed(_ bytes: UnsafePointer<UInt8>, count: Int) {
        state.withLock { s in
            _ = s.builder.feed(UnsafeBufferPointer(start: bytes, count: count))
            s.lastInput = Date()
        }
    }

    var hasDraft: Bool { state.withLock { $0.builder.hasDraft } }
    var lastInput: Date? { state.withLock { $0.lastInput } }
}
