import SwiftUI

/// What the right inspector column shows. Three things share it, and the order
/// here is the precedence:
///
/// 1. the Markdown preview, while a file is open in it — it takes the whole
///    column rather than adding a second one, because a terminal with two right
///    columns gets cramped fast;
/// 2. the file tree, on the Files pane;
/// 3. otherwise the source-control panel.
///
/// The split controller keeps the column open while any of them wants it.
struct InspectorContainer: View {
    @Bindable var git: GitPanelModel
    @Bindable var markdown: MarkdownPreviewModel
    @Bindable var files: FileTreeModel

    var body: some View {
        if markdown.isOpen {
            MarkdownPreviewPanel(model: markdown)
        } else if git.pane == .files {
            FileTreePanel(model: files, focusRequest: git.listFocusRequest)
        } else {
            SourceControlPanel(panel: git)
        }
    }
}
