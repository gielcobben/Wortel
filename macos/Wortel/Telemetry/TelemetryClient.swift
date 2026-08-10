import Foundation

/// Sends the events in `TelemetryEvent` and nothing else.
///
/// **An actor, in an app whose every other rule is main-thread-only.** That is
/// deliberate and it is the one exception: this is the only part of Wortel that
/// talks to the network, and the whole point is that it never makes the
/// terminal wait. Call sites are fire-and-forget (`Telemetry.capture(...)`) and
/// hop off the main thread immediately.
///
/// **Nothing happens at launch.** The client is not constructed until the first
/// event, the first flush is deliberately late, and cold-launch time is a
/// benchmarked number (`bench/measure.sh`). If a change here moves it, the
/// change is wrong.
///
/// **In memory only, no disk buffer.** The plan for this called for one, and it
/// was dropped on purpose: a queue file is a thing that can grow, go stale, and
/// leave events sitting on disk after someone opts out, and all of that risk
/// buys the recovery of a handful of aggregate counts if a flush fails during
/// the last second of a quit. Losing those is invisible in the numbers. The
/// disk footprint of this feature is therefore a preference and a UUID.
///
/// The queue is capped and drops its OLDEST entries when full, so a machine
/// that is offline for a day cannot grow this without bound, and cannot flood
/// the project with a day of backlog when it reconnects either.
actor TelemetryClient {
    static let shared = TelemetryClient()

    /// EU region, matching the project the website and the updates Worker
    /// report into. Same project: `app_launched` sitting beside
    /// `app_downloaded` is what makes "downloaded and never opened" one query.
    private static let endpoint = URL(string: "https://eu.i.posthog.com/batch/")!

    /// Write-only project token. Public by design: it can send events and read
    /// nothing back, which is why PostHog ships it inside client bundles.
    private static let projectKey = "phc_s9AQUzSKYsbdi8aoCWkaedPK2Cbjr9KEmYJqjgWa89oa"

    private static let queueCap = 200
    private static let batchSize = 20
    private static let flushInterval: TimeInterval = 60

    private var queue: [Payload] = []
    private var flushTask: Task<Void, Never>?
    private var isSending = false

    /// Built once. Ephemeral so nothing is cached and no cookie is ever stored,
    /// which also means this session cannot be correlated with any other
    /// request the app makes.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // ---- taking events ----------------------------------------------------

    func enqueue(_ event: TelemetryEvent) {
        queue.append(Payload(event: event, at: Date()))
        if queue.count > Self.queueCap {
            queue.removeFirst(queue.count - Self.queueCap)
        }
        if queue.count >= Self.batchSize {
            Task { await self.flush() }
        } else {
            scheduleFlush()
        }
    }

    /// One pending timer at a time. Re-arming on every event would make a busy
    /// minute postpone the flush forever; this leaves the first one standing.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flushInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.clearFlushTask()
            await self?.flush()
        }
    }

    private func clearFlushTask() { flushTask = nil }

    // ---- sending ----------------------------------------------------------

    func flush() async {
        guard !isSending, !queue.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        // Taken out of the queue up front rather than counted off the front
        // afterwards. This is an actor, so it suspends at the `await` below and
        // `enqueue` can run in the gap — and if that pushes the queue past its
        // cap, the trim there removes from the front too, which made the old
        // `removeFirst(sending.count)` eat newer events that had never been
        // sent. Anything retryable goes back on at the front instead.
        let sending = Array(queue.prefix(Self.batchSize))
        queue.removeFirst(sending.count)

        let body: Data
        do {
            body = try Self.encode(sending, distinctID: TelemetrySettings.installID)
        } catch {
            // Unencodable means a bug in this file, not a transient failure.
            // Dropping is right: retrying forever would pin the queue.
            return
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 2xx is done; 4xx is not retryable, because a rejected batch will
            // be rejected again. Either way they stay gone.
            guard !((200..<300).contains(status) || (400..<500).contains(status)) else { return }
            // 5xx and anything else: put them back for the next flush. The cap
            // is what stops that from being unbounded.
            requeue(sending)
        } catch {
            // Offline, or the request timed out. Same reasoning: keep, capped.
            requeue(sending)
        }
    }

    /// Return an unsent batch to the front of the queue, oldest first, and
    /// re-apply the cap — which drops oldest, so a queue that filled while we
    /// were away keeps the newest events rather than these.
    private func requeue(_ sending: [Payload]) {
        queue.insert(contentsOf: sending, at: 0)
        if queue.count > Self.queueCap {
            queue.removeFirst(queue.count - Self.queueCap)
        }
    }

    /// Everything that is queued, in batches, bounded by the caller's patience.
    /// Used on quit.
    func drain(deadline: Date) async {
        while !queue.isEmpty, Date() < deadline {
            let before = queue.count
            await flush()
            if queue.count >= before { return }   // not draining: stop trying
        }
    }

    // ---- the wire ---------------------------------------------------------

    /// Not private, and `encode` is not either, so the wire format can be
    /// checked in `WortelTests` without a network or a running app. What that
    /// test is really guarding is the anonymity flag and the property set: the
    /// two things whose absence would look exactly like success.
    struct Payload {
        let event: TelemetryEvent
        let at: Date
    }

    /// Built per call rather than held as a shared static: `ISO8601DateFormatter`
    /// is a mutable class and not Sendable, and this runs at most once per flush
    /// — twenty events an hour, against a network round trip. Sharing one to
    /// save that is how a formatter ends up being configured on one thread while
    /// another is mid-format.
    static func encode(_ payloads: [Payload], distinctID: String) throws -> Data {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime]
        let device = deviceProperties()
        let batch: [[String: Any]] = payloads.map { payload in
            var properties = payload.event.properties
            properties.merge(device) { current, _ in current }
            var object: [String: Any] = properties
            object["distinct_id"] = distinctID
            // Anonymous: no person profile is built, so these events cannot
            // accumulate into a record of one install's behaviour. Also about
            // four times cheaper, which is a happy coincidence and not why.
            object["$process_person_profile"] = false
            return [
                "event": payload.event.name,
                "properties": object,
                "timestamp": timestampFormatter.string(from: payload.at),
                "distinct_id": distinctID,
            ]
        }

        return try JSONSerialization.data(
            withJSONObject: ["api_key": projectKey, "batch": batch],
            options: [])
    }

    /// What every event carries. Four facts about the build and the machine,
    /// each of which changes what we would fix first, and none of which
    /// describes a person.
    static func deviceProperties() -> [String: String] {
        let bundle = Bundle.main
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            // Major.minor only. The patch level is a detail that never changes
            // a decision and narrows the field of machines this could be.
            "macos": "\(os.majorVersion).\(os.minorVersion)",
            "arch": architecture,
            "platform": "macos",
        ]
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        // Which, on an Apple Silicon Mac, means we are under Rosetta and the
        // build is wrong. Worth being able to see.
        return "x86_64"
        #else
        return "other"
        #endif
    }
}

// ==========================================================================
// The call site.
//
// One line, no await, no error to handle, and nothing to check first: every
// gate lives in here, so adding an event to a view or a model never involves
// reasoning about whether reporting is on.
// ==========================================================================
enum Telemetry {
    static func capture(_ event: TelemetryEvent) {
        guard TelemetrySettings.isEnabled else { return }
        Task.detached(priority: .utility) {
            await TelemetryClient.shared.enqueue(event)
        }
    }

    /// How long anything here may hold up a quit. Enough for one round trip on
    /// a working connection, short enough not to be felt on a broken one.
    private static let sendingGrace: TimeInterval = 1.5

    /// True while a final event is still on its way out, so quit waits for it
    /// even though the preference it announces has already been turned off.
    @MainActor private static var isFinalising = false

    /// Whether quitting has anything to wait for. Read by the app layer, which
    /// only asks AppKit to defer termination when the answer is yes.
    @MainActor static var hasWorkBeforeQuit: Bool {
        TelemetrySettings.isEnabled || isFinalising
    }

    /// Send what is queued, then call `completion` on the main actor.
    ///
    /// **Nothing blocks.** This used to park the calling thread on a semaphore,
    /// which happened to work — the client is a plain actor with its own
    /// executor — and was one refactor away from deadlocking the whole quit the
    /// day anything here touched main-actor state. The caller defers
    /// termination instead and replies from `completion`.
    @MainActor static func drainBeforeQuit(then completion: @escaping @MainActor () -> Void) {
        guard hasWorkBeforeQuit else {
            completion()
            return
        }
        Task { @MainActor in
            await bounded { await TelemetryClient.shared.drain(
                deadline: Date().addingTimeInterval(sendingGrace)) }
            completion()
        }
    }

    /// Turning it off sends one final event and then nothing, ever.
    ///
    /// Fire and forget: this is reached from a menu item, and the old version
    /// froze the app for up to 1.6 seconds on the click. `isFinalising` is what
    /// keeps the event from being abandoned by a quit that follows immediately.
    @MainActor static func captureOptOutThenStop() {
        isFinalising = true
        Task { @MainActor in
            await TelemetryClient.shared.enqueue(.reportingDisabled)
            await bounded { await TelemetryClient.shared.drain(
                deadline: Date().addingTimeInterval(sendingGrace)) }
            isFinalising = false
        }
    }

    /// Run `work`, giving up after `sendingGrace` whatever it is doing.
    ///
    /// `drain` checks its deadline between flushes, not during one, so a single
    /// request that hangs could hold it for the session's 15s request timeout.
    /// The semaphore this replaces bounded that with its own wait; racing a
    /// sleep is how you keep the bound without blocking a thread to get it.
    private static func bounded(_ work: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(sendingGrace * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
    }
}
