import AppKit
import Observation
import SwiftUI
import WebKit

/// What the browser tabs have downloaded since launch, and what they are
/// downloading now.
///
/// A download is saved to `~/Downloads`, as Safari saves one, and nothing is
/// ever opened: a page chose the file, so a click that could run it is not
/// Wortel's to make. Until 2026-11-25 a response a tab couldn't show was
/// handed to the default browser, which meant signing in again there to get a
/// file from a site you were signed in to here.
///
/// One list for the app, as Safari has one for all its windows, and kept in
/// memory only: the files stay in the folder, the list is gone after a
/// relaunch. The button that shows it is in a browser tab's header from the
/// first download on (`DownloadsButton`).
///
/// Measured off screen on 2026-11-25, which is why two things are *not* done
/// here: WebKit sets `com.apple.quarantine` on the file itself, and it has
/// already made the server's file name a single path component. A stopped
/// download leaves its partial file behind, so that is removed here.
///
/// A download is written as `<name>.download` and renamed to its name when
/// it has finished, as Safari's are, so a quit, an update's restart or a
/// crash mid-download leaves a file that says it is not whole, never a
/// truncated one under the real name. Measured off screen on 2026-11-27:
/// WebKit has set the quarantine by `downloadDidFinish`, and the rename keeps
/// it. The rename never replaces a file (`RENAME_EXCL`); a name taken in the
/// meantime is numbered.
///
/// A name is taken while a running download holds it, not only once it is
/// on disk: WebKit creates the file a moment after it is given the name,
/// and refuses a destination that exists (measured the same day: it fails
/// and leaves the file alone). Until 2026-11-27 two downloads of one name
/// were both given it, the second failed, and its cleanup deleted the
/// first's file while that row said Done.
@Observable
@MainActor
final class BrowserDownloads: NSObject {
    static let shared = BrowserDownloads()

    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case running
            case done
            /// Why, in the system's words ("The network connection was lost.").
            case failed(String)
            case stopped
        }

        let id: UUID
        /// The file's name as saved, which may be numbered.
        var name: String
        /// Where its bytes are: `<name>.download` while it runs, the file
        /// itself once it is done.
        var file: URL?
        var state: State
        var received: Int64 = 0
        /// nil when the server didn't say.
        var total: Int64?

        /// The line under the name.
        var detail: String {
            switch state {
            case .running:
                guard let total, total > 0 else { return Self.size(received) }
                return "\(Self.size(received)) of \(Self.size(total))"
            case .done: return Self.size(received)
            case .failed(let why): return why
            case .stopped: return "Stopped"
            }
        }

        private static func size(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// Newest first.
    private(set) var items: [Item] = []

    /// `items` is for drawing the list off screen, to look at it; the app's
    /// own list starts empty.
    init(items: [Item] = []) {
        self.items = items
        super.init()
    }

    var isRunning: Bool { items.contains { $0.state == .running } }

    /// How far the running downloads are, together: 0 to 1, or nil when one
    /// of them has a size the server didn't give.
    var fraction: Double? {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return nil }
        var received: Int64 = 0
        var total: Int64 = 0
        for item in running {
            guard let size = item.total, size > 0 else { return nil }
            received += item.received
            total += size
        }
        return min(1, Double(received) / Double(total))
    }

    /// The downloads still running, kept alive here, by their item.
    @ObservationIgnored private var running: [UUID: WKDownload] = [:]
    @ObservationIgnored private var itemOf: [ObjectIdentifier: UUID] = [:]
    /// Only while something is downloading: progress is read a few times a
    /// second rather than observed, so a fast download can't redraw the
    /// header once per chunk.
    @ObservationIgnored private var progressTimer: Timer?

    /// A navigation that became a download: it reports here from now on.
    func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    /// Stop a running download and take its partial file away.
    func stop(_ id: UUID) {
        guard let download = running[id], let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .stopped
        let file = items[index].file
        finished(download)
        download.cancel { _ in
            MainActor.assumeIsolated { BrowserDownloadName.removePartial(file) }
        }
    }

    /// Empty the list of everything that isn't still downloading. The files
    /// stay where they are.
    func clear() {
        items.removeAll { $0.state != .running }
    }

    func showInFinder(_ item: Item) {
        guard let file = item.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Where downloads go: the user's Downloads folder, or a test copy's own
    /// (`BrowserDownloadsFolder`).
    static func folder() -> URL? {
        let folder = BrowserDownloadsFolder.override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let folder else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder
    }

    private func item(of download: WKDownload) -> Int? {
        guard let id = itemOf[ObjectIdentifier(download)] else { return nil }
        return items.firstIndex { $0.id == id }
    }

    /// A download is over, whichever way: let it go.
    private func finished(_ download: WKDownload) {
        if let id = itemOf.removeValue(forKey: ObjectIdentifier(download)) { running[id] = nil }
        if running.isEmpty {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func readProgress() {
        for (id, download) in running {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            let progress = download.progress
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
            if items[index].received != received { items[index].received = received }
            if items[index].total != total { items[index].total = total }
        }
    }

    /// The names running downloads hold, but `except`'s own.
    private func held(except id: UUID? = nil) -> Set<String> {
        Set(items.filter { $0.state == .running && $0.id != id }.map(\.name))
    }

    /// The Dock's Downloads stack bounces for a file it is told about, as it
    /// does for Safari's.
    private static func tellTheDock(_ file: URL) {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"), object: file.path)
    }
}

/// A Debug build saves downloads to the folder `WORTEL_DOWNLOADS_DIR` names,
/// so a test copy never writes into the real Downloads folder or raises the
/// system's "access your Downloads folder" question under its own bundle id.
///
/// Read once, by main.swift, **before** the launch scrub: the app removes
/// every `WORTEL_` variable from its own environment (`InheritedEnvironment`).
/// The first version read the variable when a download started, found
/// nothing, and a test copy stood blocked behind exactly that question
/// (2026-11-25: `sandbox_extension_issue` on the main thread, tccd prompting
/// for `kTCCServiceSystemPolicyDownloadsFolder`).
enum BrowserDownloadsFolder {
    static let override: String? = {
        #if DEBUG
        if let folder = ProcessInfo.processInfo.environment["WORTEL_DOWNLOADS_DIR"], !folder.isEmpty {
            return folder
        }
        #endif
        return nil
    }()
}

extension BrowserDownloads: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let wanted = BrowserDownloadName.cleaned(suggestedFilename)
        guard let folder = Self.folder() else {
            items.insert(Item(id: UUID(), name: wanted, file: nil,
                              state: .failed("The Downloads folder can't be written to.")), at: 0)
            return completionHandler(nil)
        }
        let name = BrowserDownloadName.free(wanted, in: folder, held: held())
        let file = folder.appendingPathComponent(BrowserDownloadName.partial(name))
        let expected = response.expectedContentLength
        let item = Item(id: UUID(), name: name, file: file, state: .running,
                        total: expected > 0 ? expected : nil)
        items.insert(item, at: 0)
        running[item.id] = download
        itemOf[ObjectIdentifier(download)] = item.id
        if progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.readProgress() }
            }
        }
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let index = item(of: download) else { return finished(download) }
        // Whole now: under its own name. Should the rename fail, the
        // `.download` is kept, with every byte, and Show in Finder goes to it.
        if let partial = items[index].file,
           let file = BrowserDownloadName.finish(partial, as: items[index].name, held: held(except: items[index].id)) {
            items[index].file = file
            items[index].name = file.lastPathComponent
        }
        if let file = items[index].file {
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 {
                items[index].received = size
                items[index].total = size
            }
            Self.tellTheDock(file)
        }
        items[index].state = .done
        finished(download)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        defer { finished(download) }
        guard let index = item(of: download) else {
            // It failed before it had a file: still said, by the name it asked for.
            let name = download.originalRequest?.url?.lastPathComponent ?? ""
            items.insert(Item(id: UUID(), name: BrowserDownloadName.cleaned(name), file: nil,
                              state: .failed(error.localizedDescription)), at: 0)
            return
        }
        guard items[index].state == .running else { return }
        items[index].state = .failed(error.localizedDescription)
        BrowserDownloadName.removePartial(items[index].file)
        items[index].file = nil
    }
}

// MARK: - Views

/// The downloads button in a browser tab's header: there once something has
/// been downloaded, a ring filling while something is, and the list on a
/// click. Absent before the first download, since it would have nothing to
/// show.
struct DownloadsButton: View {
    let downloads: BrowserDownloads
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            DownloadsGlyph(isRunning: downloads.isRunning, fraction: downloads.fraction)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle())
        .foregroundStyle(.secondary)
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DownloadsList(downloads: downloads) { isOpen = false }
        }
    }
}

/// An arrow in a circle. While something downloads the circle is a ring that
/// fills, in the glyph's own grey: progress is not a state that needs colour.
struct DownloadsGlyph: View {
    let isRunning: Bool
    let fraction: Double?

    var body: some View {
        if isRunning {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 1.5)
                Circle()
                    // A size the server didn't give: a quarter, to say "going".
                    .trim(from: 0, to: fraction ?? 0.25)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .frame(width: 13.5, height: 13.5)
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 13))
        }
    }
}

/// The list under the button. Laid out as the running-jobs popover is: a
/// small grey heading, a name over a grey line, the row's buttons under the
/// pointer.
struct DownloadsList: View {
    let downloads: BrowserDownloads
    let dismiss: () -> Void

    static let width: CGFloat = 280
    /// About six rows before it scrolls.
    static let maxListHeight: CGFloat = 240
    static let margin: CGFloat = 5
    static let textInset: CGFloat = 10

    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Downloads")
                Spacer(minLength: 8)
                if downloads.items.contains(where: { $0.state != .running }) {
                    ClearButton {
                        downloads.clear()
                        if downloads.items.isEmpty { dismiss() }
                    }
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Self.textInset)
            .padding(.top, 4)
            .padding(.bottom, 3)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(downloads.items) { item in
                        DownloadRow(item: item, isHighlighted: hovered == item.id,
                                    show: {
                                        downloads.showInFinder(item)
                                        dismiss()
                                    },
                                    stop: { downloads.stop(item.id) },
                                    hover: { inside in
                                        if inside {
                                            hovered = item.id
                                        } else if hovered == item.id {
                                            hovered = nil
                                        }
                                    })
                    }
                }
            }
            .frame(maxHeight: Self.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Self.margin)
        .frame(width: Self.width)
    }
}

private struct DownloadRow: View {
    let item: BrowserDownloads.Item
    let isHighlighted: Bool
    let show: () -> Void
    let stop: () -> Void
    let hover: (Bool) -> Void

    /// A file that is there to show.
    private var canShow: Bool { item.state == .done && item.file != nil }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                // Middle, not tail: a file name's end (its number, its
                // extension) is what tells two downloads apart.
                Text(verbatim: item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.name), \(item.detail)")
            .accessibilityAddTraits(canShow ? .isButton : [])
            .accessibilityHint(canShow ? "Shows the file in the Finder" : "")
            .accessibilityAction { if canShow { show() } }

            // Under the pointer only, as the running-jobs rows' are.
            HStack(spacing: 0) {
                if canShow {
                    RowIconButton(symbol: "magnifyingglass", label: "Show in Finder", action: show)
                }
                if item.state == .running {
                    RowIconButton(symbol: "stop.fill", label: "Stop Downloading \(item.name)",
                                  isDestructive: true, action: stop)
                }
            }
            .opacity(isHighlighted ? 1 : 0)
        }
        .padding(.leading, DownloadsList.textInset)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: isHighlighted ? Chrome.hoverFill : .clear))
        }
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
        .onHover { hover($0) }
        // A click shows the file where it is. It never opens it.
        .onTapGesture { if canShow { show() } }
        .help(canShow ? "Show in Finder" : "")
    }
}

/// "Clear", as quiet as the heading it sits in.
private struct ClearButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Clear")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: isHovered ? Chrome.selectedFill : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Empty this list. The files stay in Downloads.")
    }
}
