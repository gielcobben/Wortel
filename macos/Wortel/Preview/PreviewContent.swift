import AppKit
import QuickLookUI
import SwiftUI

/// What a preview window draws.
///
/// Source mode is `DiffView` fed an all-context diff, which is the whole trick:
/// the file and its diff are then rendered by one component, so they share a
/// font, a gutter and a scroll feel by construction rather than by maintenance.
struct PreviewContent: View {
    @Bindable var document: PreviewDocument

    var body: some View {
        Group {
            if document.isBinary {
                QuickLook(url: document.url)
            } else if document.lines.isEmpty {
                empty("Empty file")
            } else {
                DiffView(lines: document.lines, highlights: document.highlights, fontSize: 12)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { notices }
    }

    /// The two things the window owes the truth about. Both are quiet — a strip
    /// under the content, not a dialog — because neither stops you reading.
    @ViewBuilder
    private var notices: some View {
        if document.isMissing || document.truncated {
            HStack(spacing: 6) {
                Image(systemName: document.isMissing ? "questionmark.circle" : "scissors")
                Text(document.isMissing
                     ? "This file is no longer on disk"
                     : "Showing the first \(PreviewDocument.maxLines) lines")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Anything that isn't text we can show. Quick Look knows more formats than we
/// ever will — images, PDFs, fonts, archives — and it costs a view to ask.
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
