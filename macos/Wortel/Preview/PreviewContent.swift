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

    /// Matches the diff in the inspector exactly. A preview that set its own
    /// size would make the same file look like two different files depending on
    /// which half of the app you opened it from.
    private static let fontSize: CGFloat = 12

    var body: some View {
        Group {
            if document.isBinary {
                QuickLook(url: document.url)
            } else {
                switch document.mode {
                case .source: source
                case .diff: diff
                case .rendered: rendered
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { notices }
    }

    @ViewBuilder
    private var source: some View {
        if document.sourceLines.isEmpty {
            empty("Empty file")
        } else {
            DiffView(lines: document.sourceLines,
                     highlights: document.sourceHighlights,
                     fontSize: Self.fontSize)
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
                     fontSize: Self.fontSize)
        }
    }

    @ViewBuilder
    private var rendered: some View {
        if document.blocks.isEmpty {
            empty("Empty document")
        } else {
            MarkdownView(blocks: document.blocks)
        }
    }

    /// The things the window owes the truth about. A strip under the content
    /// rather than a dialog, because neither stops you reading.
    @ViewBuilder
    private var notices: some View {
        let truncated = document.mode == .diff ? document.diffTruncated : document.sourceTruncated
        if document.isMissing || truncated {
            HStack(spacing: 6) {
                Image(systemName: document.isMissing ? "questionmark.circle" : "scissors")
                Text(document.isMissing
                     ? "This file is no longer on disk"
                     : "Showing the first \(PreviewDocument.maxLines) lines")
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

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Anything that isn't text we can show. Quick Look handles images, PDFs, fonts
/// and archives, and it costs a view to ask.
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
