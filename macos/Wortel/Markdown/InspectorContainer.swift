import SwiftUI

/// What the right inspector column shows: the Markdown preview when a file is
/// open in it, otherwise the source-control panel. The preview takes over the
/// whole column while it's up (rather than adding a second column) — a terminal
/// with two right columns gets cramped fast. The split controller keeps the
/// column open while either wants it.
struct InspectorContainer: View {
    @Bindable var git: GitPanelModel
    @Bindable var markdown: MarkdownPreviewModel

    var body: some View {
        if markdown.isOpen {
            MarkdownPreviewPanel(model: markdown)
        } else {
            SourceControlPanel(panel: git)
        }
    }
}
