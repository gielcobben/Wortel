import Foundation

/// A macOS crash report, reduced to what `app_crashed` may carry.
///
/// **Where it comes from.** When Wortel crashes, macOS's ReportCrash writes a
/// `Wortel-<date>.ips` into `~/Library/Logs/DiagnosticReports`, readable by the
/// user that ran it. On the next launch, and only when `ExitMarker` says the
/// last run did not quit, this reads the newest such report written after that
/// run started. MetricKit was the other candidate; this was chosen because it
/// is the report the person can open in Console themselves, it is there on a
/// Developer ID build without any opt-in, and its format can be pinned by a test
/// against a real one.
///
/// **What survives.** The report is full of things that must not leave the
/// Mac: the executable's path, every frame's symbol and source file, thread
/// names, the machine's model and boot ids, the parent process. None of it is
/// read into anything that is sent. What comes out is the exception type and
/// signal (closed sets), the version (rebuilt from integers) and the chip, and
/// the **offsets** of the faulting thread's frames that fall inside Wortel's
/// own binary, which are numbers into our code that only this build's dSYM can
/// turn into names. Frames in system libraries are dropped, not hashed: they
/// are other people's code, and their addresses differ by macOS build.
///
/// Off the main thread: a report is a few hundred kilobytes of JSON.
enum CrashReport {
    struct Summary: Equatable {
        let signal: CrashSignal
        let exception: CrashException
        /// In-binary frames of the faulting thread, top first, repeats of the
        /// same offset (inlined frames) folded.
        let offsets: [CodeOffset]
        let version: CalVer
        let arch: CrashArch
        /// When it crashed, from the report's header. Not sent: it is what
        /// ties the report to the run that ended uncleanly.
        let crashedAt: Date?

        var event: TelemetryEvent {
            .appCrashed(signal: signal, exception: exception, site: offsets.first,
                        signature: CrashSignature(offsets: offsets), version: version, arch: arch)
        }
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    /// The newest report of this app written after `date`, reduced. nil when
    /// there is none, which is an unclean exit with nothing to say about why
    /// (a force quit, `kill -9`, a power cut).
    static func latest(after date: Date, in directory: URL = directory,
                       executable: String = Bundle.main.executableURL?.lastPathComponent ?? "Wortel",
                       bundleID: String? = Bundle.main.bundleIdentifier) -> Summary? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return nil }
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix(executable + "-") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                // A cheap first cut: a file last written before the run began
                // can't hold its crash.
                guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                      modified > date else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
        for (url, modified) in candidates.prefix(3) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let summary = reduce(text, executable: executable, bundleID: bundleID) else { continue }
            // The crash itself must be after that run began, not just the
            // file: a report written late (the app relaunched before
            // ReportCrash finished) belongs to the run before, which was
            // already counted as `unclean`.
            if (summary.crashedAt ?? modified) > date { return summary }
        }
        return nil
    }

    /// One `.ips` file's text to a summary. Pure, so a real report's format is
    /// pinned in `TelemetryTests`. nil for anything that isn't a crash of a
    /// released build of this app: another bundle id (an isolated test copy),
    /// a report kind other than a crash, or no release version (a build from
    /// Xcode, whose offsets no archived dSYM could read).
    static func reduce(_ text: String, executable: String, bundleID: String?) -> Summary? {
        // Two JSON documents: a one-line header, then the body.
        guard let split = text.firstIndex(of: "\n"),
              let header = json(text[..<split]),
              let body = json(text[text.index(after: split)...]),
              header["bug_type"] as? String == "309",
              header["app_name"] as? String == executable
        else { return nil }
        if let bundleID, let signer = body["codeSigningID"] as? String, signer != bundleID { return nil }
        guard let version = CalVer(header["app_version"] as? String) else { return nil }

        let exception = body["exception"] as? [String: Any]
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
            ?? threads.first { $0["triggered"] as? Bool == true }

        // Our binary is the image the header names as the crashed slice.
        let slice = (header["slice_uuid"] as? String)?.lowercased()
        let ours = images.firstIndex { ($0["uuid"] as? String)?.lowercased() == slice }

        var offsets: [CodeOffset] = []
        if let ours, let frames = faulting?["frames"] as? [[String: Any]] {
            for frame in frames where frame["imageIndex"] as? Int == ours {
                guard let raw = (frame["imageOffset"] as? NSNumber)?.uint64Value,
                      let offset = CodeOffset(raw) else { continue }
                if offsets.last != offset { offsets.append(offset) }
            }
        }

        return Summary(signal: CrashSignal(reported: exception?["signal"] as? String),
                       exception: CrashException(reported: exception?["type"] as? String),
                       offsets: offsets,
                       version: version,
                       arch: CrashArch(cpuType: body["cpuType"] as? String),
                       crashedAt: (header["timestamp"] as? String).flatMap(timestamp.date(from:)))
    }

    /// `2026-11-10 19:44:31.00 -0500`, the header's own format.
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter
    }()

    private static func json(_ text: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
