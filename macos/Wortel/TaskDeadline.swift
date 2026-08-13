import Foundation

extension Task where Success == Void, Failure == Never {
    /// Wait for this task, but stop waiting after `timeout` and let it run on.
    ///
    /// Not a cancellation, and not a deadline on the work: the task keeps going
    /// and still lands. This only bounds how long *the caller* blocks on it, for
    /// the case where the result is an improvement rather than a requirement —
    /// a `git fetch` whose only job is to make a fork point fresher, where
    /// giving up costs exactly what being offline already costs.
    ///
    /// Written on a continuation rather than the two obvious ways, because
    /// neither works. `await value` on a non-throwing task ignores the waiting
    /// task's cancellation, so wrapping it in `withTimeout`-style cancellation
    /// does nothing; and a `TaskGroup` waits for every child at scope exit, so
    /// racing the two there still blocks on the slow one after the sleep wins.
    /// Here the loser simply resumes nothing.
    func finishing(within timeout: Duration) async {
        let gate = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await self.value
                await gate.resume(continuation)
            }
            Task {
                // Spelled out because inside this extension `Task` is
                // `Task<Void, Never>`, and `sleep` lives on `Task<Never, Never>`.
                try? await Task<Never, Never>.sleep(for: timeout)
                await gate.resume(continuation)
            }
        }
    }
}

/// A continuation two racing tasks may both reach. Resuming one twice is a
/// crash rather than a no-op, so the guard is the point of the type.
private actor ResumeOnce {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        guard !resumed else { return }
        resumed = true
        continuation.resume()
    }
}
