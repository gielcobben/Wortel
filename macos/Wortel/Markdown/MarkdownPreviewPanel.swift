import SwiftUI

/// The Markdown preview as it sits in the right inspector column: a compact
/// header naming the open file with a close button, then the rendered document.
///
/// Unlike the git panel (which is deliberately headerless so its list runs up
/// under the titlebar), this pane earns a header — the file it's showing and the
/// way back out are exactly what you need when a preview appears from a click in
/// the terminal.
struct MarkdownPreviewPanel: View {
    @Bindable var model: MarkdownPreviewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let document = model.document {
                MarkdownView(blocks: document.blocks)
            } else {
                Spacer()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
            Text(model.document?.name ?? "")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close preview")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
