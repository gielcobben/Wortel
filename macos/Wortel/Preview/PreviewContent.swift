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
    @FocusState private var findFocused: Bool

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
        .safeAreaInset(edge: .top, spacing: 0) { findBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { notices }
        // The bar searches whatever is on screen, so a mode switch re-runs it.
        .onChange(of: document.mode) { _, _ in find.update(lines: searchableLines) }
        .onChange(of: document.sourceLines.count) { _, _ in find.update(lines: searchableLines) }
        .onChange(of: document.diffLines.count) { _, _ in find.update(lines: searchableLines) }
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
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $find.query)
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                    // Enter walks matches without leaving the field, the way
                    // every find bar on the platform does.
                    .onSubmit { find.next() }
                Text(find.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack(spacing: 2) {
                    Button { find.previous() } label: { Image(systemName: "chevron.up") }
                    Button { find.next() } label: { Image(systemName: "chevron.down") }
                }
                .buttonStyle(.borderless)
                .disabled(find.matches.isEmpty)
                Button("Done") { find.dismiss() }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .onExitCommand { find.dismiss() }
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
                     fontSize: settings.fontSize)
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
                     fontSize: settings.fontSize)
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
