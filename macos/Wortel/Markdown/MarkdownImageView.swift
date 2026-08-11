import AppKit
import SwiftUI

/// One image in a rendered document.
///
/// **Local files only, and that is a decision rather than a limitation.** A
/// Markdown file is often something an agent just wrote, and fetching every
/// image it names would mean opening a document silently makes network requests
/// to whatever hosts it happens to mention — the one thing this app promises it
/// doesn't do. A remote image is shown as a chip that says what it is and opens
/// in the browser, which is a click away rather than a request you didn't make.
///
/// A missing local file gets the same chip: a screenshot that hasn't been taken
/// yet is a normal state for a README being written, and a blank space says
/// nothing about it.
struct MarkdownImageView: View {
    let image: MarkdownImage
    /// The document this image is named relative to.
    let baseURL: URL?
    /// The column the document is set in — a picture never exceeds it.
    let maxWidth: CGFloat
    /// Body type size, so the chip and the caption scale with ⌘+.
    let size: CGFloat
    /// Follows the image's link, or the image itself when it has none.
    let onOpen: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var loaded: NSImage?
    @State private var hovering = false

    /// A `<picture>` gets to be right about which background it is on. Written
    /// for a browser's media query, answered here by the window's own
    /// appearance, so switching the Mac to dark swaps the screenshot.
    private var source: String {
        colorScheme == .dark ? (image.darkSource ?? image.source) : image.source
    }

    /// The file `source` resolves to, or nil if it isn't a local file.
    private var file: URL? { MarkdownLinkTarget.imageFile(source, in: baseURL) }

    var body: some View {
        content
            .onTapGesture { onOpen(image.link ?? source) }
            // The pointing hand the rest of the document's links get. Images are
            // clickable here whether or not the author wrapped one in a link:
            // clicking a screenshot opens it in a window of its own.
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // The stack is lazy, so a hovered image can be *removed* rather than
            // exited — and a push with no pop leaves the pointing hand on screen
            // over a document that has nothing to click.
            .onDisappear {
                if hovering {
                    hovering = false
                    NSCursor.pop()
                }
            }
            .help(image.alt.isEmpty ? source : image.alt)
            .task(id: source) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let loaded, loaded.size.width > 0, loaded.size.height > 0 {
            // Sized here rather than by the layout around it. A resizable image
            // has no size of its own to offer, and this row asks its contents
            // what size they are — left to negotiate, a screenshot comes out as
            // whatever SwiftUI's default for "no opinion" happens to be.
            let factor = min(1, maxWidth / loaded.size.width)
            Image(nsImage: loaded)
                .resizable()
                // Never scaled *up*: a 16pt badge stretched across the column is
                // a wall of blur, and the picture's own size is information.
                .frame(width: (loaded.size.width * factor).rounded(),
                       height: (loaded.size.height * factor).rounded())
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            chip
        }
    }

    /// What stands in for a picture that isn't here: its alt text, which is what
    /// the author wrote for exactly this case.
    private var chip: some View {
        HStack(spacing: (size * 0.35).rounded()) {
            Image(systemName: file == nil ? "photo.on.rectangle" : "photo")
            Text(image.alt.isEmpty ? source : image.alt)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: (size * 0.85).rounded()))
        .foregroundStyle(.secondary)
        .padding(.horizontal, (size * 0.5).rounded())
        .padding(.vertical, (size * 0.3).rounded())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
        .frame(maxWidth: maxWidth, alignment: .leading)
    }

    /// Read off the main thread — a screenshot is a few megabytes, and a
    /// document with several of them would otherwise pause the scroll it appears
    /// in. `NSImage` is built here, on main, from bytes that arrive Sendable.
    private func load() async {
        guard let file else {
            loaded = nil
            return
        }
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: file, options: .mappedIfSafe)
        }.value
        guard let data else {
            loaded = nil
            return
        }
        loaded = NSImage(data: data)
    }
}

/// Lays images out left to right and wraps — a row of badges is a paragraph of
/// pictures, and an `HStack` answers a row too wide for the column by squeezing
/// every badge in it rather than by starting a second line.
struct ImageRowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(widest, width == .infinity ? widest : width), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        var index = 0
        for row in rows(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for _ in 0..<row.count {
                let subview = subviews[index]
                let size = subview.sizeThatFits(.unspecified)
                // Bottom-aligned within the row: badges of different heights sit
                // on one line rather than on a ragged edge.
                subview.place(at: CGPoint(x: x, y: y + row.height - size.height),
                              proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var count = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.count == 0 ? size.width : row.width + spacing + size.width
            if row.count > 0, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.count == 0 ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.count += 1
        }
        if row.count > 0 { rows.append(row) }
        return rows
    }
}
