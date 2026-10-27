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
    /// A prompt is a few hundred bytes. Typing this long without an accepted
    /// line is an agent being *used*, not started, and listening any further
    /// would be recording rather than naming.
    private let byteLimit = 16_384

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    /// Called from the pty write path, on whichever thread libghostty uses.
    func feed(_ bytes: UnsafePointer<UInt8>, count: Int) {
        let write = UnsafeBufferPointer(start: bytes, count: count)
        let lines: [String]? = state.withLock { s -> [String]? in
            guard s.bytesSeen < byteLimit else { return nil }
            // Only text counts: an escape sequence is a key, a mouse report
            // or the terminal answering a query, and an agent that keeps
            // asking for the colour, or a mouse moved over one that tracks
            // it, mustn't use up the budget before anything is typed.
            if write.first != 0x1B { s.bytesSeen += count }
            return s.builder.feed(write)
        }
        guard let lines, !lines.isEmpty else { return }
        let deliver = onLine
        DispatchQueue.main.async { for line in lines { deliver(line) } }
    }
}

/// A listener on a pty's input while a move waits on its session's agent
/// (`wortel cd`): it says whether the user has a draft in the agent's input,
/// and nothing else. Quitting the agent would throw a draft away. When the
/// user last touched the session is the view's to say
/// (`SurfaceView.lastUserInputAt`): this stream also carries the terminal's
/// replies, and an agent asking for the colour every few seconds would
/// otherwise look like someone typing forever.
///
/// Holds the line being typed only to know whether it's empty; the text is
/// never read out, kept or sent anywhere, and the tap is detached as soon as
/// the move happens or is cancelled.
final class DraftTap: PtyInputListener, @unchecked Sendable {
    private let builder = OSAllocatedUnfairLock(uncheckedState: TypedLineBuilder())

    /// Called from the pty write path, on whichever thread libghostty uses.
    func feed(_ bytes: UnsafePointer<UInt8>, count: Int) {
        builder.withLock { _ = $0.feed(UnsafeBufferPointer(start: bytes, count: count)) }
    }

    var hasDraft: Bool { builder.withLock { $0.hasDraft } }
}
