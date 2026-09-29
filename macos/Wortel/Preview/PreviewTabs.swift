import AppKit
import SwiftUI

/// Files previewed in tabs rather than windows.
///
/// The same document and the same view as a preview window (PreviewDocument,
/// PreviewContent): a tab is a new place to show it, not a new kind of preview.
/// What a window gets from its titlebar (the mode control, the file's name) a
/// tab gets from a slim header of its own, and a tab can still become a window.
///
/// One tab per file: opening a file that's already in a tab brings that tab
/// forward, wherever it is. There is deliberately no "preview tab" that the
/// next file replaces (Xcode's rule): the preview window tried that once and
/// took it out, because "why did this change under me" is the one question a
/// preview must never raise (docs/file-preview.md).
///
/// Documents are made the first time their tab is shown and let go when it
/// closes (or its session does, and no other session has the file open); a
/// document watches its file for as long as it lives, and nothing
/// else. A tab restored after a relaunch has no diff to show (the source it
/// came from was a moment's state) and opens on the file itself.
@MainActor
final class PreviewTabs {
    let settings = PreviewSettings()
    private let highlighter: (any DiffHighlighting)?
    private var documents: [String: Entry] = [:]
    /// Where each file's diff comes from, recorded when it's opened and used
    /// when its document is made.
    private var sources: [String: (diff: PreviewDiffSource, hasChanges: Bool)] = [:]
    /// Open a file a document links to (a link in rendered Markdown).
    var onOpenFile: ((URL) -> Void)?
    /// Turn a tab into a window.
    var onOpenInWindow: ((URL, PreviewDiffSource, Bool) -> Void)?

    private struct Entry {
        let document: PreviewDocument
        let find: PreviewFind
    }

    init(highlighter: (any DiffHighlighting)?) {
        self.highlighter = highlighter
    }

    /// The tab for a file, remembering where its diff comes from.
    func tab(for url: URL, diff: PreviewDiffSource, hasChanges: Bool) -> SideTab {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if documents[path] == nil { sources[path] = (diff, hasChanges) }
        return .file(path)
    }

    /// The document for a file's tab, made on first use.
    func document(for path: String) -> (document: PreviewDocument, find: PreviewFind) {
        if let entry = documents[path] { return (entry.document, entry.find) }
        let url = URL(fileURLWithPath: path)
        let source = sources[path] ?? (.none, false)
        let mode = PreviewMode.inferred(for: url, hasChanges: source.hasChanges,
                                        hasDiffSource: source.diff.exists)
        Telemetry.capture(.previewOpened(mode: PreviewKind(mode)))
        let entry = Entry(
            document: PreviewDocument(url: url, diffSource: source.diff, mode: mode,
                                      highlighter: highlighter),
            find: PreviewFind())
        documents[path] = entry
        return (entry.document, entry.find)
    }

    func hasDocument(for path: String) -> Bool { documents[path] != nil }

    /// A file's tab closed: stop watching it.
    func forget(_ path: String) {
        documents[path] = nil
        sources[path] = nil
    }

    func openInWindow(_ path: String) {
        let source = sources[path] ?? (documents[path]?.document.diffSource ?? .none, false)
        onOpenInWindow?(URL(fileURLWithPath: path), source.diff, source.hasChanges)
    }
}

/// One file's tab: a slim header and the preview itself.
struct PreviewTab: View {
    let tabs: PreviewTabs
    let path: String

    var body: some View {
        let (document, find) = tabs.document(for: path)
        VStack(spacing: 0) {
            PreviewTabHeader(document: document, openInWindow: { tabs.openInWindow(path) })
            PreviewContent(document: document, find: find, settings: tabs.settings,
                           onOpenFile: tabs.onOpenFile)
        }
        // A tab replaces its document when it shows a different file.
        .id(path)
    }
}

/// The header a preview window gets from its titlebar: the file's name (its
/// folder on hover), the mode control when there's a choice, and the way out
/// into a window. Laid out like the source-control tabs' RepoHeader.
private struct PreviewTabHeader: View {
    @Bindable var document: PreviewDocument
    let openInWindow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(document.requestedURL.lastPathComponent)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(document.requestedURL.path)
            Spacer(minLength: 8)
            if document.availableModes.count > 1 {
                ModeSwitch(modes: document.availableModes, selection: $document.mode)
            }
            Button(action: openInWindow) {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverFillStyle())
            .foregroundStyle(.secondary)
            .help("Open in New Window")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 34)
    }
}

/// Diff · Source · Rendered, drawn like the tab rows rather than as a system
/// segmented control: the one in front is a raised pill with a hairline, the
/// rest are quiet text. A blue segmented control was the only accent in the
/// chrome, and it said "control" louder than anything around it.
private struct ModeSwitch: View {
    let modes: [PreviewMode]
    @Binding var selection: PreviewMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.self) { mode in
                let selected = mode == selection
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: Chrome.raised))
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color(nsColor: Chrome.hairlineStrong), lineWidth: 0.5))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: Chrome.hoverFill)))
    }
}

/// A plain button that fills lightly under the pointer, as the titlebar's do.
struct HoverFillStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: configuration.isPressed ? Chrome.selectedFill
                                     : hovering ? Chrome.hoverFill : .clear)))
            .onHover { hovering = $0 }
    }
}
