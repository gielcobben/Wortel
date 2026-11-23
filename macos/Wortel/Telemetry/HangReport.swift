import Foundation

/// A macOS hang report, reduced to what `app_hung` may carry.
///
/// **Why it exists.** A run that hangs until it is force quit leaves no crash
/// report, so on its own it only ever reads as `previous_exit: unclean`, with
/// nothing to say where. The first one a user sent (2026-11-23, 2026.47.4)
/// had been stuck for twelve and a half hours at 30 GB, with the main thread
/// in SwiftUI's layout, and the only reason anyone knew was that she mailed
/// the report. This is that report, read on the next launch, the way
/// `CrashReport` reads a crash.
///
/// **Where it comes from.** When the person force quits an app that stopped
/// answering, macOS's spindump writes `Wortel_<date>_<host>.hang`: a text
/// report, not the JSON of an `.ips`. Which of the two DiagnosticReports
/// folders it lands in is not pinned here (no hang had happened on the Mac
/// this was written on), so both are read. The system one is readable by an
/// admin user (`_analyticsusers`) and silently skipped otherwise.
///
/// **What survives.** Like a crash report, the file describes the whole Mac:
/// its host name in the file name, every process running, their paths and
/// thread names. Only the first part is read at all (the header and the
/// hung process's own section come first), and out of it come closed sets
/// and numbers: the version, the chip, how long the hang lasted and how much
/// memory the app held (as buckets), what kind of code the main thread was in
/// (`HangActivity`, decided by which *framework* its stack was in, never by
/// a name being passed on), and the offsets of its frames inside Wortel's own
/// binary, which only this build's dSYM can read.
///
/// Off the main thread: it is a file read and a few hundred lines of text.
enum HangReport {
    struct Summary: Equatable {
        let activity: HangActivity
        /// In-binary frames of the main thread's heaviest stack, innermost
        /// first (the same order as a crash's), repeats folded.
        let offsets: [CodeOffset]
        let version: CalVer
        let arch: CrashArch
        let lasted: DurationBucket?
        let memory: MemoryBucket?
        /// When it stopped answering, from the report's header. Not sent: it
        /// ties the report to the run that ended uncleanly.
        let hungAt: Date?

        var event: TelemetryEvent {
            .appHung(activity: activity, site: offsets.first, signature: CrashSignature(offsets: offsets),
                     version: version, arch: arch, lasted: lasted, memory: memory)
        }
    }

    static let directories: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true),
    ]

    /// How much of a report is read. The whole file is ten megabytes and more
    /// (every process on the Mac); everything used here is in its first few
    /// hundred lines, because spindump puts the hung process first.
    static let readLimit = 512 * 1024

    /// The newest hang report of this app that started after `date`, reduced.
    /// nil when there is none: an unclean exit that was not a hang macOS
    /// caught (a `kill -9`, a power cut, a crash it kept no report of).
    ///
    /// **What it proves.** That the run hung at some point and then did not
    /// quit, not that the hang is what ended it: if macOS also keeps reports
    /// of hangs that pass, a short one followed hours later by a power cut
    /// reads the same. `lasted` is what tells the two apart in the numbers.
    static func latest(after date: Date, in directories: [URL] = directories,
                       executable: String = Bundle.main.executableURL?.lastPathComponent ?? "Wortel",
                       bundleID: String? = Bundle.main.bundleIdentifier) -> Summary? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let candidates = directories
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys)) ?? [] }
            .filter { $0.lastPathComponent.hasPrefix(executable + "_") && $0.pathExtension == "hang" }
            .compactMap { url -> (URL, Date)? in
                // Written when the hang ended, which is after the run began.
                guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                      modified > date else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
        for (url, modified) in candidates.prefix(3) {
            guard let text = head(of: url),
                  let summary = reduce(text, executable: executable, bundleID: bundleID) else { continue }
            // The hang has to have begun in that run, not only been written
            // down after it: see `CrashReport.latest(after:)` for the late
            // report that would otherwise be blamed on the next run.
            if (summary.hungAt ?? modified) > date { return summary }
        }
        return nil
    }

    /// One `.hang` file's text (its head is enough) to a summary. Pure, so the
    /// format is pinned in `TelemetryTests`. nil for anything that isn't a hang
    /// of a released build of this app: another bundle id (an isolated test
    /// copy), another event (a spin, a CPU report), no release version, or
    /// another user's process (`/Library/Logs/DiagnosticReports` is shared by
    /// everyone on the Mac).
    static func reduce(_ text: String, executable: String, bundleID: String?,
                       uid: UInt32 = getuid()) -> Summary? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        // The header: `Key:   value` lines up to the first rule. The machine's
        // own architecture comes before `Command:`; the process's after it.
        var header: [String: String] = [:]
        var sawCommand = false
        for line in lines {
            if line.hasPrefix("---") { break }
            guard let (key, value) = field(line) else { continue }
            if key == "Command" { sawCommand = true }
            if key == "Architecture", !sawCommand { continue }
            if header[key] == nil { header[key] = value }
        }
        guard header["Event"] == "hang", header["Command"] == executable else { return nil }
        if let bundleID, let identifier = header["Identifier"], identifier != bundleID { return nil }
        // `2026.47.4 (2026.47.4)`: the marketing version, then the build.
        guard let version = CalVer(header["Version"]?.split(separator: " ").first.map(String.init))
        else { return nil }

        let process = processFields(lines, executable: executable, pid: header["PID"])
        if let owner = process["UID"], owner != String(uid) { return nil }

        let frames = heaviestMainStack(lines)
        var offsets: [CodeOffset] = []
        for frame in frames.reversed() where frame.image == executable {
            guard let offset = CodeOffset(frame.offset) else { continue }
            if offsets.last != offset { offsets.append(offset) }
        }

        return Summary(activity: HangActivity(stack: frames.map { ($0.image, $0.symbol) }, executable: executable),
                       offsets: offsets,
                       version: version,
                       arch: CrashArch(architecture: header["Architecture"]),
                       lasted: lasted(header),
                       memory: process["Footprint"].flatMap(bytes(footprint:)).map(MemoryBucket.init(bytes:)),
                       hungAt: header["Date/Time"].flatMap(date(from:)))
    }

    /// A frame of a spindump stack: `  11  main + 580 (Wortel + 32400) [0x…]`.
    /// The symbol is only ever looked at to decide `HangActivity`.
    struct Frame: Equatable {
        let symbol: String
        let image: String
        let offset: UInt64
    }

    /// "Heaviest stack for the main thread of the target process:", outermost
    /// frame first, up to the blank line that ends it. Kernel frames (`*`) and
    /// lines that aren't frames are left out.
    static func heaviestMainStack(_ lines: [Substring]) -> [Frame] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Heaviest stack for the main thread") })
        else { return [] }
        var frames: [Frame] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if let frame = frame(line) { frames.append(frame) }
        }
        return frames
    }

    /// `  11  symbol + 12 (Image + 345) [0x…] 1-11` to its parts, or nil.
    static func frame(_ line: Substring) -> Frame? {
        let trimmed = line.drop { $0 == " " }
        guard let first = trimmed.first, first.isNumber else { return nil }   // `*` is the kernel
        let afterCount = trimmed.drop { $0.isNumber }.drop { $0 == " " }
        // The image is the `(Image + n)` right before the address. Found from
        // the address, not from the end: a sampled line can end in
        // `(running)`, and a C++ symbol can hold brackets of its own.
        let beforeAddress = afterCount.range(of: " [0x").map { afterCount[..<$0.lowerBound] } ?? afterCount
        guard beforeAddress.hasSuffix(")"),
              let open = beforeAddress.range(of: " (", options: .backwards) else { return nil }
        let inside = beforeAddress[open.upperBound..<beforeAddress.index(before: beforeAddress.endIndex)]
        guard let plus = inside.range(of: " + ", options: .backwards),
              let offset = UInt64(inside[plus.upperBound...]) else { return nil }
        return Frame(symbol: String(beforeAddress[..<open.lowerBound]),
                     image: String(inside[..<plus.lowerBound]),
                     offset: offset)
    }

    /// The `Key: value` lines of the hung process's own section (`Process:
    /// Wortel [pid]`), where its `UID:` and `Footprint:` are. Empty without one.
    static func processFields(_ lines: [Substring], executable: String, pid: String?) -> [String: String] {
        guard let start = lines.firstIndex(where: { line in
            guard let (key, value) = field(line), key == "Process" else { return false }
            return value.hasPrefix(pid.map { "\(executable) [\($0)]" } ?? "\(executable) [")
        }) else { return [:] }
        var fields: [String: String] = [:]
        for line in lines[(start + 1)...] {
            if line.isEmpty { break }
            guard let (key, value) = field(line), fields[key] == nil else { continue }
            fields[key] = value
        }
        return fields
    }

    /// A `Footprint:` in bytes: `30.00 GB`, or, when it moved while it was
    /// sampled, `29.98 GB -> 30.00 GB (+18.2 MB)`, which is read as where it
    /// ended up.
    static func bytes(footprint value: String) -> UInt64? {
        var text = Substring(value)
        if let arrow = text.range(of: "->", options: .backwards) { text = text[arrow.upperBound...] }
        if let paren = text.firstIndex(of: "(") { text = text[..<paren] }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let amount = Double(parts[0]), amount >= 0 else { return nil }
        let unit: Double
        switch parts[1] {
        case "KB": unit = 1_024
        case "MB": unit = 1_048_576
        case "GB": unit = 1_073_741_824
        case "TB": unit = 1_099_511_627_776
        default: return nil
        }
        return UInt64(amount * unit)
    }

    /// How long it was unresponsive: `Duration:`, or failing that the header's
    /// two times. nil rather than a guess, so a format change reads as
    /// `unknown` instead of as a run of short hangs.
    private static func lasted(_ header: [String: String]) -> DurationBucket? {
        if let seconds = seconds(header["Duration"]) { return DurationBucket(seconds: seconds) }
        guard let start = header["Date/Time"].flatMap(date(from:)),
              let end = header["End time"].flatMap(date(from:)), end >= start else { return nil }
        return DurationBucket(seconds: end.timeIntervalSince(start))
    }

    /// `Key:      value` (spindump pads to a column). nil for anything else.
    private static func field(_ line: Substring) -> (String, String)? {
        guard let first = line.first, first != " ", let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard !key.isEmpty, key.count <= 32 else { return nil }
        return (key, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// `44893.65s`
    private static func seconds(_ text: String?) -> TimeInterval? {
        guard let text, text.hasSuffix("s") else { return nil }
        return TimeInterval(text.dropLast())
    }

    /// `2026-11-22 20:08:11.555 +0100`
    private static func date(from text: String) -> Date? {
        for format in ["yyyy-MM-dd HH:mm:ss.SSS Z", "yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// The first `readLimit` bytes, as text. A cut through a multi-byte
    /// character is repaired rather than failing the whole read.
    private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: readLimit), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
