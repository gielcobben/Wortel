import AppKit
import QuickLookUI
import SwiftUI

/// What a preview window draws, per mode.
///
/// Source and Diff are both `DiffView` — the file is handed over as an
/// all-context diff — so the two share a font, a gutter and a scroll feel by
/// construction rather than by maintenance. Rendered is the same `MarkdownView`
/// the inspector used to host, and anything that isn't text at all goes to Quick
/// Look, which knows more formats than we ever will.
struct PreviewContent: View {
    @Bindable var document: PreviewDocument
    @Bindable var find: PreviewFind
    @Bindable var settings: PreviewSettings
    /// Opens a file this document points at — a link in rendered Markdown — in a
    /// window of its own, through the app's one opener.
    var onOpenFile: ((URL) -> Void)?
    /// Mark-up over this preview (`Wortel/Markup/`), beside its find.
    var markup: MarkupSession?
    @FocusState private var findFocused: Bool
    /// False for a tab kept built behind the one in front (`TabContent`).
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Group {
            if document.isBinary {
                // An image is shown as an image: at its own size, scaled down
                // only when it doesn't fit. Quick Look scales *up* to fill the
                // window, which turns a 16pt icon into a wall of blur.
                if PreviewMode.isImage(document.url) {
                    // The image keeps its size; the space around it is the
                    // view's. Without the frame the whole tab shrinks to the
                    // picture and its header floats down to mid-column with it.
                    ImagePreview(url: document.url, version: document.contentVersion, markup: markup?.views)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    QuickLook(url: document.url)
                }
            } else {
                switch document.mode {
                case .source: source
                case .diff: diff
                case .rendered: rendered
                }
            }
        }
        // The marks and the note, over the content and under the find bar.
        // Not over a tab kept built behind the one in front.
        .overlay {
            if let markup, isEnabled, markup.isShown(over: document) {
                MarkupOverlayHost(session: markup)
            }
        }
        // Nothing left to mark: the marks' rows or blocks went with it.
        .onChange(of: document.markupPlace) { _, place in
            if place == nil { markup?.views.emptied() }
        }
        .safeAreaInset(edge: .top, spacing: 0) { findBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { notices }
        // The bar searches whatever is on screen, so a mode switch re-runs it.
        .onChange(of: document.mode) { _, _ in
            find.update(lines: searchableLines)
            // Another view of the file: the marks were on the one before.
            markup?.end()
        }
        .onChange(of: document.sourceLines.count) { _, _ in find.update(lines: searchableLines) }
        .onChange(of: document.diffLines.count) { _, _ in find.update(lines: searchableLines) }
        // Hidden behind another tab: the find field gives up the keyboard, or
        // typing would go on into a field nobody can see.
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { findFocused = false }
        }
        .onChange(of: find.isPresented) { _, presented in
            if presented {
                find.update(lines: searchableLines)
                findFocused = true
            }
        }
    }

    /// What ⌘F searches: the lines the window is actually showing. Rendered
    /// Markdown has no lines to point at, so the bar doesn't open over it.
    private var searchableLines: [DiffLine] {
        switch document.mode {
        case .source: return document.sourceLines
        case .diff: return document.diffLines
        case .rendered: return []
        }
    }

    @ViewBuilder
    private var findBar: some View {
        if find.isPresented {
            FindBar(query: $find.query, summary: find.summary, canStep: !find.matches.isEmpty,
                    focused: $findFocused, next: find.next, previous: find.previous,
                    dismiss: find.dismiss)
        }
    }

    @ViewBuilder
    private var source: some View {
        if document.sourceLines.isEmpty {
            empty("Empty file")
        } else {
            DiffView(lines: document.sourceLines,
                     highlights: document.sourceHighlights,
                     focusedLine: find.focusedLine,
                     fontSize: settings.fontSize,
                     gutter: .file,
                     anchorLine: document.anchorLine,
                     anchorOffset: document.anchorOffset,
                     onTopLine: { document.visibleLine = $0; document.visibleOffset = $1 },
                     reveal: document.lineReveal,
                     onRevealed: { document.revealDone($0) },
                     onSelectLine: { document.selectedLine = $0 },
                     markup: markup?.views)
        }
    }

    @ViewBuilder
    private var diff: some View {
        if !document.diffLoaded {
            // Deliberately blank rather than a spinner: the diff arrives in a
            // few milliseconds, and a spinner that flashes for one frame reads
            // as jank rather than as progress.
            Color.clear
        } else if document.diffIsBinary {
            empty("Binary file")
        } else if document.diffLines.isEmpty {
            empty("No changes to this file")
        } else {
            DiffView(lines: document.diffLines,
                     highlights: document.diffHighlights,
                     focusedLine: find.focusedLine,
                     fontSize: settings.fontSize,
                     anchorLine: document.anchorLine,
                     anchorOffset: document.anchorOffset,
                     onTopLine: { document.visibleLine = $0; document.visibleOffset = $1 },
                     reveal: document.lineReveal,
                     onRevealed: { document.revealDone($0) },
                     onSelectLine: { document.selectedLine = $0 },
                     markup: markup?.views)
        }
    }

    @ViewBuilder
    private var rendered: some View {
        if PreviewMode.isSVG(document.url) {
            // The picture the code makes. NSImage renders SVG as vector, so it's
            // sharp at any size rather than a bitmap of one.
            ImagePreview(url: document.url, version: document.contentVersion, markup: markup?.views)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if document.blocks.isEmpty {
            empty("Empty document")
        } else {
            // Rendered text has a type *scale*, not a font size — headings and
            // code sit in fixed proportion to the body. So ⌘+ moves the whole
            // sheet by the ratio the source view is running at.
            MarkdownView(blocks: document.blocks,
                         scale: settings.fontSize / PreviewSettings.defaultFontSize,
                         isSelected: document.selectsAll,
                         anchorLine: document.anchorLine,
                         anchorOffset: document.anchorOffset,
                         onTopLine: { document.visibleLine = $0; document.visibleOffset = $1 },
                         reveal: document.lineReveal,
                         onRevealed: { document.revealDone($0) },
                         // A document's links and images are relative to where
                         // the file *is*, and this is the only view that knows.
                         baseURL: document.url,
                         onOpenFile: onOpenFile,
                         markup: markup?.views,
                         reportsFrames: markup?.isOn == true && isEnabled)
                .onExitCommand { document.selectsAll = false }
        }
    }

    /// The things the window owes the truth about. A strip under the content
    /// rather than a dialog, because neither stops you reading.
    @ViewBuilder
    private var notices: some View {
        let truncated = document.mode == .diff ? document.diffTruncated : document.sourceTruncated
        if document.isMissing || truncated || document.isAlias {
            HStack(spacing: 6) {
                Image(systemName: noticeSymbol(truncated: truncated))
                Text(noticeText(truncated: truncated))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func noticeSymbol(truncated: Bool) -> String {
        if document.isMissing { return "questionmark.circle" }
        if truncated { return "scissors" }
        return "arrow.up.forward"
    }

    /// One strip, in order of urgency: gone, cut short, or somewhere else. An
    /// alias is the mildest — it's not a problem, it's a fact you'd otherwise
    /// have to discover by editing the wrong copy.
    private func noticeText(truncated: Bool) -> String {
        if document.isMissing { return "This file is no longer on disk" }
        if truncated { return "Showing the first \(PreviewDocument.maxLines) lines" }
        return "Alias. The file is at "
            + document.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An image at its own size.
///
/// `.scaleProportionallyDown` is the whole point: it fits an image too big for
/// the window and leaves everything else exactly as authored. A 16×16 icon
/// should look like a 16×16 icon — blown up to 700pt it tells you nothing about
/// itself except that it's blurry.
///
/// A transparent PNG on a transparent background is an invisible PNG, so the
/// picture gets a backing. Resolved again whenever the appearance changes: a
/// `cgColor` is a fixed colour, and one taken when the view was made kept the
/// light backing after the Mac went dark.
private final class BackedImageView: NSImageView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBacking()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBacking()
    }

    private func applyBacking() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        }
    }
}

private struct ImagePreview: NSViewRepresentable {
    let url: URL
    /// Changes only when the file does — see `PreviewDocument.contentVersion`.
    let version: Int
    /// Where mark-up finds this picture (`MarkupViews`).
    var markup: MarkupViews?

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var loaded: Int? }

    func makeNSView(context: Context) -> NSImageView {
        let view = BackedImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        // An image view resists being made smaller than its image. Left at the
        // default it wins that argument and the picture is clipped by the window
        // rather than fitted to it.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
            view.setContentHuggingPriority(.defaultLow, for: axis)
        }
        view.image = NSImage(contentsOf: url)
        context.coordinator.loaded = version
        register(view)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        register(view)
        // Re-read rather than trusting NSImage's URL cache — an agent rewriting
        // an icon has to redraw here — but only when the file actually moved.
        guard context.coordinator.loaded != version else { return }
        context.coordinator.loaded = version
        view.image = NSImage(contentsOf: url)
        markup?.changed()
    }

    private func register(_ view: NSImageView) {
        guard let markup, markup.image !== view else { return }
        markup.image = view
        markup.changed()
    }

    /// Fit if it's too big, natural size if it isn't.
    ///
    /// `.scaleProportionallyDown` already says that, and says it about the
    /// *drawing* — but the view still asks for its image's full size, and an
    /// `NSViewRepresentable` that asks for more than it's offered simply
    /// overflows. So the size has to be negotiated here: never above 1, so a
    /// 16pt icon stays a 16pt icon, and clamped to whichever axis runs out
    /// first, so a wide screenshot fits the width and a tall one the height.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSImageView, context: Context
    ) -> CGSize? {
        guard let natural = nsView.image?.size,
              natural.width > 0, natural.height > 0 else { return nil }
        let available = CGSize(width: proposal.width ?? natural.width,
                               height: proposal.height ?? natural.height)
        let factor = min(1, available.width / natural.width, available.height / natural.height)
        return CGSize(width: (natural.width * factor).rounded(),
                      height: (natural.height * factor).rounded())
    }
}

/// Anything that isn't text we can show. Quick Look handles PDFs, fonts and
/// archives, and it costs a view to ask.
private struct QuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }
}
