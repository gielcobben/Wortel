import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where a note's pictures and its details file go, and when they are
/// removed.
///
/// In the app's cache folder, a folder per note under the day it was made:
/// `…/Caches/<bundle id>/Markup/2026-11-25/3/1.png`. A path with no space
/// in it, in a folder macOS asks no permission for and does not empty by
/// itself, so an agent in any session reads it the way it reads a pasted
/// image. A test copy has a bundle id of its own, so a folder of its own.
///
/// A note's folder is removed seven days after anything was last written to
/// it. A pasted image goes after one (`DropPasteboard`), because its path is
/// typed straight into a prompt. A note is copied, and what is copied may be
/// pasted later: on Monday, for a note made on Friday.
struct MarkupStore {
    let root: URL

    /// How long a note's folder is kept after its last write.
    static let keptFor: TimeInterval = 7 * 24 * 60 * 60

    static let shared = MarkupStore(root: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "sh.wortel", isDirectory: true)
        .appendingPathComponent("Markup", isDirectory: true))

    /// Everything written here goes through one queue, in order, so a
    /// picture asked for before the details file is on disk before it.
    static let queue = DispatchQueue(label: "sh.wortel.markup", qos: .userInitiated)

    /// A new folder for a note: the day, then one more than the highest
    /// number there. Made with a plain `mkdir`, which fails when the folder
    /// exists, so two notes started in the same moment never share one.
    func newFolder(now: Date = Date(), calendar: Calendar = .current) -> URL? {
        let day = root.appendingPathComponent(Self.dayName(now, calendar: calendar), isDirectory: true)
        let files = FileManager.default
        do {
            try files.createDirectory(at: day, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let taken = ((try? files.contentsOfDirectory(atPath: day.path)) ?? []).compactMap { Int($0) }
        var number = (taken.max() ?? 0) + 1
        for _ in 0..<50 {
            let folder = day.appendingPathComponent(String(number), isDirectory: true)
            if (try? files.createDirectory(at: folder, withIntermediateDirectories: false)) != nil {
                return folder
            }
            number += 1
        }
        return nil
    }

    static func dayName(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Remove every note's folder nothing was written to for `age`, and a
    /// day's folder once it is empty. `keeping` are the folders of notes
    /// still open, which stay however old.
    ///
    /// Removed, not moved to the Trash: Wortel made these files, and a Trash
    /// filling with screenshots is nothing anyone would put back.
    func sweep(olderThan age: TimeInterval = MarkupStore.keptFor, keeping: Set<String> = [],
               now: Date = Date()) {
        let files = FileManager.default
        let cutoff = now.addingTimeInterval(-age)
        guard let days = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for day in days where Self.isFolder(day) {
            let notes = (try? files.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []
            for note in notes where Self.isFolder(note) {
                guard !keeping.contains(note.standardizedFileURL.path),
                      Self.lastWrite(in: note) < cutoff else { continue }
                try? files.removeItem(at: note)
            }
            if ((try? files.contentsOfDirectory(atPath: day.path)) ?? []).isEmpty {
                try? files.removeItem(at: day)
            }
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// The newest date among a folder and what is in it. The folder's own
    /// date moves when a file is added, not when one is rewritten.
    private static func lastWrite(in folder: URL) -> Date {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        var newest = (try? folder.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
        let inside = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        for file in inside {
            if let date = try? file.resourceValues(forKeys: keys).contentModificationDate, date > newest {
                newest = date
            }
        }
        return newest
    }

    /// Write a picture as a PNG. Called on `queue`.
    @discardableResult
    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
